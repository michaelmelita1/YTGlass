// Liquid Glass video player controls (formerly the separate PlayerGlass dylib).
//
// YouTube already ships Liquid Glass behind its play/pause and previous/next buttons (and its other player
// glass views): +[YTFrostedGlassView liquidGlassEffect] returns a UIGlassEffect on iOS 26 when the
// enableLiquidGlassEffect flag is on, with liquidGlassEffectStyle 1 = regular and 2 = clear. We turn that on,
// and give the top-row buttons (captions, settings, cast, ...) the same glass circles.

#import "Common.h"

static NSInteger const PGGlassStyle = 2;       // YouTube's liquidGlassEffectStyle: 1 regular, 2 clear
static CGFloat const PGTopGlassDiameter = 40.0; // glass circle behind each top-row button

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

static IMP OriginalOverlayLayout;

static void PGOverlayLayout(UIView *self, SEL _cmd) {
    if (OriginalOverlayLayout) ((void (*)(id, SEL))OriginalOverlayLayout)(self, _cmd);
    static Class buttonClass;
    if (buttonClass == Nil) buttonClass = NSClassFromString(@"YTQTMButton");
    SEL maxYSel = NSSelectorFromString(@"topControlsMaxY");
    if (buttonClass == Nil || ![self respondsToSelector:maxYSel]) return;
    CGFloat maxY = ((CGFloat (*)(id, SEL))objc_msgSend)(self, maxYSel);
    if (maxY <= 0.0) return;
    NSMutableArray *buttons = [NSMutableArray array];
    PGCollectTopButtons(self, maxY, self, buttonClass, 3, buttons);
    for (UIButton *button in buttons) PGPlaceGlass(button);
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
