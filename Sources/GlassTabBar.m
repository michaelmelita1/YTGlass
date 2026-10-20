// GlassTabBar
// Our own Liquid Glass tab bar, drawn on YouTube's own YTPivotBarView and independent of other tweaks (use it with
// YTPlus's Liquid Glass tab bar off): a glass capsule holding YouTube's own tab buttons, iOS's liquid lens behind the
// selected tab, and (Search: Separate) a round glass search button.
//
// Touch: pressing lifts the lens (it bends the tabs under it, iOS's own effect) and swells the glass, dragging moves
// it across the tabs, letting go selects the nearest tab and the lens drops back with a bounce; tapping the selected tab bumps it. Capsule and search
// button sit in one UIGlassContainerEffect, so iOS merges their glass when they come close: dragging past the last tab
// stretches the capsule into the button, and letting go there opens search, like the iOS 26 Phone app.
//
// The capsule's geometry, the way YouTube's bar is cleared and the lens (_UILiquidLensView with a _UITabSelectionView
// resting background) are ported from YTKACE (https://github.com/itzzace/ytkace)
// v1.1.3, Tweak/Features/Navigation/TabBarHooks.mm. MIT License, Copyright (c) 2026 YTKACE contributors. See LICENSE.
//
// Pure Objective-C runtime swizzling: no CydiaSubstrate / ElleKit dependency.

#import "Common.h"

static CGFloat const GTMargin = 21.0;        // capsule to the screen edges
static CGFloat const GTPressedScale = 1.04;  // while pressed, the glass swells (as iOS 26's tab bar does)
static CGFloat const GTSearchGap = 12.0;     // capsule to the search button
static CGFloat const GTMergeSpacing = 10.0;  // glass closer than this merges (just under the gap)
static CGFloat const GTLensInset = 4.0;      // resting lens inside the capsule
static CGFloat const GTLift = 16.0;          // the lens grows by this while lifted
static CGFloat const GTStretchMax = 28.0;    // how far the capsule follows a drag past its end

static const void *GTStateKey = &GTStateKey; // YTPivotBarView -> GTState
static const void *GTItemFrameKey = &GTItemFrameKey; // YouTube's tab button -> NSValue: the frame we gave it
static int GTPlacingItems;                           // placing them ourselves (not overridden)

@interface GTState : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *bar;
@property (nonatomic, strong) UIVisualEffectView *container, *capsule, *search;
@property (nonatomic, strong) UIView *searchItem;     // Search: Integrated, the last slot in the capsule
@property (nonatomic, strong) UIView *lens;           // _UILiquidLensView (a plain pill where that's missing)
@property (nonatomic, strong) id moving;              // set while the lens is being moved by touch or animation
@property (nonatomic, strong) CADisplayLink *link;    // watches the lens arrive (to drop it there)
@property (nonatomic, assign) CFTimeInterval linkUntil;
@property (nonatomic, copy) dispatch_block_t lowerOnArrival;
@property (nonatomic, assign) CGFloat lowerX;
@property (nonatomic, strong) NSHashTable<UIView *> *faded; // YouTube's background views we made invisible
@property (nonatomic, assign) CGRect capsuleFrame;          // at rest
@property (nonatomic, assign) CGFloat stretch;              // capsule's extra width while dragged past its end
@property (nonatomic, assign) BOOL cleared;                 // YouTube's background is cleared (until it restyles the bar)
@property (nonatomic, weak) UIView *lensItem;               // the tab the lens rests on (it only animates when this changes)
// The current press.
@property (nonatomic, assign) BOOL lifted, dragging, expanded;
@property (nonatomic, assign) CGPoint startPoint;
@property (nonatomic, assign) CGFloat restingWidth, anchorX;
@property (nonatomic, weak) UIView *touchedItem;
@end

#pragma mark - Glass

static UIVisualEffect *GTGlass(BOOL interactive) {
    Class effectClass = NSClassFromString(@"UIGlassEffect");
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

static UIColor *GTPillColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return [UIColor colorWithWhite:0.0 alpha:traits.userInterfaceStyle == UIUserInterfaceStyleDark ? 0.4 : 0.08];
    }];
}

