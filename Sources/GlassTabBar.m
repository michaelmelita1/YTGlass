// GlassTabBar
// Our own Liquid Glass tab bar, drawn on YouTube's YTPivotBarView, whatever YTPlus is set to (its system UITabBar, if
// it adds one, is hidden and YouTube's own tab buttons shown again): a glass capsule holding YouTube's own tab buttons, a pill behind the selected tab, and (Search: Separate) a round
// glass search button. Capsule and button sit in one UIGlassContainerEffect, so iOS merges their glass when they come
// close: dragging along the bar past the last tab stretches the capsule into the button, and letting go there opens
// search, like the iOS 26 Phone app. The capsule's geometry and the way YouTube's bar is cleared follow YTKACE
// (https://github.com/itzzace/ytkace) v1.1.3, Tweak/Features/Navigation/TabBarHooks.mm. MIT License, Copyright (c)
// 2026 YTKACE contributors. See LICENSE.
//
// Pure Objective-C runtime swizzling: no CydiaSubstrate / ElleKit dependency.

#import "Common.h"

static CGFloat const GTMargin = 21.0;        // capsule to the screen edges
static CGFloat const GTSearchGap = 12.0;     // capsule to the search button
static CGFloat const GTMergeSpacing = 10.0;  // glass closer than this merges (just under the gap)
static CGFloat const GTPillInset = 4.0;      // selection pill inside the capsule
static CGFloat const GTStretchMax = 28.0;    // how far the capsule follows a drag past its end

static const void *GTStateKey = &GTStateKey; // YTPivotBarView -> GTState

@interface GTState : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *bar;
@property (nonatomic, strong) UIVisualEffectView *container, *capsule, *search;
@property (nonatomic, strong) UIView *pill;
@property (nonatomic, strong) NSHashTable<UIView *> *faded; // YouTube's background views we made invisible
@property (nonatomic, assign) CGRect capsuleFrame;          // at rest
@property (nonatomic, assign) CGFloat stretch;              // capsule's extra width while dragged past its end
@end

#pragma mark - Glass

static UIVisualEffect *GTGlass(BOOL interactive) {
    Class effectClass = NSClassFromString(@"UIGlassEffect");
    if (effectClass == Nil) return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    SEL style = NSSelectorFromString(@"effectWithStyle:");
    UIVisualEffect *effect = [effectClass respondsToSelector:style] ? ((id (*)(id, SEL, NSInteger))objc_msgSend)(effectClass, style, 0) : [effectClass new];
    SEL setInteractive = NSSelectorFromString(@"setInteractive:");
    if (interactive && [effect respondsToSelector:setInteractive]) ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, setInteractive, YES);
    return effect;
}

static UIVisualEffect *GTContainerEffect(void) {
    Class containerClass = NSClassFromString(@"UIGlassContainerEffect");
    UIVisualEffect *effect = containerClass ? [containerClass new] : nil;
    SEL spacing = NSSelectorFromString(@"setSpacing:");
    if ([effect respondsToSelector:spacing]) ((void (*)(id, SEL, CGFloat))objc_msgSend)(effect, spacing, GTMergeSpacing);
    return effect;
}

static UIVisualEffectView *GTGlassView(BOOL interactive) {
    UIVisualEffectView *view = [[UIVisualEffectView alloc] initWithEffect:GTGlass(interactive)];
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.clipsToBounds = NO;
    return view;
}

#pragma mark - YouTube's tab buttons

static void GTCollectItems(UIView *view, NSMutableArray<UIView *> *items) {
    static Class itemClass;
    if (itemClass == Nil) itemClass = NSClassFromString(@"YTPivotBarItemView");
    if (itemClass && [view isKindOfClass:itemClass]) {
        if (!view.hidden && CGRectGetWidth(view.bounds) > 0.0) [items addObject:view];
        return;
    }
    for (UIView *subview in view.subviews) GTCollectItems(subview, items);
}

static NSArray<UIView *> *GTItems(UIView *bar) {
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    GTCollectItems(bar, items);
    [items sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return [@(CGRectGetMinX([a convertRect:a.bounds toView:bar])) compare:@(CGRectGetMinX([b convertRect:b.bounds toView:bar]))];
    }];
    return items;
}

