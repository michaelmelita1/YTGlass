// AiSList
// Removes AI-generated channels from feeds and search, using the AiSList blocklist and warnlist
// (https://aisloplist.com, https://github.com/Override92/AiSList, CC BY-NC 4.0; downloaded unmodified, only read).
// Ported from YTKACE (https://github.com/itzzace/ytkace) v1.1.3, Tweak/Features/Interface/AiSList.mm and the AiSList
// part of ContentVisibilityHooks.mm. MIT License, Copyright (c) 2026 YTKACE contributors. See LICENSE.
//
// How: the lists (channel handles "@name" and channel IDs "UC...") are downloaded every 4 hours and cached. Feed
// sections reach YouTube's YTInnerTubeCollectionViewController (addSectionsFromArray: and
// sectionControllersForSectionRenderers:reloadingSectionControllerByRenderer:); each section's serialized protobuf
// (-data) is scanned for handles and channel IDs, and sections (or single entries of a shelf) from a listed channel
// are left out.
//
// Pure Objective-C runtime swizzling: no CydiaSubstrate / ElleKit dependency.

#import "Common.h"
#import <os/lock.h>

static NSString *const ASBlockURL = @"https://raw.githubusercontent.com/Override92/AiSList/main/AiSList/aislist_blocklist.txt";
static NSString *const ASWarnURL = @"https://raw.githubusercontent.com/Override92/AiSList/main/AiSList/aislist_warnlist.txt";
static NSString *const ASFetchedKey = @"YTGlass_AiSListFetched";
static NSTimeInterval const ASMaxAge = 4 * 60 * 60;

static BOOL ASBlocklist, ASWarnlist; // read at launch

static os_unfair_lock ASLock = OS_UNFAIR_LOCK_INIT;
static NSSet<NSString *> *ASBlock, *ASWarn;

#pragma mark - The lists

static NSURL *ASFile(NSString *name) {
    NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [base URLByAppendingPathComponent:@"YTGlass" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return [directory URLByAppendingPathComponent:name];
}

static NSSet<NSString *> *ASParse(NSString *text) {
    NSMutableSet<NSString *> *entries = [NSMutableSet set];
    [text enumerateLinesUsingBlock:^(NSString *line, __unused BOOL *stop) {
        NSString *entry = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (entry.length < 3 || [entry hasPrefix:@"!"]) return; // "!" starts a comment
        if ([entry hasPrefix:@"@"]) [entries addObject:entry.lowercaseString];
        else if ([entry hasPrefix:@"UC"] && entry.length == 24) [entries addObject:entry];
    }];
    return entries;
}

static void ASLoadCached(void) {
    NSString *block = [NSString stringWithContentsOfURL:ASFile(@"aislist_blocklist.txt") encoding:NSUTF8StringEncoding error:nil];
    NSString *warn = [NSString stringWithContentsOfURL:ASFile(@"aislist_warnlist.txt") encoding:NSUTF8StringEncoding error:nil];
    NSSet *blockSet = block.length ? ASParse(block) : nil, *warnSet = warn.length ? ASParse(warn) : nil;
    os_unfair_lock_lock(&ASLock);
    if (blockSet) ASBlock = blockSet;
    if (warnSet) ASWarn = warnSet;
    os_unfair_lock_unlock(&ASLock);
}

static NSData *ASDownload(NSString *address) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
    request.timeoutInterval = 30.0;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *body = nil;
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, __unused NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (status == 200 && data.length && data.length < 8 * 1024 * 1024) body = data;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(35 * NSEC_PER_SEC)));
    return body;
}