static void GTSpring(NSTimeInterval response, CGFloat bounce, dispatch_block_t animations) {
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction;
    SEL spring = NSSelectorFromString(@"animateWithSpringDuration:bounce:initialSpringVelocity:delay:options:animations:completion:");
    if ([UIView respondsToSelector:spring]) {
        ((void (*)(id, SEL, NSTimeInterval, CGFloat, CGFloat, NSTimeInterval, UIViewAnimationOptions, id, id))objc_msgSend)(
            UIView.class, spring, response, bounce, 0.0, 0.0, options, animations, nil);
    } else {
        [UIView animateWithDuration:response delay:0.0 usingSpringWithDamping:1.0 - bounce initialSpringVelocity:0.0
                            options:options animations:animations completion:nil];
    }
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

// YouTube's tabs, then (Search: Integrated) our Search slot: the lens moves across all of them.
static NSArray<UIView *> *GTSlots(GTState *state) {
    NSArray<UIView *> *items = GTItems(state.bar);
    return YTGSearchMode() == YTGSearchInTabBar && items.count ? [items arrayByAddingObject:state.searchItem] : items;
}

static UIView *GTSelectedItem(NSArray<UIView *> *items) {
    for (UIView *item in items) if (TBHPivotItemSelected(item)) return item;
    return nil;
}

static NSString *GTItemIdentifier(UIView *item) {
    id renderer = nil, identifier = nil;
    @try { renderer = [item valueForKey:@"renderer"]; } @catch (__unused NSException *e) {}
    @try { identifier = [renderer valueForKey:@"pivotIdentifier"]; } @catch (__unused NSException *e) {}
    return [identifier isKindOfClass:NSString.class] && [identifier length] ? identifier : nil;
}

// Selects a tab the way YouTube's own button does.
static void GTSelectItem(UIView *item) {
    id delegate = nil, renderer = nil;
    @try { delegate = [item valueForKey:@"delegate"]; renderer = [item valueForKey:@"renderer"]; } @catch (__unused NSException *e) {}
    SEL tap = NSSelectorFromString(@"didTapItemWithRenderer:");
    if (renderer && [delegate respondsToSelector:tap]) {
        ((void (*)(id, SEL, id))objc_msgSend)(delegate, tap, renderer);
        return;
    }
    SEL select = NSSelectorFromString(@"selectItemWithPivotIdentifier:");
    NSString *identifier = GTItemIdentifier(item);
    if (identifier && [delegate respondsToSelector:select]) {
        ((void (*)(id, SEL, id))objc_msgSend)(delegate, select, identifier);
        return;
    }
    SEL buttonSel = NSSelectorFromString(@"navigationButton");
    UIControl *button = [item respondsToSelector:buttonSel] ? ((id (*)(id, SEL))objc_msgSend)(item, buttonSel) : nil;
    if ([button isKindOfClass:UIControl.class]) [button sendActionsForControlEvents:UIControlEventTouchUpInside];
}

#pragma mark - Geometry

static CGRect GTSlot(CGRect capsule, NSUInteger count, NSUInteger index) {
    CGFloat width = count ? (CGRectGetWidth(capsule) - GTLensInset * 2.0) / (CGFloat)count : 0.0;
    return CGRectMake(CGRectGetMinX(capsule) + GTLensInset + width * (CGFloat)index, CGRectGetMinY(capsule), width, CGRectGetHeight(capsule));
}

// The resting lens for a tab, in the bar.
static CGRect GTLensFrame(GTState *state, NSArray<UIView *> *items, UIView *item) {
    NSUInteger index = [items indexOfObject:item];
    if (index == NSNotFound) return CGRectNull;
    return CGRectInset(GTSlot(state.capsuleFrame, items.count, index), 0.0, GTLensInset);
}

static UIView *GTItemNearX(GTState *state, NSArray<UIView *> *items, CGFloat x) {
    if (items.count == 0) return nil;
    CGRect first = GTSlot(state.capsuleFrame, items.count, 0);
    NSInteger index = CGRectGetWidth(first) > 0.0 ? (NSInteger)floor((x - CGRectGetMinX(first)) / CGRectGetWidth(first)) : 0;
    return items[(NSUInteger)MAX(0, MIN((NSInteger)items.count - 1, index))];
}

// Sets a glass view's frame and radius only when they change: each set makes the glass render again, and the bar lays
// out many times while it hides and shows.
static void GTSetGlassFrame(UIView *view, CGRect frame) {
    if (!CGRectEqualToRect(view.frame, frame)) view.frame = frame;
    CGFloat radius = CGRectGetHeight(frame) / 2.0;
    if (fabs(view.layer.cornerRadius - radius) > 0.01) view.layer.cornerRadius = radius;
}

static void GTPlaceCapsule(GTState *state) {
    CGRect frame = state.capsuleFrame;
    frame.size.width += state.stretch;
    GTSetGlassFrame(state.capsule, frame);
}

#pragma mark - The lens

static BOOL GTIsSystemLens(UIView *view) {
    Class lensClass = NSClassFromString(@"_UILiquidLensView");
    return lensClass && [view isKindOfClass:lensClass];
}

static void GTLensSend(UIView *lens, NSString *name, id object, NSInteger number, BOOL flag, int kind) {
    SEL selector = NSSelectorFromString(name);
    if (![lens respondsToSelector:selector]) return;
    if (kind == 0) ((void (*)(id, SEL, id))objc_msgSend)(lens, selector, object);
    else if (kind == 1) ((void (*)(id, SEL, NSInteger))objc_msgSend)(lens, selector, number);
    else ((void (*)(id, SEL, BOOL))objc_msgSend)(lens, selector, flag);
}

static UIView *GTMakeLens(UIView *host) {
    Class lensClass = NSClassFromString(@"_UILiquidLensView");
    SEL initSel = NSSelectorFromString(@"initWithRestingBackground:");
    if (lensClass && [lensClass instancesRespondToSelector:initSel]) {
        Class selectionClass = NSClassFromString(@"_UITabSelectionView");
        BOOL native = selectionClass && [selectionClass isSubclassOfClass:UIView.class];
        UIView *resting = native ? [selectionClass new] : [UIView new];
        if (!native) resting.backgroundColor = GTPillColor();
        UIView *lens = ((id (*)(id, SEL, id))objc_msgSend)([lensClass alloc], initSel, resting);
        if ([lens isKindOfClass:UIView.class]) {
            GTLensSend(lens, @"setLiftedContainerView:", host, 0, NO, 0);
            GTLensSend(lens, @"setLiftedContentMode:", nil, 1, NO, 1);
            GTLensSend(lens, @"setStyle:", nil, 1, NO, 1);
            GTLensSend(lens, @"setWarpsContentBelow:", nil, 0, NO, 2); // only while lifted (GTSetLifted): it costs a frame at rest
            if (!native) @try { [lens setValue:GTPillColor() forKey:@"restingBackgroundColor"]; } @catch (__unused NSException *e) {}
            lens.userInteractionEnabled = NO;
            return lens;
        }
    }
    UIView *pill = [UIView new]; // no liquid lens: a plain pill
    pill.userInteractionEnabled = NO;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.backgroundColor = GTPillColor();
    return pill;
}

static void GTSetLifted(UIView *lens, BOOL lifted, dispatch_block_t animations, dispatch_block_t done) {
    if (lifted) GTLensSend(lens, @"setWarpsContentBelow:", nil, 0, YES, 2);
    SEL selector = NSSelectorFromString(@"setLifted:animated:alongsideAnimations:completion:");
    void (^completion)(BOOL) = ^(__unused BOOL finished) {
        if (!lifted) GTLensSend(lens, @"setWarpsContentBelow:", nil, 0, NO, 2);
        if (done) done();
    };
    if ([lens respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL, BOOL, id, id))objc_msgSend)(lens, selector, lifted, YES, animations, completion);
    } else {
        [UIView animateWithDuration:0.3 animations:animations completion:completion];
    }
}

