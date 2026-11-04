// SystemTabBar
// iOS 26's own Liquid Glass tab bar in place of YouTube's (and YTPlus's), so everything about it is native: the glass,
// the touch response, the selection bubble, and Search (Search: Separate) as the system's own circle beside the bar.
// Built as Vitrine's system tab bar is: a UITabBarController of ours stands over YouTube's whole app view, with empty,
// see-through pages, and takes only the touches on its bar; YouTube's pages, player and mini player stay underneath.
// (Placed inside YouTube's bar, as the earlier attempt on wip/native-tab-bar was, the system never separated Search.)
//
// - Its tabs are YouTube's own, with YouTube's icons: YTPlus's tab bar items when YTPlus's bar is there (choosing one
//   chooses it on YTPlus's bar), else YouTube's visible tab buttons (YTPivotBarItemView; choosing one taps it). Read
//   at each layout of YouTube's bar; the system bar follows the selection.
// - YouTube's bar stays where it is, invisible, so YouTube's layout (page insets, the mini player) doesn't change; ours
//   hides and shows with it (YouTube's -[YTAppView hidePivotBar] / -showPivotBar, and the tab bar autohide).
// - The search tab never stays selected: it opens YouTube's search.
// - Every tab YTPlus shows is shown: iOS's limit (four beside the search circle, five without, then its own "More"
//   tab) is raised with -[UITabBarController _setMaximumNumberOfItems:], and the tabs narrow to fit. Should that ever
//   be refused, the tabs past iOS's limit are left out rather than put under "More".
// - Holding the first tab opens YouTube's settings, through YouTube's own command,
//   +[YTICommand applicationSettingsNavigationEndpoint].
// - The mini player fix (TabBarAutoHide.m) comes with it, under the same switch (Liquid Glass Tab Bar).
//
// The UITab API is newer than the SDK this builds with, so it's used through the runtime.
//
// Pure Objective-C runtime swizzling: no CydiaSubstrate / ElleKit dependency.

#import "Common.h"

NSString *const YTGSystemTabBarKey = @"YTGlass_SystemTabBar";

BOOL YTGSystemTabBarOn(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        on = YTGFeatureEnabled(YTGSystemTabBarKey) && NSClassFromString(@"UITab") != Nil && NSClassFromString(@"UISearchTab") != Nil;
    });
    return on;
}

static NSString *const STSearchIdentifier = @"ytglass.search";
static NSString *const STTabPrefix = @"ytglass.tab.";

