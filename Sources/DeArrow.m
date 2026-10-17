// DeArrow
// Replaces feed titles and thumbnails with DeArrow's community ones (https://dearrow.ajay.app). Ported from YTKACE
// (https://github.com/itzzace/ytkace) v1.1.3, Tweak/Features/SponsorBlock/DeArrow.mm. MIT License, Copyright (c) 2026
// YTKACE contributors. DeArrow data is provided by the SponsorBlock service under CC BY-NC-SA 4.0. See LICENSE.
//
// How: feed thumbnails are ELMImageNodes, loaded through downloadImageWithURL:... or cachedImageWithURL:...; the
// video ID is read from the thumbnail URL (/vi/<id>/). DeArrow's branding API gives a title and a thumbnail time for
// it; the thumbnail is fetched from DeArrow's thumbnail server and set on the node, and the title replaces the card's
// title text node (the second-to-last ELMTextNode of the ELMCellNode, the last being the duration). Results are kept
// in NSUserDefaults (newest 800), with at most 4 requests at once and 90 a minute.
//
// Pure Objective-C runtime swizzling: no CydiaSubstrate / ElleKit dependency.

#import "Common.h"
#import <os/lock.h>

static NSString *const DAStoreKey = @"YTGlass_DeArrowBranding";

static NSUInteger const DAStoreLimit = 800;
static NSUInteger const DAMaxConcurrent = 4;
static NSUInteger const DARequestsPerMinute = 90;
static NSUInteger const DAPendingLimit = 300;
static NSUInteger const DAAncestorDepth = 12;
static NSUInteger const DACellTextDepth = 10;
static NSUInteger const DAMaxCellText = 10;
static NSTimeInterval const DANegativeTTL = 7 * 24 * 60 * 60; // videos without DeArrow data are asked again after a week
static NSInteger const DAStoreVersion = 2;

static IMP OriginalDownloadImage, OriginalCachedImage, OriginalApplyProperties;

static const void *DANodeVideoKey = &DANodeVideoKey; // image node -> video ID
static const void *DACellVideoKey = &DACellVideoKey; // cell node -> video ID
static const void *DATitleVideoKey = &DATitleVideoKey; // title text node -> video ID (its title is ours)

static BOOL DATitles, DAThumbnails; // read at launch

static os_unfair_lock DALock = OS_UNFAIR_LOCK_INIT;
static NSUInteger DAActiveRequests, DAWindowCount;
static NSTimeInterval DAWindowStart;
static NSMutableSet<NSString *> *DAInFlight, *DAThumbInFlight;
static NSMutableArray<NSString *> *DAPendingIDs;
static NSMapTable *DAPendingNodes, *DAPendingCells;
static NSMutableDictionary<NSString *, NSDictionary *> *DAStore; // video ID -> a: added, v: version, t: time, ti: title
static NSCache<NSString *, UIImage *> *DAImageCache;

static void DAPumpQueue(void);
static void DAApplyTitleToCell(id root, NSString *videoID);

static id DASend(id object, SEL selector) {
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(object, selector); } @catch (__unused NSException *e) { return nil; }
}

