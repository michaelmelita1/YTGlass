// GlassTabBar
// iOS 26's own Liquid Glass tab bar in place of YouTube's, independent of other tweaks (use it with YTPlus's Liquid
// Glass tab bar off). A real UITabBarController's tab bar sits inside YouTube's YTPivotBarView, with a UITab for each
// of YouTube's tabs (YouTube's name, an iOS symbol), so everything about it is native: the glass, the touch response,
// the lens, and (Search: Separate) the system search tab beside the bar that merges into it when stretched, as in the
// iOS 26 Phone app. Search: Integrated puts a plain Search tab in the bar instead.
//
// YouTube's own tab buttons stay underneath, invisible: choosing a tab selects YouTube's button the way a tap would,
// and the bar follows YouTube's selection. A search tab never stays selected: it opens YouTube's search.
//
// The UITab API is newer than the SDK this builds with, so it's used through the runtime.
//
// Pure Objective-C runtime swizzling: no CydiaSubstrate / ElleKit dependency.

#import "Common.h"

static NSString *const GTSearchIdentifier = @"ytglass.search";
static const void *GTStateKey = &GTStateKey; // YTPivotBarView -> GTState

@interface GTState : NSObject <UITabBarControllerDelegate>
@property (nonatomic, weak) UIView *bar;
@property (nonatomic, strong) UITabBarController *controller;
@property (nonatomic, copy) NSArray<NSString *> *identifiers; // the tabs the controller was built with
@property (nonatomic, assign) NSInteger searchMode;
@property (nonatomic, strong) NSMapTable<NSString *, UIView *> *items; // identifier -> YouTube's button (weak)
@property (nonatomic, assign) BOOL syncing;                          // selecting to match YouTube, not the user
@end

#pragma mark - YouTube's tab buttons

static void GTCollectItems(UIView *view, NSMutableArray<UIView *> *items) {
    static Class itemClass;
    if (itemClass == Nil) itemClass = NSClassFromString(@"YTPivotBarItemView");
    if (itemClass && [view isKindOfClass:itemClass]) {
        if (CGRectGetWidth(view.bounds) > 0.0) [items addObject:view];
        return;
    }
    for (UIView *subview in view.subviews) GTCollectItems(subview, items);
}

static NSArray<UIView *> *GTItems(UIView *bar) {
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    GTCollectItems(bar, items);
    [items sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return [@(CGRectGetMinX([a convertRect:a.bounds toView:bar])) compare:@(CGRectGetMinX([b convertRect:b.bounds toView:bar]))];
    }];
    return items;
}