static id STValue(id object, NSString *key) {
    @try { return [object valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

static void STSend(id target, NSString *selectorName, id argument) {
    SEL selector = NSSelectorFromString(selectorName);
    if ([target respondsToSelector:selector]) ((void (*)(id, SEL, id))objc_msgSend)(target, selector, argument);
}

static void STOpenSettings(void) {
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

#pragma mark - The host

// Over the whole of YouTube's app view, taking only the bar's touches (the search circle is part of the bar).
@interface STHost : UIView
@property (nonatomic, weak) UITabBarController *controller;
@end

@implementation STHost
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    UITabBar *tabBar = self.controller.tabBar;
    return hit && tabBar && !tabBar.hidden && [hit isDescendantOfView:tabBar] ? hit : nil;
}
@end

@interface STState : NSObject <UITabBarControllerDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) UITabBarController *controller;
@property (nonatomic, strong) STHost *host;
@property (nonatomic, weak) UIView *bar;                   // YouTube's YTPivotBarView
@property (nonatomic, copy) NSString *signature;           // the tabs the controller was built with
@property (nonatomic, strong) NSPointerArray *items;       // YouTube's buttons, by tab index (weak), without YTPlus's bar
@property (nonatomic, weak) UITabBar *ytplusBar;           // YTPlus's bar, when the tabs are its items
@property (nonatomic, assign) BOOL syncing;                // selecting to match YouTube, not the user
@property (nonatomic, assign) CFTimeInterval heldUntil;    // the tap a hold ends in is no tab change
@end

static STState *STShared;

#pragma mark - YouTube's tabs

// iOS symbols, only for a tab whose YouTube icon can't be read.
static NSString *STSymbol(NSString *identifier) {
    NSDictionary *symbols = @{ @"FEwhat_to_watch": @"house", @"FEshorts": @"play.rectangle.on.rectangle", @"FEsubscriptions": @"play.square.stack",
                               @"FEhistory": @"clock.arrow.circlepath", @"FElibrary": @"person.crop.circle", @"FEyou": @"person.crop.circle",
                               @"FEdownloads": @"arrow.down.circle", @"FEexplore": @"safari" };
    return identifier ? symbols[identifier] : nil;
}

static UIImage *STImage(NSString *identifier, BOOL filled) {
    NSString *symbol = STSymbol(identifier) ?: @"circle";
    UIImage *image = filled ? [UIImage systemImageNamed:[symbol stringByAppendingString:@".fill"]] : nil;
    return image ?: [UIImage systemImageNamed:symbol];
}

// YTPlus's bar (a system UITabBar inside YouTube's), whose items carry YouTube's own icons, outline and filled.
static UITabBar *STYTPlusTabBar(UIView *bar) {
    for (UIView *subview in bar.subviews) if ([subview isKindOfClass:UITabBar.class]) return (UITabBar *)subview;
    return nil;
}

// Chooses a tab through YTPlus's bar, as a tap on it does.
static void STTapYTPlus(UITabBar *ytplus, NSUInteger index) {
    if (index >= ytplus.items.count) return;
    UITabBarItem *target = ytplus.items[index];
    if (ytplus.selectedItem == target) return;
    ytplus.selectedItem = target;
    id<UITabBarDelegate> delegate = ytplus.delegate;
    if ([delegate respondsToSelector:@selector(tabBar:didSelectItem:)]) [delegate tabBar:ytplus didSelectItem:target];
}

// Without YTPlus's bar: chooses a tab the way a tap on YouTube's button does.
static void STTapItem(UIView *item, NSUInteger index) {
    UIControl *button = STValue(item, @"navigationButton");
    id renderer = STValue(item, @"renderer"), delegate = STValue(item, @"delegate");
    SEL tap = NSSelectorFromString(@"didTapItemWithRenderer:");
    if ([button isKindOfClass:UIControl.class]) [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    else if (renderer && [delegate respondsToSelector:tap]) ((void (*)(id, SEL, id))objc_msgSend)(delegate, tap, renderer);
    __weak UIView *weakItem = item;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *again = weakItem, *bar = STShared.bar;
        if (again == nil || TBHTabSelected(again)) return;
        UITabBar *ytplus = STYTPlusTabBar(bar);
        if (index >= ytplus.items.count) return;
        UITabBarItem *target = ytplus.items[index];
        ytplus.selectedItem = target;
        id<UITabBarDelegate> ytplusDelegate = ytplus.delegate;
        if ([ytplusDelegate respondsToSelector:@selector(tabBar:didSelectItem:)]) [ytplusDelegate tabBar:ytplus didSelectItem:target];
    });
}

#pragma mark - The system tab bar

static UIViewController *STBlankPage(void) {
    UIViewController *page = [UIViewController new];
    page.view.backgroundColor = UIColor.clearColor;
    page.view.userInteractionEnabled = NO;
    return page;
}

static id STMakeTab(NSString *title, UIImage *image, UIImage *selectedImage, NSString *identifier) {
    Class tabClass = NSClassFromString(@"UITab");
    SEL init = NSSelectorFromString(@"initWithTitle:image:identifier:viewControllerProvider:");
    if (![tabClass instancesRespondToSelector:init]) return nil;
    UIViewController *(^provider)(id) = ^UIViewController *(__unused id tab) { return STBlankPage(); };
    id tab = ((id (*)(id, SEL, NSString *, UIImage *, NSString *, id))objc_msgSend)([tabClass alloc], init, title, image, identifier, provider);
    if (selectedImage) STSend(tab, @"setSelectedImage:", selectedImage); // iOS 26.1: filled while selected
    return tab;
}

static id STMakeSearchTab(void) {
    Class searchClass = NSClassFromString(@"UISearchTab");
    SEL init = NSSelectorFromString(@"initWithViewControllerProvider:");
    if (![searchClass instancesRespondToSelector:init]) return nil;
    UIViewController *(^provider)(id) = ^UIViewController *(__unused id tab) { return STBlankPage(); };
    id tab = ((id (*)(id, SEL, id))objc_msgSend)([searchClass alloc], init, provider);
    return tab;
}

static NSString *STTabIdentifier(id tab) {
    id identifier = STValue(tab, @"identifier");
    return [identifier isKindOfClass:NSString.class] ? identifier : nil;
}

static BOOL STIsSearchTab(id tab) {
    Class searchClass = NSClassFromString(@"UISearchTab");
    return (searchClass && [tab isKindOfClass:searchClass]) || [STTabIdentifier(tab) isEqualToString:STSearchIdentifier];
}

static void STSelectIndex(STState *state, NSUInteger index) {
    NSArray *tabs = STValue(state.controller, @"tabs");
    if (index >= tabs.count || STIsSearchTab(tabs[index])) return;
    id tab = tabs[index];
    if (STValue(state.controller, @"selectedTab") == tab) return;
    state.syncing = YES;
    STSend(state.controller, @"setSelectedTab:", tab);
    state.syncing = NO;
}

// The tab buttons the system draws, left to right.
static NSArray<UIView *> *STTabButtons(UITabBar *tabBar) {
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:tabBar];
    for (NSUInteger i = 0; i < queue.count && i < 400; i++) {
        UIView *view = queue[i];
        if (view != tabBar && [NSStringFromClass(view.class) containsString:@"TabButton"] && CGRectGetWidth(view.bounds) > 20.0) [buttons addObject:view];
        else [queue addObjectsFromArray:view.subviews];
    }
    [buttons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return [@([a convertPoint:CGPointZero toView:tabBar].x) compare:@([b convertPoint:CGPointZero toView:tabBar].x)];
    }];
    return buttons;
}

