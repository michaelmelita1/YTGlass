// GlassTabBar
// Our own Liquid Glass tab bar, drawn on YouTube's own YTPivotBarView and independent of other tweaks (use it with
// YTPlus's Liquid Glass tab bar off): a glass capsule holding YouTube's own tab buttons, iOS's liquid lens behind the
// selected tab, and (Search: Separate) a round glass search button.
//
// Touch: pressing lifts the lens (it magnifies the tabs under it), dragging moves it across the tabs, letting go
// selects the nearest tab and the lens drops back with a bounce; tapping the selected tab bumps it. Capsule and search
// button sit in one UIGlassContainerEffect, so iOS merges their glass when they come close: dragging past the last tab
// stretches the capsule into the button, and letting go there opens search, like the iOS 26 Phone app.
//
// The capsule's geometry, the way YouTube's bar is cleared and the lens (_UILiquidLensView with a _UITabSelectionView
// resting background, lifted over a tinted copy of the tabs) are ported from YTKACE (https://github.com/itzzace/ytkace)
// v1.1.3, Tweak/Features/Navigation/TabBarHooks.mm. MIT License, Copyright (c) 2026 YTKACE contributors. See LICENSE.
//
// Pure Objective-C runtime swizzling: no CydiaSubstrate / ElleKit dependency.

#import "Common.h"

static CGFloat const GTMargin = 21.0;        // capsule to the screen edges
static CGFloat const GTSearchGap = 12.0;     // capsule to the search button
static CGFloat const GTMergeSpacing = 10.0;  // glass closer than this merges (just under the gap)
static CGFloat const GTLensInset = 4.0;      // resting lens inside the capsule
static CGFloat const GTLift = 16.0;          // the lens grows by this while lifted
static CGFloat const GTStretchMax = 28.0;    // how far the capsule follows a drag past its end

static const void *GTStateKey = &GTStateKey; // YTPivotBarView -> GTState

@interface GTState : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *bar;
@property (nonatomic, strong) UIVisualEffectView *container, *capsule, *search;
@property (nonatomic, strong) UIView *lens;           // _UILiquidLensView (a plain pill where that's missing)
@property (nonatomic, strong) UIView *magnified;      // the tinted copy of the tabs the lifted lens shows
@property (nonatomic, weak) UIView *holed;            // the tabs' container, masked under the lens while lifted
@property (nonatomic, strong) id moving;              // set while the lens is being moved by touch or animation
@property (nonatomic, strong) CADisplayLink *link;    // keeps the copy's mask on the lens while it moves
@property (nonatomic, assign) CFTimeInterval linkUntil;
@property (nonatomic, copy) dispatch_block_t lowerOnArrival;
@property (nonatomic, assign) CGFloat lowerX;
@property (nonatomic, strong) NSHashTable<UIView *> *faded; // YouTube's background views we made invisible
@property (nonatomic, assign) CGRect capsuleFrame;          // at rest
@property (nonatomic, assign) CGFloat stretch;              // capsule's extra width while dragged past its end
// The current press.
@property (nonatomic, assign) BOOL lifted, dragging;
@property (nonatomic, assign) CGPoint startPoint;
@property (nonatomic, assign) CGFloat restingWidth, anchorX;
@property (nonatomic, weak) UIView *touchedItem;
@property (nonatomic, assign) NSUInteger pressID;
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

static BOOL GTHoldsItems(UIView *view) {
    NSMutableArray *items = [NSMutableArray array];
    GTCollectItems(view, items);
    return items.count != 0;
}

static UIView *GTItemsContainer(UIView *bar) {
    for (UIView *subview in bar.subviews) if (GTHoldsItems(subview)) return subview;
    return nil;
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

static void GTPlaceCapsule(GTState *state) {
    CGRect frame = state.capsuleFrame;
    frame.size.width += state.stretch;
    state.capsule.frame = frame;
    state.capsule.layer.cornerRadius = CGRectGetHeight(frame) / 2.0;
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
            GTLensSend(lens, @"setWarpsContentBelow:", nil, 0, YES, 2);
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
    SEL selector = NSSelectorFromString(@"setLifted:animated:alongsideAnimations:completion:");
    void (^completion)(BOOL) = ^(__unused BOOL finished) { if (done) done(); };
    if ([lens respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL, BOOL, id, id))objc_msgSend)(lens, selector, lifted, YES, animations, completion);
    } else {
        [UIView animateWithDuration:0.3 animations:animations completion:completion];
    }
}

