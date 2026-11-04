// HomeTabs
// Removes the Subscriptions, Music and Live tabs YouTube puts at the top of Home. Home's requests report an
// older app version so the server sends the layout from before the redesign; if tabs still come back, Home keeps
// only its own tab and the others become filter chips at the top of its feed.
//
// Ported from YTKACE (https://github.com/itzzace/ytkace) v1.1.5, HomeTabs.mm.
// MIT License, Copyright (c) 2026 YTKACE contributors. See LICENSE.
//
// Pure Objective-C runtime swizzling: no CydiaSubstrate / ElleKit dependency.

#import "Common.h"

static id HTObject(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static BOOL HTBool(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSInteger HTInt(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? (NSInteger)((int (*)(id, SEL))objc_msgSend)(object, selector) : -1;
}

static void HTSet(id object, NSString *name, id value) {
    SEL selector = NSSelectorFromString(name);
    if (object != nil && value != nil && [object respondsToSelector:selector]) ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
}

static void HTSetBool(id object, NSString *name, BOOL value) {
    SEL selector = NSSelectorFromString(name);
    if ([object respondsToSelector:selector]) ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
}

static id HTNew(NSString *name) {
    Class cls = NSClassFromString(name);
    return cls != Nil ? [cls new] : nil;
}

// YouTube's scrollable/collapsing Home tabs, off.
static BOOL HTNo(__unused id self, __unused SEL _cmd) { return NO; }

#pragma mark - Tabs become chips

static NSString *HTTabBrowseID(id tab) {
    id browseID = HTObject(HTObject(HTObject(HTObject(tab, @"tabRenderer"), @"endpoint"), @"browseEndpoint"), @"browseId");
    return [browseID isKindOfClass:NSString.class] ? browseID : nil;
}

// A protobuf extension (field number) of a message class, looked up once.
static id HTExtension(NSString *className, NSInteger field) {
    static NSMutableDictionary *cache;
    NSString *key = [NSString stringWithFormat:@"%@|%ld", className, (long)field];
    if (cache == nil) cache = [NSMutableDictionary dictionary];
    if (cache[key] != nil) return cache[key] == NSNull.null ? nil : cache[key];
    id result = nil;
    Class registryClass = NSClassFromString(@"GoogleGlobalExtensionRegistry");
    Class target = NSClassFromString(className);
    SEL registrySel = NSSelectorFromString(@"extensionRegistry");
    SEL lookup = NSSelectorFromString(@"extensionForDescriptor:fieldNumber:");
    if (registryClass != Nil && target != Nil && [registryClass respondsToSelector:registrySel] && [target respondsToSelector:@selector(descriptor)]) {
        id registry = ((id (*)(id, SEL))objc_msgSend)(registryClass, registrySel);
        id descriptor = ((id (*)(id, SEL))objc_msgSend)(target, @selector(descriptor));
        if ([registry respondsToSelector:lookup]) result = ((id (*)(id, SEL, id, NSInteger))objc_msgSend)(registry, lookup, descriptor, field);
    }
    cache[key] = result ?: NSNull.null;
    return result;
}

static id HTWrap(NSString *className, NSInteger field, id value) {
    id extension = HTExtension(className, field);
    id wrapper = HTNew(className);
    SEL setter = NSSelectorFromString(@"setExtension:value:");
    if (extension == nil || wrapper == nil || value == nil || ![wrapper respondsToSelector:setter]) return nil;
    ((void (*)(id, SEL, id, id))objc_msgSend)(wrapper, setter, extension, value);
    return wrapper;
}

static id HTReloadData(id tab) {
    id list = HTObject(HTObject(HTObject(tab, @"tabRenderer"), @"content"), @"sectionListRenderer");
    for (id continuation in HTObject(list, @"continuationsArray")) {
        id data = HTObject(continuation, @"reloadContinuationData");
        if ([HTObject(data, @"continuation") length] != 0) return data;
    }
    return nil;
}

static id HTReloadCommand(id data) {
    id endpoint = HTNew(@"YTIBrowseSectionListReloadEndpoint");
    id continuations = HTNew(@"YTIBrowseSectionListReloadSupportedContinuations");
    if (data == nil || endpoint == nil || continuations == nil) return nil;
    HTSet(continuations, @"setReloadContinuationData:", data);
    HTSet(endpoint, @"setContinuation:", continuations);
    return HTWrap(@"YTICommand", 120837120, endpoint);
}

static id HTChip(NSString *title, NSInteger icon, id command, BOOL selected) {
    id chip = HTNew(@"YTIChipCloudChipRenderer");
    Class styleClass = NSClassFromString(@"YTIChipCloudChipStyle");
    if (chip == nil || styleClass == Nil) return nil;
    id style = [styleClass new];
    id styleDescriptor = ((id (*)(id, SEL))objc_msgSend)(styleClass, @selector(descriptor));
    id field = ((id (*)(id, SEL, id))objc_msgSend)(styleDescriptor, NSSelectorFromString(@"fieldWithName:"), @"styleType");
    id enumDescriptor = HTObject(field, @"enumDescriptor");
    int32_t value = 0;
    SEL lookup = NSSelectorFromString(@"getValue:forEnumTextFormatName:");
    if ([enumDescriptor respondsToSelector:lookup] &&
        ((BOOL (*)(id, SEL, int32_t *, id))objc_msgSend)(enumDescriptor, lookup, &value, @"STYLE_HOME_FILTER")) {
        ((void (*)(id, SEL, int))objc_msgSend)(style, NSSelectorFromString(@"setStyleType:"), value);
        HTSet(chip, @"setStyle:", style);
    }
    if (title.length != 0) {
        Class formatted = NSClassFromString(@"YTIFormattedString");
        SEL make = NSSelectorFromString(@"formattedStringWithString:");
        if ([formatted respondsToSelector:make]) HTSet(chip, @"setText:", ((id (*)(id, SEL, id))objc_msgSend)(formatted, make, title));
    }
    if (icon > 0) {
        id image = HTNew(@"YTIIcon");
        if (image) ((void (*)(id, SEL, int))objc_msgSend)(image, NSSelectorFromString(@"setIconType:"), (int)icon);
        HTSet(chip, @"setIcon:", image);
    }
    HTSet(chip, @"setNavigationEndpoint:", command);
    HTSetBool(chip, @"setIsSelected:", selected);
    return HTWrap(@"YTIRenderer", 91394224, chip);
}

// The other tabs as chips above Home's feed: icon-only tabs first, then Home's own ("All", selected), then the rest.
static void HTBuildChips(NSArray *tabs, id home) {
    id list = HTObject(HTObject(HTObject(home, @"tabRenderer"), @"content"), @"sectionListRenderer");
    if (list == nil) return;
    id header = HTObject(list, @"header");
    if (HTBool(list, @"hasHeader") && HTBool(header, @"hasFeedFilterChipBarRenderer")) return;
    id bar = HTNew(@"YTIFeedFilterChipBarRenderer");
    NSMutableArray *contents = HTObject(bar, @"contentsArray");
    if (![contents isKindOfClass:NSMutableArray.class]) return;
    id homeReload = HTReloadData(home);
    for (id tab in tabs) {
        if (tab == home) continue;
        id renderer = HTObject(tab, @"tabRenderer");
        if (!HTBool(renderer, @"unselectable")) continue;
        id command = HTObject(renderer, @"endpoint");
        NSInteger icon = HTInt(renderer, @"tabIcon");
        if (command == nil || icon <= 0) continue;
        id chip = HTChip(nil, icon, command, NO);
        if (chip != nil) [contents addObject:chip];
        Class dividerClass = HTObject(HTExtension(@"YTIRenderer", 325920579), @"msgClass");
        id divider = dividerClass != Nil ? HTWrap(@"YTIRenderer", 325920579, [dividerClass new]) : nil;
        if (divider != nil) [contents addObject:divider];
    }
    NSString *homeTitle = HTObject(HTObject(home, @"tabRenderer"), @"title");
    id all = HTChip(homeTitle.length != 0 ? homeTitle : @"All", 0, HTReloadCommand(homeReload), YES);
    if (all != nil) [contents addObject:all];
    for (id tab in tabs) {
        if (tab == home) continue;
        id renderer = HTObject(tab, @"tabRenderer");
        NSString *title = HTObject(renderer, @"title");
        if (title.length == 0 || HTBool(renderer, @"unselectable")) continue;
        id chip = HTChip(title, 0, HTReloadCommand(HTReloadData(tab)) ?: HTObject(renderer, @"endpoint"), NO);
        if (chip != nil) [contents addObject:chip];
    }
    if (contents.count < 2) return;
    HTSet(bar, @"setOnFiltersCleared:", HTReloadCommand(homeReload));
    id newHeader = header ?: HTNew(@"YTISectionListHeaderSupportedRenderers");
    HTSet(newHeader, @"setFeedFilterChipBarRenderer:", bar);
    HTSet(list, @"setHeader:", newHeader);
}

static void HTTrimTabs(id single) {
    NSMutableArray *tabs = HTObject(single, @"tabsArray");
    if (![tabs isKindOfClass:NSMutableArray.class] || tabs.count < 2) return;
    id home = nil;
    BOOL subscriptions = NO;
    for (id tab in tabs) {
        NSString *browseID = HTTabBrowseID(tab);
        if (home == nil && [browseID isEqualToString:@"FEwhat_to_watch"]) home = tab;
        if ([browseID isEqualToString:@"FEsubscriptions"]) subscriptions = YES;
    }
    if (home == nil && subscriptions) home = tabs.firstObject;
    if (home == nil) return;
    HTBuildChips([tabs copy], home);
    [tabs setArray:@[home]];
    HTSetBool(single, @"setHideTabBar:", YES);
    HTSetBool(single, @"setDisableTabSwiping:", YES);
    HTSetBool(HTObject(home, @"tabRenderer"), @"setHasPresentationStyle:", NO);
}

static IMP OriginalTabsLoad, OriginalTabsLoadReload, OriginalTabsUpdate, OriginalBrowseLoad, OriginalBrowseLoadInitial;

static void HTTabsLoad(id self, SEL _cmd, id model) {
    HTTrimTabs(model);
    ((void (*)(id, SEL, id))OriginalTabsLoad)(self, _cmd, model);
}

static void HTTabsLoadReload(id self, SEL _cmd, id model, BOOL reload) {
    HTTrimTabs(model);
    ((void (*)(id, SEL, id, BOOL))OriginalTabsLoadReload)(self, _cmd, model, reload);
}

static void HTTabsUpdate(id self, SEL _cmd, id model, BOOL isDefault, BOOL reload) {
    HTTrimTabs(model);
    ((void (*)(id, SEL, id, BOOL, BOOL))OriginalTabsUpdate)(self, _cmd, model, isDefault, reload);
}

static void HTBrowseLoad(id self, SEL _cmd, id response) {
    HTTrimTabs(HTObject(HTObject(response, @"contents"), @"singleColumnBrowseResultsRenderer"));
    ((void (*)(id, SEL, id))OriginalBrowseLoad)(self, _cmd, response);
}

static void HTBrowseLoadInitial(id self, SEL _cmd, id response) {
    HTTrimTabs(HTObject(HTObject(response, @"contents"), @"singleColumnBrowseResultsRenderer"));
    ((void (*)(id, SEL, id))OriginalBrowseLoadInitial)(self, _cmd, response);
}

#pragma mark - Older app version on Home's requests

static NSString *const HTOldVersion = @"21.33.6";

static BOOL HTIsHomeContinuation(NSString *token) {
    if (![token isKindOfClass:NSString.class] || token.length == 0) return NO;
    NSString *base64 = [[token stringByReplacingOccurrencesOfString:@"-" withString:@"+"] stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    base64 = [base64 stringByRemovingPercentEncoding] ?: base64;
    while (base64.length % 4 != 0) base64 = [base64 stringByAppendingString:@"="];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    NSData *needle = [@"FEwhat_to_watch" dataUsingEncoding:NSUTF8StringEncoding];
    return data.length != 0 && [data rangeOfData:needle options:0 range:NSMakeRange(0, data.length)].location != NSNotFound;
}

static void HTOldVersionForHome(id request) {
    id browseID = HTObject(request, @"browseId");
    BOOL home = [browseID isKindOfClass:NSString.class] && [browseID isEqualToString:@"FEwhat_to_watch"];
    if (!home && !HTIsHomeContinuation(HTObject(request, @"continuation"))) return;
    id context = HTObject(request, @"context");
    NSString *version = HTObject(HTObject(context, @"client"), @"clientVersion");
    if (context == nil || [version isEqualToString:HTOldVersion]) return;
    YTGDAct(@"HomeTabs", nil, [NSString stringWithFormat:@"old client version on a %@ request", home ? @"Home" : @"Home continuation"]); // TEMPORARY DIAGNOSTIC
    id copy = [context copy];
    HTSet(HTObject(copy, @"client"), @"setClientVersion:", HTOldVersion);
    HTSet(request, @"setContext:", copy);
}

static IMP OriginalRequestWrite, OriginalRequestSize;

static size_t HTRequestSize(id self, SEL _cmd) {
    HTOldVersionForHome(self);
    return ((size_t (*)(id, SEL))OriginalRequestSize)(self, _cmd);
}

static void HTRequestWrite(id self, SEL _cmd, id stream) {
    HTOldVersionForHome(self);
    ((void (*)(id, SEL, id))OriginalRequestWrite)(self, _cmd, stream);
}

// The version header goes with the request body.
static IMP OriginalSetHeader, OriginalSetBody;

static void HTMatchVersionHeader(NSMutableURLRequest *request) {
    if (![request.URL.path containsString:@"/browse"]) return;
    NSData *body = request.HTTPBody;
    NSData *needle = [HTOldVersion dataUsingEncoding:NSUTF8StringEncoding];
    if (body.length == 0 || [body rangeOfData:needle options:0 range:NSMakeRange(0, body.length)].location == NSNotFound) return;
    NSString *current = [request valueForHTTPHeaderField:@"X-Youtube-Client-Version"];
    if (current == nil || [current isEqualToString:HTOldVersion]) return;
    YTGDAct(@"HomeTabs", nil, [NSString stringWithFormat:@"old version header on %@", request.URL.path]); // TEMPORARY DIAGNOSTIC
    ((void (*)(id, SEL, id, id))OriginalSetHeader)(request, @selector(setValue:forHTTPHeaderField:), HTOldVersion, @"X-Youtube-Client-Version");
}

static void HTSetHeader(NSMutableURLRequest *self, SEL _cmd, NSString *value, NSString *field) {
    ((void (*)(id, SEL, id, id))OriginalSetHeader)(self, _cmd, value, field);
    if ([field isKindOfClass:NSString.class] && [field caseInsensitiveCompare:@"X-Youtube-Client-Version"] == NSOrderedSame) HTMatchVersionHeader(self);
}

static void HTSetBody(NSMutableURLRequest *self, SEL _cmd, NSData *body) {
    ((void (*)(id, SEL, id))OriginalSetBody)(self, _cmd, body);
    HTMatchVersionHeader(self);
}

__attribute__((constructor)) static void HTInit(void) {
    if (!YTGFeatureEnabled(YTGHomeTabsKey)) return;
    @autoreleasepool {
        Class request = NSClassFromString(@"YTIBrowseRequest");
        Method write = request ? class_getInstanceMethod(request, NSSelectorFromString(@"writeToCodedOutputStream:")) : NULL;
        Method size = request ? class_getInstanceMethod(request, NSSelectorFromString(@"serializedSize")) : NULL;
        if (write && size && strncmp(method_getTypeEncoding(write), "v24@0:8@16", 10) == 0 && strncmp(method_getTypeEncoding(size), "Q16@0:8", 7) == 0) {
            TBHHookMethod(request, @"writeToCodedOutputStream:", (IMP)HTRequestWrite, &OriginalRequestWrite);
            TBHHookMethod(request, @"serializedSize", (IMP)HTRequestSize, &OriginalRequestSize);
            TBHHookMethod(NSMutableURLRequest.class, @"setValue:forHTTPHeaderField:", (IMP)HTSetHeader, &OriginalSetHeader);
            TBHHookMethod(NSMutableURLRequest.class, @"setHTTPBody:", (IMP)HTSetBody, &OriginalSetBody);
        }
        Class browse = NSClassFromString(@"YTBrowseViewController");
        TBHHookMethod(browse, @"loadWithResponse:", (IMP)HTBrowseLoad, &OriginalBrowseLoad);
        TBHHookMethod(browse, @"loadWithInitialResponse:", (IMP)HTBrowseLoadInitial, &OriginalBrowseLoadInitial);
        Class tabs = NSClassFromString(@"YTTabsViewController");
        TBHHookMethod(tabs, @"loadWithModel:", (IMP)HTTabsLoad, &OriginalTabsLoad);
        TBHHookMethod(tabs, @"loadWithModel:reloadContentViewControllers:", (IMP)HTTabsLoadReload, &OriginalTabsLoadReload);
        TBHHookMethod(tabs, @"updateWithModel:isDefaultModel:reloadContentViewControllers:", (IMP)HTTabsUpdate, &OriginalTabsUpdate);
        Class config = NSClassFromString(@"YTColdConfig");
        TBHHookMethod(config, @"mainAppCoreClientIosEnableScrollableTabsInFox", (IMP)HTNo, NULL);
        TBHHookMethod(config, @"mainAppCoreClientEnableCollapsingTabsAfterDwellInFox", (IMP)HTNo, NULL);
        TBHHookMethod(config, @"mainAppCoreClientIosEnableCollapsingTabsAfterDwellInFox", (IMP)HTNo, NULL);
    }
}
