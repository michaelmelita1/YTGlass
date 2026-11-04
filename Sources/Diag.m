// TEMPORARY DIAGNOSTIC (0.2.0~debug2..8): YTGDLog lines also go to Documents/YTGlass-diag.log in YouTube's folder
// (copied off the phone with devicectl). Logs how YouTube 21.43.5 decides on Liquid Glass.

#import "Common.h"

void YTGDWrite(NSString *line) {
    static NSFileHandle *file;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"YTGlass-diag.log"];
        [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil]; // fresh each launch
        file = [NSFileHandle fileHandleForWritingAtPath:path];
    });
    NSString *stamped = [NSString stringWithFormat:@"%.3f %@\n", CACurrentMediaTime(), line];
    @synchronized (file) { [file writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]]; }
}

static NSString *const YTGDGlassNames[] = {
    @"isLiquidGlassActive", @"isLiquidGlassAvailable", @"computeIsLiquidGlassAvailable", @"shouldApplyLiquidGlass",
    @"shouldDisableLiquidGlassEffect", @"liquidGlassEffect", @"liquidGlassEffectStyle", @"enableLiquidGlassEffect",
    @"mainAppCoreClientIos27EnableLiquidGlass", @"ios27EnableLiquidGlass", @"liquidGlassActive", @"useLiquidGlassStyling",
};

static void YTGDGlass(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        for (int meta = 0; meta < 2; meta++) {
            Class cls = meta ? object_getClass(classes[i]) : classes[i];
            unsigned int n = 0;
            Method *methods = class_copyMethodList(cls, &n);
            for (unsigned int j = 0; j < n; j++) {
                NSString *name = NSStringFromSelector(method_getName(methods[j]));
                BOOL wanted = NO;
                for (size_t k = 0; k < sizeof(YTGDGlassNames) / sizeof(*YTGDGlassNames); k++) wanted |= [name isEqualToString:YTGDGlassNames[k]];
                if (!wanted) continue;
                char type[32] = { 0 };
                method_getReturnType(methods[j], type, sizeof(type));
                NSString *value = @"";
                if (meta && method_getNumberOfArguments(methods[j]) == 2) { // class method without arguments: ask it
                    @try {
                        if (type[0] == 'B' || type[0] == 'c') value = ((BOOL (*)(id, SEL))objc_msgSend)(classes[i], method_getName(methods[j])) ? @" = YES" : @" = NO";
                        else if (type[0] == 'q' || type[0] == 'Q') value = [NSString stringWithFormat:@" = %ld", ((long (*)(id, SEL))objc_msgSend)(classes[i], method_getName(methods[j]))];
                        else if (type[0] == '@') value = [NSString stringWithFormat:@" = %@", NSStringFromClass([((id (*)(id, SEL))objc_msgSend)(classes[i], method_getName(methods[j])) class])];
                    } @catch (__unused NSException *e) { value = @" = (threw)"; }
                }
                YTGDLog(@"YTGDIAG glass %c[%s %@] %s%@", meta ? '+' : '-', class_getName(classes[i]), name, type, value);
            }
            free(methods);
        }
    }
    free(classes);
}

__attribute__((constructor)) static void YTGDInit(void) {
    YTGDLog(@"YTGDIAG launch YTGlass %s", YTG_VERSION);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ YTGDGlass(); });
    // The glass effect again once a video has had time to open.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        Class glass = NSClassFromString(@"YTFrostedGlassView");
        SEL effect = NSSelectorFromString(@"liquidGlassEffect");
        id value = [glass respondsToSelector:effect] ? ((id (*)(id, SEL))objc_msgSend)(glass, effect) : nil;
        YTGDLog(@"YTGDIAG glass at 30s: liquidGlassEffect = %@", value);
    });
}
