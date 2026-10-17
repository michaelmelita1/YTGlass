// TabBarAutoHide
// Hides YouTube's tab bar when you scroll down, on every page, the way YouTube does on Home. Meant as an add-on for
// builds that already restyle the tab bar, such as YTPlus with its Liquid Glass tab bar.
//
// How: YouTube's own hide-on-scroll lives in YTScrollableNavigationController: hidePivotBarOnScroll (on for Home only)
// and updatePivotBarVisibilityForScrollView:contentOffsetY:isAtBottom:, which Home's feed calls as it scrolls and
// which hides and shows the bar through YTAppView, keeping the feed's inset and the mini player in step. Here
// hidePivotBarOnScroll is on for every tab but Shorts, and every page's main feed reports its scrolling to its
// navigation controller the same way. Switching tabs brings the bar back; on Shorts it's never hidden.
// It adds no views and changes nothing about how the bar looks.
//
// Pure Objective-C runtime swizzling: no CydiaSubstrate / ElleKit dependency.

#import "Common.h"

#pragma mark - Tab bar helpers

static const void *TBHSelectedKey = &TBHSelectedKey;
static __weak UIView *TBHBar;      // the YTPivotBarView currently on screen
static __weak UIView *TBHLastSelected; // the tab button selected last (kept up to date by TBHItemSetSelected)

static Class TBHItemClass(void) {
    static Class itemClass;
    if (itemClass == Nil) itemClass = NSClassFromString(@"YTPivotBarItemView");
    return itemClass;
}

static void TBHCollectItems(UIView *view, NSMutableArray<UIView *> *items) {
    if (TBHItemClass() && [view isKindOfClass:TBHItemClass()]) {
        [items addObject:view];
        return;
    }
    for (UIView *subview in view.subviews) TBHCollectItems(subview, items);
}

static BOOL TBHItemSelected(UIView *item) {
    if ([objc_getAssociatedObject(item, TBHSelectedKey) boolValue]) return YES;
    if ([item respondsToSelector:@selector(isSelected)] && ((BOOL (*)(id, SEL))objc_msgSend)(item, @selector(isSelected))) return YES;
    return (item.accessibilityTraits & UIAccessibilityTraitSelected) != 0;
}

static UIView *TBHSelectedItem(UIView *bar) {
    UIView *last = TBHLastSelected;
    if (last != nil && TBHItemSelected(last) && [last isDescendantOfView:bar]) return last;
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    TBHCollectItems(bar, items);
    // Hidden buttons count too: tweaks like YTPlus hide YouTube's own buttons behind a system
    // UITabBar, but YouTube still keeps their selected state up to date.
    for (UIView *item in items) {
        if (TBHItemSelected(item)) return (TBHLastSelected = item);
    }
    return nil;
}

static NSString *TBHItemIdentifier(UIView *item) {
    id renderer = nil, identifier = nil;
    @try { renderer = [item valueForKey:@"renderer"]; } @catch (__unused NSException *e) {}
    @try { identifier = [renderer valueForKey:@"pivotIdentifier"]; } @catch (__unused NSException *e) {}
    return [identifier isKindOfClass:NSString.class] ? identifier : nil;
}

// Whether the tab bar has a Shorts tab (YTPlus can remove it). Decided once every tab's identifier can be read;
// selecting a Shorts tab later turns it back on (TBHItemSetSelected).
typedef NS_ENUM(NSInteger, TBHShortsTabState) { TBHShortsTabUnknown, TBHShortsTabNone, TBHShortsTabPresent };
static TBHShortsTabState TBHShortsTab;

static BOOL TBHHasShortsTab(UIView *bar) {
    if (TBHShortsTab != TBHShortsTabUnknown) return TBHShortsTab == TBHShortsTabPresent;
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    TBHCollectItems(bar, items);
    if (items.count == 0) return YES;
    for (UIView *item in items) {
        NSString *identifier = TBHItemIdentifier(item);
        if (identifier == nil) return YES; // not readable yet
        if ([identifier isEqualToString:@"FEshorts"]) {
            TBHShortsTab = TBHShortsTabPresent;
            return YES;
        }
    }
    TBHShortsTab = TBHShortsTabNone;
    return NO;
}