@implementation STState

// Holding the first tab opens YouTube's settings: a little longer than iOS's own press, with a firm tap when it opens.
- (void)held:(UILongPressGestureRecognizer *)hold {
    if (hold.state != UIGestureRecognizerStateBegan) return;
    UITabBar *tabBar = self.controller.tabBar;
    UIView *first = STTabButtons(tabBar).firstObject;
    if (first == nil || !CGRectContainsPoint([first convertRect:first.bounds toView:tabBar], [hold locationInView:tabBar])) return;
    self.heldUntil = CACurrentMediaTime() + 2.0;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    STOpenSettings();
}

// The tab buttons have recognizers of their own: the hold runs beside them.
- (BOOL)gestureRecognizer:(__unused UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(__unused UIGestureRecognizer *)b {
    return YES;
}

- (BOOL)tabBarController:(UITabBarController *)controller shouldSelectTab:(id)tab {
    if (self.syncing) return YES;
    if (CACurrentMediaTime() < self.heldUntil) return NO;
    if (STIsSearchTab(tab)) {
        YTGOpenSearch(self.bar ?: controller.view);
        return NO;
    }
    NSUInteger index = [STValue(controller, @"tabs") indexOfObject:tab];
    UITabBar *ytplus = self.ytplusBar;
    if (ytplus) {
        STTapYTPlus(ytplus, index);
        return YES;
    }
    UIView *item = index < self.items.count ? (__bridge UIView *)[self.items pointerAtIndex:index] : nil;
    if (item && !TBHTabSelected(item)) STTapItem(item, index);
    return YES;
}

@end

// Room for every tab, not iOS's five (private: -[UITabBarController _setMaximumNumberOfItems:]).
static BOOL STRaiseLimit(UITabBarController *controller, NSUInteger slots) {
    SEL limit = NSSelectorFromString(@"_setMaximumNumberOfItems:");
    if (![controller respondsToSelector:limit]) return slots <= 5;
    @try {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(controller, limit, (NSInteger)MAX(slots, (NSUInteger)5));
    } @catch (__unused NSException *e) {
        return slots <= 5;
    }
    return YES;
}

// The image drawn as it is, not tinted; kept on the image so each pass hands back the same one.
static UIImage *STAsIs(UIImage *image) {
    static const void *key = &key;
    if (image.renderingMode == UIImageRenderingModeAlwaysOriginal) return image;
    UIImage *original = objc_getAssociatedObject(image, key);
    if (original == nil) {
        original = [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        objc_setAssociatedObject(image, key, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return original;
}

// YouTube's icon on its own button, for the selected and unselected look.
static UIImage *STButtonImage(UIView *item, BOOL selected) {
    UIButton *button = STValue(item, @"navigationButton");
    if (![button isKindOfClass:UIButton.class]) return nil;
    return [button imageForState:selected ? UIControlStateSelected : UIControlStateNormal] ?: button.currentImage;
}

// (Re)builds the tabs when YouTube's tabs or the search style change. They're YTPlus's items when its bar is there
// (YouTube's own tab buttons include hidden placeholders, and YTPlus may add or drop tabs), else YouTube's visible buttons.
static void STBuildTabs(STState *state, UIView *bar, NSArray<UIView *> *allItems) {
    UITabBar *ytplus = STYTPlusTabBar(bar);
    if (ytplus.items.count == 0) ytplus = nil;
    NSArray *titles = nil; // YouTube's names, read only when a tab has none of its own
    static BOOL iconsOnly; // YTPlus's "Remove tab labels"
    static dispatch_once_t once;
    dispatch_once(&once, ^{ iconsOnly = [[[NSUserDefaults alloc] initWithSuiteName:@"com.dvntm.ytlite"] boolForKey:@"removeLabels"]; });
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    for (UIView *item in allItems) if (!item.hidden && CGRectGetWidth(item.bounds) > 0.0) [items addObject:item];
    NSInteger mode = YTGSearchMode();
    NSMutableString *signature = [NSMutableString stringWithFormat:@"%ld|%@", (long)mode, ytplus ? @"ytplus" : @"youtube"];
    NSUInteger count = ytplus ? ytplus.items.count : items.count;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableArray<UIImage *> *images = [NSMutableArray array], *selectedImages = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        NSString *title = nil;
        UIImage *image = nil, *selected = nil;
        if (ytplus) {
            UITabBarItem *item = ytplus.items[i];
            title = item.title;
            if (title.length == 0) {
                if (titles == nil) titles = TBHTabTitles(bar);
                id known = i < titles.count ? titles[i] : nil;
                title = [known isKindOfClass:NSString.class] ? known : nil;
            }
            // A picture rather than a glyph (the You tab's profile picture) is drawn as it is, the same for both looks:
            // tinted as a template it would be a plain disc.
            BOOL picture = item.image && item.image.renderingMode != UIImageRenderingModeAlwaysTemplate;
            image = picture ? STAsIs(item.image) : item.image;
            selected = picture ? image : item.selectedImage;
        } else {
            NSUInteger index = [allItems indexOfObject:items[i]];
            if (titles == nil) titles = TBHTabTitles(bar);
            id known = index < titles.count ? titles[index] : nil;
            title = [known isKindOfClass:NSString.class] ? known : nil;
            image = STButtonImage(items[i], NO) ?: STImage(TBHTabIdentifier(items[i]), NO);
            selected = STButtonImage(items[i], YES) ?: STImage(TBHTabIdentifier(items[i]), YES);
        }
        [names addObject:iconsOnly ? @"" : title ?: @""];
        [images addObject:image ?: STImage(nil, NO)];
        [selectedImages addObject:selected ?: images.lastObject];
        [signature appendFormat:@"|%@:%p:%p", names.lastObject, images.lastObject, selectedImages.lastObject];
    }
    if ([signature isEqualToString:state.signature]) return;
    if (!STRaiseLimit(state.controller, count + (mode == YTGSearchOff ? 0 : 1))) count = MIN(count, (NSUInteger)(mode == YTGSearchOff ? 5 : 4));
    NSMutableArray *tabs = [NSMutableArray array];
    state.items = [NSPointerArray weakObjectsPointerArray];
    state.ytplusBar = ytplus;
    for (NSUInteger i = 0; i < count; i++) {
        id tab = STMakeTab(names[i], images[i], selectedImages[i], [STTabPrefix stringByAppendingFormat:@"%lu", (unsigned long)i]);
        if (tab == nil) return;
        [tabs addObject:tab];
        if (!ytplus) [state.items addPointer:(__bridge void *)items[i]];
    }
    NSString *prominent = nil;
    if (mode == YTGSearchSeparate) {
        id search = STMakeSearchTab();
        if (search) [tabs addObject:search];
        prominent = STTabIdentifier(search);
    } else if (mode == YTGSearchInTabBar) {
        id search = STMakeTab(@"Search", [UIImage systemImageNamed:@"magnifyingglass"], nil, STSearchIdentifier);
        if (search) [tabs addObject:search];
    }
    state.syncing = YES;
    STSend(state.controller, @"setTabs:", tabs);
    // iOS 27: the prominent tab is drawn as its own glass circle beside the bar (the Music app's Search).
    STSend(state.controller, @"setProminentTabIdentifier:", prominent);
    state.syncing = NO;
    state.signature = signature;
}

// UIKit paints the controller's view and the views between it and the pages in the system background: all but the bar
// are made clear, and the pages' layer takes no touches.
static void STClearBackdrops(UITabBarController *controller) {
    UIView *root = controller.viewIfLoaded, *tabBar = controller.tabBar;
    if (root == nil) return;
    if (root.backgroundColor != UIColor.clearColor) root.backgroundColor = UIColor.clearColor;
    for (UIView *sub in root.subviews) {
        if (sub == tabBar || [tabBar isDescendantOfView:sub]) continue;
        NSString *name = NSStringFromClass(sub.class);
        if (![name containsString:@"Transition"] && ![name containsString:@"Wrapper"]) continue; // only the pages' layer
        if (sub.backgroundColor) sub.backgroundColor = UIColor.clearColor;
        if (sub.userInteractionEnabled) sub.userInteractionEnabled = NO;
        for (UIView *inner in sub.subviews) if (inner.backgroundColor) inner.backgroundColor = UIColor.clearColor;
    }
}

static STState *STMakeState(void) {
    STState *state = [STState new];
    UITabBarController *controller = [UITabBarController new];
    controller.delegate = state;
    controller.tabBar.tintColor = UIColor.labelColor; // the selected tab: white in dark mode, black in light
    state.controller = controller;
    STHost *host = [[STHost alloc] initWithFrame:CGRectZero];
    host.controller = controller;
    host.backgroundColor = UIColor.clearColor;
    state.host = host;
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:state action:@selector(held:)];
    hold.minimumPressDuration = 0.8;
    hold.delegate = state;
    hold.cancelsTouchesInView = NO;
    [controller.tabBar addGestureRecognizer:hold];
    return state;
}

#pragma mark - Following YouTube's bar

static UIView *STAppView(UIView *bar) {
    static Class appViewClass;
    if (appViewClass == Nil) appViewClass = NSClassFromString(@"YTAppView");
    for (UIView *view = bar.superview; view != nil; view = view.superview) if (appViewClass && [view isKindOfClass:appViewClass]) return view;
    return nil;
}

// YouTube's bar is shown when it's on screen (YouTube hides it by moving it below the screen).
static BOOL STBarShown(UIView *bar) {
    UIWindow *window = bar.window;
    if (window == nil || bar.hidden || bar.alpha < 0.01) return NO;
    CGRect frame = [bar convertRect:bar.bounds toView:nil];
    return CGRectGetMinY(frame) < CGRectGetHeight(window.bounds) - 1.0;
}

static void STSetHidden(STState *state, BOOL hidden, BOOL animated) {
    UITabBarController *controller = state.controller;
    SEL getter = NSSelectorFromString(@"isTabBarHidden"), setter = NSSelectorFromString(@"setTabBarHidden:animated:");
    if ([controller respondsToSelector:getter] && [controller respondsToSelector:setter]) {
        if (((BOOL (*)(id, SEL))objc_msgSend)(controller, getter) == hidden) return;
        ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(controller, setter, hidden, animated);
    } else if (controller.tabBar.hidden != hidden) {
        controller.tabBar.hidden = hidden;
    }
}

// YouTube's own bar goes invisible (its background, its buttons and YTPlus's bar), staying in place for YouTube's layout.
static void STHideYouTubeBar(UIView *bar) {
    UIView *blur = STValue(bar, @"blurView");
    if ([blur isKindOfClass:UIView.class] && !blur.hidden) blur.hidden = YES;
    for (UIView *subview in bar.subviews) if (subview.alpha > 0.0) subview.alpha = 0.0;
    if (bar.backgroundColor != UIColor.clearColor) bar.backgroundColor = UIColor.clearColor;
}

static void STLayout(UIView *bar) {
    UIView *appView = STAppView(bar);
    NSArray<UIView *> *items = TBHTabItems(bar);
    if (appView == nil || bar.window == nil || items.count == 0) return;
    STState *state = STShared ?: (STShared = STMakeState());
    state.bar = bar;
    STHost *host = state.host;
    UITabBarController *controller = state.controller;
    if (host.superview != appView) {
        UIViewController *owner = nil;
        for (UIResponder *r = appView.nextResponder; r && owner == nil; r = r.nextResponder) {
            if ([r isKindOfClass:UIViewController.class]) owner = (UIViewController *)r;
        }
        [controller willMoveToParentViewController:nil];
        [controller.viewIfLoaded removeFromSuperview];
        [controller removeFromParentViewController];
        if (owner) [owner addChildViewController:controller];
        host.frame = appView.bounds;
        host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        controller.view.frame = host.bounds;
        controller.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [host addSubview:controller.view];
        [appView addSubview:host];
        if (owner) [controller didMoveToParentViewController:owner];
    }
    // Just above YouTube's bar, so the player and the mini player (above it) stay above ours.
    UIView *barChild = bar;
    while (barChild.superview && barChild.superview != appView) barChild = barChild.superview;
    NSUInteger barIndex = [appView.subviews indexOfObject:barChild], hostIndex = [appView.subviews indexOfObject:host];
    if (barIndex != NSNotFound && hostIndex != barIndex + 1) [appView insertSubview:host aboveSubview:barChild];
    if (!CGRectEqualToRect(host.frame, appView.bounds)) host.frame = appView.bounds;
    STHideYouTubeBar(bar);
    STClearBackdrops(controller);
    STBuildTabs(state, bar, items);
    UITabBar *ytplus = state.ytplusBar;
    if (ytplus) {
        NSUInteger index = ytplus.selectedItem ? [ytplus.items indexOfObject:ytplus.selectedItem] : NSNotFound;
        if (index != NSNotFound) STSelectIndex(state, index);
    } else {
        for (NSUInteger i = 0; i < state.items.count; i++) {
            UIView *item = (__bridge UIView *)[state.items pointerAtIndex:i];
            if (item && TBHTabSelected(item)) STSelectIndex(state, i);
        }
    }
    STSetHidden(state, !STBarShown(bar), NO);
}

#pragma mark - Hooks

static IMP OriginalBarLayout, OriginalItemSetSelected, OriginalHidePivotBar, OriginalShowPivotBar, OriginalTabBarSetSelected;

// YTPlus's bar changed its selection (YouTube switched tabs): the system bar follows.
static void STTabBarSetSelected(UITabBar *self, SEL _cmd, UITabBarItem *item) {
    ((void (*)(id, SEL, UITabBarItem *))OriginalTabBarSetSelected)(self, _cmd, item);
    STState *state = STShared;
    if (state == nil || state.ytplusBar != self || item == nil) return;
    NSUInteger index = [self.items indexOfObject:item];
    if (index != NSNotFound) STSelectIndex(state, index);
}

static void STBarLayout(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))OriginalBarLayout)(self, _cmd);
    STLayout(self);
}

