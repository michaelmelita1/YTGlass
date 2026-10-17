// SearchButton
// Search for YTPlus's Liquid Glass tab bar, in one of two styles (Settings → YTGlass → Search):
// - a round Liquid Glass search button to the right of the tab bar, like Apple Music and the
//   App Store on iOS 26;
// - a Search item at the end of the tab bar itself.
// Either opens YouTube's normal search (it taps the search button in the top bar,
// id.ui.navigation.search.button).
//
// Only active when the tab bar is a system UITabBar inside YTPivotBarView (YTPlus 6 and its
// Liquid Glass tab bar). The tab bar is narrowed to make room, and the button lives inside
// YTPivotBarView, so it hides and shows together with the bar.
//
// Pure Objective-C runtime swizzling: no CydiaSubstrate / ElleKit dependency.

#import "Common.h"

static CGFloat const TBSGap = 10.0;          // space between the tab bar capsule and the circle
static CGFloat const TBSDefaultSize = 62.0;  // used until the capsule's real height is measured

static const void *TBSButtonKey = &TBSButtonKey;       // YTPivotBarView -> our button
static const void *TBSManagedKey = &TBSManagedKey;     // UITabBar -> @YES when we narrow it
static const void *TBSAdjustedKey = &TBSAdjustedKey;   // UITabBar -> NSValue, the frame we gave it
static const void *TBSFullKey = &TBSFullKey;           // UITabBar -> NSValue, the frame YTPlus gave it
static CGFloat TBSSize = TBSDefaultSize;               // circle diameter = capsule height

#pragma mark - Opening search

static BOOL TBSUsable(UIView *view) {
    if (view.window == nil) return NO;
    for (UIView *v = view; v != nil; v = v.superview) {
        if (TBHTopBarHiddenByUs(v)) continue; // the top bar we removed still holds the page's search button
        if (v.hidden || v.alpha < 0.01) return NO;
    }
    CGRect frame = [view convertRect:view.bounds toView:view.window];
    return CGRectIntersectsRect(frame, view.window.bounds);
}

static void TBSFindSearchButtons(UIView *view, NSMutableArray<UIView *> *found) {
    if ([view.accessibilityIdentifier isEqualToString:@"id.ui.navigation.search.button"]) [found addObject:view];
    for (UIView *subview in view.subviews) TBSFindSearchButtons(subview, found);
}

void YTGOpenSearch(UIView *from) {
    UIWindow *window = from.window;
    if (window == nil) return;
    NSMutableArray<UIView *> *found = [NSMutableArray array];
    TBSFindSearchButtons(window, found);
    // Prefer the one actually on screen (other tabs keep their own, hidden, top bars).
    UIView *target = nil;
    for (UIView *candidate in found) if (TBSUsable(candidate)) target = candidate;
    if (target == nil) target = found.lastObject;
    if (target == nil) return;
    UIView *control = target;
    while (control != nil && ![control isKindOfClass:UIControl.class]) control = control.superview;
    if ([control isKindOfClass:UIControl.class] && control.window == window) {
        [(UIControl *)control sendActionsForControlEvents:UIControlEventTouchUpInside];
    } else {
        [target accessibilityActivate];
    }
}

@interface TBSSearchTarget : NSObject
@end

@implementation TBSSearchTarget
- (void)tapped:(UIButton *)button {
    YTGOpenSearch(button);
}
@end

#pragma mark - The button

static UIImageSymbolConfiguration *TBSGlyphConfiguration(CGFloat pointSize) {
    return [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:UIImageSymbolWeightMedium];
}

static UIImage *TBSGlyph(CGFloat pointSize) {
    return [UIImage systemImageNamed:@"magnifyingglass" withConfiguration:TBSGlyphConfiguration(pointSize)];
}

