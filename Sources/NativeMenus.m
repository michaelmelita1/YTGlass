// NativeMenus
// Long press on a video or tap on its ⋯: iOS's own menu, opening at the finger or the ⋯ (nothing lifts out), in place
// of YouTube's menu.
//
// How: a long press makes YouTube's YTMenuController fill a YTDefaultSheetController with YTActionSheetAction items
// (title, icon, handler) and present it with -presentFromViewController:animated:completion: (its sourceView the
// video, or the ⋯). While a long press is under way on that view, or when it's a ⋯ button's small menu, the same items
// become UIActions in a UIMenu instead. YouTube's current menus leave the items' title and icon empty and put them on
// each item's button, so they are read from there.
// The menu is opened from code (UIContextMenuInteraction's private -_presentMenuAtLocation:) at the finger, from a 2pt
// clear point used as its preview, in a small window of our own laid over YouTube's (kept apart from YouTube's view
// controllers). The picked item's own handler runs once the menu has closed and YouTube's window is key again, so what
// it opens (a share sheet, another sheet) opens from YouTube.
//
// The ⋯ in the row below the player (after like, dislike, share and download) opens a bottom sheet that loads its items
// afterwards, which iOS's menu can't show, so it's hidden: the last button of YouTube's
// id.video.non_scrollable_action_bar.
//
// Pure Objective-C runtime swizzling: no CydiaSubstrate / ElleKit dependency.

#import "Common.h"

@interface NMWindow : UIWindow
@end

@implementation NMWindow
// Only the menu takes touches; everything else falls through to YouTube's window.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self || hit == self.rootViewController.view) ? nil : hit;
}
@end

@interface NMMenu : NSObject <UIContextMenuInteractionDelegate>
@property (nonatomic, strong) id sheetController; // kept alive while the menu is open (the handlers may need it)
@property (nonatomic, copy) NSArray *actions;      // YTActionSheetAction
@property (nonatomic, strong) UIWindow *window;    // our own window, over YouTube's, while the menu is open
@property (nonatomic, weak) UIWindow *youTubeWindow; // made key again when the menu closes
@property (nonatomic, strong) UIView *anchor;      // a clear point at the finger: the menu opens from it
@property (nonatomic, strong) UIContextMenuInteraction *interaction;
@property (nonatomic, copy) void (^chosen)(void); // the picked item, run once the menu has closed
@end

static NMMenu *NMOpenMenu; // the menu on screen, if any

@implementation NMMenu

- (UIMenu *)menu {
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    for (id action in self.actions) {
        NSString *title = nil;
        UIImage *icon = nil;
        id handler = nil;
        @try {
            title = [action valueForKey:@"title"];
            icon = [action valueForKey:@"iconImage"];
            handler = [action valueForKey:@"handler"];
        } @catch (__unused NSException *e) {
            continue;
        }
        // YouTube's newer menus leave title and icon empty and put them on the item's button.
        UIButton *button = nil;
        @try { button = [action valueForKey:@"button"]; } @catch (__unused NSException *e) {}
        if ([button isKindOfClass:UIButton.class]) {
            if (![title isKindOfClass:NSString.class] || title.length == 0) title = [button titleForState:UIControlStateNormal] ?: button.currentTitle;
            if (![icon isKindOfClass:UIImage.class]) icon = [button imageForState:UIControlStateNormal] ?: button.currentImage;
        }
        if (![title isKindOfClass:NSString.class] || title.length == 0) continue;
        UIImage *image = [icon isKindOfClass:UIImage.class] ? [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] : nil;
        __weak NMMenu *weakSelf = self;
        [items addObject:[UIAction actionWithTitle:title image:image identifier:nil handler:^(__unused UIAction *a) {
            if (handler) weakSelf.chosen = ^{ ((void (^)(id))handler)(action); };
        }]];
    }
    return [UIMenu menuWithTitle:@"" children:items];
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    __weak NMMenu *weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
                                                    actionProvider:^UIMenu *(__unused NSArray<UIMenuElement *> *suggested) {
        return [weakSelf menu];
    }];
}

- (UITargetedPreview *)anchorPreview {
    if (self.anchor.window == nil) return nil;
    UIPreviewParameters *parameters = [UIPreviewParameters new];
    parameters.backgroundColor = UIColor.clearColor;
    parameters.visiblePath = [UIBezierPath bezierPathWithRect:self.anchor.bounds];
    return [[UITargetedPreview alloc] initWithView:self.anchor parameters:parameters];
}

- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
    previewForHighlightingMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    return [self anchorPreview];
}

- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
    previewForDismissingMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    return [self anchorPreview];
}

- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction
       willEndForConfiguration:(UIContextMenuConfiguration *)configuration
                      animator:(id<UIContextMenuInteractionAnimating>)animator {
    void (^finish)(void) = ^{
        self.window.hidden = YES;
        [self.youTubeWindow makeKeyWindow];
        // YouTube's own action, once its window is back in front and key (a share sheet, another sheet or the sign-in
        // prompt opens from the key window; run in the same pass, our closing window still counted as key).
        void (^chosen)(void) = self.chosen;
        self.chosen = nil;
        if (chosen) dispatch_async(dispatch_get_main_queue(), chosen);
        if (NMOpenMenu == self) NMOpenMenu = nil;
    };
    if (animator) [animator addCompletion:finish];
    else finish();
}