static void GTTrack(GTState *state, CFTimeInterval seconds) {
    state.linkUntil = MAX(state.linkUntil, CACurrentMediaTime() + seconds);
    if (state.link == nil) {
        state.link = [CADisplayLink displayLinkWithTarget:state selector:@selector(tick:)];
        [state.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}

// Runs `lower` once the lens (moving there) has nearly arrived at x, or after a second at the latest.
static void GTLowerOnArrival(GTState *state, CGFloat x, id token, dispatch_block_t lower) {
    GTTrack(state, 1.0);
    state.lowerX = x;
    state.lowerOnArrival = ^{ if (state.moving == token) lower(); };
    dispatch_block_t pending = state.lowerOnArrival;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (state.lowerOnArrival != pending) return;
        state.lowerOnArrival = nil;
        pending();
    });
}

// Scaled about point (in the bar), for a view that's a direct subview of the bar.
static CGAffineTransform GTScaleAbout(UIView *view, CGPoint point, CGFloat scale) {
    CGFloat dx = point.x - view.center.x, dy = point.y - view.center.y;
    return CGAffineTransformTranslate(CGAffineTransformScale(CGAffineTransformMakeTranslation(dx, dy), scale, scale), -dx, -dy);
}

// The glass (capsule, lens and search button) swells about the capsule's centre while pressed, and springs back.
// YouTube's tab buttons don't scale with it: they stay where they are (scaling them moved the icons).
static void GTSetExpanded(GTState *state, BOOL expanded) {
    if (state.expanded == expanded) return;
    state.expanded = expanded;
    GTTrack(state, 0.7);
    CGPoint middle = CGPointMake(CGRectGetMidX(state.capsuleFrame), CGRectGetMidY(state.capsuleFrame));
    CGFloat scale = expanded ? GTPressedScale : 1.0;
    GTSpring(0.4, expanded ? 0.5 : 0.3, ^{
        state.container.transform = GTScaleAbout(state.container, middle, scale);
    });
}