static UIButton *TBSMakeButton(void) {
    UIButtonConfiguration *config = nil;
    SEL glass = NSSelectorFromString(@"glassButtonConfiguration"); // iOS 26
    if ([UIButtonConfiguration respondsToSelector:glass]) {
        config = ((UIButtonConfiguration * (*)(id, SEL))objc_msgSend)(UIButtonConfiguration.class, glass);
    } else {
        config = [UIButtonConfiguration filledButtonConfiguration];
        config.baseBackgroundColor = [UIColor.secondarySystemBackgroundColor colorWithAlphaComponent:0.9];
    }
    config.image = TBSGlyph(18.0); // resized to the circle in TBSBarLayout
    config.baseForegroundColor = UIColor.labelColor;
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    config.contentInsets = NSDirectionalEdgeInsetsZero;
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    static TBSSearchTarget *target;
    if (target == nil) target = [TBSSearchTarget new];
    [button addTarget:target action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
    button.accessibilityLabel = @"Search";
    button.accessibilityIdentifier = @"tbh.search.button";
    return button;
}

static UITabBar *TBSTabBar(UIView *view, NSInteger depth) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:UITabBar.class]) return (UITabBar *)subview;
    }
    if (depth <= 0) return nil;
    for (UIView *subview in view.subviews) {
        UITabBar *found = TBSTabBar(subview, depth - 1);
        if (found) return found;
    }
    return nil;
}

// The glass capsule the tab bar draws. Full-width bar backgrounds are skipped (the capsule has
// side margins); among the rest, the platter/glass view with the largest area wins.
static NSInteger TBSCapsuleScore(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    if ([name containsString:@"Platter"]) return 3;
    if ([name containsString:@"Glass"]) return 2;
    if ([view isKindOfClass:UIVisualEffectView.class]) return 1;
    return 0;
}

static UIView *TBSCapsule(UIView *view, UITabBar *tabBar, NSInteger depth, UIView *best) {
    for (UIView *subview in view.subviews) {
        if (subview.hidden || subview.alpha < 0.01) continue;
        CGRect frame = [subview convertRect:subview.bounds toView:tabBar];
        BOOL shaped = CGRectGetHeight(frame) >= 40.0 && CGRectGetHeight(frame) <= 76.0 &&
                      CGRectGetWidth(frame) >= CGRectGetWidth(tabBar.bounds) * 0.5 &&
                      CGRectGetWidth(frame) <= CGRectGetWidth(tabBar.bounds) - 8.0;
        NSInteger score = shaped ? TBSCapsuleScore(subview) : 0;
        if (score > 0) {
            NSInteger bestScore = best ? TBSCapsuleScore(best) : 0;
            CGFloat area = CGRectGetWidth(frame) * CGRectGetHeight(frame);
            CGFloat bestArea = best ? CGRectGetWidth(best.bounds) * CGRectGetHeight(best.bounds) : 0.0;
            if (score > bestScore || (score == bestScore && area > bestArea)) best = subview;
        }
        if (depth > 0) best = TBSCapsule(subview, tabBar, depth - 1, best);
    }
    return best;
}

// The capsule found last time, reused while it's still shown inside the same tab bar.
static UIView *TBSFindCapsule(UITabBar *tabBar) {
    static __weak UIView *lastCapsule;
    static __weak UITabBar *lastTabBar;
    UIView *capsule = lastCapsule;
    if (capsule && lastTabBar == tabBar && !capsule.hidden && capsule.alpha >= 0.01 && [capsule isDescendantOfView:tabBar]) return capsule;
    capsule = TBSCapsule(tabBar, tabBar, 4, nil);
    lastCapsule = capsule;
    lastTabBar = tabBar;
    return capsule;
}

static BOOL TBSRightToLeft(UIView *view) {
    return view.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
}

static CGRect TBSNarrowed(CGRect full, UIView *tabBar) {
    CGFloat reserve = TBSSize + TBSGap;
    if (CGRectGetWidth(full) < reserve * 4.0) return full; // too narrow to share (e.g. iPad sidebar)
    CGRect frame = full;
    frame.size.width -= reserve;
    if (TBSRightToLeft(tabBar)) frame.origin.x += reserve;
    return frame;
}