static NSString *DANodeText(id node) {
    id value = DASend(node, NSSelectorFromString(@"attributedText"));
    if ([value isKindOfClass:NSAttributedString.class]) return ((NSAttributedString *)value).string;
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static id DACellRoot(id node) {
    static Class cellClass;
    if (cellClass == Nil) cellClass = NSClassFromString(@"ELMCellNode");
    if (cellClass == Nil) return nil;
    SEL supernode = NSSelectorFromString(@"supernode");
    id current = node;
    for (NSUInteger level = 0; level < DAAncestorDepth && current != nil; level++) {
        if ([current isKindOfClass:cellClass]) return current;
        current = DASend(current, supernode);
    }
    return nil;
}

static NSString *DAVideoIDFromURL(id URL) {
    NSString *absolute = [URL isKindOfClass:NSURL.class] ? ((NSURL *)URL).absoluteString
                       : [URL isKindOfClass:NSString.class] ? URL : DASend(URL, @selector(absoluteString));
    if (![absolute isKindOfClass:NSString.class]) return nil;
    // .../vi/<11-character id>/... or .../vi_webp/<id>/... (every image in the feed comes through here: no regex)
    NSRange marker = [absolute rangeOfString:@"/vi/"];
    if (marker.location == NSNotFound) marker = [absolute rangeOfString:@"/vi_webp/"];
    if (marker.location == NSNotFound) return nil;
    NSUInteger start = NSMaxRange(marker);
    if (start + 12 > absolute.length || [absolute characterAtIndex:start + 11] != '/') return nil;
    for (NSUInteger i = start; i < start + 11; i++) {
        unichar c = [absolute characterAtIndex:i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-')) return nil;
    }
    return [absolute substringWithRange:NSMakeRange(start, 11)];
}

#pragma mark - Store

static void DALoadStore(void) {
    if (DAStore != nil) return;
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:DAStoreKey];
    DAStore = [stored isKindOfClass:NSDictionary.class] ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    DAImageCache = [NSCache new];
    DAImageCache.countLimit = 160;
    DAInFlight = [NSMutableSet set];
    DAThumbInFlight = [NSMutableSet set];
    DAPendingIDs = [NSMutableArray array];
    DAPendingNodes = [NSMapTable strongToWeakObjectsMapTable];
    DAPendingCells = [NSMapTable strongToWeakObjectsMapTable];
}

static void DAEvictLocked(void) {
    if (DAStore.count <= DAStoreLimit) return;
    NSArray<NSString *> *ordered = [DAStore.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        return [DAStore[left][@"a"] compare:DAStore[right][@"a"]];
    }];
    NSUInteger drop = MIN(ordered.count, DAStore.count - DAStoreLimit * 3 / 4);
    for (NSUInteger index = 0; index < drop; index++) [DAStore removeObjectForKey:ordered[index]];
}

// Saved a few seconds after the last change (not once per lookup: the whole store is rewritten each time).
static void DAPersistStore(void) {
    static BOOL scheduled;
    os_unfair_lock_lock(&DALock);
    BOOL already = scheduled;
    scheduled = YES;
    os_unfair_lock_unlock(&DALock);
    if (already) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        os_unfair_lock_lock(&DALock);
        scheduled = NO;
        DAEvictLocked();
        NSDictionary *snapshot = [DAStore copy];
        os_unfair_lock_unlock(&DALock);
        if (snapshot) [NSUserDefaults.standardUserDefaults setObject:snapshot forKey:DAStoreKey];
    });
}

static NSDictionary *DAFreshEntryLocked(NSString *videoID) {
    NSDictionary *entry = DAStore[videoID];
    if (entry == nil) return nil;
    if ([entry[@"v"] integerValue] < DAStoreVersion) {
        [DAStore removeObjectForKey:videoID];
        return nil;
    }
    if (entry[@"t"] != nil || entry[@"ti"] != nil) return entry;
    if (NSDate.date.timeIntervalSince1970 - [entry[@"a"] doubleValue] > DANegativeTTL) {
        [DAStore removeObjectForKey:videoID];
        return nil;
    }
    return entry;
}

static void DAStoreBranding(NSString *videoID, NSNumber *timestamp, NSString *title) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithDictionary:@{ @"a": @(NSDate.date.timeIntervalSince1970), @"v": @(DAStoreVersion) }];
    if (timestamp) entry[@"t"] = timestamp;
    if (title.length) entry[@"ti"] = title;
    os_unfair_lock_lock(&DALock);
    DAStore[videoID] = entry;
    [DAInFlight removeObject:videoID];
    if (DAActiveRequests > 0) DAActiveRequests--;
    os_unfair_lock_unlock(&DALock);
    DAPersistStore();
    DAPumpQueue();
}

static NSString *DAStoredTitle(NSString *videoID) {
    if (videoID.length == 0) return nil;
    os_unfair_lock_lock(&DALock);
    id title = DAStore[videoID][@"ti"];
    os_unfair_lock_unlock(&DALock);
    return [title isKindOfClass:NSString.class] ? title : nil;
}

#pragma mark - Thumbnails