static id GTValue(id object, NSString *key) {
    @try { return [object valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

static NSString *GTItemIdentifier(UIView *item) {
    id identifier = GTValue(GTValue(item, @"renderer"), @"pivotIdentifier");
    return [identifier isKindOfClass:NSString.class] && [identifier length] ? identifier : nil;
}

static NSString *GTItemTitle(UIView *item) {
    id title = GTValue(GTValue(item, @"renderer"), @"title");
    SEL plain = NSSelectorFromString(@"stringWithFormattingRemoved");
    if (title && ![title isKindOfClass:NSString.class] && [title respondsToSelector:plain]) title = ((id (*)(id, SEL))objc_msgSend)(title, plain);
    if ([title isKindOfClass:NSString.class] && [title length]) return title;
    return item.accessibilityLabel ?: @"";
}

// iOS symbols for YouTube's tabs (YouTube's own icon views don't carry a usable image); anything else gets a circle.
static UIImage *GTItemImage(NSString *identifier) {
    NSDictionary *symbols = @{ @"FEwhat_to_watch": @"house", @"FEshorts": @"play.rectangle.on.rectangle", @"FEsubscriptions": @"play.square.stack",
                               @"FEhistory": @"clock.arrow.circlepath", @"FElibrary": @"person.crop.circle", @"FEyou": @"person.crop.circle",
                               @"FEdownloads": @"arrow.down.circle", @"FEexplore": @"safari" };
    return [UIImage systemImageNamed:symbols[identifier] ?: @"circle"];
}

// Selects a tab the way YouTube's own button does.
static void GTSelectItem(UIView *item) {
    id delegate = GTValue(item, @"delegate"), renderer = GTValue(item, @"renderer");
    SEL tap = NSSelectorFromString(@"didTapItemWithRenderer:");
    if (renderer && [delegate respondsToSelector:tap]) {
        ((void (*)(id, SEL, id))objc_msgSend)(delegate, tap, renderer);
        return;
    }
    SEL buttonSel = NSSelectorFromString(@"navigationButton");
    UIControl *button = [item respondsToSelector:buttonSel] ? ((id (*)(id, SEL))objc_msgSend)(item, buttonSel) : nil;
    if ([button isKindOfClass:UIControl.class]) [button sendActionsForControlEvents:UIControlEventTouchUpInside];
}

#pragma mark - The system tab bar

static UIViewController *GTBlankPage(void) {
    UIViewController *page = [UIViewController new];
    page.view.backgroundColor = UIColor.clearColor;
    page.view.userInteractionEnabled = NO; // only the tab bar takes touches
    return page;
}

static id GTMakeTab(NSString *title, UIImage *image, NSString *identifier) {
    Class tabClass = NSClassFromString(@"UITab");
    SEL init = NSSelectorFromString(@"initWithTitle:image:identifier:viewControllerProvider:");
    if (![tabClass instancesRespondToSelector:init]) return nil;
    UIViewController *(^provider)(id) = ^UIViewController *(__unused id tab) { return GTBlankPage(); };
    return ((id (*)(id, SEL, NSString *, UIImage *, NSString *, id))objc_msgSend)([tabClass alloc], init, title, image, identifier, provider);
}

static id GTMakeSearchTab(void) {
    Class searchClass = NSClassFromString(@"UISearchTab");
    SEL init = NSSelectorFromString(@"initWithViewControllerProvider:");
    if (![searchClass instancesRespondToSelector:init]) return nil;
    UIViewController *(^provider)(id) = ^UIViewController *(__unused id tab) { return GTBlankPage(); };
    return ((id (*)(id, SEL, id))objc_msgSend)([searchClass alloc], init, provider);
}

static NSString *GTTabIdentifier(id tab) {
    id identifier = GTValue(tab, @"identifier");
    return [identifier isKindOfClass:NSString.class] ? identifier : nil;
}

static void GTSelectTab(GTState *state, NSString *identifier) {
    NSArray *tabs = GTValue(state.controller, @"tabs");
    for (id tab in tabs) {
        if (![GTTabIdentifier(tab) isEqualToString:identifier]) continue;
        if (GTValue(state.controller, @"selectedTab") == tab) return;
        state.syncing = YES;
        ((void (*)(id, SEL, id))objc_msgSend)(state.controller, NSSelectorFromString(@"setSelectedTab:"), tab);
        state.syncing = NO;
        return;
    }
}

@implementation GTState

// The user chose a tab: YouTube's button for it is selected; a search tab opens search and never stays selected.
- (BOOL)tabBarController:(__unused UITabBarController *)controller shouldSelectTab:(id)tab {
    if (self.syncing) return YES;
    NSString *identifier = GTTabIdentifier(tab);
    Class searchClass = NSClassFromString(@"UISearchTab");
    if ((searchClass && [tab isKindOfClass:searchClass]) || [identifier isEqualToString:GTSearchIdentifier]) {
        YTGOpenSearch(self.bar);
        return NO;
    }
    UIView *item = identifier ? [self.items objectForKey:identifier] : nil;
    if (item && !TBHPivotItemSelected(item)) GTSelectItem(item);
    return YES;
}

@end

// (Re)builds the controller's tabs when YouTube's tabs or the search mode change.
static void GTBuildTabs(GTState *state, NSArray<UIView *> *items) {
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    for (UIView *item in items) {
        NSString *identifier = GTItemIdentifier(item);
        if (identifier) [identifiers addObject:identifier];
    }
    NSInteger mode = YTGSearchMode();
    if ([identifiers isEqualToArray:state.identifiers] && mode == state.searchMode) return;
    NSMutableArray *tabs = [NSMutableArray array];
    [state.items removeAllObjects];
    for (UIView *item in items) {
        NSString *identifier = GTItemIdentifier(item);
        id tab = identifier ? GTMakeTab(GTItemTitle(item), GTItemImage(identifier), identifier) : nil;
        if (tab == nil) continue;
        [tabs addObject:tab];
        [state.items setObject:item forKey:identifier];
    }
    if (mode == YTGSearchSeparate) {
        id search = GTMakeSearchTab(); // the system places it beside the bar, as its own glass button
        if (search) [tabs addObject:search];
    } else if (mode == YTGSearchInTabBar) {
        id search = GTMakeTab(@"Search", [UIImage systemImageNamed:@"magnifyingglass"], GTSearchIdentifier);
        if (search) [tabs addObject:search];
    }
    state.syncing = YES;
    ((void (*)(id, SEL, id))objc_msgSend)(state.controller, NSSelectorFromString(@"setTabs:"), tabs);
    state.syncing = NO;
    state.identifiers = identifiers;
    state.searchMode = mode;
}

static GTState *GTStateFor(UIView *bar) {
    GTState *state = objc_getAssociatedObject(bar, GTStateKey);
    if (state) return state;
    state = [GTState new];
    state.bar = bar;
    state.items = [NSMapTable strongToWeakObjectsMapTable];
    state.searchMode = -1;
    state.controller = [UITabBarController new];
    state.controller.delegate = state;
    state.controller.view.backgroundColor = UIColor.clearColor;
    state.controller.tabBar.tintColor = UIColor.labelColor; // the selected tab: white in dark mode, black in light
    objc_setAssociatedObject(bar, GTStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return state;
}

#pragma mark - Layout

// YouTube's own bar goes invisible (its background and its buttons, which stay in place for selection).
static void GTHideYouTubeBar(UIView *bar, GTState *state) {
    SEL blurSel = NSSelectorFromString(@"blurView");
    UIView *blur = [bar respondsToSelector:blurSel] ? ((id (*)(id, SEL))objc_msgSend)(bar, blurSel) : nil;
    if ([blur isKindOfClass:UIView.class]) blur.hidden = YES;
    for (UIView *sibling in bar.subviews) {
        if (sibling == state.controller.view) continue;
        if (sibling.alpha > 0.0) sibling.alpha = 0.0;
    }
    bar.backgroundColor = UIColor.clearColor;
    bar.opaque = NO;
    bar.clipsToBounds = NO;
    bar.layer.masksToBounds = NO;
}

static void GTLayout(UIView *bar) {
    GTState *state = GTStateFor(bar);
    NSArray<UIView *> *items = GTItems(bar);
    if (items.count == 0) return;
    UIView *host = state.controller.view;
    if (host.superview != bar) {
        // Contained by the view controller that owns YouTube's bar, so it gets its appearance calls.
        UIViewController *owner = nil;
        for (UIResponder *r = bar.nextResponder; r && owner == nil; r = r.nextResponder) {
            if ([r isKindOfClass:UIViewController.class]) owner = (UIViewController *)r;
        }
        if (owner && state.controller.parentViewController != owner) [owner addChildViewController:state.controller];
        [bar addSubview:host];
        [state.controller didMoveToParentViewController:owner];
    }
    GTHideYouTubeBar(bar, state);
    if (bar.subviews.lastObject != host) [bar bringSubviewToFront:host];
    if (!CGRectEqualToRect(host.frame, bar.bounds)) host.frame = bar.bounds;
    GTBuildTabs(state, items);
    for (UIView *item in items) {
        if (TBHPivotItemSelected(item)) GTSelectTab(state, GTItemIdentifier(item));
    }
}

#pragma mark - Hooks

static IMP OriginalBarLayout, OriginalStyleColors, OriginalSetBackgroundStyle, OriginalItemSetSelected;

static void GTBarLayout(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))OriginalBarLayout)(self, _cmd);
    GTLayout(self);
}

// YouTube restyles its bar (e.g. when the mini player appears): it goes invisible again.
static void GTStyleColors(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))OriginalStyleColors)(self, _cmd);
    GTState *state = objc_getAssociatedObject(self, GTStateKey);
    if (state) GTHideYouTubeBar(self, state);
}