#pragma mark - Hooks

static IMP OriginalTabBarSetFrame;

// YTPlus sizes the tab bar to the full width of YouTube's bar; we hand it a narrower frame.
static void TBSTabBarSetFrame(UITabBar *self, SEL _cmd, CGRect frame) {
    if ([objc_getAssociatedObject(self, TBSManagedKey) boolValue]) {
        NSValue *adjusted = objc_getAssociatedObject(self, TBSAdjustedKey);
        if (adjusted == nil || !CGRectEqualToRect(adjusted.CGRectValue, frame)) {
            objc_setAssociatedObject(self, TBSFullKey, [NSValue valueWithCGRect:frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            frame = TBSNarrowed(frame, self);
            objc_setAssociatedObject(self, TBSAdjustedKey, [NSValue valueWithCGRect:frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    ((void (*)(id, SEL, CGRect))OriginalTabBarSetFrame)(self, _cmd, frame);
}

static void TBSReapply(UITabBar *tabBar) {
    NSValue *full = objc_getAssociatedObject(tabBar, TBSFullKey);
    objc_setAssociatedObject(tabBar, TBSAdjustedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    tabBar.frame = full ? full.CGRectValue : tabBar.frame;
}

// The glass grows a little while pressed; YouTube's bar clips to its bounds, which would cut the top off.
// (YTKACE's glass tab bar turns this off for the same reason.) Done in every search mode.
static void TBSUnclip(UIView *bar) {
    if (bar.clipsToBounds) bar.clipsToBounds = NO;
    if (bar.layer.masksToBounds) bar.layer.masksToBounds = NO;
}

static IMP OriginalBarLayout;

static void TBSBarLayout(UIView *self, SEL _cmd) {
    if (OriginalBarLayout) ((void (*)(id, SEL))OriginalBarLayout)(self, _cmd);
    UIButton *button = objc_getAssociatedObject(self, TBSButtonKey);
    UITabBar *tabBar = TBSTabBar(self, 2);
    if (tabBar == nil || tabBar.hidden) { // stock YouTube bar: leave it alone
        button.hidden = YES;
        return;
    }
    if (![objc_getAssociatedObject(tabBar, TBSManagedKey) boolValue]) {
        objc_setAssociatedObject(tabBar, TBSManagedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        TBSReapply(tabBar);
    }
    NSValue *full = objc_getAssociatedObject(tabBar, TBSFullKey);
    if (full == nil || CGRectEqualToRect(full.CGRectValue, tabBar.frame)) { // too narrow to share
        button.hidden = YES;
        return;
    }
    [tabBar layoutIfNeeded];

    // Match the capsule: same height, same vertical centre, same outer margin.
    UIView *capsule = TBSFindCapsule(tabBar);
    CGRect capsuleFrame = capsule ? [capsule convertRect:capsule.bounds toView:self] : CGRectZero;
    if (capsule != nil && fabs(CGRectGetHeight(capsuleFrame) - TBSSize) > 0.5) {
        TBSSize = CGRectGetHeight(capsuleFrame);
        TBSReapply(tabBar);
        [tabBar layoutIfNeeded];
        capsuleFrame = [capsule convertRect:capsule.bounds toView:self];
    }
    CGFloat size = TBSSize;
    CGRect fullFrame = [tabBar.superview convertRect:full.CGRectValue toView:self];
    CGFloat midY, x;
    if (capsule != nil) {
        midY = CGRectGetMidY(capsuleFrame);
        x = TBSRightToLeft(self) ? CGRectGetMinX(capsuleFrame) - TBSGap - size : CGRectGetMaxX(capsuleFrame) + TBSGap;
    } else {
        CGFloat contentHeight = CGRectGetHeight(fullFrame) - tabBar.safeAreaInsets.bottom;
        midY = CGRectGetMinY(fullFrame) + MAX(size, contentHeight) / 2.0;
        x = TBSRightToLeft(self) ? CGRectGetMinX(fullFrame) + 21.0 : CGRectGetMaxX(fullFrame) - 21.0 - size;
    }

    if (button == nil) {
        button = TBSMakeButton();
        objc_setAssociatedObject(self, TBSButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (button.superview != self) [self addSubview:button];
    [self bringSubviewToFront:button];
    button.hidden = NO;
    TBSUnclip(self);
    button.overrideUserInterfaceStyle = tabBar.traitCollection.userInterfaceStyle; // dark on Shorts, like the bar
    CGRect frame = CGRectMake(x, midY - size / 2.0, size, size);
    if (!CGRectEqualToRect(button.frame, frame)) button.frame = frame;
    // Glyph sized like the system search button beside iOS 26 tab bars (about 29% of the circle).
    CGFloat pointSize = round(size * 0.29 * 2.0) / 2.0;
    UIButtonConfiguration *config = button.configuration;
    UIImageSymbolConfiguration *symbol = (UIImageSymbolConfiguration *)config.image.symbolConfiguration;
    if (config != nil && ![symbol isEqual:TBSGlyphConfiguration(pointSize)]) {
        config.image = TBSGlyph(pointSize);
        button.configuration = config;
    }
}

static IMP OriginalBarHitTest;

// Make sure taps on the circle reach it, whatever YouTube or YTPlus do with touches on the bar.
static UIView *TBSBarHitTest(UIView *self, SEL _cmd, CGPoint point, UIEvent *event) {
    UIButton *button = objc_getAssociatedObject(self, TBSButtonKey);
    if (button != nil && !button.hidden && button.superview == self && self.userInteractionEnabled &&
        CGRectContainsPoint(CGRectInset(button.frame, -4.0, -4.0), point)) {
        return button;
    }
    return ((UIView * (*)(id, SEL, CGPoint, UIEvent *))OriginalBarHitTest)(self, _cmd, point, event);
}

static IMP OriginalBarPointInside;

static BOOL TBSBarPointInside(UIView *self, SEL _cmd, CGPoint point, UIEvent *event) {
    UIButton *button = objc_getAssociatedObject(self, TBSButtonKey);
    if (button != nil && !button.hidden && CGRectContainsPoint(CGRectInset(button.frame, -4.0, -4.0), point)) return YES;
    return ((BOOL (*)(id, SEL, CGPoint, UIEvent *))OriginalBarPointInside)(self, _cmd, point, event);
}

#pragma mark - Search inside the tab bar

static const void *TBSItemKey = &TBSItemKey;   // UITabBar -> our Search item
static const void *TBSLastKey = &TBSLastKey;   // UITabBar -> the last tab selected (to go back to)
static NSInteger const TBSItemTag = 'srch';
static NSMutableSet<Class> *TBSWrappedDelegates;

static BOOL TBSInPivotBar(UIView *view) {
    static Class pivotClass;
    if (pivotClass == Nil) pivotClass = NSClassFromString(@"YTPivotBarView");
    for (UIView *v = view.superview; v != nil; v = v.superview) if (pivotClass && [v isKindOfClass:pivotClass]) return YES;
    return NO;
}

static BOOL TBSIsSearchItem(UITabBarItem *item) {
    return item != nil && item.tag == TBSItemTag && [item.accessibilityIdentifier isEqualToString:@"tbh.search.item"];
}

// YouTube's own word for Search (the top bar button's label), so it follows the app's language.
static NSString *TBSSearchTitle(UIView *view) {
    NSMutableArray<UIView *> *found = [NSMutableArray array];
    if (view.window) TBSFindSearchButtons(view.window, found);
    for (UIView *button in found) if (button.accessibilityLabel.length) return button.accessibilityLabel;
    return @"Search";
}

static UITabBarItem *TBSSearchItem(UITabBar *tabBar) {
    UITabBarItem *item = objc_getAssociatedObject(tabBar, TBSItemKey);
    if (item == nil) {
        item = [[UITabBarItem alloc] initWithTitle:TBSSearchTitle(tabBar) image:[UIImage systemImageNamed:@"magnifyingglass"] tag:TBSItemTag];
        item.accessibilityIdentifier = @"tbh.search.item";
        objc_setAssociatedObject(tabBar, TBSItemKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return item;
}

static IMP OriginalSetItems;

static void TBSSetItems(UITabBar *self, SEL _cmd, NSArray<UITabBarItem *> *items, BOOL animated) {
    if (objc_getAssociatedObject(self, TBSItemKey) != nil || TBSInPivotBar(self)) {
        NSMutableArray *withSearch = [NSMutableArray array];
        for (UITabBarItem *item in items) if (!TBSIsSearchItem(item)) [withSearch addObject:item];
        if (withSearch.count > 0) [withSearch addObject:TBSSearchItem(self)];
        items = withSearch;
    }
    ((void (*)(id, SEL, NSArray *, BOOL))OriginalSetItems)(self, _cmd, items, animated);
}

static IMP OriginalSetSelectedItem;

static void TBSSetSelectedItem(UITabBar *self, SEL _cmd, UITabBarItem *item) {
    if (!TBSIsSearchItem(item) && item) objc_setAssociatedObject(self, TBSLastKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, UITabBarItem *))OriginalSetSelectedItem)(self, _cmd, item);
}

// The tab bar's delegate (YTPlus) maps taps to YouTube's tabs; a tap on Search never reaches it.
static NSMutableDictionary<NSString *, NSValue *> *TBSOriginals(void) {
    static NSMutableDictionary<NSString *, NSValue *> *originals;
    if (originals == nil) originals = [NSMutableDictionary dictionary];
    return originals;
}

static void TBSDidSelect(id self, SEL _cmd, UITabBar *tabBar, UITabBarItem *item) {
    if (TBSIsSearchItem(item)) {
        UITabBarItem *last = objc_getAssociatedObject(tabBar, TBSLastKey);
        if (last && [tabBar.items containsObject:last]) ((void (*)(id, SEL, id))OriginalSetSelectedItem)(tabBar, @selector(setSelectedItem:), last);
        YTGOpenSearch(tabBar);
        return;
    }
    IMP original = NULL;
    for (Class c = object_getClass(self); c != Nil && original == NULL; c = class_getSuperclass(c)) {
        original = (IMP)TBSOriginals()[NSStringFromClass(c)].pointerValue;
    }
    if (original) ((void (*)(id, SEL, UITabBar *, UITabBarItem *))original)(self, _cmd, tabBar, item);
}

static void TBSWrapDelegate(id delegate) {
    if (delegate == nil) return;
    SEL sel = @selector(tabBar:didSelectItem:);
    Class cls = object_getClass(delegate);
    if (TBSWrappedDelegates == nil) TBSWrappedDelegates = [NSMutableSet set];
    for (Class c = cls; c != Nil; c = class_getSuperclass(c)) if ([TBSWrappedDelegates containsObject:c]) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (method == NULL) {
        class_addMethod(cls, sel, (IMP)TBSDidSelect, "v32@0:8@16@24");
    } else {
        // Hook on the class that implements it, so subclasses and the class itself share one original.
        Class owner = cls;
        while (class_getSuperclass(owner) && class_getInstanceMethod(class_getSuperclass(owner), sel) == method) owner = class_getSuperclass(owner);
        IMP original = NULL;
        if (TBHHookMethod(owner, NSStringFromSelector(sel), (IMP)TBSDidSelect, &original) && original != (IMP)TBSDidSelect) {
            TBSOriginals()[NSStringFromClass(owner)] = [NSValue valueWithPointer:(const void *)original];
        }
        cls = owner;
    }
    [TBSWrappedDelegates addObject:cls];
}

static IMP OriginalSetDelegate;

static void TBSSetDelegate(UITabBar *self, SEL _cmd, id delegate) {
    ((void (*)(id, SEL, id))OriginalSetDelegate)(self, _cmd, delegate);
    if (objc_getAssociatedObject(self, TBSItemKey) != nil || TBSInPivotBar(self)) TBSWrapDelegate(delegate);
}

static IMP OriginalInlineBarLayout;

// Adds the item to a tab bar that got its items before it was put in YouTube's bar.
static void TBSInlineBarLayout(UIView *self, SEL _cmd) {
    if (OriginalInlineBarLayout) ((void (*)(id, SEL))OriginalInlineBarLayout)(self, _cmd);
    UITabBar *tabBar = TBSTabBar(self, 2);
    if (tabBar == nil || tabBar.hidden || tabBar.items.count == 0) return;
    TBSUnclip(self);
    TBSWrapDelegate(tabBar.delegate);
    if (![tabBar.items containsObject:TBSSearchItem(tabBar)]) {
        UITabBarItem *selected = tabBar.selectedItem;
        tabBar.items = tabBar.items; // goes through TBSSetItems
        if (selected && [tabBar.items containsObject:selected]) tabBar.selectedItem = selected;
    }
}

static IMP OriginalPlainBarLayout;

// Search off: only the clipping.
static void TBSPlainBarLayout(UIView *self, SEL _cmd) {
    if (OriginalPlainBarLayout) ((void (*)(id, SEL))OriginalPlainBarLayout)(self, _cmd);
    UITabBar *tabBar = TBSTabBar(self, 2);
    if (tabBar != nil && !tabBar.hidden) TBSUnclip(self);
}

#pragma mark - Search results behind the floating bar

// YTPlus's translucent tab bar uses YouTube's frosted tab bar mode, where pages run underneath the bar.
// Search results opt out of it (-[YTSearchResultsViewController optOutOfFrostedPivotBar]), so YouTube stopped
// that page at the bar's top edge and the app's white background showed as a strip behind the glass.
static BOOL TBSSearchOptOut(__unused id self, __unused SEL _cmd) {
    return NO;
}

__attribute__((constructor)) static void TBSInit(void) {
    @autoreleasepool {
        Class results = NSClassFromString(@"YTSearchResultsViewController");
        Method optOut = results ? class_getInstanceMethod(results, NSSelectorFromString(@"optOutOfFrostedPivotBar")) : NULL;
        char type[8] = { 0 };
        if (optOut) method_getReturnType(optOut, type, sizeof(type));
        if (type[0] == 'B' || type[0] == 'c') TBHHookMethod(results, @"optOutOfFrostedPivotBar", (IMP)TBSSearchOptOut, NULL);
        NSInteger mode = YTGSearchMode();
        Class bar = NSClassFromString(@"YTPivotBarView");
        if (bar == Nil) return;
        if (mode == YTGSearchOff) {
            TBHHookMethod(bar, @"layoutSubviews", (IMP)TBSPlainBarLayout, &OriginalPlainBarLayout);
            return;
        }
        if (mode == YTGSearchInTabBar) {
            TBHHookMethod(UITabBar.class, @"setItems:animated:", (IMP)TBSSetItems, &OriginalSetItems);
            TBHHookMethod(UITabBar.class, @"setSelectedItem:", (IMP)TBSSetSelectedItem, &OriginalSetSelectedItem);
            TBHHookMethod(UITabBar.class, @"setDelegate:", (IMP)TBSSetDelegate, &OriginalSetDelegate);
            TBHHookMethod(bar, @"layoutSubviews", (IMP)TBSInlineBarLayout, &OriginalInlineBarLayout);
            return;
        }
        TBHHookMethod(UITabBar.class, @"setFrame:", (IMP)TBSTabBarSetFrame, &OriginalTabBarSetFrame);
        TBHHookMethod(bar, @"layoutSubviews", (IMP)TBSBarLayout, &OriginalBarLayout);
        TBHHookMethod(bar, @"hitTest:withEvent:", (IMP)TBSBarHitTest, &OriginalBarHitTest);
        TBHHookMethod(bar, @"pointInside:withEvent:", (IMP)TBSBarPointInside, &OriginalBarPointInside);
    }
}