// YouTube changed the selection (a tab opened from elsewhere, or at launch): the system bar follows.
static void STItemSetSelected(UIView *self, SEL _cmd, BOOL selected) {
    ((void (*)(id, SEL, BOOL))OriginalItemSetSelected)(self, _cmd, selected);
    STState *state = STShared;
    if (!selected || state == nil || state.ytplusBar) return;
    for (NSUInteger i = 0; i < state.items.count; i++) {
        if ([state.items pointerAtIndex:i] == (__bridge void *)self) STSelectIndex(state, i);
    }
}

// YouTube moves its bar off the screen and back without laying it out (when the player opens and closes): ours follows
// where it is.
static IMP OriginalBarSetFrame, OriginalBarSetCenter, OriginalBarSetHidden, OriginalBarSetAlpha;

static void STFollowBar(UIView *bar) {
    STState *state = STShared;
    if (state == nil || state.bar != bar) return;
    STSetHidden(state, !STBarShown(bar), YES);
}

static void STBarSetFrame(UIView *self, SEL _cmd, CGRect frame) {
    ((void (*)(id, SEL, CGRect))OriginalBarSetFrame)(self, _cmd, frame);
    STFollowBar(self);
}

static void STBarSetCenter(UIView *self, SEL _cmd, CGPoint center) {
    ((void (*)(id, SEL, CGPoint))OriginalBarSetCenter)(self, _cmd, center);
    STFollowBar(self);
}