// Lifted, the lens bends the real tabs below it (iOS's own effect: no drawn copy of them).
static void GTLiftLens(GTState *state, CGSize size, CGPoint center) {
    UIView *lens = state.lens;
    GTSetExpanded(state, YES);
    state.lifted = YES;
    GTTrack(state, 0.8);
    GTSetLifted(lens, YES, ^{ lens.bounds = CGRectMake(0.0, 0.0, size.width, size.height); }, nil);
    GTSpring(0.4, 0.15, ^{ lens.center = center; });
}

// At rest: the lens sits on the selected tab (sliding there, lifted, when the selection changes).
static void GTPlaceLens(GTState *state, NSArray<UIView *> *items) {
    if (state.moving) return;
    UIView *lens = state.lens;
    UIView *selected = GTSelectedItem(items);
    if (selected == nil) { lens.hidden = YES; return; }
    CGRect target = [state.bar convertRect:GTLensFrame(state, items, selected) toView:lens.superview];
    CGRect current = CGRectMake(lens.center.x - CGRectGetWidth(lens.bounds) / 2.0, lens.center.y - CGRectGetHeight(lens.bounds) / 2.0,
                                CGRectGetWidth(lens.bounds), CGRectGetHeight(lens.bounds));
    BOOL moved = fabs(CGRectGetMidX(current) - CGRectGetMidX(target)) > 1.0 || fabs(CGRectGetMidY(current) - CGRectGetMidY(target)) > 1.0 ||
                 fabs(CGRectGetWidth(current) - CGRectGetWidth(target)) > 1.0 || fabs(CGRectGetHeight(current) - CGRectGetHeight(target)) > 1.0;
    // Animated only when the selection moved to another tab; the bar changing size (hiding, showing) just snaps it.
    BOOL animate = !lens.hidden && !CGRectIsEmpty(current) && moved && state.lensItem != nil && state.lensItem != selected;
    state.lensItem = selected;
    lens.hidden = NO;
    if (!GTIsSystemLens(lens)) {
        lens.layer.cornerRadius = CGRectGetHeight(target) / 2.0;
        if (animate) GTSpring(0.35, 0.2, ^{ lens.frame = target; });
        else lens.frame = target;
        return;
    }
    if (!moved) return;
    CGPoint center = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
    if (!animate || fabs(CGRectGetMidX(current) - CGRectGetMidX(target)) < 12.0) {
        [UIView performWithoutAnimation:^{
            lens.bounds = CGRectMake(0.0, 0.0, CGRectGetWidth(target), CGRectGetHeight(target));
            lens.center = center;
        }];
        return;
    }
    // Lift, slide over, and drop once there.
    id token = [NSObject new];
    state.moving = token;
    CGPoint start = lens.center;
    GTSetLifted(lens, YES, ^{
        lens.bounds = CGRectMake(0.0, 0.0, CGRectGetWidth(target) + GTLift, CGRectGetHeight(target) + GTLift);
        lens.center = start;
    }, nil);
    GTSpring(0.4, 0.15, ^{ lens.center = center; });
    GTLowerOnArrival(state, center.x, token, ^{
        GTSetLifted(lens, NO, ^{
            lens.bounds = CGRectMake(0.0, 0.0, CGRectGetWidth(target), CGRectGetHeight(target));
            lens.center = center;
        }, ^{ if (state.moving == token) state.moving = nil; });
    });
}

#pragma mark - Layout