// The cached lists straight away, fresh ones from GitHub when they're over 4 hours old (in the background).
static void ASRefresh(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ASLoadCached();
        double last = [NSUserDefaults.standardUserDefaults doubleForKey:ASFetchedKey];
        os_unfair_lock_lock(&ASLock);
        BOOL empty = (ASBlocklist && ASBlock == nil) || (ASWarnlist && ASWarn == nil); // a list switched on for the first time
        os_unfair_lock_unlock(&ASLock);
        if (!empty && NSDate.date.timeIntervalSince1970 - last <= ASMaxAge) return;
        NSData *block = ASBlocklist ? ASDownload(ASBlockURL) : nil;
        NSData *warn = ASWarnlist ? ASDownload(ASWarnURL) : nil;
        if (block) [block writeToURL:ASFile(@"aislist_blocklist.txt") atomically:YES];
        if (warn) [warn writeToURL:ASFile(@"aislist_warnlist.txt") atomically:YES];
        if (block || warn) {
            [NSUserDefaults.standardUserDefaults setDouble:NSDate.date.timeIntervalSince1970 forKey:ASFetchedKey];
            ASLoadCached();
        }
    });
}

#pragma mark - Matching

static BOOL ASHandleByte(unsigned char byte) {
    return isalnum(byte) || byte == '_' || byte == '-' || byte == '.' || byte >= 0x80;
}

// Handles and channel IDs found in a section's protobuf bytes: an "@handle" is a length-delimited string (or follows
// "/" in a URL); a channel ID is 24 characters starting with "UC". A section naming more than one channel (a mixed
// shelf) is never matched as a whole.
static BOOL ASMatches(NSData *bytes) {
    if (bytes.length == 0) return NO;
    os_unfair_lock_lock(&ASLock);
    NSSet<NSString *> *block = ASBlocklist ? ASBlock : nil, *warn = ASWarnlist ? ASWarn : nil;
    os_unfair_lock_unlock(&ASLock);
    if (block.count == 0 && warn.count == 0) return NO;
    const unsigned char *raw = bytes.bytes;
    NSUInteger length = bytes.length;
    NSMutableSet<NSString *> *handles = [NSMutableSet set], *channels = [NSMutableSet set];
    for (NSUInteger i = 2; i < length; i++) {
        if (raw[i] == '@') {
            NSUInteger size = 0;
            if (raw[i - 1] == '/' && i >= 3 && (raw[i - 3] & 0x07) == 2) size = (NSUInteger)raw[i - 2] - 1;
            else if ((raw[i - 2] & 0x07) == 2) size = raw[i - 1];
            if (size < 4 || size > 100 || i + size > length) continue;
            BOOL valid = YES;
            for (NSUInteger k = i + 1; k < i + size && valid; k++) valid = ASHandleByte(raw[k]);
            NSString *handle = valid ? [[NSString alloc] initWithBytes:raw + i length:size encoding:NSUTF8StringEncoding] : nil;
            if (handle) [handles addObject:handle.lowercaseString];
        } else if (raw[i] == 'U' && i + 24 <= length && raw[i + 1] == 'C' && (raw[i - 1] == 24 || raw[i - 1] == '/')) {
            BOOL valid = YES;
            for (NSUInteger k = i + 2; k < i + 24 && valid; k++) valid = isalnum(raw[k]) || raw[k] == '_' || raw[k] == '-';
            NSString *channel = valid ? [[NSString alloc] initWithBytes:raw + i length:24 encoding:NSASCIIStringEncoding] : nil;
            if (channel) [channels addObject:channel];
        }
    }
    if (channels.count > 1) return NO;
    for (NSSet<NSString *> *candidates in @[handles, channels]) {
        for (NSString *candidate in candidates) {
            if ([block containsObject:candidate] || [warn containsObject:candidate]) return YES;
        }
    }
    return NO;
}

#pragma mark - Feed sections

static id ASChild(id object, SEL selector) {
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(object, selector); } @catch (__unused NSException *e) { return nil; }
}

static const void *ASBytesKey = &ASBytesKey; // renderer -> its serialized bytes (empty NSData for none)
static const void *ASResultKey = &ASResultKey; // section -> @YES/@NO: from a listed channel

