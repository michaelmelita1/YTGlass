// TEMPORARY DIAGNOSTIC (0.2.0~debug2..4): logs where YTPlus 6.0 puts its tab bar. Read with idevicesyslog, grep YTGDIAG.

#import "Common.h"
#import <os/log.h>

// Public (unredacted) log line.
#define YTGDLog(...) os_log(OS_LOG_DEFAULT, "%{public}s", [NSString stringWithFormat:__VA_ARGS__].UTF8String)

static NSString *YTGDChain(UIView *view) {
    NSMutableArray *parts = [NSMutableArray array];
    for (UIView *v = view; v != nil; v = v.superview) {
        CGRect f = [v convertRect:v.bounds toView:nil];
        [parts addObject:[NSString stringWithFormat:@"%@ %.0f,%.0f %.0fx%.0f%@%@", NSStringFromClass(v.class), f.origin.x, f.origin.y,
                          f.size.width, f.size.height, v.hidden ? @" H" : @"", v.alpha < 0.01 ? @" A0" : @""]];
    }
    return [parts componentsJoinedByString:@" < "];
}

static void YTGDCollect(UIView *view, NSMutableArray *tabBars, NSMutableArray *pivots, Class pivot) {
    if ([view isKindOfClass:UITabBar.class]) [tabBars addObject:view];
    if (pivot && [view isKindOfClass:pivot]) [pivots addObject:view];
    for (UIView *subview in view.subviews) YTGDCollect(subview, tabBars, pivots, pivot);
}

static void YTGDDump(NSString *reason) {
    Class pivot = NSClassFromString(@"YTPivotBarView");
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            NSMutableArray *tabBars = [NSMutableArray array], *pivots = [NSMutableArray array];
            YTGDCollect(window, tabBars, pivots, pivot);
            for (UIView *v in tabBars) YTGDLog(@"YTGDIAG %@ TABBAR %@", reason, YTGDChain(v));
            for (UIView *v in pivots) {
                YTGDLog(@"YTGDIAG %@ PIVOT %@", reason, YTGDChain(v));
                for (UIView *s in v.subviews) YTGDLog(@"YTGDIAG %@ PIVOT-SUB %@ hidden=%d alpha=%.2f", reason, NSStringFromClass(s.class), s.hidden, s.alpha);
            }
        }
    }
}

static IMP OriginalHide, OriginalShow;

static void YTGDHide(id self, SEL _cmd) {
    ((void (*)(id, SEL))OriginalHide)(self, _cmd);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ YTGDDump(@"afterHide"); });
}

static void YTGDShow(id self, SEL _cmd) {
    ((void (*)(id, SEL))OriginalShow)(self, _cmd);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ YTGDDump(@"afterShow"); });
}

__attribute__((constructor)) static void YTGDInit(void) {
    // Which classes implement YTPlus's new tab bar methods.
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSArray *names = @[@"placeTabBar:inPivotBar:", @"setPivotBarHidden:", @"visibleTabBarTopInView:", @"updateStyleOfTabBar:inPivotBar:"];
    for (unsigned int i = 0; i < count; i++) {
        for (NSString *name in names) {
            SEL sel = NSSelectorFromString(name);
            unsigned int n = 0;
            Method *methods = class_copyMethodList(classes[i], &n);
            for (unsigned int j = 0; j < n; j++) if (method_getName(methods[j]) == sel) YTGDLog(@"YTGDIAG METHOD -[%s %@]", class_getName(classes[i]), name);
            free(methods);
            methods = class_copyMethodList(object_getClass(classes[i]), &n);
            for (unsigned int j = 0; j < n; j++) if (method_getName(methods[j]) == sel) YTGDLog(@"YTGDIAG METHOD +[%s %@]", class_getName(classes[i]), name);
            free(methods);
        }
    }
    free(classes);
    Class appView = NSClassFromString(@"YTAppView");
    YTGInstallHook(appView, @"hidePivotBar", (IMP)YTGDHide, &OriginalHide);
    YTGInstallHook(appView, @"showPivotBar", (IMP)YTGDShow, &OriginalShow);
    for (int i = 1; i <= 3; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ YTGDDump([NSString stringWithFormat:@"t%d", i * 4]); });
    }
}