// YouTube's own background goes (its blur, and full-height or hairline views that hold no tab button). Also redone
// when YouTube restyles the bar (it does when the mini player appears).
static void GTClearBackground(UIView *bar, GTState *state, NSArray<UIView *> *items) {
    if (state.cleared) { // cheap check that YouTube hasn't brought it back some other way
        SEL blurSel = NSSelectorFromString(@"blurView");
        UIView *blur = [bar respondsToSelector:blurSel] ? ((id (*)(id, SEL))objc_msgSend)(bar, blurSel) : nil;
        BOOL back = ([blur isKindOfClass:UIView.class] && !blur.hidden) || (bar.backgroundColor && CGColorGetAlpha(bar.backgroundColor.CGColor) > 0.0);
        if (!back) return;
    }
    state.cleared = YES;
    SEL blurSel = NSSelectorFromString(@"blurView");
    UIView *blur = [bar respondsToSelector:blurSel] ? ((id (*)(id, SEL))objc_msgSend)(bar, blurSel) : nil;
    if ([blur isKindOfClass:UIView.class]) blur.hidden = YES;
    for (UIView *sibling in bar.subviews) {
        if (sibling == state.container) continue;
        BOOL holdsItems = NO;
        for (UIView *item in items) if ([item isDescendantOfView:sibling]) { holdsItems = YES; break; }
        if (holdsItems) {
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
}

static void GTLayout(UIView *bar, GTState *state) {
    NSArray<UIView *> *items = GTSlots(state);
    GTClearBackground(bar, state, items);

    // The capsule: tab height plus 7pt above and below, 21pt from the edges, narrower for few tabs (as YTKACE).
    CGFloat itemHeight = CGRectGetHeight(bar.bounds) - bar.safeAreaInsets.bottom;
    CGFloat height = MAX(itemHeight, 44.0) + 14.0;
    CGFloat top = MIN(0.0, CGRectGetHeight(bar.bounds) - height - 4.0);
    BOOL withSearch = YTGSearchMode() == YTGSearchSeparate;
    CGFloat margin = GTMargin;
    CGFloat width = CGRectGetWidth(bar.bounds) - margin * 2.0 - (withSearch ? height + GTSearchGap : 0.0);
    if (items.count > 0 && items.count <= 4) width = MIN(width, 86.0 * (CGFloat)items.count + 16.0);
    CGFloat groupWidth = width + (withSearch ? GTSearchGap + height : 0.0);
    state.capsuleFrame = CGRectMake((CGRectGetWidth(bar.bounds) - groupWidth) / 2.0, top, width, height);

    CGRect bounds = CGRectMake(0.0, 0.0, CGRectGetWidth(bar.bounds), CGRectGetHeight(bar.bounds)); // not frame: it may be scaled
    CGPoint center = CGPointMake(CGRectGetMidX(bar.bounds), CGRectGetMidY(bar.bounds));
    if (!CGRectEqualToRect(state.container.bounds, bounds)) state.container.bounds = bounds;
    if (!CGPointEqualToPoint(state.container.center, center)) state.container.center = center;
    if (state.container.superview != bar) [bar insertSubview:state.container atIndex:0];
    else if (bar.subviews.firstObject != state.container) [bar sendSubviewToBack:state.container];
    GTPlaceCapsule(state);
    state.search.hidden = !withSearch;
    if (withSearch) {
        GTSetGlassFrame(state.search, CGRectMake(CGRectGetMaxX(state.capsuleFrame) + GTSearchGap, top, height, height));
        UIView *glyph = state.search.contentView.subviews.firstObject;
        CGPoint glyphCenter = CGPointMake(height / 2.0, height / 2.0);
        if (!CGPointEqualToPoint(glyph.center, glyphCenter)) glyph.center = glyphCenter;
    }

    // YouTube's tab buttons, one slot each across the capsule (they stay YouTube's: taps on them work as before), and
    // our Search slot after them.
    state.searchItem.hidden = ![items containsObject:state.searchItem];
    if (!state.searchItem.hidden) {
        CGRect slot = GTSlot(state.capsuleFrame, items.count, items.count - 1);
        CGRect itemFrame = [bar convertRect:CGRectInset(slot, 0.0, GTLensInset) toView:state.container.contentView];
        if (!CGRectEqualToRect(state.searchItem.frame, itemFrame)) state.searchItem.frame = itemFrame;
        if (state.searchItem.superview != state.container.contentView) [state.container.contentView addSubview:state.searchItem];
    }
    for (NSUInteger index = 0; index < items.count; index++) {
        UIView *item = items[index];
        if (item == state.searchItem) continue;
        CGRect slot = GTSlot(state.capsuleFrame, items.count, index);
        CGRect current = [item convertRect:item.bounds toView:bar];
        CGRect target = CGRectMake(CGRectGetMinX(slot), CGRectGetMidY(slot) - CGRectGetHeight(current) / 2.0, CGRectGetWidth(slot), CGRectGetHeight(current));
        CGRect local = CGRectIntegral([bar convertRect:target toView:item.superview]);
        NSValue *known = objc_getAssociatedObject(item, GTItemFrameKey);
        if (known == nil || !CGRectEqualToRect(known.CGRectValue, local)) {
            objc_setAssociatedObject(item, GTItemFrameKey, [NSValue valueWithCGRect:local], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (!CGRectEqualToRect(CGRectIntegral(item.frame), local)) {
            GTPlacingItems++;
            item.frame = local;
            GTPlacingItems--;
        }
    }
    GTPlaceLens(state, items);
}

#pragma mark - Touch

@implementation GTState

- (void)tick:(CADisplayLink *)link {
    if (self.lowerOnArrival) {
        CGFloat x = (self.lens.layer.presentationLayer ?: self.lens.layer).position.x;
        if (fabs(x - self.lowerX) < 8.0) {
            dispatch_block_t lower = self.lowerOnArrival;
            self.lowerOnArrival = nil;
            lower();
        }
    }
    if (link.timestamp > self.linkUntil && self.lowerOnArrival == nil) {
        [self.link invalidate];
        self.link = nil;
    }
}

- (void)searchTapped:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateEnded) YTGOpenSearch(self.bar);
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (gesture.view != self.bar) return YES;
    CGPoint point = [gesture locationInView:self.bar];
    if (!CGRectContainsPoint(self.capsuleFrame, point)) return NO;
    NSArray<UIView *> *items = GTSlots(self);
    UIView *touched = GTItemNearX(self, items, point.x);
    if (touched && touched != self.searchItem && GTItemIdentifier(touched) == nil) return NO;
    // Another tab: we select it (YouTube's button doesn't also get the tap). The selected tab: YouTube's button keeps
    // its own tap (scrolling the page to the top).
    gesture.cancelsTouchesInView = touched == nil || touched != GTSelectedItem(items);
    return YES;
}

- (void)pressed:(UILongPressGestureRecognizer *)press {
    UIView *bar = self.bar, *lens = self.lens;
    if (bar == nil || lens.superview == nil) return;
    NSArray<UIView *> *items = GTSlots(self);
    UIView *host = lens.superview;
    CGPoint point = [press locationInView:bar];
    UIView *selected = GTSelectedItem(items);
    CGRect resting = selected ? [bar convertRect:GTLensFrame(self, items, selected) toView:host] : lens.frame;
    CGFloat lensWidth = self.lifted ? self.restingWidth : CGRectGetWidth(resting);
    CGSize liftedSize = CGSizeMake(lensWidth + GTLift, CGRectGetHeight(resting) + GTLift);

    if (press.state == UIGestureRecognizerStateBegan) {
        UIView *grabbed = GTItemNearX(self, items, point.x);
        CGRect slot = grabbed ? GTLensFrame(self, items, grabbed) : CGRectNull;
        self.anchorX = CGRectIsNull(slot) || CGRectGetWidth(slot) <= 0.0 ? 0.5 : MAX(0.0, MIN(1.0, (point.x - CGRectGetMinX(slot)) / CGRectGetWidth(slot)));
    }
    // Past the last tab (Search: Separate): the capsule stretches after the finger, rubber-banded, into the button.
    CGFloat past = point.x - CGRectGetMaxX(self.capsuleFrame);
    CGFloat stretch = (!self.search.hidden && self.dragging && past > 0.0) ? GTStretchMax * (1.0 - exp(-past / GTStretchMax)) : 0.0;
    CGFloat minX = CGRectGetMinX(self.capsuleFrame) + GTLensInset, maxX = CGRectGetMaxX(self.capsuleFrame) - GTLensInset + stretch;
    CGFloat clamped = MAX(minX + lensWidth * self.anchorX, MIN(point.x, maxX - lensWidth * (1.0 - self.anchorX)));
    CGPoint center = [bar convertPoint:CGPointMake(clamped - lensWidth * self.anchorX + lensWidth / 2.0, CGRectGetMidY(self.capsuleFrame)) toView:host];

    if (press.state == UIGestureRecognizerStateBegan) {
        self.moving = [NSObject new];
        self.startPoint = point;
        self.dragging = NO;
        self.lifted = NO;
        self.restingWidth = CGRectGetWidth(resting);
        self.touchedItem = GTItemNearX(self, items, point.x);
        if (self.touchedItem) GTLiftLens(self, liftedSize, center);
        return;
    }
    if (press.state == UIGestureRecognizerStateChanged) {
        if (!self.dragging && fabs(point.x - self.startPoint.x) > 4.0) {
            self.dragging = YES;
            if (!self.lifted) { GTLiftLens(self, liftedSize, center); return; }
        }
        if (!self.lifted) return;
        if (fabs(stretch - self.stretch) > 0.25) {
            self.stretch = stretch;
            GTPlaceCapsule(self);
        }
        GTSpring(0.2, 0.15, ^{ lens.center = center; });
        GTTrack(self, 0.4);
        return;
    }
    if (press.state != UIGestureRecognizerStateEnded && press.state != UIGestureRecognizerStateCancelled) return;

    BOOL dragging = self.dragging;
    BOOL ended = press.state == UIGestureRecognizerStateEnded;
    BOOL toSearch = ended && dragging && !self.search.hidden &&
                    CGRectContainsPoint(CGRectInset(self.search.frame, -6.0, -6.0), [bar convertPoint:point toView:self.container.contentView]);
    GTSetExpanded(self, NO);
    if (self.stretch != 0.0) {
        self.stretch = 0.0;
        GTSpring(0.45, 0.3, ^{ GTPlaceCapsule(self); });
    }
    if (!self.lifted) {
        self.moving = nil;
        UIView *tapped = self.touchedItem;
        if (ended && tapped == self.searchItem) YTGOpenSearch(bar);
        else if (ended && tapped && GTItemIdentifier(tapped) && tapped != selected) GTSelectItem(tapped);
        return;
    }
    self.lifted = NO;
    id token = [NSObject new];
    self.moving = token;
    // A tap on the selected tab bumps the lens; otherwise it goes to the nearest tab (or back, for search).
    UIView *nearest = dragging ? GTItemNearX(self, items, point.x) : self.touchedItem;
    if (ended && nearest == self.searchItem) toSearch = YES; // landed on the Search slot
    if (!ended || toSearch || (nearest && GTItemIdentifier(nearest) == nil)) nearest = selected;
    CGRect target = nearest ? [bar convertRect:GTLensFrame(self, items, nearest) toView:host] : lens.frame;
    CGPoint slide = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
    GTSpring(0.4, 0.15, ^{ lens.center = slide; });
    GTLowerOnArrival(self, slide.x, token, ^{
        GTSetLifted(lens, NO, ^{
            lens.bounds = CGRectMake(0.0, 0.0, CGRectGetWidth(target), CGRectGetHeight(target));
            lens.center = slide;
        }, ^{ if (self.moving == token) self.moving = nil; });
    });
    self.lensItem = nearest; // the lens is already on its way there
    if (toSearch) YTGOpenSearch(bar);
    else if (ended && nearest && nearest != selected) GTSelectItem(nearest);
}

@end

static GTState *GTStateFor(UIView *bar) {
    GTState *state = objc_getAssociatedObject(bar, GTStateKey);
    if (state) return state;
    state = [GTState new];
    state.bar = bar;
    state.faded = [NSHashTable weakObjectsHashTable];
    state.container = [[UIVisualEffectView alloc] initWithEffect:GTContainerEffect()];
    state.capsule = GTGlassView(NO);
    state.capsule.userInteractionEnabled = NO;
    state.capsule.contentView.clipsToBounds = NO;
    state.search = GTGlassView(YES);
    state.search.accessibilityLabel = @"Search";
    state.search.isAccessibilityElement = YES;
    state.search.accessibilityTraits = UIAccessibilityTraitButton;
    UIImageView *glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:19.0 weight:UIImageSymbolWeightMedium]]];
    glyph.tintColor = UIColor.labelColor;
    [state.search.contentView addSubview:glyph];
    [state.search addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:state action:@selector(searchTapped:)]];
    [state.container.contentView addSubview:state.capsule];
    [state.container.contentView addSubview:state.search];
    // The Search slot: a glyph and a label, sized like YouTube's tab buttons.
    UIView *searchItem = [UIView new];
    searchItem.userInteractionEnabled = NO;
    searchItem.isAccessibilityElement = YES;
    searchItem.accessibilityLabel = @"Search";
    searchItem.accessibilityTraits = UIAccessibilityTraitButton;
    UIImageView *itemGlyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20.0 weight:UIImageSymbolWeightMedium]]];
    itemGlyph.tintColor = UIColor.labelColor;
    itemGlyph.contentMode = UIViewContentModeCenter;
    UILabel *itemLabel = [UILabel new];
    itemLabel.text = @"Search";
    itemLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightMedium];
    itemLabel.textColor = UIColor.labelColor;
    itemLabel.textAlignment = NSTextAlignmentCenter;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[itemGlyph, itemLabel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 2.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [searchItem addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.centerXAnchor constraintEqualToAnchor:searchItem.centerXAnchor],
                                              [stack.centerYAnchor constraintEqualToAnchor:searchItem.centerYAnchor]]];
    state.searchItem = searchItem;
    state.lens = GTMakeLens(state.capsule.contentView);
    [state.capsule.contentView addSubview:state.lens];
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:state action:@selector(pressed:)];
    press.minimumPressDuration = 0.0;
    press.allowableMovement = CGFLOAT_MAX;
    press.cancelsTouchesInView = NO;
    press.delaysTouchesEnded = NO;
    press.delegate = state;
    [bar addGestureRecognizer:press];
    objc_setAssociatedObject(bar, GTStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return state;
}