// The magnified copy follows the lens (masked to it), and the real tabs are cut out under it.
static void GTSyncMask(GTState *state) {
    UIView *lens = state.lens, *copy = state.magnified;
    if (copy == nil || lens.superview == nil) return;
    CALayer *shown = lens.layer.presentationLayer ?: lens.layer;
    CGRect frame = [lens.superview convertRect:shown.frame toView:copy];
    UIView *mask = copy.maskView;
    if (mask == nil) {
        mask = [UIView new];
        mask.backgroundColor = UIColor.blackColor;
        mask.layer.cornerCurve = kCACornerCurveContinuous;
        copy.maskView = mask;
    }
    mask.frame = frame;
    mask.layer.cornerRadius = CGRectGetHeight(frame) / 2.0;
    UIView *items = state.holed;
    if (items == nil) return;
    CAShapeLayer *hole = [items.layer.mask isKindOfClass:CAShapeLayer.class] ? (CAShapeLayer *)items.layer.mask : nil;
    if (hole == nil) {
        hole = [CAShapeLayer layer];
        hole.fillRule = kCAFillRuleEvenOdd;
        items.layer.mask = hole;
    }
    CGRect cut = CGRectInset([lens.superview convertRect:shown.frame toView:items], 4.0, 4.0);
    UIBezierPath *path = [UIBezierPath bezierPathWithRect:CGRectInset(items.bounds, -200.0, -200.0)];
    [path appendPath:[UIBezierPath bezierPathWithRoundedRect:cut cornerRadius:CGRectGetHeight(cut) / 2.0]];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    hole.frame = items.bounds;
    hole.path = path.CGPath;
    [CATransaction commit];
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

static void GTClearMagnifier(GTState *state) {
    state.magnified.hidden = YES;
    state.holed.layer.mask = nil;
    state.holed = nil;
}

// A copy of the tabs, every one drawn selected and turned into a single tint, for the lifted lens to magnify.
static UIView *GTStencil(UIView *items, NSArray<UIView *> *tabs) {
    CGSize size = items.bounds.size;
    CGFloat scale = items.window.screen.scale ?: 3.0;
    size_t width = (size_t)ceil(size.width * scale), height = (size_t)ceil(size.height * scale);
    if (width == 0 || height == 0) return nil;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (context == NULL) return nil;
    CGContextTranslateCTM(context, 0.0, (CGFloat)height);
    CGContextScaleCTM(context, scale, -scale);
    SEL setSelected = NSSelectorFromString(@"setSelected:");
    NSMutableArray<UIView *> *flipped = [NSMutableArray array];
    for (UIView *tab in tabs) {
        if (TBHPivotItemSelected(tab) || ![tab respondsToSelector:setSelected]) continue;
        ((void (*)(id, SEL, BOOL))objc_msgSend)(tab, setSelected, YES);
        [tab layoutIfNeeded];
        [flipped addObject:tab];
    }
    CALayer *hole = items.layer.mask;
    items.layer.mask = nil;
    [items.layer renderInContext:context];
    items.layer.mask = hole;
    for (UIView *tab in flipped) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(tab, setSelected, NO);
        [tab layoutIfNeeded];
    }
    // Light or dark icons decide the tint; each pixel becomes an alpha level by its contrast.
    uint8_t *pixels = CGBitmapContextGetData(context);
    double total = 0.0, weight = 0.0;
    for (size_t i = 0; i < width * height; i++) {
        uint8_t *p = pixels + i * 4;
        if (p[3] < 128) continue;
        total += (double)MAX(p[0], MAX(p[1], p[2])) / (double)p[3];
        weight += 1.0;
    }
    BOOL bright = weight == 0.0 || total / weight > 0.5;
    for (size_t i = 0; i < width * height; i++) {
        uint8_t *p = pixels + i * 4;
        uint8_t level = 0;
        if (p[3] > 0) {
            CGFloat color = (CGFloat)MAX(p[0], MAX(p[1], p[2])) / (CGFloat)p[3];
            CGFloat contrast = bright ? color : 1.0 - color;
            level = (uint8_t)(MAX(0.0, MIN(1.0, (contrast - 0.5) / 0.35)) * (CGFloat)p[3]);
        }
        p[0] = p[1] = p[2] = p[3] = level;
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (image == NULL) return nil;
    UIImageView *copy = [[UIImageView alloc] initWithImage:[[UIImage imageWithCGImage:image scale:scale orientation:UIImageOrientationUp]
                                                             imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    CGImageRelease(image);
    copy.frame = CGRectMake(0.0, 0.0, size.width, size.height);
    copy.tintColor = bright ? UIColor.whiteColor : UIColor.blackColor;
    return copy;
}

static void GTAttachMagnifier(GTState *state, NSArray<UIView *> *tabs) {
    [state.magnified removeFromSuperview];
    state.magnified = nil;
    UIView *items = GTItemsContainer(state.bar);
    UIView *copy = items ? GTStencil(items, tabs) : nil;
    if (copy == nil || state.lens.superview == nil) return;
    copy.userInteractionEnabled = NO;
    copy.frame = [items convertRect:items.bounds toView:state.lens.superview];
    [state.lens.superview insertSubview:copy atIndex:0];
    GTLensSend(state.lens, @"setLiftedContentView:", copy, 0, NO, 0);
    state.magnified = copy;
    state.holed = items;
    GTSyncMask(state);
}

static void GTLiftLens(GTState *state, NSArray<UIView *> *tabs, CGSize size, CGPoint center) {
    UIView *lens = state.lens;
    NSUInteger pressID = state.pressID;
    GTAttachMagnifier(state, tabs);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (state.lifted && state.pressID == pressID) GTAttachMagnifier(state, GTItems(state.bar)); // after the tabs settle
    });
    state.lifted = YES;
    GTTrack(state, 0.8);
    GTSetLifted(lens, YES, ^{
        lens.bounds = CGRectMake(0.0, 0.0, size.width, size.height);
        GTSyncMask(state);
    }, nil);
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
    BOOL animate = !lens.hidden && !CGRectIsEmpty(current) && moved;
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

static void GTLayout(UIView *bar, GTState *state) {
    // YouTube's own background goes (its blur, and full-height or hairline views that hold no tab button).
    SEL blurSel = NSSelectorFromString(@"blurView");
    UIView *blur = [bar respondsToSelector:blurSel] ? ((id (*)(id, SEL))objc_msgSend)(bar, blurSel) : nil;
    if ([blur isKindOfClass:UIView.class]) blur.hidden = YES;
    for (UIView *sibling in bar.subviews) {
        if (sibling == state.container || sibling == state.magnified) continue;
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
    CGFloat width = CGRectGetWidth(bar.bounds) - GTMargin * 2.0 - (withSearch ? height + GTSearchGap : 0.0);
    if (items.count > 0 && items.count <= 4) width = MIN(width, 86.0 * (CGFloat)items.count + 16.0);
    CGFloat groupWidth = width + (withSearch ? GTSearchGap + height : 0.0);
    state.capsuleFrame = CGRectMake((CGRectGetWidth(bar.bounds) - groupWidth) / 2.0, top, width, height);

    state.container.frame = bar.bounds;
    if (state.container.superview != bar) [bar insertSubview:state.container atIndex:0];
    else if (bar.subviews.firstObject != state.container) [bar sendSubviewToBack:state.container];
    GTPlaceCapsule(state);
    state.search.hidden = !withSearch;
    if (withSearch) {
        state.search.frame = CGRectMake(CGRectGetMaxX(state.capsuleFrame) + GTSearchGap, top, height, height);
        state.search.layer.cornerRadius = height / 2.0;
        UIView *glyph = state.search.contentView.subviews.firstObject;
        glyph.center = CGPointMake(height / 2.0, height / 2.0);
    }

    // YouTube's tab buttons, one slot each across the capsule (they stay YouTube's: taps on them work as before).
    for (NSUInteger index = 0; index < items.count; index++) {
        UIView *item = items[index];
        CGRect slot = GTSlot(state.capsuleFrame, items.count, index);
        CGRect current = [item convertRect:item.bounds toView:bar];
        CGRect target = CGRectMake(CGRectGetMinX(slot), CGRectGetMidY(slot) - CGRectGetHeight(current) / 2.0, CGRectGetWidth(slot), CGRectGetHeight(current));
        CGRect local = [bar convertRect:target toView:item.superview];
        if (!CGRectEqualToRect(CGRectIntegral(item.frame), CGRectIntegral(local))) item.frame = local;
    }
    GTPlaceLens(state, items);
}

#pragma mark - Touch

@implementation GTState

- (void)tick:(CADisplayLink *)link {
    GTSyncMask(self);
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
        GTSyncMask(self);
    }
}

- (void)searchTapped:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateEnded) YTGOpenSearch(self.bar);
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (gesture.view != self.bar) return YES;
    CGPoint point = [gesture locationInView:self.bar];
    if (!CGRectContainsPoint(self.capsuleFrame, point)) return NO;
    NSArray<UIView *> *items = GTItems(self.bar);
    UIView *touched = GTItemNearX(self, items, point.x);
    if (touched && GTItemIdentifier(touched) == nil) return NO;
    // Another tab: we select it (YouTube's button doesn't also get the tap). The selected tab: YouTube's button keeps
    // its own tap (scrolling the page to the top).
    gesture.cancelsTouchesInView = touched == nil || touched != GTSelectedItem(items);
    return YES;
}

