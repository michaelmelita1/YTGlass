// YTPlusSettingsFix
// With YTPlus's Liquid Glass enabled, the close button of YouTube's settings (a YTQTMButton,
// id.ui.browse.close.button, in the navigation bar) gets no width: its X and glass circle are drawn over the
// "Settings" title and taps miss it. The button is given a square size. Separate so it can be removed once
// YTPlus fixes it.
//
// Pure Objective-C runtime swizzling: no CydiaSubstrate / ElleKit dependency.

#import "Common.h"

static BOOL YSFIsCloseButton(UIView *button) {
    if (![button.accessibilityIdentifier isEqualToString:@"id.ui.browse.close.button"]) return NO;
    for (UIView *v = button.superview; v != nil; v = v.superview) {
        if ([v isKindOfClass:UINavigationBar.class]) return YES;
    }
    return NO;
}

static CGSize YSFFixed(UIView *button, CGSize size) {
    if (size.width >= 1.0 || !YSFIsCloseButton(button)) return size;
    CGFloat side = MAX(size.height, 24.0);
    return CGSizeMake(side, side);
}

static IMP OriginalIntrinsicSize, OriginalSizeThatFits;

static CGSize YSFIntrinsicSize(UIView *self, SEL _cmd) {
    return YSFFixed(self, ((CGSize (*)(id, SEL))OriginalIntrinsicSize)(self, _cmd));
}

static CGSize YSFSizeThatFits(UIView *self, SEL _cmd, CGSize fitting) {
    return YSFFixed(self, ((CGSize (*)(id, SEL, CGSize))OriginalSizeThatFits)(self, _cmd, fitting));
}

__attribute__((constructor)) static void YSFInit(void) {
    if (!YTGFeatureEnabled(YTGSettingsFixKey)) return;
    @autoreleasepool {
        Class button = NSClassFromString(@"YTQTMButton");
        TBHHookMethod(button, @"intrinsicContentSize", (IMP)YSFIntrinsicSize, &OriginalIntrinsicSize);
        TBHHookMethod(button, @"sizeThatFits:", (IMP)YSFSizeThatFits, &OriginalSizeThatFits);
    }
}