static BOOL GTHoldsItems(UIView *view) {
    NSMutableArray *items = [NSMutableArray array];
    GTCollectItems(view, items);
    return items.count != 0;
}

#pragma mark - Layout

static CGRect GTSlot(CGRect capsule, NSUInteger count, NSUInteger index) {
    CGFloat width = count ? (CGRectGetWidth(capsule) - GTPillInset * 2.0) / (CGFloat)count : 0.0;
    return CGRectMake(CGRectGetMinX(capsule) + GTPillInset + width * (CGFloat)index, CGRectGetMinY(capsule), width, CGRectGetHeight(capsule));
}

static void GTPlaceCapsule(GTState *state) {
    CGRect frame = state.capsuleFrame;
    frame.size.width += state.stretch;
    state.capsule.frame = frame;
    state.capsule.layer.cornerRadius = CGRectGetHeight(frame) / 2.0;
}

static void GTPlacePill(GTState *state, NSArray<UIView *> *items, BOOL animated) {
    UIView *selected = nil;
    for (UIView *item in items) if (TBHPivotItemSelected(item)) selected = item;
    if (selected == nil) { state.pill.hidden = YES; return; }
    CGRect slot = GTSlot(state.capsuleFrame, items.count, [items indexOfObject:selected]);
    CGRect frame = [state.container.contentView convertRect:CGRectInset(slot, 0.0, GTPillInset) fromView:state.bar];
    frame = [state.capsule.contentView convertRect:frame fromView:state.container.contentView];
    if (CGRectEqualToRect(state.pill.frame, frame) && !state.pill.hidden) return;
    BOOL move = animated && !state.pill.hidden && !CGRectIsEmpty(state.pill.frame);
    state.pill.hidden = NO;
    state.pill.layer.cornerRadius = CGRectGetHeight(frame) / 2.0;
    if (move) {
        [UIView animateWithDuration:0.35 delay:0.0 usingSpringWithDamping:0.8 initialSpringVelocity:0.3
                            options:UIViewAnimationOptionBeginFromCurrentState animations:^{ state.pill.frame = frame; } completion:nil];
    } else {
        state.pill.frame = frame;
    }
}

static void GTLayout(UIView *bar, GTState *state) {
    // YouTube's own background goes (its blur, and full-height or hairline views that hold no tab button).
    SEL blurSel = NSSelectorFromString(@"blurView");
    UIView *blur = [bar respondsToSelector:blurSel] ? ((id (*)(id, SEL))objc_msgSend)(bar, blurSel) : nil;
    if ([blur isKindOfClass:UIView.class]) blur.hidden = YES;
    for (UIView *sibling in bar.subviews) {
        if (sibling == state.container) continue;
        if (GTHoldsItems(sibling)) {
            sibling.backgroundColor = UIColor.clearColor;
            sibling.opaque = NO;
        } else if (sibling.alpha > 0.0 && (CGRectGetHeight(sibling.frame) >= CGRectGetHeight(bar.bounds) * 0.6 || CGRectGetHeight(sibling.frame) <= 1.5)) {
            sibling.alpha = 0.0;
            [state.faded addObject:sibling];
        }
    }
    bar.backgroundColor = UIColor.clearColor;
    bar.opaque = NO;
    bar.clipsToBounds = NO;
    bar.layer.masksToBounds = NO;

    // The capsule: tab height plus 7pt above and below, 21pt from the edges, narrower for few tabs (as YTKACE).
    NSArray<UIView *> *items = GTItems(bar);
    CGFloat itemHeight = CGRectGetHeight(bar.bounds) - bar.safeAreaInsets.bottom;
    CGFloat height = MAX(itemHeight, 44.0) + 14.0;
    CGFloat top = MIN(0.0, CGRectGetHeight(bar.bounds) - height - 4.0);
    BOOL withSearch = YTGSearchMode() == YTGSearchSeparate;
    CGFloat available = CGRectGetWidth(bar.bounds) - GTMargin * 2.0 - (withSearch ? height + GTSearchGap : 0.0);
    CGFloat width = available;
    if (items.count > 0 && items.count <= 4) width = MIN(width, 86.0 * (CGFloat)items.count + 16.0);
    CGFloat groupWidth = width + (withSearch ? GTSearchGap + height : 0.0);
    CGFloat left = (CGRectGetWidth(bar.bounds) - groupWidth) / 2.0;
    state.capsuleFrame = CGRectMake(left, top, width, height);

    state.container.frame = bar.bounds;
    if (state.container.superview != bar) [bar insertSubview:state.container atIndex:0];
    else if (bar.subviews.firstObject != state.container) [bar sendSubviewToBack:state.container];
    GTPlaceCapsule(state);
    state.search.hidden = !withSearch;
    if (withSearch) {
        state.search.frame = CGRectMake(CGRectGetMaxX(state.capsuleFrame) + GTSearchGap, top, height, height);
        state.search.layer.cornerRadius = height / 2.0;
    }

    // YouTube's tab buttons, one slot each across the capsule (they stay YouTube's: taps work as before).
    for (NSUInteger index = 0; index < items.count; index++) {
        UIView *item = items[index];
        CGRect slot = GTSlot(state.capsuleFrame, items.count, index);
        CGRect current = [item convertRect:item.bounds toView:bar];
        CGRect target = CGRectMake(CGRectGetMinX(slot), CGRectGetMidY(slot) - CGRectGetHeight(current) / 2.0, CGRectGetWidth(slot), CGRectGetHeight(current));
        CGRect local = [bar convertRect:target toView:item.superview];
        if (!CGRectEqualToRect(CGRectIntegral(item.frame), CGRectIntegral(local))) item.frame = local;
    }
    GTPlacePill(state, items, YES);
}