static void DAApplyImage(id node, NSString *videoID, UIImage *image) {
    if (node == nil || image == nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![objc_getAssociatedObject(node, DANodeVideoKey) isEqual:videoID]) return; // the node shows another video now
        SEL setter = NSSelectorFromString(@"setImage:");
        if (![node respondsToSelector:setter]) return;
        @try { ((void (*)(id, SEL, id))objc_msgSend)(node, setter, image); } @catch (__unused NSException *e) {}
    });
}

static void DAFetchThumbnail(NSString *videoID, double timestamp, id node) {
    if (!DAThumbnails) return;
    os_unfair_lock_lock(&DALock);
    BOOL busy = [DAThumbInFlight containsObject:videoID];
    if (!busy) [DAThumbInFlight addObject:videoID];
    os_unfair_lock_unlock(&DALock);
    if (busy) return;
    NSURL *URL = [NSURL URLWithString:[NSString stringWithFormat:@"https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=%@&time=%.3f", videoID, timestamp]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.timeoutInterval = 20.0;
    __weak id weakNode = node;
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        os_unfair_lock_lock(&DALock);
        [DAThumbInFlight removeObject:videoID];
        os_unfair_lock_unlock(&DALock);
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        UIImage *image = (error == nil && status == 200 && data.length) ? [UIImage imageWithData:data] : nil;
        if (image == nil) return;
        os_unfair_lock_lock(&DALock);
        [DAImageCache setObject:image forKey:videoID];
        os_unfair_lock_unlock(&DALock);
        DAApplyImage(weakNode, videoID, image);
    }] resume];
}

#pragma mark - Titles

static void DACollectTextNodes(id node, NSUInteger depth, NSMutableArray *out) {
    if (node == nil || depth > DACellTextDepth || out.count >= DAMaxCellText) return;
    static Class textClass;
    if (textClass == Nil) textClass = NSClassFromString(@"ELMTextNode");
    if (textClass && [node isKindOfClass:textClass] && DANodeText(node).length) [out addObject:node];
    id subnodes = DASend(node, NSSelectorFromString(@"subnodes"));
    if ([subnodes isKindOfClass:NSArray.class]) for (id child in subnodes) DACollectTextNodes(child, depth + 1, out);
}

static BOOL DALooksLikeDuration(NSString *text) {
    static NSRegularExpression *expression;
    if (expression == nil) expression = [NSRegularExpression regularExpressionWithPattern:@"^\\d{1,2}:\\d{2}(:\\d{2})?$" options:0 error:nil];
    return [expression numberOfMatchesInString:text options:0 range:NSMakeRange(0, text.length)] != 0;
}

static void DAWriteTitle(id textNode, NSString *title) {
    void (^work)(void) = ^{
        id current = DASend(textNode, NSSelectorFromString(@"attributedText"));
        if (![current isKindOfClass:NSAttributedString.class] || [((NSAttributedString *)current).string isEqualToString:title]) return;
        NSAttributedString *existing = current;
        NSDictionary *attributes = existing.length ? [existing attributesAtIndex:0 effectiveRange:NULL] : nil;
        SEL setter = NSSelectorFromString(@"setAttributedText:");
        if (![textNode respondsToSelector:setter]) return;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(textNode, setter, [[NSAttributedString alloc] initWithString:title attributes:attributes]);
        } @catch (__unused NSException *e) {}
    };
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

static void DAApplyTitleToCell(id root, NSString *videoID) {
    if (root == nil || videoID.length == 0 || !DATitles) return;
    NSString *title = DAStoredTitle(videoID);
    if (title.length == 0) { // applied when the lookup comes back
        os_unfair_lock_lock(&DALock);
        [DAPendingCells setObject:root forKey:videoID];
        os_unfair_lock_unlock(&DALock);
        return;
    }
    NSMutableArray *nodes = [NSMutableArray array];
    DACollectTextNodes(root, 0, nodes);
    if (nodes.count < 2) return;
    id candidate = nodes[nodes.count - 2];
    NSString *text = DANodeText(candidate);
    if ([text isEqualToString:title] || DALooksLikeDuration(text)) return;
    objc_setAssociatedObject(candidate, DATitleVideoKey, videoID, OBJC_ASSOCIATION_COPY_NONATOMIC);
    DAWriteTitle(candidate, title);
}

