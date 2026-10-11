// Liquid Glass video player controls (formerly the separate PlayerGlass dylib).
//
// YouTube already ships Liquid Glass behind its play/pause and previous/next buttons (and its other player
// glass views): +[YTFrostedGlassView liquidGlassEffect] returns a UIGlassEffect on iOS 26 when the
// enableLiquidGlassEffect flag is on, with liquidGlassEffectStyle 1 = regular and 2 = clear. We turn that on,
// and give the top-row buttons (captions, settings, cast, ...) the same glass circles.
//
// YTPlus puts a second row of buttons (mute, sleep timer, its menu) under the top row's quality label and settings
// button, in a UIStackView of YTQTMButtons labelled YTL...; that row is moved up between them (quality label, YTPlus's
// buttons, settings, at the row's own spacing), and the group shares one glass capsule instead of a circle each.

#import "Common.h"

static NSInteger const PGGlassStyle = 2;       // YouTube's liquidGlassEffectStyle: 1 regular, 2 clear
static CGFloat const PGTopGlassDiameter = 40.0; // glass circle behind each top-row button
static CGFloat const PGGroupPadding = 8.0;      // capsule beyond the group's outer buttons

// Hooks only when the method returns the expected type (these are YouTube flags; a changed type means a
// changed meaning).
static void PGHookTyped(Class cls, NSString *selectorName, const char *returnType, IMP replacement) {
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(selectorName)) : NULL;
    if (method == NULL) return;
    char type[8] = { 0 };
    method_getReturnType(method, type, sizeof(type));
    if (strcmp(type, returnType) == 0) TBHHookMethod(cls, selectorName, replacement, NULL);
}

#pragma mark - YouTube's own Liquid Glass

static BOOL PGEnableLiquidGlass(__unused id self, __unused SEL _cmd) { return YES; }
static NSInteger PGLiquidGlassStyle(__unused id self, __unused SEL _cmd) { return PGGlassStyle; }

#pragma mark - Top-row buttons

static const void *PGGlassKey = &PGGlassKey; // button -> its glass circle

static UIView *PGMakeGlass(void) {
    Class glassClass = NSClassFromString(@"YTFrostedGlassView");
    SEL styleSel = NSSelectorFromString(@"frostedGlassBlurEffectStyle");
    SEL initSel = NSSelectorFromString(@"initWithBlurEffectStyle:alpha:");
    if (glassClass == Nil || ![glassClass respondsToSelector:styleSel] || ![glassClass instancesRespondToSelector:initSel]) return nil;
    NSInteger style = ((NSInteger (*)(id, SEL))objc_msgSend)(glassClass, styleSel);
    UIView *glass = ((id (*)(id, SEL, NSInteger, CGFloat))objc_msgSend)([glassClass alloc], initSel, style, 1.0);
    glass.userInteractionEnabled = NO;
    return glass;
}

static void PGRemoveGlass(UIButton *button) {
    UIView *glass = objc_getAssociatedObject(button, PGGlassKey);
    if (glass.superview) [glass removeFromSuperview];
}

static void PGPlaceGlass(UIButton *button) {
    UIView *glass = objc_getAssociatedObject(button, PGGlassKey);
    if (glass == nil) {
        glass = PGMakeGlass();
        if (glass == nil) return;
        objc_setAssociatedObject(button, PGGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGRect bounds = button.bounds;
    CGFloat diameter = MIN(PGTopGlassDiameter, MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds)));
    CGRect frame = CGRectMake(CGRectGetMidX(bounds) - diameter / 2.0, CGRectGetMidY(bounds) - diameter / 2.0, diameter, diameter);
    if (!CGRectEqualToRect(glass.frame, frame)) {
        glass.frame = frame;
        SEL radiusSel = NSSelectorFromString(@"setCornerRadius:");
        if ([glass respondsToSelector:radiusSel]) ((void (*)(id, SEL, CGFloat))objc_msgSend)(glass, radiusSel, diameter / 2.0);
        else { glass.layer.cornerRadius = diameter / 2.0; glass.clipsToBounds = YES; }
    }
    if (glass.superview != button) [button insertSubview:glass atIndex:0];
    else if (button.subviews.firstObject != glass) [button sendSubviewToBack:glass];
}