#pragma mark - Search: tap, and stretching into it

@implementation GTState

- (void)searchTapped:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateEnded) YTGOpenSearch(self.bar);
}

// Dragging along the bar past the last tab: the capsule follows (rubber-banded) and merges with the search button;
// letting go over the button opens search. Anything else springs back.
- (void)stretched:(UIPanGestureRecognizer *)pan {
    UIView *bar = self.bar;
    if (bar == nil || self.search.hidden) return;
    CGPoint point = [pan locationInView:bar];
    CGFloat past = point.x - CGRectGetMaxX(self.capsuleFrame);
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        CGFloat stretch = past <= 0.0 ? 0.0 : GTStretchMax * (1.0 - exp(-past / GTStretchMax)); // rubber band
        self.stretch = stretch;
        GTPlaceCapsule(self);
        return;
    }
    BOOL overSearch = CGRectContainsPoint(CGRectInset(self.search.frame, -6.0, -6.0), point) && pan.state == UIGestureRecognizerStateEnded;
    self.stretch = 0.0;
    [UIView animateWithDuration:0.45 delay:0.0 usingSpringWithDamping:0.7 initialSpringVelocity:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ GTPlaceCapsule(self); } completion:nil];
    if (overSearch) YTGOpenSearch(bar);
}

- (BOOL)gestureRecognizerShouldBegin:(UIPanGestureRecognizer *)pan {
    CGPoint velocity = [pan velocityInView:pan.view];
    return fabs(velocity.x) > fabs(velocity.y); // sideways drags only; scrolling and taps go on as usual
}

- (BOOL)gestureRecognizer:(__unused UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(__unused UIGestureRecognizer *)b {
    return YES;
}

@end

static GTState *GTStateFor(UIView *bar) {
    GTState *state = objc_getAssociatedObject(bar, GTStateKey);
    if (state) return state;
    state = [GTState new];
    state.bar = bar;
    state.faded = [NSHashTable weakObjectsHashTable];
    state.container = [[UIVisualEffectView alloc] initWithEffect:GTContainerEffect()];
    state.container.userInteractionEnabled = YES;
    state.capsule = GTGlassView(NO);
    state.capsule.userInteractionEnabled = NO;
    state.search = GTGlassView(YES);
    state.search.accessibilityLabel = @"Search";
    state.search.isAccessibilityElement = YES;
    state.search.accessibilityTraits = UIAccessibilityTraitButton;
    UIImageView *glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:19.0 weight:UIImageSymbolWeightMedium]]];
    glyph.tintColor = UIColor.labelColor;
    glyph.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                             UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [state.search.contentView addSubview:glyph];
    [state.search addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:state action:@selector(searchTapped:)]];
    state.pill = [UIView new];
    state.pill.userInteractionEnabled = NO;
    state.pill.layer.cornerCurve = kCACornerCurveContinuous;
    state.pill.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return [UIColor colorWithWhite:0.0 alpha:traits.userInterfaceStyle == UIUserInterfaceStyleDark ? 0.4 : 0.08]; // as YTKACE
    }];
    [state.capsule.contentView addSubview:state.pill];
    [state.container.contentView addSubview:state.capsule];
    [state.container.contentView addSubview:state.search];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:state action:@selector(stretched:)];
    pan.delegate = state;
    pan.cancelsTouchesInView = NO;
    [bar addGestureRecognizer:pan];
    objc_setAssociatedObject(bar, GTStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return state;
}

