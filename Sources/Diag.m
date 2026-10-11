// Temporary diagnostic: the views in the player overlay's bottom-right area (class, frame in the overlay, depth).

#import "Common.h"

static UILabel *YTGDiagLabel;
static __weak UIView *YTGDiagOverlay;

static void YTGDiagCollect(UIView *view, UIView *overlay, int depth, NSMutableArray<NSString *> *out) {
    if (out.count > 40 || view.hidden || view.alpha < 0.01) return;
    CGRect f = [view convertRect:view.bounds toView:overlay];
    BOOL bottomRight = CGRectGetMaxY(f) > CGRectGetHeight(overlay.bounds) * 0.6 && CGRectGetMinX(f) > CGRectGetWidth(overlay.bounds) * 0.6 &&
                       CGRectGetWidth(f) < CGRectGetWidth(overlay.bounds) * 0.4 && CGRectGetHeight(f) < CGRectGetHeight(overlay.bounds) * 0.4;
    if (bottomRight && depth > 0) {
        NSMutableString *line = [NSMutableString stringWithFormat:@"%d %@ (%.0f,%.0f %.0fx%.0f)", depth, NSStringFromClass(view.class),
            f.origin.x, f.origin.y, f.size.width, f.size.height];
        if (view.accessibilityIdentifier.length) [line appendFormat:@" id=%@", view.accessibilityIdentifier];
        if ([view isKindOfClass:UILabel.class]) [line appendFormat:@" \"%@\"", [((UILabel *)view).text stringByReplacingOccurrencesOfString:@"\n" withString:@" "]];
        [line appendFormat:@" in %@", NSStringFromClass(view.superview.class)];
        [out addObject:line];
    }
    if (depth < 9) for (UIView *sub in view.subviews) YTGDiagCollect(sub, overlay, depth + 1, out);
}

static void YTGDiagTick(void) {
    UIView *overlay = YTGDiagOverlay;
    UIWindow *window = overlay.window;
    if (window == nil) { YTGDiagLabel.hidden = YES; return; }
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"overlay %@ %.0fx%.0f",
        NSStringFromClass(overlay.class), CGRectGetWidth(overlay.bounds), CGRectGetHeight(overlay.bounds)]];
    YTGDiagCollect(overlay, overlay, 0, lines);
    if (YTGDiagLabel == nil) {
        YTGDiagLabel = [UILabel new];
        YTGDiagLabel.numberOfLines = 0;
        YTGDiagLabel.font = [UIFont monospacedSystemFontOfSize:7.5 weight:UIFontWeightMedium];
        YTGDiagLabel.textColor = UIColor.blackColor;
        YTGDiagLabel.backgroundColor = [UIColor.systemYellowColor colorWithAlphaComponent:0.92];
        YTGDiagLabel.userInteractionEnabled = NO;
    }
    if (YTGDiagLabel.superview != window) [window addSubview:YTGDiagLabel];
    [window bringSubviewToFront:YTGDiagLabel];
    YTGDiagLabel.hidden = NO;
    YTGDiagLabel.text = [lines componentsJoinedByString:@"\n"];
    CGFloat width = MIN(CGRectGetWidth(window.bounds) - 8.0, 520.0);
    CGSize size = [YTGDiagLabel sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    YTGDiagLabel.frame = CGRectMake(4.0, 30.0, width, size.height);
}

static IMP YTGDiagOriginalLayout;

static void YTGDiagOverlayLayout(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))YTGDiagOriginalLayout)(self, _cmd);
    if (self.window) YTGDiagOverlay = self;
}

__attribute__((constructor)) static void YTGDiagInit(void) {
    TBHHookMethod(NSClassFromString(@"YTMainAppVideoPlayerOverlayView"), @"layoutSubviews", (IMP)YTGDiagOverlayLayout, &YTGDiagOriginalLayout);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) { YTGDiagTick(); }];
    });
}