static NSData *ASBytes(id object) {
    NSData *cached = objc_getAssociatedObject(object, ASBytesKey);
    if (cached) return cached.length ? cached : nil;
    id data = ASChild(object, @selector(data));
    if (![data isKindOfClass:NSData.class]) data = nil;
    objc_setAssociatedObject(object, ASBytesKey, data ?: [NSData data], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return data;
}

// Sections that don't serialize themselves: the bytes of their first entries (12 at most in all: each is serialized
// on the main thread as the feed loads).
static NSData *ASDescendantBytes(id section) {
    static SEL containers[8];
    if (containers[0] == NULL) {
        NSArray<NSString *> *names = @[@"contentsArray", @"itemsArray", @"content", @"elementRenderer", @"shelfRenderer",
                                      @"horizontalListRenderer", @"itemSectionRenderer", @"expandedShelfContentsRenderer"];
        for (NSUInteger i = 0; i < 8; i++) containers[i] = NSSelectorFromString(names[i]);
    }
    NSMutableData *combined = nil;
    NSUInteger taken = 0;
    for (NSUInteger i = 0; i < 8 && taken < 12; i++) {
        id child = ASChild(section, containers[i]);
        if (child == nil) continue;
        for (id entry in [child isKindOfClass:NSArray.class] ? child : @[child]) {
            if (taken++ >= 12) break;
            NSData *bytes = ASBytes(entry);
            if (bytes.length == 0) continue;
            if (combined == nil) combined = [NSMutableData data];
            [combined appendData:bytes];
        }
    }
    return combined;
}

// Whether the whole section is from a listed channel. If not, entries of a shelf that are get removed from it (unless
// that would empty it, which makes the whole section a match).
static BOOL ASSectionIsListed(id section) {
    NSNumber *known = objc_getAssociatedObject(section, ASResultKey);
    if (known) return known.boolValue;
    NSData *bytes = ASBytes(section) ?: ASDescendantBytes(section);
    BOOL hit = ASMatches(bytes);
    if (!hit) {
        id contents = ASChild(section, NSSelectorFromString(@"contentsArray"));
        if ([contents isKindOfClass:NSMutableArray.class] && [contents count] > 1) {
            NSIndexSet *drop = [(NSArray *)contents indexesOfObjectsPassingTest:^BOOL(id entry, __unused NSUInteger index, __unused BOOL *stop) {
                return ASMatches(ASBytes(entry));
            }];
            if (drop.count == [contents count]) hit = YES;
            else if (drop.count) [(NSMutableArray *)contents removeObjectsAtIndexes:drop];
        }
    }
    objc_setAssociatedObject(section, ASResultKey, @(hit), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return hit;
}

static NSArray *ASFiltered(NSArray *sections) {
    if (![sections isKindOfClass:NSArray.class] || sections.count == 0) return sections;
    os_unfair_lock_lock(&ASLock);
    BOOL ready = ASBlock.count != 0 || ASWarn.count != 0;
    os_unfair_lock_unlock(&ASLock);
    if (!ready) return sections;
    NSIndexSet *drop = [sections indexesOfObjectsPassingTest:^BOOL(id section, __unused NSUInteger index, __unused BOOL *stop) {
        return ASSectionIsListed(section);
    }];
    if (drop.count == 0) return sections;
    NSMutableArray *kept = [sections mutableCopy];
    [kept removeObjectsAtIndexes:drop];
    return kept;
}

static IMP OriginalAddSections, OriginalSectionControllers;

static void ASAddSections(id self, SEL _cmd, NSArray *sections) {
    ((void (*)(id, SEL, id))OriginalAddSections)(self, _cmd, ASFiltered(sections));
}

static id ASSectionControllers(id self, SEL _cmd, NSArray *sections, id reloadMap) {
    return ((id (*)(id, SEL, id, id))OriginalSectionControllers)(self, _cmd, ASFiltered(sections), reloadMap);
}

__attribute__((constructor)) static void ASInit(void) {
    ASBlocklist = YTGOptInEnabled(YTGHideAIKey);
    ASWarnlist = YTGOptInEnabled(YTGHideSuspectedAIKey);
    if (!ASBlocklist && !ASWarnlist) return;
    @autoreleasepool {
        ASRefresh();
        Class controller = NSClassFromString(@"YTInnerTubeCollectionViewController");
        TBHHookMethod(controller, @"addSectionsFromArray:", (IMP)ASAddSections, &OriginalAddSections);
        TBHHookMethod(controller, @"sectionControllersForSectionRenderers:reloadingSectionControllerByRenderer:", (IMP)ASSectionControllers, &OriginalSectionControllers);
    }
}