- (void)pressed:(UILongPressGestureRecognizer *)press {
    UIView *bar = self.bar, *lens = self.lens;
    if (bar == nil || lens.superview == nil) return;
    NSArray<UIView *> *items = GTItems(bar);
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
        self.pressID += 1;
        if (self.touchedItem) GTLiftLens(self, items, liftedSize, center);
        return;
    }
    if (press.state == UIGestureRecognizerStateChanged) {
        if (!self.dragging && fabs(point.x - self.startPoint.x) > 4.0) {
            self.dragging = YES;
            if (!self.lifted) { GTLiftLens(self, items, liftedSize, center); return; }
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
    self.pressID += 1;
    if (self.stretch != 0.0) {
        self.stretch = 0.0;
        GTSpring(0.45, 0.3, ^{ GTPlaceCapsule(self); });
    }
    if (!self.lifted) {
        self.moving = nil;
        UIView *tapped = self.touchedItem;
        if (ended && tapped && GTItemIdentifier(tapped) && tapped != selected) GTSelectItem(tapped);
        return;
    }
    self.lifted = NO;
    id token = [NSObject new];
    self.moving = token;
    // A tap on the selected tab bumps the lens; otherwise it goes to the nearest tab (or back, for search).
    UIView *nearest = dragging ? GTItemNearX(self, items, point.x) : self.touchedItem;
    if (!ended || toSearch || (nearest && GTItemIdentifier(nearest) == nil)) nearest = selected;
    CGRect target = nearest ? [bar convertRect:GTLensFrame(self, items, nearest) toView:host] : lens.frame;
    CGPoint slide = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
    GTSpring(0.4, 0.15, ^{
        lens.center = slide;
        GTSyncMask(self);
    });
    GTLowerOnArrival(self, slide.x, token, ^{
        GTClearMagnifier(self);
        GTSetLifted(lens, NO, ^{
            lens.bounds = CGRectMake(0.0, 0.0, CGRectGetWidth(target), CGRectGetHeight(target));
            lens.center = slide;
        }, ^{ if (self.moving == token) self.moving = nil; });
    });
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

static IMP OriginalBarLayout, OriginalBarHitTest, OriginalItemSetSelected;

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
    if (state) GTPlaceLens(state, GTItems(bar));
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