// Buttons in the overlay's top row (YouTube's own and ones other tweaks add there).
static void PGCollectTopButtons(UIView *view, CGFloat maxY, UIView *overlay, Class buttonClass, int depth, NSMutableArray *out) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:buttonClass]) {
            CGRect frame = [subview convertRect:subview.bounds toView:overlay];
            if (CGRectGetHeight(frame) >= 20.0 && CGRectGetMidY(frame) < maxY) [out addObject:subview];
            continue;
        }
        if (depth > 0) PGCollectTopButtons(subview, maxY, overlay, buttonClass, depth - 1, out);
    }
}

#pragma mark - YTPlus's row

static UIView *PGFindIdentifier(UIView *view, NSString *identifier, int depth) {
    if ([view.accessibilityIdentifier isEqualToString:identifier]) return view;
    if (depth <= 0) return nil;
    for (UIView *subview in view.subviews) {
        UIView *found = PGFindIdentifier(subview, identifier, depth - 1);
        if (found) return found;
    }
    return nil;
}

static UIStackView *PGYTPlusRow(UIView *overlay, Class buttonClass) {
    for (UIView *subview in overlay.subviews) {
        if (![subview isKindOfClass:UIStackView.class]) continue;
        NSArray<UIView *> *buttons = ((UIStackView *)subview).arrangedSubviews;
        BOOL ytplus = buttons.count > 0;
        for (UIView *button in buttons) {
            if (![button isKindOfClass:buttonClass] || ![button.accessibilityLabel hasPrefix:@"YTL"]) ytplus = NO;
        }
        if (ytplus) return (UIStackView *)subview;
    }
    return nil;
}

static const void *PGGroupKey = &PGGroupKey; // settings button -> the group's glass capsule

// The top row's container, once the quality label is moved out of its bounds: taps there still reach the label.
@interface PGTopRowView : UIView
@end

@implementation PGTopRowView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit != nil && hit != self) return hit;
    for (UIView *subview in self.subviews.reverseObjectEnumerator) {
        if (CGAffineTransformIsIdentity(subview.transform) || subview.hidden || subview.alpha < 0.01 || !subview.userInteractionEnabled) continue;
        CGRect area = subview.frame; // the button and what it draws (the label sits outside its zero height)
        for (UIView *inner in subview.subviews) area = CGRectUnion(area, [subview convertRect:inner.frame toView:self]);
        if (CGRectContainsPoint(CGRectInset(area, -8.0, -8.0), point)) return subview;
    }
    return hit;
}
@end