static void STBarSetHidden(UIView *self, SEL _cmd, BOOL hidden) {
    ((void (*)(id, SEL, BOOL))OriginalBarSetHidden)(self, _cmd, hidden);
    STFollowBar(self);
}

static void STBarSetAlpha(UIView *self, SEL _cmd, CGFloat alpha) {
    ((void (*)(id, SEL, CGFloat))OriginalBarSetAlpha)(self, _cmd, alpha);
    STFollowBar(self);
}

// YouTube hides or shows its bar (on scroll, for the player, or the tab bar autohide): ours goes with it.
static void STHidePivotBar(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))OriginalHidePivotBar)(self, _cmd);
    if (STShared) STSetHidden(STShared, YES, YES);
}

static void STShowPivotBar(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))OriginalShowPivotBar)(self, _cmd);
    if (STShared) STSetHidden(STShared, NO, YES);
}

__attribute__((constructor)) static void STInit(void) {
    if (!YTGSystemTabBarOn()) return;
    @autoreleasepool {
        Class pivotBar = NSClassFromString(@"YTPivotBarView");
        TBHHookMethod(pivotBar, @"layoutSubviews", (IMP)STBarLayout, &OriginalBarLayout);
        TBHHookMethod(pivotBar, @"setFrame:", (IMP)STBarSetFrame, &OriginalBarSetFrame);
        TBHHookMethod(pivotBar, @"setCenter:", (IMP)STBarSetCenter, &OriginalBarSetCenter);
        TBHHookMethod(pivotBar, @"setHidden:", (IMP)STBarSetHidden, &OriginalBarSetHidden);
        TBHHookMethod(pivotBar, @"setAlpha:", (IMP)STBarSetAlpha, &OriginalBarSetAlpha);
        TBHHookMethod(NSClassFromString(@"YTPivotBarItemView"), @"setSelected:", (IMP)STItemSetSelected, &OriginalItemSetSelected);
        TBHHookMethod(UITabBar.class, @"setSelectedItem:", (IMP)STTabBarSetSelected, &OriginalTabBarSetSelected);
        Class appView = NSClassFromString(@"YTAppView");
        TBHHookMethod(appView, @"hidePivotBar", (IMP)STHidePivotBar, &OriginalHidePivotBar);
        TBHHookMethod(appView, @"showPivotBar", (IMP)STShowPivotBar, &OriginalShowPivotBar);
    }
}