static void DAApplyPendingTitle(NSString *videoID) {
    os_unfair_lock_lock(&DALock);
    id root = [DAPendingCells objectForKey:videoID];
    os_unfair_lock_unlock(&DALock);
    if (root) DAApplyTitleToCell(root, videoID);
}

#pragma mark - Lookups

static BOOL DAClaimSlotLocked(void) {
    if (DAActiveRequests >= DAMaxConcurrent) return NO;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now - DAWindowStart >= 60.0) {
        DAWindowStart = now;
        DAWindowCount = 0;
    }
    if (DAWindowCount >= DARequestsPerMinute) return NO;
    DAWindowCount++;
    DAActiveRequests++;
    return YES;
}

// DeArrow's best submission, if it's trusted (locked or not voted down) and not the original.
static NSDictionary *DABest(id list) {
    NSDictionary *best = [list isKindOfClass:NSArray.class] ? [list firstObject] : nil;
    if (![best isKindOfClass:NSDictionary.class] || [best[@"original"] boolValue]) return nil;
    return ([best[@"locked"] boolValue] || [best[@"votes"] integerValue] >= 0) ? best : nil;
}

static void DAFetchBranding(NSString *videoID, id node) {
    NSURL *URL = [NSURL URLWithString:[NSString stringWithFormat:@"https://sponsor.ajay.app/api/branding?videoID=%@", videoID]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.timeoutInterval = 15.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    __weak id weakNode = node;
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error != nil) { // asked again next time the video shows up
            os_unfair_lock_lock(&DALock);
            [DAInFlight removeObject:videoID];
            if (DAActiveRequests > 0) DAActiveRequests--;
            os_unfair_lock_unlock(&DALock);
            DAPumpQueue();
            return;
        }
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        id json = (status == 200 && data.length) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *payload = [json isKindOfClass:NSDictionary.class] ? json : nil;
        NSString *title = nil;
        id text = DABest(payload[@"titles"])[@"title"];
        if ([text isKindOfClass:NSString.class]) {
            // DeArrow marks words to keep as-is with ">"
            title = [[text stringByReplacingOccurrencesOfString:@">" withString:@""] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (title.length == 0) title = nil;
        }
        id timestamp = DABest(payload[@"thumbnails"])[@"timestamp"];
        NSNumber *time = [timestamp isKindOfClass:NSNumber.class] ? timestamp : nil;
        DAStoreBranding(videoID, time, title);
        if (title) DAApplyPendingTitle(videoID);
        if (time) DAFetchThumbnail(videoID, time.doubleValue, weakNode);
    }] resume];
}

static void DAPumpQueue(void) {
    while (YES) {
        NSString *videoID = nil;
        id node = nil;
        os_unfair_lock_lock(&DALock);
        while (DAPendingIDs.count != 0 && videoID == nil) {
            NSString *candidate = DAPendingIDs.firstObject;
            [DAPendingIDs removeObjectAtIndex:0];
            if (DAFreshEntryLocked(candidate) != nil || [DAInFlight containsObject:candidate]) {
                [DAPendingNodes removeObjectForKey:candidate];
                continue;
            }
            if (!DAClaimSlotLocked()) {
                [DAPendingIDs insertObject:candidate atIndex:0];
                break;
            }
            [DAInFlight addObject:candidate];
            node = [DAPendingNodes objectForKey:candidate];
            [DAPendingNodes removeObjectForKey:candidate];
            videoID = candidate;
        }
        os_unfair_lock_unlock(&DALock);
        if (videoID == nil) return;
        DAFetchBranding(videoID, node);
    }
}

static void DAEnqueueLookup(NSString *videoID, id node) {
    os_unfair_lock_lock(&DALock);
    BOOL known = DAFreshEntryLocked(videoID) != nil || [DAInFlight containsObject:videoID] || [DAPendingIDs containsObject:videoID];
    if (!known) {
        if (DAPendingIDs.count >= DAPendingLimit) [DAPendingIDs removeObjectAtIndex:0];
        [DAPendingIDs addObject:videoID];
        if (node) [DAPendingNodes setObject:node forKey:videoID];
    }
    os_unfair_lock_unlock(&DALock);
    if (!known) DAPumpQueue();
}