static void GTSetBackgroundStyle(UIView *self, SEL _cmd, int style) {
    ((void (*)(id, SEL, int))OriginalSetBackgroundStyle)(self, _cmd, style);
    GTState *state = objc_getAssociatedObject(self, GTStateKey);
    if (state) GTHideYouTubeBar(self, state);
}

// YouTube changed the selection (a tab opened from elsewhere, or at launch): the system bar follows.
static void GTItemSetSelected(UIView *self, SEL _cmd, BOOL selected) {
    ((void (*)(id, SEL, BOOL))OriginalItemSetSelected)(self, _cmd, selected);
    if (!selected) return;
    UIView *bar = self.superview;
    while (bar && ![NSStringFromClass(bar.class) isEqualToString:@"YTPivotBarView"]) bar = bar.superview;
    GTState *state = bar ? objc_getAssociatedObject(bar, GTStateKey) : nil;
    NSString *identifier = GTItemIdentifier(self);
    if (state && identifier) GTSelectTab(state, identifier);
}

__attribute__((constructor)) static void GTInit(void) {
    if (!YTGOptInEnabled(YTGGlassTabBarKey) || NSClassFromString(@"UITab") == Nil || NSClassFromString(@"UIGlassEffect") == Nil) return;
    @autoreleasepool {
        Class bar = NSClassFromString(@"YTPivotBarView");
        TBHHookMethod(bar, @"layoutSubviews", (IMP)GTBarLayout, &OriginalBarLayout);
        TBHHookMethod(bar, @"styleBackgroundColors", (IMP)GTStyleColors, &OriginalStyleColors);
        TBHHookMethod(bar, @"setBackgroundStyle:", (IMP)GTSetBackgroundStyle, &OriginalSetBackgroundStyle);
        TBHHookMethod(NSClassFromString(@"YTPivotBarItemView"), @"setSelected:", (IMP)GTItemSetSelected, &OriginalItemSetSelected);
    }
}