@end

// YouTube's long press recognizer under way on the view or one of its ancestors, if any.
static UIGestureRecognizer *NMLongPress(UIView *view) {
    for (UIView *v = view; v != nil; v = v.superview) {
        for (UIGestureRecognizer *recognizer in v.gestureRecognizers) {
            if ([recognizer isKindOfClass:UILongPressGestureRecognizer.class] &&
                (recognizer.state == UIGestureRecognizerStateBegan || recognizer.state == UIGestureRecognizerStateChanged)) return recognizer;
        }
    }
    return nil;
}

static BOOL NMPresent(id sheetController, UIView *source, CGPoint location) {
    static SEL present;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ present = NSSelectorFromString(@"_presentMenuAtLocation:"); });
    UIWindowScene *scene = source.window.windowScene;
    if (scene == nil || ![UIContextMenuInteraction instancesRespondToSelector:present]) return NO;
    NSArray *actions = nil;
    @try { actions = [sheetController valueForKey:@"actions"]; } @catch (__unused NSException *e) { return NO; }
    if (![actions isKindOfClass:NSArray.class] || actions.count == 0) return NO;

    NMMenu *menu = [NMMenu new];
    menu.sheetController = sheetController;
    menu.actions = actions;
    NMWindow *window = [[NMWindow alloc] initWithWindowScene:scene];
    window.windowLevel = source.window.windowLevel + 1.0;
    window.backgroundColor = UIColor.clearColor;
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.clearColor;
    window.rootViewController = root;
    menu.window = window;
    menu.youTubeWindow = source.window;
    [window makeKeyAndVisible];
    CGPoint point = [source convertPoint:location toView:nil];
    point = [root.view convertPoint:point fromView:nil];
    menu.anchor = [[UIView alloc] initWithFrame:CGRectMake(point.x - 1.0, point.y - 1.0, 2.0, 2.0)];
    [root.view addSubview:menu.anchor];
    menu.interaction = [[UIContextMenuInteraction alloc] initWithDelegate:menu];
    [menu.anchor addInteraction:menu.interaction];
    NMOpenMenu = menu;
    // Opened once the new window is on screen.
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(menu.interaction, present, CGPointMake(1.0, 1.0));
    });
    return YES;
}

static IMP OriginalPresentFromViewController;

static void NMPresentFromViewController(id self, SEL _cmd, UIViewController *presenter, BOOL animated, id completion) {
    UIView *source = nil;
    @try { source = [self valueForKey:@"sourceView"]; } @catch (__unused NSException *e) {}
    UIGestureRecognizer *longPress = [source isKindOfClass:UIView.class] ? NMLongPress(source) : nil;
    // A ⋯ button's menu: the small menu YouTube opens beside the button (forced sheet style 1). Other sheets (the ⋯
    // under a playing video is a bottom sheet that loads its items afterwards; quality, speed, comments) stay YouTube's.
    BOOL menuButton = NO;
    if (!longPress && [source isKindOfClass:UIView.class]) {
        @try { menuButton = [[self valueForKey:@"forcedSheetStyle"] integerValue] == 1; } @catch (__unused NSException *e) {}
    }
    CGPoint location = longPress ? [longPress locationInView:source]
                                 : CGPointMake(CGRectGetMidX(source.bounds), CGRectGetMidY(source.bounds));
    if ((longPress || menuButton) && NMPresent(self, source, location)) {
        if (completion) ((void (^)(void))completion)();
        return;
    }
    ((void (*)(id, SEL, UIViewController *, BOOL, id))OriginalPresentFromViewController)(self, _cmd, presenter, animated, completion);
}

// The action row below the player: hide its last button (the ⋯) each time it lays out, and close the gap it leaves.
static IMP OriginalDisplayLayout;

static void NMDisplayLayout(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))OriginalDisplayLayout)(self, _cmd);
    if (self.subviews.count < 2 || ![self.accessibilityIdentifier isEqualToString:@"id.video.non_scrollable_action_bar"]) return;
    UIView *last = nil;
    for (UIView *v in self.subviews) if (last == nil || CGRectGetMaxX(v.frame) > CGRectGetMaxX(last.frame)) last = v;
    if (!last.hidden) last.hidden = YES;
    // The row is aligned to the right edge: move it over by the hidden button so no gap is left there.
    CGAffineTransform shift = CGAffineTransformMakeTranslation(CGRectGetWidth(last.frame), 0.0);
    if (!CGAffineTransformEqualToTransform(self.transform, shift)) self.transform = shift;
}

__attribute__((constructor)) static void NMInit(void) {
    if (!YTGFeatureEnabled(YTGNativeMenusKey)) return;
    @autoreleasepool {
        TBHHookMethod(NSClassFromString(@"YTDefaultSheetController"), @"presentFromViewController:animated:completion:",
                      (IMP)NMPresentFromViewController, &OriginalPresentFromViewController);
        TBHHookMethod(NSClassFromString(@"_ASDisplayView"), @"layoutSubviews", (IMP)NMDisplayLayout, &OriginalDisplayLayout);
    }
}