static BOOL TBHOnShorts(UIView *bar) {
    if (!TBHHasShortsTab(bar)) return NO;
    UIView *selected = TBHSelectedItem(bar);
    return selected != nil && [TBHItemIdentifier(selected) isEqualToString:@"FEshorts"];
}

// YTAppView owns the bar's position; hiding through it is what YouTube does on Home.
// Asked on every scroll step, so the last answer is kept while the bar stays inside it.
static UIView *TBHAppView(UIView *bar) {
    static Class appViewClass;
    static __weak UIView *lastBar, *lastAppView;
    if (bar == lastBar && lastAppView != nil && bar.window == lastAppView.window) return lastAppView;
    if (appViewClass == Nil) appViewClass = NSClassFromString(@"YTAppView");
    if (appViewClass == Nil) return nil;
    for (UIView *view = bar.superview; view != nil; view = view.superview) {
        if ([view isKindOfClass:appViewClass]) {
            lastBar = bar;
            lastAppView = view;
            return view;
        }
    }
    return nil;
}

static void TBHAppViewCall(UIView *appView, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (appView != nil && [appView respondsToSelector:selector]) ((void (*)(id, SEL))objc_msgSend)(appView, selector);
}

static BOOL TBHBarHidden(UIView *bar) {
    UIView *appView = bar ? TBHAppView(bar) : nil;
    static SEL selector;
    if (selector == NULL) selector = NSSelectorFromString(@"isPivotBarHidden");
    if (appView == nil || ![appView respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(appView, selector);
}

#pragma mark - Hide / show

static void TBHSetBarHidden(UIView *bar, BOOL hidden) {
    if (bar == nil || TBHBarHidden(bar) == hidden) return;
    if (hidden && (TBHOnShorts(bar) || bar.hidden || bar.alpha < 0.01 || bar.window == nil)) return;
    TBHAppViewCall(TBHAppView(bar), hidden ? @"hidePivotBar" : @"showPivotBar");
}

#pragma mark - YouTube's hide-on-scroll on every page

// YouTube's own setting (on for Home only): on for every tab but Shorts.
static BOOL TBHHideOnScroll(__unused id self, __unused SEL _cmd) {
    return ![TBHSelectedTabIdentifier() isEqualToString:@"FEshorts"];
}

// The YTScrollableNavigationController a feed belongs to (kept per feed).
static UIViewController *TBHNavigation(UIScrollView *scrollView) {
    static NSMapTable<UIScrollView *, UIViewController *> *known;
    if (known == nil) known = [NSMapTable weakToWeakObjectsMapTable];
    UIViewController *nav = [known objectForKey:scrollView];
    if (nav) return nav;
    static Class navClass;
    if (navClass == Nil) navClass = NSClassFromString(@"YTScrollableNavigationController");
    if (navClass == Nil) return nil;
    UIViewController *page = nil;
    for (UIResponder *r = scrollView.nextResponder; r != nil && page == nil; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) page = (UIViewController *)r;
    }
    for (UIViewController *v = page; v != nil; v = v.parentViewController) {
        if ([v isKindOfClass:navClass]) nav = v;
    }
    if (nav) [known setObject:nav forKey:scrollView];
    return nav;
}

static IMP OriginalScrollSetContentOffset;
static CFTimeInterval TBHLastTouchTime; // last time any scroll view was dragged or flinging

static void TBHScrollSetContentOffset(UIScrollView *receiver, SEL selector, CGPoint offset) {
    ((void (*)(id, SEL, CGPoint))OriginalScrollSetContentOffset)(receiver, selector, offset);
    UIView *bar = TBHBar;
    UIWindow *window = bar.window;
    // Only the page's main feed, not shelves, sheets or Shorts-style pagers.
    if (window == nil || receiver.window != window || receiver.pagingEnabled ||
        CGRectGetHeight(receiver.bounds) < CGRectGetHeight(window.bounds) * 0.4) return;
    // Moved by the user: directly, or (History's collapsing header nests two scroll views, the finger driving the
    // outer one and code moving the list) within a moment of a touch.
    CFTimeInterval now = CACurrentMediaTime();
    if (receiver.isTracking || receiver.isDecelerating) TBHLastTouchTime = now;
    else if (now - TBHLastTouchTime > 0.25) return;
    static SEL update;
    if (update == NULL) update = NSSelectorFromString(@"updatePivotBarVisibilityForScrollView:contentOffsetY:isAtBottom:");
    UIViewController *nav = TBHNavigation(receiver);
    if (![nav respondsToSelector:update]) return;
    CGFloat y = receiver.contentOffset.y;
    BOOL atBottom = y + CGRectGetHeight(receiver.bounds) >= receiver.contentSize.height + receiver.adjustedContentInset.bottom - 1.0;
    ((void (*)(id, SEL, UIScrollView *, CGFloat, BOOL))objc_msgSend)(nav, update, receiver, y, atBottom);
}

#pragma mark - Tab bar hooks

static IMP OriginalBarLayout;
static IMP OriginalItemSetSelected;

static void TBHBarLayout(UIView *self, SEL _cmd) {
    if (OriginalBarLayout) ((void (*)(id, SEL))OriginalBarLayout)(self, _cmd);
    TBHBar = self;
    if (TBHBarHidden(self) && TBHOnShorts(self)) TBHSetBarHidden(self, NO); // never hidden on Shorts
}

static void TBHItemSetSelected(UIView *self, SEL _cmd, BOOL selected) {
    BOOL wasSelected = [objc_getAssociatedObject(self, TBHSelectedKey) boolValue];
    if (OriginalItemSetSelected) ((void (*)(id, SEL, BOOL))OriginalItemSetSelected)(self, _cmd, selected);
    objc_setAssociatedObject(self, TBHSelectedKey, @(selected), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!selected) return;
    TBHLastSelected = self;
    if (TBHShortsTab == TBHShortsTabNone && [TBHItemIdentifier(self) isEqualToString:@"FEshorts"]) TBHShortsTab = TBHShortsTabPresent;
    if (wasSelected) return;
    UIView *bar = self.superview;
    while (bar != nil && ![NSStringFromClass(bar.class) isEqualToString:@"YTPivotBarView"]) bar = bar.superview;
    TBHSetBarHidden(bar, NO); // switching tabs always brings the bar back
}

__attribute__((constructor)) static void TBHInit(void) {
    @autoreleasepool {
        TBHHookMethod(NSClassFromString(@"YTPivotBarView"), @"layoutSubviews", (IMP)TBHBarLayout, &OriginalBarLayout);
        TBHHookMethod(NSClassFromString(@"YTPivotBarItemView"), @"setSelected:", (IMP)TBHItemSetSelected, &OriginalItemSetSelected);
        TBHHookMethod(NSClassFromString(@"YTScrollableNavigationController"), @"hidePivotBarOnScroll", (IMP)TBHHideOnScroll, NULL);
        TBHHookMethod(UIScrollView.class, @"setContentOffset:", (IMP)TBHScrollSetContentOffset, &OriginalScrollSetContentOffset);
    }
}

UIView *TBHFindBar(void) {
    UIView *bar = TBHBar;
    if (bar) return bar;
    Class cls = NSClassFromString(@"YTPivotBarView");
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    for (UIWindow *window in windows) {
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
        for (NSUInteger i = 0; i < queue.count && i < 2000 && bar == nil; i++) {
            if (cls && [queue[i] isKindOfClass:cls]) bar = queue[i];
            else [queue addObjectsFromArray:queue[i].subviews];
        }
        if (bar) break;
    }
    return bar;
}

NSString *TBHSelectedTabIdentifier(void) {
    UIView *bar = TBHFindBar();
    UIView *selected = bar ? TBHSelectedItem(bar) : nil;
    return selected ? TBHItemIdentifier(selected) : nil;
}

NSString *TBHSelectedTabTitle(void) {
    UIView *bar = TBHFindBar();
    UIView *selected = bar ? TBHSelectedItem(bar) : nil;
    if (selected == nil) return nil;
    id renderer = nil, title = nil;
    @try { renderer = [selected valueForKey:@"renderer"]; } @catch (__unused NSException *e) {}
    @try { title = [renderer valueForKey:@"title"]; } @catch (__unused NSException *e) {}
    SEL plain = NSSelectorFromString(@"stringWithFormattingRemoved");
    if (title && ![title isKindOfClass:NSString.class] && [title respondsToSelector:plain]) {
        title = ((id (*)(id, SEL))objc_msgSend)(title, plain);
    }
    if ([title isKindOfClass:NSString.class] && [title length]) return title;
    NSString *label = selected.accessibilityLabel;
    return label.length ? label : nil;
}
