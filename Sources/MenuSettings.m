// MenuSettings
// Adds a Settings item to YTPlus's tab bar menu (Whitelist, Tab bar, Open link, ...) that opens
// YouTube's settings from any tab. The menu is recognised by YTPlus's own (translated) Tab bar item.
// Settings open through YouTube's own command, +[YTICommand applicationSettingsNavigationEndpoint].
//
// Pure Objective-C runtime swizzling: no CydiaSubstrate / ElleKit dependency.

#import "Common.h"

static NSString *const MSActionIdentifier = @"ytglass.settings";

static NSString *MSTabBarTitle(void) {
    static NSString *title;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *bundle = [NSBundle bundleWithPath:[NSBundle.mainBundle pathForResource:@"YTLite" ofType:@"bundle"]];
        title = [bundle localizedStringForKey:@"Tabbar" value:nil table:nil];
    });
    return title;
}

void YTGOpenSettings(void) {
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

static NSArray *MSWithSettings(NSArray *children) {
    NSString *tabBarTitle = MSTabBarTitle();
    if (tabBarTitle.length == 0) return children;
    BOOL ytplusMenu = NO;
    for (UIMenuElement *element in children) {
        if (![element isKindOfClass:UIAction.class]) continue;
        if ([((UIAction *)element).identifier isEqualToString:MSActionIdentifier]) return children;
        if ([element.title isEqualToString:tabBarTitle]) ytplusMenu = YES;
    }
    if (!ytplusMenu) return children;
    UIAction *settings = [UIAction actionWithTitle:@"Settings" image:[UIImage systemImageNamed:@"gearshape"]
                                        identifier:MSActionIdentifier handler:^(__unused UIAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{ YTGOpenSettings(); });
    }];
    return [children arrayByAddingObject:settings];
}

static IMP OriginalMenu, OriginalShortMenu;

static UIMenu *MSMenu(id self, SEL _cmd, NSString *title, UIImage *image, UIMenuIdentifier identifier, UIMenuOptions options, NSArray *children) {
    return ((UIMenu * (*)(id, SEL, NSString *, UIImage *, UIMenuIdentifier, UIMenuOptions, NSArray *))OriginalMenu)(
        self, _cmd, title, image, identifier, options, MSWithSettings(children));
}

static UIMenu *MSShortMenu(id self, SEL _cmd, NSString *title, NSArray *children) {
    return ((UIMenu * (*)(id, SEL, NSString *, NSArray *))OriginalShortMenu)(self, _cmd, title, MSWithSettings(children));
}

__attribute__((constructor)) static void MSInit(void) {
    @autoreleasepool {
        Class menu = object_getClass(UIMenu.class);
        TBHHookMethod(menu, @"menuWithTitle:image:identifier:options:children:", (IMP)MSMenu, &OriginalMenu);
        TBHHookMethod(menu, @"menuWithTitle:children:", (IMP)MSShortMenu, &OriginalShortMenu);
    }
}
