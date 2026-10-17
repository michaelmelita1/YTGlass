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

#pragma mark - The mini player follows the bar

// YouTube only moves its floating mini player for its own hiding of the bar (on Home), not for ours on the other
// pages, which left a gap below it. Whoever hides or shows the bar, the mini player is moved down by the
// bar's height above the home indicator, or back, with the bar's own animation, while it's docked at the bottom (not
// dragged to the top); when YouTube docks it itself (after a drag) it's placed again for where the bar is.
static __weak UIView *TBHMini; // the mini player, recorded as it appears and moves (YTWatchFloating... hooks)

// The animation YouTube just added to the bar's position (on the bar or the view it moves), if any.
static CAAnimation *TBHBarAnimation(UIView *bar) {
    for (UIView *view = bar; view != nil && ![NSStringFromClass(view.class) isEqualToString:@"YTAppView"]; view = view.superview) {
        for (NSString *key in view.layer.animationKeys) {
            if ([key rangeOfString:@"position"].location == NSNotFound && [key rangeOfString:@"bounds"].location == NSNotFound &&
                [key rangeOfString:@"transform"].location == NSNotFound) continue;
            CAAnimation *animation = [view.layer animationForKey:key];
            if (animation) return animation;
        }
    }
    return nil;
}

// Where the docked mini player should sit: YouTube docks it a little above the bar's top, but measures that from the
// shown bar or from the hidden one depending on when it docked; the shift puts it the same distance above wherever the
// bar is now. Not docked (dragged up): no shift.
static CGFloat TBHMiniShift(UIView *mini, UIView *bar, BOOL barHidden) {
    UIWindow *window = mini.window;
    if (window == nil) return 0.0;
    CGPoint center = [mini.superview convertPoint:mini.center toView:nil]; // where YouTube put it (ignores the transform)
    CGFloat bottom = center.y + CGRectGetHeight(mini.bounds) / 2.0;
    CGFloat height = CGRectGetHeight(window.bounds);
    CGFloat shownTop = height - CGRectGetHeight(bar.bounds), hiddenTop = height - window.safeAreaInsets.bottom;
    if (bottom < shownTop - 40.0) return 0.0;
    CGFloat gap = bottom <= shownTop + 4.0 ? shownTop - bottom : hiddenTop - bottom; // YouTube's distance to the bar
    return (barHidden ? hiddenTop : shownTop) - gap - bottom;
}

static void TBHMoveMini(UIView *mini, BOOL barHidden, BOOL withBar) {
    UIView *bar = TBHBar;
    if (mini == nil || bar == nil) return;
    CGFloat target = TBHMiniShift(mini, bar, barHidden);
    CALayer *shown = mini.layer.presentationLayer ?: mini.layer;
    CGFloat from = [[shown valueForKeyPath:@"transform.translation.y"] doubleValue];
    if (fabs(from - target) < 0.5 && fabs(mini.transform.ty - target) < 0.5) return;
    mini.transform = CGAffineTransformMakeTranslation(0.0, target);
    // The same animation YouTube gives the bar (its duration and curve, or spring), so they move as one.
    CAAnimation *barAnimation = withBar ? TBHBarAnimation(bar) : nil;
    CABasicAnimation *animation = [barAnimation isKindOfClass:CABasicAnimation.class] ? [barAnimation copy] : nil; // and springs
    if (animation == nil) {
        CABasicAnimation *basic = [CABasicAnimation animation];
        basic.duration = 0.25;
        basic.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        animation = basic;
    }
    animation.keyPath = @"transform.translation.y";
    animation.additive = NO;
    animation.removedOnCompletion = YES;
    animation.fromValue = @(from);
    animation.toValue = @(target);
    animation.byValue = nil;
    [mini.layer addAnimation:animation forKey:@"ytglass.follow"];
}

static IMP OriginalHidePivotBar, OriginalShowPivotBar;

static void TBHHidePivotBar(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))OriginalHidePivotBar)(self, _cmd);
    if (TBHMini.window == self.window) TBHMoveMini(TBHMini, YES, YES);
}

