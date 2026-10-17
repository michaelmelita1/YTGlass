// TabBarAutoHide
// Hides YouTube's tab bar when you scroll down, on every page (YouTube itself only
// does this on Home). Meant as an add-on for builds that already restyle the tab bar,
// such as YTPlus with its Liquid Glass tab bar.
//
// The scroll tracking is ported from YTKACE (https://github.com/itzzace/ytkace) v1.1.1,
// TabBarHooks.mm. MIT License, Copyright (c) 2026 YTKACE contributors. See LICENSE.
//
// How it hides the bar:
// - It calls YouTube's own -[YTAppView hidePivotBar] / -showPivotBar, the same calls YouTube
//   makes on Home. YTAppView lays the bar out by frame on every layout pass, so moving the bar
//   any other way (e.g. with a transform) gets undone straight away; going through YouTube
//   keeps the layout, the feed's bottom inset and the mini-player in step.
// - With YTPlus, the visible glass bar is a system UITabBar laid out inside YouTube's
//   YTPivotBarView, so it moves with it.
// - Never on Shorts. It adds no views and changes nothing about how the bar looks.
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

static CGFloat TBHProgress; // 0 = fully shown, 1 = scrolled far enough to hide

static void TBHSetBarHidden(UIView *bar, BOOL hidden) {
    if (bar == nil || TBHBarHidden(bar) == hidden) return;
    if (hidden && (TBHOnShorts(bar) || bar.hidden || bar.alpha < 0.01 || bar.window == nil)) return;
    TBHProgress = hidden ? 1.0 : 0.0;
    TBHAppViewCall(TBHAppView(bar), hidden ? @"hidePivotBar" : @"showPivotBar");
}

#pragma mark - Scroll tracking (from YTKACE)

static CGFloat const TBHDistance = 64.0; // points of scrolling down before the bar hides
static __weak UIScrollView *TBHScroll;      // the feed currently being followed
static CFTimeInterval TBHLastTouchTime;     // last time any scroll view was dragged or flinging
static CGFloat TBHLastOffset;
static const void *TBHPanKey = &TBHPanKey;

static BOOL TBHEligible(UIScrollView *scrollView, UIView *bar) {
    UIWindow *window = bar.window;
    if (window == nil || scrollView.window != window) return NO;
    // Only the page's main feed, not small horizontal shelves or sheets.
    if (CGRectGetHeight(scrollView.bounds) < CGRectGetHeight(window.bounds) * 0.4) return NO;
    // Shorts (and other one-item-per-page pagers) never hide the bar, even if the tab can't be read.
    if (scrollView.pagingEnabled) return NO;
    CGFloat range = scrollView.contentSize.height + scrollView.adjustedContentInset.top +
        scrollView.adjustedContentInset.bottom - CGRectGetHeight(scrollView.bounds);
    if (range < TBHDistance * 1.5) return NO;
    return !TBHOnShorts(bar);
}

@interface TBHPanTracker : NSObject
@end

@implementation TBHPanTracker

// Decides at finger-lift, projecting a fling forward the way UIScrollView will.
- (void)pan:(UIPanGestureRecognizer *)pan {
    UIScrollView *scrollView = (UIScrollView *)pan.view;
    UIView *bar = TBHBar;
    if (bar == nil || ![scrollView isKindOfClass:UIScrollView.class]) return;
    if (pan.state == UIGestureRecognizerStateBegan) {
        if (!TBHEligible(scrollView, bar)) return;
        TBHScroll = scrollView;
        TBHLastOffset = scrollView.contentOffset.y;
        return;
    }
    if (pan.state != UIGestureRecognizerStateEnded && pan.state != UIGestureRecognizerStateCancelled &&
        pan.state != UIGestureRecognizerStateFailed) return;
    if (TBHScroll != scrollView) return;
    BOOL hidden = TBHBarHidden(bar);
    CGFloat progress = TBHProgress;
    CGFloat velocity = -[pan velocityInView:scrollView].y;
    if (pan.state == UIGestureRecognizerStateEnded && fabs(velocity) > 50.0) {
        CGFloat rate = scrollView.decelerationRate;
        CGFloat travel = velocity / 1000.0 * rate / MAX(0.0001, 1.0 - rate);
        CGFloat minY = -scrollView.adjustedContentInset.top;
        CGFloat maxY = MAX(minY, scrollView.contentSize.height + scrollView.adjustedContentInset.bottom -
                                 CGRectGetHeight(scrollView.bounds));
        CGFloat target = MAX(minY, MIN(maxY, scrollView.contentOffset.y + travel));
        progress += (target - scrollView.contentOffset.y) / TBHDistance;
        if (target <= minY + 0.5) progress = 0.0;
    }
    if (progress >= 1.0) {
        if (hidden) TBHProgress = 1.0;
        else TBHSetBarHidden(bar, YES);
    } else if (hidden) {
        TBHSetBarHidden(bar, NO);
    } else {
        TBHProgress = 0.0;
    }
}

