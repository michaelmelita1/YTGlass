// HomeHold
// Holding the Home tab (the first one) opens YouTube's settings straight away instead of YTPlus's tab bar menu. YTPlus's tab bar is a
// system UITabBar with a UIContextMenuInteraction; its delegate's contextMenuInteraction:configurationForMenuAtLocation:
// gets no menu (nil) when the press is on the first tab (other tabs keep YTPlus's menu). Settings open through YouTube's
// own command, +[YTICommand applicationSettingsNavigationEndpoint].
//
// Pure Objective-C runtime swizzling: no CydiaSubstrate / ElleKit dependency.

#import "Common.h"

static void MSOpenSettings(void) {
    Class commandClass = NSClassFromString(@"YTICommand");
    Class eventClass = NSClassFromString(@"YTCommandResponderEvent");
    SEL commandSel = NSSelectorFromString(@"applicationSettingsNavigationEndpoint");
    SEL eventSel = NSSelectorFromString(@"eventWithCommand:fromView:entry:sendClick:firstResponder:");
    if (![commandClass respondsToSelector:commandSel] || ![eventClass respondsToSelector:eventSel]) return;
    UIView *bar = TBHFindBar();
    SEL parentSel = NSSelectorFromString(@"parentResponder");
    id responder = nil;
    for (UIResponder *r = bar; r != nil && responder == nil; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class] && [r respondsToSelector:parentSel]) responder = r;
    }
    if (responder == nil) return;
    id command = ((id (*)(id, SEL))objc_msgSend)(commandClass, commandSel);
    id event = ((id (*)(id, SEL, id, UIView *, id, BOOL, id))objc_msgSend)(eventClass, eventSel, command, bar, nil, NO, responder);
    SEL send = NSSelectorFromString(@"send");
    if ([event respondsToSelector:send]) ((void (*)(id, SEL))objc_msgSend)(event, send);
}

#pragma mark - Holding Home

static NSMutableDictionary<NSString *, NSValue *> *MSOriginalConfigs; // class name -> its original method
static NSMutableSet<Class> *MSWrapped;

// The press is on the first tab (Home) of YTPlus's tab bar. YTPlus 6.0's tabs have no titles, so it goes by position.
static BOOL MSOnHomeTab(UIContextMenuInteraction *interaction, CGPoint location) {
    UIView *view = interaction.view;
    if (![view isKindOfClass:UITabBar.class]) return NO;
    static Class pivotClass;
    if (pivotClass == Nil) pivotClass = NSClassFromString(@"YTPivotBarView");
    BOOL inYouTubeBar = NO;
    for (UIView *v = view.superview; v && !inYouTubeBar; v = v.superview) inYouTubeBar = [v isKindOfClass:pivotClass];
    UITabBarItem *first = ((UITabBar *)view).items.firstObject;
    UIView *itemView = nil;
    @try { itemView = [first valueForKey:@"view"]; } @catch (__unused NSException *e) {}
    BOOL onHome = inYouTubeBar && [itemView isKindOfClass:UIView.class] &&
                  CGRectContainsPoint([itemView convertRect:itemView.bounds toView:view], location);
    return onHome;
}

static NSTimeInterval const MSExtraHold = 0.3; // held this much longer than iOS's own menu needs

// A finger is still on the view (one of its gesture recognizers is still tracking a touch).
static BOOL MSStillHeld(UIView *view) {
    for (UIView *v = view; v != nil; v = v.superview) {
        for (UIGestureRecognizer *gesture in v.gestureRecognizers) {
            if (gesture.numberOfTouches > 0) return YES;
        }
        if (v != view) break; // the view and its holder
    }
    return NO;
}

static UIContextMenuConfiguration *MSConfiguration(id self, SEL _cmd, UIContextMenuInteraction *interaction, CGPoint location) {
    if (MSOnHomeTab(interaction, location)) {
        // Settings open after a little longer, if the finger is still down then (letting go earlier does nothing).
        __weak UIView *view = interaction.view;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MSExtraHold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!MSStillHeld(view)) return;
            [[UIImpactFeedbackGenerator.alloc initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
            MSOpenSettings();
        });
        return nil; // no menu
    }
    IMP original = NULL;
    for (Class c = object_getClass(self); c != Nil && original == NULL; c = class_getSuperclass(c)) {
        original = (IMP)MSOriginalConfigs[NSStringFromClass(c)].pointerValue;
    }
    return original ? ((UIContextMenuConfiguration * (*)(id, SEL, id, CGPoint))original)(self, _cmd, interaction, location) : nil;
}

// Wraps the delegate's method once per class that implements it (on that class, so subclasses share one original).
static void MSWrapDelegate(id delegate) {
    SEL sel = @selector(contextMenuInteraction:configurationForMenuAtLocation:);
    Method method = delegate ? class_getInstanceMethod(object_getClass(delegate), sel) : NULL;
    if (method == NULL) return;
    if (MSWrapped == nil) {
        MSWrapped = [NSMutableSet set];
        MSOriginalConfigs = [NSMutableDictionary dictionary];
    }
    Class owner = object_getClass(delegate);
    while (class_getSuperclass(owner) && class_getInstanceMethod(class_getSuperclass(owner), sel) == method) owner = class_getSuperclass(owner);
    if ([MSWrapped containsObject:owner]) return;
    IMP original = NULL;
    if (TBHHookMethod(owner, NSStringFromSelector(sel), (IMP)MSConfiguration, &original) && original != (IMP)MSConfiguration) {
        MSOriginalConfigs[NSStringFromClass(owner)] = [NSValue valueWithPointer:(const void *)original];
    }
    [MSWrapped addObject:owner];
}

static IMP OriginalAddInteraction;

// The context menu interaction YTPlus adds to its tab bar: its delegate gets wrapped.
static void MSAddInteraction(UIView *self, SEL _cmd, id<UIInteraction> interaction) {
    ((void (*)(id, SEL, id))OriginalAddInteraction)(self, _cmd, interaction);
    if ([(id)interaction isKindOfClass:UIContextMenuInteraction.class]) MSWrapDelegate(((UIContextMenuInteraction *)interaction).delegate);
}

__attribute__((constructor)) static void MSInit(void) {
    if (!YTGFeatureEnabled(YTGHomeHoldKey)) return;
    @autoreleasepool {
        TBHHookMethod(UITabBar.class, @"addInteraction:", (IMP)MSAddInteraction, &OriginalAddInteraction);
    }
}