static void TBHShowPivotBar(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))OriginalShowPivotBar)(self, _cmd);
    if (TBHMini.window == self.window) TBHMoveMini(TBHMini, NO, YES);
}

// YouTube moved the mini player (it docked after a drag, or appeared): placed again for where the bar is, once it
// has settled (one check, pushed back while it keeps moving, so not while it's being dragged).
static IMP OriginalMiniSetCenter, OriginalMiniDidMoveToWindow;
static CFTimeInterval TBHMiniMovedAt;
static BOOL TBHMiniCheckPending;

static void TBHMiniCheck(void) {
    CFTimeInterval wait = TBHMiniMovedAt + 0.12 - CACurrentMediaTime();
    if (wait > 0.0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ TBHMiniCheck(); });
        return;
    }
    TBHMiniCheckPending = NO;
    UIView *mini = TBHMini, *bar = TBHBar;
    if (mini && bar) TBHMoveMini(mini, TBHBarHidden(bar), NO);
}

static void TBHMiniSetCenter(UIView *self, SEL _cmd, CGPoint center) {
    ((void (*)(id, SEL, CGPoint))OriginalMiniSetCenter)(self, _cmd, center);
    TBHMini = self;
    // Moved away from the bottom (dragged up): our shift goes at once, so it stays where YouTube puts it.
    UIView *bar = TBHBar;
    if (bar && fabs(self.transform.ty) > 0.5 && fabs(TBHMiniShift(self, bar, YES)) < 0.5) {
        [self.layer removeAnimationForKey:@"ytglass.follow"];
        self.transform = CGAffineTransformIdentity;
    }
    TBHMiniMovedAt = CACurrentMediaTime();
    if (TBHMiniCheckPending) return;
    TBHMiniCheckPending = YES;
    TBHMiniCheck();
}

// YouTube moves it by frame while it's dragged; with our shift on, that frame would include it. YouTube's frame is
// taken as where it wants the mini player (its centre), and our shift goes on top as usual.
static IMP OriginalMiniSetFrame;

static void TBHMiniSetFrame(UIView *self, SEL _cmd, CGRect frame) {
    if (CGAffineTransformIsIdentity(self.transform)) {
        ((void (*)(id, SEL, CGRect))OriginalMiniSetFrame)(self, _cmd, frame);
        TBHMiniSetCenter(self, @selector(setCenter:), self.center); // noted like any other move
        return;
    }
    self.bounds = CGRectMake(0.0, 0.0, CGRectGetWidth(frame), CGRectGetHeight(frame));
    self.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
}

static void TBHMiniDidMoveToWindow(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))OriginalMiniDidMoveToWindow)(self, _cmd);
    if (self.window) TBHMini = self;
}

#pragma mark - Scroll tracking (from YTKACE)

// The scroll offset at the end of the list (past it, the list is bouncing back or loading more).
static CGFloat TBHListEnd(UIScrollView *scrollView) {
    return scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - CGRectGetHeight(scrollView.bounds);
}

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
    if (scrollView.contentOffset.y >= TBHListEnd(scrollView) - 0.5) return; // let go past the end of the list: leave the bar as it is
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
    // Past the end of the list (it bounces back, or new videos are still loading in): not a scroll up.
    CGFloat end = TBHListEnd(receiver);
    if (y >= end - 0.5 || TBHLastOffset >= end - 0.5) {
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
        Class appView = NSClassFromString(@"YTAppView");
        TBHHookMethod(appView, @"hidePivotBar", (IMP)TBHHidePivotBar, &OriginalHidePivotBar);
        TBHHookMethod(appView, @"showPivotBar", (IMP)TBHShowPivotBar, &OriginalShowPivotBar);
        Class mini = NSClassFromString(@"YTWatchFloatingMiniplayerWithPersistentControlsView");
        TBHHookMethod(mini, @"setCenter:", (IMP)TBHMiniSetCenter, &OriginalMiniSetCenter);
        TBHHookMethod(mini, @"setFrame:", (IMP)TBHMiniSetFrame, &OriginalMiniSetFrame);
        TBHHookMethod(mini, @"didMoveToWindow", (IMP)TBHMiniDidMoveToWindow, &OriginalMiniDidMoveToWindow);
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