// Moved with a transform: YTPlus keeps laying the row out where it was, and the move is worked out again each time.
// YouTube fades each button on its own, so the capsule lives in the settings button (fading with it) and reaches
// left under the quality label and YTPlus's row, which are kept above it. Returns the capsule's frame in the overlay,
// or CGRectNull.
static CGRect PGGroupYTPlusRow(UIView *overlay, Class buttonClass) {
    UIStackView *row = PGYTPlusRow(overlay, buttonClass);
    UIView *settings = PGFindIdentifier(overlay, @"id.player.overflow.button", 3);
    UIView *topRow = settings.superview;
    if (row == nil || topRow == nil || row.superview != overlay || topRow.superview != overlay) return CGRectNull;
    CGRect top = topRow.frame;
    CGRect settingsFrame = [topRow convertRect:settings.frame toView:overlay];
    CGFloat gap = row.spacing;
    // YTPlus's row right before settings.
    CGFloat rowWidth = CGRectGetWidth(row.bounds);
    CGPoint target = CGPointMake(CGRectGetMinX(settingsFrame) - gap - rowWidth / 2.0, CGRectGetMidY(top));
    CGAffineTransform move = CGAffineTransformMakeTranslation(target.x - row.center.x, target.y - row.center.y);
    if (!CGAffineTransformEqualToTransform(row.transform, move)) row.transform = move;
    if ([overlay.subviews indexOfObject:row] < [overlay.subviews indexOfObject:topRow]) [overlay insertSubview:row aboveSubview:topRow];
    // The quality label left of it, above the capsule.
    UIView *quality = nil;
    for (UIView *sibling in topRow.subviews) {
        if (sibling != settings && [sibling isKindOfClass:buttonClass]) quality = sibling;
    }
    CGRect group = CGRectUnion(row.frame, settingsFrame);
    if (quality) {
        if (object_getClass(topRow) == UIView.class) object_setClass(topRow, PGTopRowView.class);
        CGFloat x = target.x - rowWidth / 2.0 - gap - CGRectGetWidth(quality.bounds) / 2.0;
        CGPoint center = [topRow convertPoint:quality.center toView:overlay];
        CGAffineTransform shift = CGAffineTransformMakeTranslation(x - center.x, 0.0);
        if (!CGAffineTransformEqualToTransform(quality.transform, shift)) quality.transform = shift;
        if (topRow.subviews.lastObject != quality) [topRow bringSubviewToFront:quality];
        group = CGRectUnion(group, [topRow convertRect:quality.frame toView:overlay]);
    }
    UIView *capsule = objc_getAssociatedObject(settings, PGGroupKey);
    if (capsule == nil) {
        capsule = PGMakeGlass();
        if (capsule == nil) return CGRectNull;
        objc_setAssociatedObject(settings, PGGroupKey, capsule, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat height = MIN(PGTopGlassDiameter, CGRectGetHeight(group));
    group = CGRectMake(CGRectGetMinX(group) - PGGroupPadding, CGRectGetMidY(top) - height / 2.0,
                       CGRectGetWidth(group) + PGGroupPadding * 2.0, height);
    CGRect frame = [overlay convertRect:group toView:settings];
    if (!CGRectEqualToRect(capsule.frame, frame)) {
        capsule.frame = frame;
        SEL radiusSel = NSSelectorFromString(@"setCornerRadius:");
        if ([capsule respondsToSelector:radiusSel]) ((void (*)(id, SEL, CGFloat))objc_msgSend)(capsule, radiusSel, height / 2.0);
        else { capsule.layer.cornerRadius = height / 2.0; capsule.clipsToBounds = YES; }
    }
    if (capsule.superview != settings) [settings insertSubview:capsule atIndex:0];
    else if (settings.subviews.firstObject != capsule) [settings sendSubviewToBack:capsule];
    return group;
}

static IMP OriginalOverlayLayout;

static void PGOverlayLayout(UIView *self, SEL _cmd) {
    if (OriginalOverlayLayout) ((void (*)(id, SEL))OriginalOverlayLayout)(self, _cmd);
    static Class buttonClass;
    if (buttonClass == Nil) buttonClass = NSClassFromString(@"YTQTMButton");
    SEL maxYSel = NSSelectorFromString(@"topControlsMaxY");
    if (buttonClass == Nil || ![self respondsToSelector:maxYSel]) return;
    CGRect group = PGGroupYTPlusRow(self, buttonClass);
    CGFloat maxY = ((CGFloat (*)(id, SEL))objc_msgSend)(self, maxYSel);
    if (maxY <= 0.0) return;
    NSMutableArray *buttons = [NSMutableArray array];
    PGCollectTopButtons(self, maxY, self, buttonClass, 3, buttons);
    for (UIButton *button in buttons) {
        CGRect frame = [button convertRect:button.bounds toView:self];
        if (CGRectContainsPoint(group, CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame)))) PGRemoveGlass(button);
        else PGPlaceGlass(button);
    }
}

__attribute__((constructor)) static void PGInit(void) {
    if (!YTGFeatureEnabled(YTGPlayerKey)) return;
    @autoreleasepool {
        Class config = NSClassFromString(@"YTColdConfig");
        PGHookTyped(config, @"enableLiquidGlassEffect", "B", (IMP)PGEnableLiquidGlass);
        PGHookTyped(config, @"liquidGlassEffectStyle", "q", (IMP)PGLiquidGlassStyle);
        TBHHookMethod(NSClassFromString(@"YTMainAppControlsOverlayView"), @"layoutSubviews", (IMP)PGOverlayLayout, &OriginalOverlayLayout);
    }
}