#pragma mark - Hooks

// YouTube lays its tab buttons out again on its own passes (by frame, or by centre and bounds), which put them back
// where it wants them for a frame (the buttons jumped): a button we've placed keeps our frame, however it's moved.
static IMP OriginalItemSetFrame, OriginalItemSetCenter, OriginalItemSetBounds;

static void GTItemSetFrame(UIView *self, SEL _cmd, CGRect frame) {
    NSValue *ours = GTPlacingItems ? nil : objc_getAssociatedObject(self, GTItemFrameKey);
    ((void (*)(id, SEL, CGRect))OriginalItemSetFrame)(self, _cmd, ours ? ours.CGRectValue : frame);
}

static void GTItemSetCenter(UIView *self, SEL _cmd, CGPoint center) {
    NSValue *ours = GTPlacingItems ? nil : objc_getAssociatedObject(self, GTItemFrameKey);
    if (ours) center = CGPointMake(CGRectGetMidX(ours.CGRectValue), CGRectGetMidY(ours.CGRectValue));
    ((void (*)(id, SEL, CGPoint))OriginalItemSetCenter)(self, _cmd, center);
}

static void GTItemSetBounds(UIView *self, SEL _cmd, CGRect bounds) {
    NSValue *ours = GTPlacingItems ? nil : objc_getAssociatedObject(self, GTItemFrameKey);
    if (ours) bounds.size = ours.CGRectValue.size;
    ((void (*)(id, SEL, CGRect))OriginalItemSetBounds)(self, _cmd, bounds);
}