static void DAConsiderVideo(id node, NSString *videoID) {
    os_unfair_lock_lock(&DALock);
    UIImage *ready = DAThumbnails ? [DAImageCache objectForKey:videoID] : nil;
    NSDictionary *known = DAFreshEntryLocked(videoID);
    os_unfair_lock_unlock(&DALock);
    if (ready) {
        DAApplyImage(node, videoID, ready);
        return;
    }
    if (known) {
        NSNumber *time = known[@"t"];
        if (DAThumbnails && [time isKindOfClass:NSNumber.class]) DAFetchThumbnail(videoID, time.doubleValue, node);
        return;
    }
    DAEnqueueLookup(videoID, node);
}

#pragma mark - Hooks

static void DANoteImage(id node, id URL) {
    NSString *videoID = DAVideoIDFromURL(URL);
    if (videoID.length == 0) return;
    objc_setAssociatedObject(node, DANodeVideoKey, videoID, OBJC_ASSOCIATION_COPY_NONATOMIC);
    id root = DACellRoot(node);
    if (root) objc_setAssociatedObject(root, DACellVideoKey, videoID, OBJC_ASSOCIATION_COPY_NONATOMIC);
    DAConsiderVideo(node, videoID);
    if (root) DAApplyTitleToCell(root, videoID);
}

static id DADownloadImage(id self, SEL _cmd, id URL, BOOL shouldRetry, id callbackQueue, id progress, id completion) {
    DANoteImage(self, URL);
    return ((id (*)(id, SEL, id, BOOL, id, id, id))OriginalDownloadImage)(self, _cmd, URL, shouldRetry, callbackQueue, progress, completion);
}

static void DACachedImage(id self, SEL _cmd, id URL, id callbackQueue, id completion) {
    DANoteImage(self, URL);
    ((void (*)(id, SEL, id, id, id))OriginalCachedImage)(self, _cmd, URL, callbackQueue, completion);
}

// YouTube re-applies a card's texts when it's reused or updated; the DeArrow title goes back on.
// Only text nodes that show one of our titles are looked at (every text node in the feed comes through here).
static void DAApplyProperties(id self, SEL _cmd) {
    ((void (*)(id, SEL))OriginalApplyProperties)(self, _cmd);
    NSString *ours = objc_getAssociatedObject(self, DATitleVideoKey);
    if (ours == nil) return;
    id root = DACellRoot(self);
    id videoID = root ? objc_getAssociatedObject(root, DACellVideoKey) : nil;
    if (![videoID isEqual:ours]) { // the node now shows another video
        objc_setAssociatedObject(self, DATitleVideoKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        if ([videoID isKindOfClass:NSString.class] && DAStoredTitle(videoID).length) DAApplyTitleToCell(root, videoID);
        return;
    }
    NSString *title = DAStoredTitle(ours);
    if (title.length) DAWriteTitle(self, title);
}

__attribute__((constructor)) static void DAInit(void) {
    DATitles = YTGOptInEnabled(YTGDeArrowTitlesKey);
    DAThumbnails = YTGOptInEnabled(YTGDeArrowThumbnailsKey);
    if (!DATitles && !DAThumbnails) return;
    @autoreleasepool {
        DALoadStore();
        Class image = NSClassFromString(@"ELMImageNode");
        TBHHookMethod(image, @"downloadImageWithURL:shouldRetry:callbackQueue:downloadProgress:completion:", (IMP)DADownloadImage, &OriginalDownloadImage);
        TBHHookMethod(image, @"cachedImageWithURL:callbackQueue:completion:", (IMP)DACachedImage, &OriginalCachedImage);
        if (DATitles) TBHHookMethod(NSClassFromString(@"ELMTextNode"), @"controllerDidApplyProperties", (IMP)DAApplyProperties, &OriginalApplyProperties);
    }
}
