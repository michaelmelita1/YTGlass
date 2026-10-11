// TabAnimation
// Removes YouTube's slide-up animation when switching tabs (the new tab's page fades in from slightly lower
// down). It's a YouTube flag, +[YTModernTransitions isTabSlideUpAnimationEnabled].
//
// Pure Objective-C runtime swizzling: no CydiaSubstrate / ElleKit dependency.

#import "Common.h"

static BOOL TASlideUpEnabled(__unused id self, __unused SEL _cmd) { return NO; }

__attribute__((constructor)) static void TAInit(void) {
    if (!YTGFeatureEnabled(YTGSlideUpKey)) return;
    @autoreleasepool {
        Class transitions = NSClassFromString(@"YTModernTransitions");
        if (transitions == Nil) return;
        Method method = class_getClassMethod(transitions, NSSelectorFromString(@"isTabSlideUpAnimationEnabled"));
        char type[8] = { 0 };
        if (method) method_getReturnType(method, type, sizeof(type));
        if (strcmp(type, "B") == 0) TBHHookMethod(object_getClass(transitions), @"isTabSlideUpAnimationEnabled", (IMP)TASlideUpEnabled, NULL);
        else TBHHookMethod(transitions, @"isTabSlideUpAnimationEnabled", (IMP)TASlideUpEnabled, NULL);
    }
}
