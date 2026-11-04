// YTPlusTabLabels
// Workaround for a YTPlus 6.0 bug: its tab bar (a system UITabBar inside YouTube's YTPivotBarView) gets its tabs with
// no titles even when YTPlus's "Remove tab labels" is off. Each untitled tab is given the label of YouTube's own tab in
// the same place, in the app's language. Drop this file once YTPlus fixes it.
//
// Pure Objective-C runtime swizzling: no CydiaSubstrate / ElleKit dependency.

#import "Common.h"

static IMP OriginalBarLayout;

static void YTLBarLayout(UIView *self, SEL _cmd) {
    if (OriginalBarLayout) ((void (*)(id, SEL))OriginalBarLayout)(self, _cmd);
    UITabBar *tabBar = nil;
    for (UIView *subview in self.subviews) if ([subview isKindOfClass:UITabBar.class]) tabBar = (UITabBar *)subview;
    if (tabBar == nil || tabBar.hidden) return;
    NSArray<UITabBarItem *> *tabs = tabBar.items;
    BOOL untitled = NO;
    for (UITabBarItem *tab in tabs) untitled |= tab.title.length == 0;
    if (!untitled) return;
    NSArray *titles = TBHTabTitles(self);
    { // TEMPORARY: both lists, to check they line up
        static NSString *last;
        NSMutableArray *ours = [NSMutableArray array];
        for (UITabBarItem *tab in tabs) [ours addObject:[NSString stringWithFormat:@"'%@' tag=%ld ax='%@'", tab.title, (long)tab.tag, tab.accessibilityLabel]];
        NSString *line = [NSString stringWithFormat:@"YTGDIAG labels youtube=%@ ytplus=%@", [titles componentsJoinedByString:@" | "], [ours componentsJoinedByString:@" | "]];
        if (![line isEqualToString:last]) { last = line; YTGDLog(@"%@", line); }
    }
    for (NSUInteger i = 0; i < tabs.count && i < titles.count; i++) {
        if (tabs[i].title.length == 0 && [titles[i] isKindOfClass:NSString.class]) tabs[i].title = titles[i];
    }
}

__attribute__((constructor)) static void YTLInit(void) {
    NSUserDefaults *ytplus = [[NSUserDefaults alloc] initWithSuiteName:@"com.dvntm.ytlite"];
    if ([ytplus boolForKey:@"removeLabels"]) return; // YTPlus is meant to hide them
    @autoreleasepool {
        TBHHookMethod(NSClassFromString(@"YTPivotBarView"), @"layoutSubviews", (IMP)YTLBarLayout, &OriginalBarLayout);
    }
}