static IMP OriginalBarLayout, OriginalBarHitTest, OriginalItemSetSelected, OriginalStyleColors, OriginalSetBackgroundStyle;

static void GTRestyled(UIView *bar) {
    GTState *state = GTStateFor(bar);
    state.cleared = NO;
    GTClearBackground(bar, state, GTItems(bar));
}

static void GTStyleColors(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))OriginalStyleColors)(self, _cmd);
    GTRestyled(self);
}

static void GTSetBackgroundStyle(UIView *self, SEL _cmd, int style) {
    ((void (*)(id, SEL, int))OriginalSetBackgroundStyle)(self, _cmd, style);
    GTRestyled(self);
}

static void GTBarLayout(UIView *self, SEL _cmd) {
    if (OriginalBarLayout) ((void (*)(id, SEL))OriginalBarLayout)(self, _cmd);
    GTLayout(self, GTStateFor(self));
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
    if (state) GTPlaceLens(state, GTSlots(state));
}

__attribute__((constructor)) static void GTInit(void) {
    if (!YTGOptInEnabled(YTGGlassTabBarKey) || NSClassFromString(@"UIGlassEffect") == Nil) return;
    @autoreleasepool {
        Class bar = NSClassFromString(@"YTPivotBarView");
        TBHHookMethod(bar, @"layoutSubviews", (IMP)GTBarLayout, &OriginalBarLayout);
        TBHHookMethod(bar, @"hitTest:withEvent:", (IMP)GTBarHitTest, &OriginalBarHitTest);
        TBHHookMethod(bar, @"styleBackgroundColors", (IMP)GTStyleColors, &OriginalStyleColors);
        TBHHookMethod(bar, @"setBackgroundStyle:", (IMP)GTSetBackgroundStyle, &OriginalSetBackgroundStyle);
        TBHHookMethod(NSClassFromString(@"YTPivotBarItemView"), @"setSelected:", (IMP)GTItemSetSelected, &OriginalItemSetSelected);
        Class item = NSClassFromString(@"YTPivotBarItemView");
        TBHHookMethod(item, @"setFrame:", (IMP)GTItemSetFrame, &OriginalItemSetFrame);
        TBHHookMethod(item, @"setCenter:", (IMP)GTItemSetCenter, &OriginalItemSetCenter);
        TBHHookMethod(item, @"setBounds:", (IMP)GTItemSetBounds, &OriginalItemSetBounds);
    }
}