#pragma mark - Hooks

static IMP OriginalBarLayout, OriginalBarHitTest, OriginalItemSetSelected;

// YTPlus's Liquid Glass tab bar is a system UITabBar over YouTube's own buttons, which it hides: ours uses YouTube's.
static void GTTakeOverFromYTPlus(UIView *bar) {
    static Class itemClass;
    if (itemClass == Nil) itemClass = NSClassFromString(@"YTPivotBarItemView");
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:bar.subviews];
    for (NSUInteger i = 0; i < queue.count && i < 400; i++) {
        UIView *view = queue[i];
        if ([view isKindOfClass:UITabBar.class]) {
            if (!view.hidden) view.hidden = YES;
            continue;
        }
        if ([view isKindOfClass:itemClass]) {
            for (UIView *v = view; v != nil && v != bar; v = v.superview) {
                if (v.hidden) v.hidden = NO;
                if (v.alpha < 1.0) v.alpha = 1.0;
            }
            continue;
        }
        [queue addObjectsFromArray:view.subviews];
    }
}

static void GTBarLayout(UIView *self, SEL _cmd) {
    if (OriginalBarLayout) ((void (*)(id, SEL))OriginalBarLayout)(self, _cmd);
    GTTakeOverFromYTPlus(self);
    GTState *state = GTStateFor(self);
    GTLayout(self, state);
    UIImageView *glyph = state.search.contentView.subviews.firstObject;
    glyph.center = CGPointMake(CGRectGetWidth(state.search.bounds) / 2.0, CGRectGetHeight(state.search.bounds) / 2.0);
}

// The search button sits outside the bar's tab buttons; taps on it reach it.
static UIView *GTBarHitTest(UIView *self, SEL _cmd, CGPoint point, UIEvent *event) {
    GTState *state = objc_getAssociatedObject(self, GTStateKey);
    if (state && !state.search.hidden &&
        CGRectContainsPoint(CGRectInset([self convertRect:state.search.bounds fromView:state.search], -4.0, -4.0), point)) {
        return state.search;
    }
    return ((UIView * (*)(id, SEL, CGPoint, UIEvent *))OriginalBarHitTest)(self, _cmd, point, event);
}

static void GTItemSetSelected(UIView *self, SEL _cmd, BOOL selected) {
    ((void (*)(id, SEL, BOOL))OriginalItemSetSelected)(self, _cmd, selected);
    if (!selected) return;
    UIView *bar = self.superview;
    while (bar && ![NSStringFromClass(bar.class) isEqualToString:@"YTPivotBarView"]) bar = bar.superview;
    GTState *state = bar ? objc_getAssociatedObject(bar, GTStateKey) : nil;
    if (state) GTPlacePill(state, GTItems(bar), YES);
}

__attribute__((constructor)) static void GTInit(void) {
    if (!YTGOptInEnabled(YTGGlassTabBarKey) || NSClassFromString(@"UIGlassEffect") == Nil) return;
    @autoreleasepool {
        Class bar = NSClassFromString(@"YTPivotBarView");
        TBHHookMethod(bar, @"layoutSubviews", (IMP)GTBarLayout, &OriginalBarLayout);
        TBHHookMethod(bar, @"hitTest:withEvent:", (IMP)GTBarHitTest, &OriginalBarHitTest);
        TBHHookMethod(NSClassFromString(@"YTPivotBarItemView"), @"setSelected:", (IMP)GTItemSetSelected, &OriginalItemSetSelected);
    }
}