@end

static IMP OriginalScrollSetContentOffset;

static void TBHScrollSetContentOffset(UIScrollView *receiver, SEL selector, CGPoint offset) {
    ((void (*)(id, SEL, CGPoint))OriginalScrollSetContentOffset)(receiver, selector, offset);
    UIView *bar = TBHBar;
    if (bar == nil) return;
    // Is this movement caused by the user? Directly (being dragged or flinging), or indirectly:
    // some pages (e.g. History, with its collapsing header) nest two scroll views, where the
    // finger drives an outer one that only moves the header and code moves the inner list.
    CFTimeInterval now = CACurrentMediaTime();
    BOOL touching = receiver.isTracking || receiver.isDecelerating;
    if (touching) TBHLastTouchTime = now;
    BOOL userDriven = touching || now - TBHLastTouchTime < 0.25;
    // First time the user drags this scroll view: also follow its pan gesture (fling projection).
    if (receiver.isTracking && objc_getAssociatedObject(receiver, TBHPanKey) == nil) {
        static TBHPanTracker *tracker;
        if (tracker == nil) tracker = [TBHPanTracker new];
        objc_setAssociatedObject(receiver, TBHPanKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [receiver.panGestureRecognizer addTarget:tracker action:@selector(pan:)];
    }
    CGFloat y = receiver.contentOffset.y;
    if (receiver != TBHScroll) {
        // Follow the page's main feed: the first tall, long scroll view the user moves.
        if (!userDriven || !TBHEligible(receiver, bar)) return;
        TBHScroll = receiver;
        TBHLastOffset = y;
        return;
    }
    BOOL hidden = TBHBarHidden(bar);
    static BOOL lastHidden;
    if (hidden != lastHidden) { // changed by YouTube itself (Home, tab switch, navigation)
        lastHidden = hidden;
        TBHProgress = hidden ? 1.0 : 0.0;
    }
    if (y <= -receiver.adjustedContentInset.top + 0.5) { // back at the top
        TBHLastOffset = y;
        if (hidden) TBHSetBarHidden(bar, NO);
        else TBHProgress = 0.0;
        return;
    }
    if (!userDriven) { // YouTube moving the feed by itself (restoring a position etc.)
        TBHLastOffset = y;
        return;
    }
    CGFloat delta = y - TBHLastOffset;
    TBHLastOffset = y;
    if (fabs(delta) < 0.01) return;
    CGFloat progress = MAX(hidden ? 0.01 : 0.0, MIN(1.0, TBHProgress + delta / TBHDistance));
    if (!hidden && progress >= 1.0) {
        TBHSetBarHidden(bar, YES);
        return;
    }
    // Bring the bar back as soon as the user scrolls up a little (about 25pt).
    if (hidden && progress <= 0.6) {
        TBHSetBarHidden(bar, NO);
        return;
    }
    TBHProgress = progress;
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
        TBHHookMethod(UIScrollView.class, @"setContentOffset:", (IMP)TBHScrollSetContentOffset, &OriginalScrollSetContentOffset);
    }
}

BOOL TBHPivotItemSelected(UIView *item) {
    return TBHItemSelected(item);
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
