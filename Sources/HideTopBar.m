// HideTopBar
// Removes YouTube's top navigation bar (YTHeaderView) on every page except search (whose text box lives
// in it) and the You tab. Pages scroll behind the status bar under a variable blur, like Apple Music, and
// Home, Subscriptions and History get a large Apple Music-style title.
//
// How: YouTube's header already knows how to collapse itself (it does that when you scroll down on Home):
// -[YTHeaderView scrollHeaderViewWithOffset:] shrinks it between its min height (the status bar) and max
// height, and YouTube lays the page out below it. We keep it collapsed for good with a min height of zero
// and make it invisible, so the page starts at the top of the screen; the page's list is then given a top
// inset that puts its first row below the clock (and the title). The bar still exists, so its search button
// keeps working for SearchButton.m.
//
// Pure Objective-C runtime swizzling: no CydiaSubstrate / ElleKit dependency.

#import "Common.h"

static const void *THBHiddenKey = &THBHiddenKey;   // view -> @YES while we keep it invisible
static const void *THBDecisionKey = &THBDecisionKey; // YTHeaderView -> @YES/@NO: hide it (decided once per page)

static id THBCall(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

// YES when page is (inside) the first screen of nav.
static BOOL THBIsRoot(UIViewController *page, UINavigationController *nav) {
    UIViewController *root = nav.viewControllers.firstObject;
    for (UIViewController *v = page; v != nil; v = v.parentViewController) if (v == root) return YES;
    return NO;
}

// The selected tab's identifier when this page is that tab's first screen, else nil.
static NSString *THBTabOfRootPage(UIViewController *page) {
    NSString *tab = TBHSelectedTabIdentifier();
    if (tab == nil) return nil;
    UINavigationController *nav = page.navigationController;
    return nav == nil || THBIsRoot(page, nav) ? tab : nil;
}

static UINavigationController *THBNavigation(UIViewController *page, BOOL *barOwnedByNavigation) {
    *barOwnedByNavigation = NO;
    if (page.navigationController) return page.navigationController;
    for (UIViewController *v = page.parentViewController; v != nil; v = v.parentViewController) {
        if ([v isKindOfClass:UINavigationController.class]) { *barOwnedByNavigation = YES; return (UINavigationController *)v; }
    }
    return nil;
}

static UIViewController *THBPage(UIView *view) {
    for (UIResponder *r = view.nextResponder; r != nil; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) return (UIViewController *)r;
    }
    return nil;
}

// Only a tab's first screen (Home, Subscriptions, History, ...), never search's own screen or the You tab's
// first screen. Pages opened on top (a channel, a playlist, ...) keep YouTube's bar, so they keep their back
// button and their own header. The tab check is decided when the page first appears (the You page is created
// when its tab is opened); whether something is open on top is checked every time, since a tab's pages can
// share one bar. Search results reuse the page's bar, which is shown while it holds the search box
// (THBShowsSearchBox).
static BOOL THBAllowed(UIView *header) {
    if (header.window == nil) return NO;
    UIViewController *page = THBPage(header);
    BOOL shared = NO;
    UINavigationController *nav = page ? THBNavigation(page, &shared) : nil;
    if (shared && nav.viewControllers.count > 1) return NO; // a page is open on top of the tab's first screen
    NSNumber *decided = objc_getAssociatedObject(header, THBDecisionKey);
    if (decided) return decided.boolValue;
    static Class searchClass;
    if (searchClass == Nil) searchClass = NSClassFromString(@"YTSearchViewController");
    BOOL allowed = page != nil;
    for (UIViewController *v = page; v != nil && allowed; v = v.parentViewController) {
        if (searchClass && [v isKindOfClass:searchClass]) allowed = NO;
    }
    if (allowed && nav && !shared) allowed = THBIsRoot(page, nav); // the page's own bar: only on the tab's first screen
    NSString *tab = allowed ? TBHSelectedTabIdentifier() : nil;
    if ([tab isEqualToString:@"FElibrary"] || [tab isEqualToString:@"FEyou"]) allowed = NO;
    objc_setAssociatedObject(header, THBDecisionKey, @(allowed), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return allowed;
}

static BOOL THBFlagged(UIView *view) {
    return [objc_getAssociatedObject(view, THBHiddenKey) boolValue];
}

static void THBSetFlag(UIView *view, BOOL on) {
    if (view == nil) return;
    objc_setAssociatedObject(view, THBHiddenKey, on ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat alpha = on ? 0.0 : 1.0; // invisible, not hidden: hiding changes YouTube's layout
    if (view.alpha != alpha) view.alpha = alpha;
    view.userInteractionEnabled = !on;
}

static UIView *THBCombo(UIView *view) {
    static Class comboClass;
    if (comboClass == Nil) comboClass = NSClassFromString(@"YTHeaderContentComboView");
    for (UIView *v = view.superview; v != nil; v = v.superview) {
        if (comboClass && [v isKindOfClass:comboClass]) return v;
    }
    return nil;
}

static UIView *THBFindHeader(UIView *view, NSInteger depth) {
    static Class headerClass;
    if (headerClass == Nil) headerClass = NSClassFromString(@"YTHeaderView");
    if ([view isKindOfClass:headerClass]) return view;
    if (depth <= 0) return nil;
    for (UIView *subview in view.subviews) {
        UIView *found = THBFindHeader(subview, depth - 1);
        if (found) return found;
    }
    return nil;
}

// The page's top bar, if we've hidden it.
static UIView *THBHiddenHeader(UIView *combo) {
    UIView *header = THBCall(combo, @"headerView");
    header = [header isKindOfClass:UIView.class] ? THBFindHeader(header, 3) : nil;
    return header != nil && THBFlagged(header) ? header : nil;
}

#pragma mark - Keeping the bar collapsed

static IMP OriginalScrollHeader, OriginalResetParams, OriginalSetParams, OriginalCanScrollDown, OriginalHeaderLayout;
static IMP OriginalComboLayout;

static int THBCollapsing; // the collapse itself calls the methods that trigger a collapse

static void THBCollapse(UIView *header) {
    if (THBCollapsing) return;
    THBCollapsing++;
    // A large offset scrolls the bar fully away; YouTube clamps the height to its minimum (the status bar).
    ((void (*)(id, SEL, CGFloat))OriginalScrollHeader)(header, NSSelectorFromString(@"scrollHeaderViewWithOffset:"), 10000.0);
    THBCollapsing--;
}

static void THBScrollHeader(UIView *self, SEL _cmd, CGFloat offset) {
    if (THBFlagged(self)) offset = 10000.0; // never let it come back
    ((void (*)(id, SEL, CGFloat))OriginalScrollHeader)(self, _cmd, offset);
}

static void THBSetDoubleIvar(id object, const char *name, double value) {
    Ivar ivar = object ? class_getInstanceVariable(object_getClass(object), name) : NULL;
    if (ivar) *(double *)((uint8_t *)(__bridge void *)object + ivar_getOffset(ivar)) = value;
}

static void THBResetParams(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))OriginalResetParams)(self, _cmd);
    // Collapsed, the bar normally keeps the status bar's height, and YouTube starts the feed below it.
    // With no minimum it collapses to nothing and the feed starts at the top of the screen.
    if (!THBFlagged(self)) return;
    THBSetDoubleIvar(self, "_statusBarHeight", 0.0);
    THBCollapse(self);
}

static void THBSetParams(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))OriginalSetParams)(self, _cmd);
    if (THBFlagged(self)) THBCollapse(self);
}

static BOOL THBCanScrollDown(UIView *self, SEL _cmd) {
    if (THBFlagged(self)) return NO;
    return ((BOOL (*)(id, SEL))OriginalCanScrollDown)(self, _cmd);
}

// The bar is showing YouTube's search box (search typing and results reuse the page's own top bar).
static BOOL THBShowsSearchBox(UIView *view, int depth) {
    if (view.hidden || (view.alpha < 0.01 && !THBFlagged(view))) return NO;
    if ([view isKindOfClass:UITextField.class] || [view isKindOfClass:UISearchBar.class]) return YES;
    if (depth <= 0) return NO;
    for (UIView *subview in view.subviews) if (THBShowsSearchBox(subview, depth - 1)) return YES;
    return NO;
}

static void THBHeaderLayout(UIView *self, SEL _cmd) {
    if (OriginalHeaderLayout) ((void (*)(id, SEL))OriginalHeaderLayout)(self, _cmd);
    BOOL hide = THBAllowed(self) && !THBShowsSearchBox(self, 10);
    if (hide == THBFlagged(self)) return;
    UIView *combo = THBCombo(self);
    // The bar plus any wrappers YouTube puts around it (never anything holding the feed or chips).
    UIView *content = THBCall(combo, @"childView"), *subheader = THBCall(combo, @"subheaderView");
    for (UIView *v = self.superview; v != nil && v != combo; v = v.superview) {
        BOOL holdsPage = ([content isKindOfClass:UIView.class] && [content isDescendantOfView:v]) ||
                         ([subheader isKindOfClass:UIView.class] && [subheader isDescendantOfView:v]);
        if (holdsPage) break;
        THBSetFlag(v, hide);
    }
    THBSetFlag(self, hide);
    if (hide) {
        THBCollapse(self);
    } else {
        // Back to YouTube's own bar (for the search box): its status bar height and full height again.
        THBCollapsing++;
        if (OriginalResetParams) ((void (*)(id, SEL))OriginalResetParams)(self, NSSelectorFromString(@"resetHeaderParamsForStatusBarUpdate"));
        if (OriginalSetParams) ((void (*)(id, SEL))OriginalSetParams)(self, NSSelectorFromString(@"setHeaderParams"));
        ((void (*)(id, SEL, CGFloat))OriginalScrollHeader)(self, NSSelectorFromString(@"scrollHeaderViewWithOffset:"), 0.0);
        THBCollapsing--;
    }
    [combo setNeedsLayout];
}

#pragma mark - Status bar blur
//
// Ported from BlurUIKit's VariableBlurView (https://github.com/TimOliver/BlurUIKit, MIT, (c) Tim Oliver),
// with its defaults: a "variableBlur" filter (the class the effect view's own blur uses) of radius 3.5
// with edge normalising, masked by a linear gradient (full at the top, none at the bottom), the backdrop
// at 0.75 scale and the material overlay hidden; plus a smooth (ease-in-out sine) wash of the page colour
// whose clear end extends 25% below the view (BlurUIKit uses 50% light / 25% dark; this is a lighter tint).
static CGFloat const THBTintLight = 0.2, THBTintDark = 0.1;

static CGImageRef THBGradientImage(NSInteger length, BOOL smooth) {
    if (length <= 0) return NULL;
    static NSMutableDictionary<NSString *, id> *cache; // images by length and curve
    if (cache == nil) cache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%ld-%d", (long)length, smooth];
    id cached = cache[key];
    if (cached) return (__bridge CGImageRef)cached;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(NULL, 1, length, 8, 2, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (context == NULL) return NULL;
    uint8_t *pixels = CGBitmapContextGetData(context);
    CGFloat reciprocal = length > 1 ? 1.0 / (CGFloat)(length - 1) : 0.0;
    for (NSInteger i = 0; i < length; i++) { // row 0 is the top
        CGFloat t = (CGFloat)i * reciprocal;
        CGFloat eased = smooth ? -(cos(M_PI * t) - 1.0) / 2.0 : t;
        CGFloat alpha = 1.0 - eased;
        pixels[i * 2] = 0;
        pixels[i * 2 + 1] = (uint8_t)MIN(MAX(alpha * 255.0, 0.0), 255.0);
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (image) cache[key] = (__bridge_transfer id)image; // the cache owns it
    return image;
}

@interface THBBlurView : UIView
@property (nonatomic, strong) UIVisualEffectView *effectView;
@property (nonatomic, strong) UIImageView *dimmingView;
@property (nonatomic, assign) NSInteger maskLength;
@property (nonatomic, assign) NSInteger dimmingLength;
@end

@implementation THBBlurView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = NO;
        _effectView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleRegular]];
        _effectView.userInteractionEnabled = NO;
        [self addSubview:_effectView];
        _dimmingView = [UIImageView new];
        _dimmingView.userInteractionEnabled = NO;
        _dimmingView.contentMode = UIViewContentModeScaleToFill;
        [self addSubview:_dimmingView];
    }
    return self;
}

- (UIView *)backdropView {
    for (UIView *subview in self.effectView.subviews) {
        if ([NSStringFromClass(subview.class).lowercaseString containsString:@"backdrop"]) return subview;
    }
    return nil;
}

- (void)updateBlurFilter {
    UIView *backdrop = [self backdropView];
    CGImageRef mask = THBGradientImage(self.maskLength, NO);
    if (backdrop == nil || mask == NULL) return;
    static Class filterClass;
    if (filterClass == Nil) {
        UIVisualEffectView *probe = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleRegular]];
        for (UIView *subview in probe.subviews) {
            if ([NSStringFromClass(subview.class).lowercaseString containsString:@"backdrop"]) {
                filterClass = [subview.layer.filters.firstObject class];
            }
        }
        if (filterClass == Nil) filterClass = [backdrop.layer.filters.firstObject class];
    }
    SEL make = NSSelectorFromString(@"filterWithType:");
    if (filterClass == Nil || ![filterClass respondsToSelector:make]) return;
    id filter = ((id (*)(id, SEL, NSString *))objc_msgSend)(filterClass, make, @"variableBlur");
    if (filter == nil) return;
    @try {
        [filter setValue:(__bridge id)mask forKey:@"inputMaskImage"];
        [filter setValue:@3.5 forKey:@"inputRadius"];
        [filter setValue:@YES forKey:@"inputNormalizeEdges"];
        backdrop.layer.filters = @[ filter ];
        [backdrop.layer setValue:@0.75 forKey:@"scale"];
    } @catch (__unused NSException *e) {
        return;
    }
    for (UIView *subview in self.effectView.subviews) {
        if ([NSStringFromClass(subview.class).lowercaseString containsString:@"subview"]) subview.hidden = YES;
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) {
        self.maskLength = 0;
        [self setNeedsLayout];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    if (CGRectGetWidth(bounds) <= 0.0 || CGRectGetHeight(bounds) <= 0.0) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.effectView.frame = bounds;
    NSInteger maskLength = (NSInteger)ceil(CGRectGetHeight(bounds));
    if (maskLength != self.maskLength || [self backdropView].layer.filters.count != 1) {
        self.maskLength = maskLength;
        [self updateBlurFilter];
    }
    CGFloat dimmingHeight = ceil(CGRectGetHeight(bounds) * 1.25);
    self.dimmingView.frame = CGRectMake(0.0, 0.0, CGRectGetWidth(bounds), dimmingHeight);
    if ((NSInteger)dimmingHeight != self.dimmingLength || self.dimmingView.image == nil) {
        self.dimmingLength = (NSInteger)dimmingHeight;
        CGImageRef image = THBGradientImage(self.dimmingLength, YES);
        self.dimmingView.image = image ? [[UIImage imageWithCGImage:image] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] : nil;
    }
    self.dimmingView.tintColor = UIColor.systemBackgroundColor;
    self.dimmingView.alpha = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? THBTintDark : THBTintLight;
    [CATransaction commit];
}

// Light/dark switches: re-tint, and put the blur filter back if the effect view reset it.
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self setNeedsLayout];
}

@end

static const void *THBBlurKey = &THBBlurKey; // YTHeaderContentComboView -> blur view

static void THBPlaceBlur(UIView *combo) {
    THBBlurView *blur = objc_getAssociatedObject(combo, THBBlurKey);
    if (blur == nil) {
        blur = [[THBBlurView alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(combo, THBBlurKey, blur, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (blur.superview != combo || combo.subviews.lastObject != blur) [combo addSubview:blur];
    CGFloat status = MAX(20.0, combo.window ? combo.window.safeAreaInsets.top : 0.0);
    CGFloat top = [combo convertPoint:CGPointZero fromView:nil].y; // the screen's top edge, in the page
    // As in BlurUIKit's example: the top safe area (the status bar), from the top of the screen.
    CGRect frame = CGRectMake(0.0, top, CGRectGetWidth(combo.bounds), status);
    if (!CGRectEqualToRect(blur.frame, frame)) blur.frame = frame;
    blur.hidden = NO;
}

#pragma mark - Pages' own headers (Subscriptions avatars and chips, History title and search box)
//
// These live in a YTVariableHeightHeaderView above the list. They're detached and given no height, so
// the list starts at the top and scrolls behind the status bar like Home.

static BOOL THBPageBarRemoved(UIView *pageHeader) {
    return THBHiddenHeader(THBCombo(pageHeader)) != nil;
}

static IMP OriginalSetHeaderSizes, OriginalPageHeaderLayout;

static void THBSetHeaderSizes(UIView *self, SEL _cmd, CGFloat header, CGFloat subheader, CGFloat topOffset, BOOL animated) {
    if (THBPageBarRemoved(self)) header = subheader = 0.0;
    ((void (*)(id, SEL, CGFloat, CGFloat, CGFloat, BOOL))OriginalSetHeaderSizes)(self, _cmd, header, subheader, topOffset, animated);
}

// Size getters: zero while the bar is removed. Some return a CGFloat, some a CGSize.
static IMP OriginalSizeGetters[4];
static NSString *const THBSizeGetterNames[4] = { @"targetHeaderSize", @"targetSubheaderSize", @"maximumHeaderSize", @"maximumSubheaderSize" };

#define THB_SIZE_HOOKS(i) \
    static CGSize THBSizeGetter##i(UIView *self, SEL _cmd) { \
        if (THBPageBarRemoved(self)) return CGSizeZero; \
        return ((CGSize (*)(id, SEL))OriginalSizeGetters[i])(self, _cmd); \
    } \
    static CGFloat THBFloatGetter##i(UIView *self, SEL _cmd) { \
        if (THBPageBarRemoved(self)) return 0.0; \
        return ((CGFloat (*)(id, SEL))OriginalSizeGetters[i])(self, _cmd); \
    }
THB_SIZE_HOOKS(0)
THB_SIZE_HOOKS(1)
THB_SIZE_HOOKS(2)
THB_SIZE_HOOKS(3)

static void THBHookSizeGetters(Class cls) {
    IMP sizeImps[4] = { (IMP)THBSizeGetter0, (IMP)THBSizeGetter1, (IMP)THBSizeGetter2, (IMP)THBSizeGetter3 };
    IMP floatImps[4] = { (IMP)THBFloatGetter0, (IMP)THBFloatGetter1, (IMP)THBFloatGetter2, (IMP)THBFloatGetter3 };
    for (int i = 0; i < 4; i++) {
        Method method = class_getInstanceMethod(cls, NSSelectorFromString(THBSizeGetterNames[i]));
        if (method == NULL) continue;
        char type[64] = { 0 };
        method_getReturnType(method, type, sizeof(type));
        if (strncmp(type, "{CGSize", 7) == 0) TBHHookMethod(cls, THBSizeGetterNames[i], sizeImps[i], &OriginalSizeGetters[i]);
        else if (strcmp(type, "d") == 0) TBHHookMethod(cls, THBSizeGetterNames[i], floatImps[i], &OriginalSizeGetters[i]);
    }
}

// Setters for the page header's parts: while the bar is removed they're given nil, so the page lays
// out as if it had no header at all (like Home): no gap, nothing under the clock.
static IMP OriginalSetPart[3];
static NSString *const THBPartSetters[3] = { @"setHeaderView:", @"setSubheaderView:", @"setPinnedHeaderView:" };
static NSString *const THBPartIvars[3] = { @"_headerView", @"_subheaderView", @"_pinnedHeaderView" };

#define THB_PART_HOOK(i) \
    static void THBSetPart##i(UIView *self, SEL _cmd, UIView *part) { \
        if (part != nil && THBPageBarRemoved(self)) part = nil; \
        ((void (*)(id, SEL, UIView *))OriginalSetPart[i])(self, _cmd, part); \
    }
THB_PART_HOOK(0)
THB_PART_HOOK(1)
THB_PART_HOOK(2)

static void THBFixContentsFrame(UIView *pageHeader) {
    Ivar ivar = class_getInstanceVariable(object_getClass(pageHeader), "_contentsView");
    UIView *contents = ivar ? object_getIvar(pageHeader, ivar) : nil;
    if (![contents isKindOfClass:UIView.class] || contents.superview != pageHeader) return;
    if (CGRectGetMinY(contents.frame) > 0.5) {
        CGRect frame = contents.frame;
        frame.size.height = CGRectGetHeight(pageHeader.bounds);
        frame.origin.y = 0.0;
        contents.frame = frame;
    }
}

#pragma mark - The page's list and its title
//
// The first row sits right below the clock, or below the large title on Home, Subscriptions and History
// (Apple Music style: a large bold title that scrolls with the list, under the status bar blur). Checked
// on every layout, in screen coordinates, and only changed when it's off.

static CGFloat const THBTitleArea = 52.0;
static CGFloat const THBHomeLeadingSpace = 8.0;  // Home's usual space above its first video, until it's measured
static const void *THBLeadingKey = &THBLeadingKey;       // Home list -> NSNumber: space above its first video
static const void *THBTitleKey = &THBTitleKey;           // combo -> UILabel
static const void *THBTitleTextKey = &THBTitleTextKey;   // combo -> NSString (@"" for none), decided once
static const void *THBTitleTabKey = &THBTitleTabKey;     // combo -> NSString: the tab whose title it shows
static const void *THBListTargetKey = &THBListTargetKey; // list -> NSNumber: the top inset we keep

// UIScrollView hook, only for lists with a kept inset (Subscriptions, History): no automatic safe-area inset.
static IMP OriginalSetAdjustment;

static void THBSetAdjustment(UIScrollView *self, SEL _cmd, UIScrollViewContentInsetAdjustmentBehavior behavior) {
    if (objc_getAssociatedObject(self, THBListTargetKey)) behavior = UIScrollViewContentInsetAdjustmentNever;
    ((void (*)(id, SEL, UIScrollViewContentInsetAdjustmentBehavior))OriginalSetAdjustment)(self, _cmd, behavior);
}

// The gap's source: YouTube's YTVariableHeightHeaderController sets the list's top inset to the page
// header's maximum height plus its "effective base top inset" (-[... setupCollectionViewIfNeeded]). The
// header is gone but still reports its height, so the base is lowered by that much: YouTube's own sum then
// comes out as our inset, and nothing has to be corrected afterwards.
static IMP OriginalEffectiveBase;

static id THBIvarMatching(id object, BOOL (^match)(id value)) {
    for (Class c = object_getClass(object); c != Nil && c != NSObject.class; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Ivar *ivars = class_copyIvarList(c, &n);
        id found = nil;
        for (unsigned int i = 0; i < n && found == nil; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (type == NULL || type[0] != '@') continue;
            id value = object_getIvar(object, ivars[i]);
            if (value && match(value)) found = value;
        }
        free(ivars);
        if (found) return found;
    }
    return nil;
}

static CGFloat THBEffectiveBase(id self, SEL _cmd) {
    CGFloat base = ((CGFloat (*)(id, SEL))OriginalEffectiveBase)(self, _cmd);
    UIScrollView *list = THBIvarMatching(self, ^BOOL(id value) {
        return [value isKindOfClass:UIScrollView.class] && objc_getAssociatedObject(value, THBListTargetKey) != nil;
    });
    if (list == nil) return base;
    SEL maxSel = NSSelectorFromString(@"headerMaximumHeight");
    id header = THBIvarMatching(self, ^BOOL(id value) { return [value respondsToSelector:maxSel]; });
    CGFloat headerMax = header ? ((CGFloat (*)(id, SEL))objc_msgSend)(header, maxSel) : 0.0;
    CGFloat target = [objc_getAssociatedObject(list, THBListTargetKey) doubleValue];
    return target - headerMax;
}

static void THBHookEffectiveBase(void) {
    Class cls = NSClassFromString(@"YTVariableHeightHeaderController");
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(@"effectiveBaseTopContentInset")) : NULL;
    char type[8] = { 0 };
    if (method) method_getReturnType(method, type, sizeof(type));
    if (strcmp(type, "d") == 0) TBHHookMethod(cls, @"effectiveBaseTopContentInset", (IMP)THBEffectiveBase, &OriginalEffectiveBase);
}

static UIScrollView *THBMainList(UIView *root, UIWindow *window) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    for (NSUInteger i = 0; i < queue.count && i < 400; i++) {
        UIView *v = queue[i];
        BOOL scroll = [v isKindOfClass:UIScrollView.class];
        if (scroll && !((UIScrollView *)v).pagingEnabled && !v.hidden && v.alpha > 0.01 &&
            CGRectGetHeight(v.bounds) > CGRectGetHeight(window.bounds) * 0.4) return (UIScrollView *)v;
        if (!scroll || ((UIScrollView *)v).pagingEnabled) [queue addObjectsFromArray:v.subviews];
    }
    return nil;
}

static NSString *THBTitleText(UIView *combo) {
    NSString *text = objc_getAssociatedObject(combo, THBTitleTextKey);
    if (text) return text.length ? text : nil;
    if (combo.window == nil) return nil;
    UIViewController *page = THBPage(combo);
    NSString *tab = page ? THBTabOfRootPage(page) : nil;
    // The tab's own label, so the title follows the app's language; English if YouTube doesn't give one.
    NSDictionary *titles = @{ @"FEwhat_to_watch": @"Home", @"FEsubscriptions": @"Subscriptions", @"FEhistory": @"History" };
    text = tab ? titles[tab] : nil;
    if (text) text = TBHSelectedTabTitle() ?: text;
    if (text) objc_setAssociatedObject(combo, THBTitleTabKey, tab, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(combo, THBTitleTextKey, text ?: @"", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return text;
}

// Home's feed puts a varying amount of space above its first video (it changes between refreshes). Read from
// the cells on screen (no layout is triggered), only while the top of the feed is among them; -1 otherwise.
static CGFloat THBMeasureLeading(UICollectionView *list) {
    CGFloat first = CGFLOAT_MAX, video = CGFLOAT_MAX;
    for (UICollectionViewCell *cell in list.visibleCells) {
        if (cell.hidden) continue;
        first = MIN(first, CGRectGetMinY(cell.frame));
        if (CGRectGetHeight(cell.frame) > 40.0) video = MIN(video, CGRectGetMinY(cell.frame));
    }
    return (first < 1.0 && video <= 60.0) ? video : -1.0;
}

static CGFloat THBHomeLeading(UIScrollView *list) {
    if (![list isKindOfClass:UICollectionView.class]) return THBHomeLeadingSpace;
    CGFloat measured = THBMeasureLeading((UICollectionView *)list);
    NSNumber *known = objc_getAssociatedObject(list, THBLeadingKey);
    if (measured >= 0.0 && (known == nil || fabs(known.doubleValue - measured) > 0.5)) {
        known = @(measured);
        objc_setAssociatedObject(list, THBLeadingKey, known, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (known == nil) {
        objc_setAssociatedObject(list, THBLeadingKey, @(THBHomeLeadingSpace), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return known ? known.doubleValue : THBHomeLeadingSpace;
}

// When the feed's cells change (a refresh), re-arrange the page if the space above the first video changed.
static IMP OriginalListLayout;

static void THBListLayout(UICollectionView *self, SEL _cmd) {
    if (OriginalListLayout) ((void (*)(id, SEL))OriginalListLayout)(self, _cmd);
    NSNumber *known = objc_getAssociatedObject(self, THBLeadingKey);
    if (known == nil) return; // not Home's feed
    if (self.contentOffset.y > -self.adjustedContentInset.top + CGRectGetHeight(self.bounds)) return; // top not on screen
    CGFloat measured = THBMeasureLeading(self);
    if (measured >= 0.0 && fabs(known.doubleValue - measured) > 0.5) [THBCombo(self) setNeedsLayout];
}

static void THBArrangePage(UIView *combo) {
    UIWindow *window = combo.window;
    UIView *child = THBCall(combo, @"childView");
    if (window == nil || ![child isKindOfClass:UIView.class]) return;
    UIScrollView *list = THBMainList(child, window);
    UILabel *label = objc_getAssociatedObject(combo, THBTitleKey);
    if (list == nil) { label.hidden = YES; return; }
    NSString *title = THBTitleText(combo);
    CGFloat status = window.safeAreaInsets.top;
    CGFloat area = title ? THBTitleArea : 0.0;
    if (title && [objc_getAssociatedObject(combo, THBTitleTabKey) isEqualToString:@"FEwhat_to_watch"]) area -= THBHomeLeading(list); // line its first video up with the other tabs

    // Inset: first item at status + title area.
    CGFloat listTop = [list convertPoint:CGPointMake(0.0, list.contentOffset.y) toView:nil].y;
    static Class pageHeaderClass;
    if (pageHeaderClass == Nil) pageHeaderClass = NSClassFromString(@"YTVariableHeightHeaderView");
    BOOL underPageHeader = NO;
    for (UIView *v = list.superview; v != nil && v != combo; v = v.superview) {
        if (pageHeaderClass && [v isKindOfClass:pageHeaderClass]) { underPageHeader = YES; break; }
    }
    CGFloat restTop; // the list's top inset as it's laid out (content y 0 sits this far below the list's top)
    if (underPageHeader) {
        // Subscriptions/History: the inset is ours (no automatic safe-area inset; YouTube's own value is made to
        // match it, see THBEffectiveBase).
        CGFloat target = MAX(0.0, status + area - listTop);
        NSNumber *old = objc_getAssociatedObject(list, THBListTargetKey);
        objc_setAssociatedObject(list, THBListTargetKey, @(target), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (list.contentInsetAdjustmentBehavior != UIScrollViewContentInsetAdjustmentNever) {
            list.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        }
        if (fabs(list.contentInset.top - target) >= 0.5) {
            BOOL atTop = old == nil || list.contentOffset.y <= -old.doubleValue + 1.0 || list.contentOffset.y <= -list.contentInset.top + 1.0;
            UIEdgeInsets inset = list.contentInset;
            inset.top = target;
            list.contentInset = inset;
            if (atTop && !list.isTracking && !list.isDecelerating) list.contentOffset = CGPointMake(list.contentOffset.x, -target);
        }
        restTop = target;
    } else {
        // Home: just add the title's room to what YouTube does.
        CGFloat delta = (status + area - listTop) - list.adjustedContentInset.top;
        BOOL refreshing = delta < -20.0 && list.contentOffset.y < -(list.adjustedContentInset.top + delta) - 1.0; // spinner's room
        if (fabs(delta) >= 0.5 && !refreshing) {
            BOOL atTop = list.contentOffset.y <= -list.adjustedContentInset.top + 1.0;
            UIEdgeInsets inset = list.contentInset;
            inset.top += delta;
            list.contentInset = inset;
            if (atTop && !list.isTracking && !list.isDecelerating) list.contentOffset = CGPointMake(list.contentOffset.x, -list.adjustedContentInset.top);
        }
        restTop = list.adjustedContentInset.top;
    }

    if (title == nil) { label.hidden = YES; return; }
    if (label == nil) {
        label = [UILabel new];
        label.font = [UIFont systemFontOfSize:34.0 weight:UIFontWeightBold];
        label.textColor = UIColor.labelColor;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.7;
        label.userInteractionEnabled = NO;
        label.accessibilityTraits = UIAccessibilityTraitHeader;
        objc_setAssociatedObject(combo, THBTitleKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    label.text = title;
    label.hidden = NO;
    if (label.superview != list) [list addSubview:label];
    // In the list's content, just above the first row, never higher than right below the clock.
    CGFloat minY = status - listTop - restTop; // content y that sits right below the clock at rest
    CGFloat y = MAX(-THBTitleArea, minY);
    CGRect frame = CGRectMake(20.0, y + 2.0, CGRectGetWidth(list.bounds) - 40.0, 41.0);
    if (!CGRectEqualToRect(label.frame, frame)) label.frame = frame;
    if (list.subviews.lastObject != label) [list bringSubviewToFront:label];
}

#pragma mark - Layout hooks

static void THBPageHeaderLayout(UIView *self, SEL _cmd) {
    if (THBPageBarRemoved(self)) {
        // Parts set before the page was on screen: detach them now.
        for (int i = 0; i < 3; i++) {
            Ivar ivar = class_getInstanceVariable(object_getClass(self), THBPartIvars[i].UTF8String);
            UIView *part = ivar ? object_getIvar(self, ivar) : nil;
            SEL setter = NSSelectorFromString(THBPartSetters[i]);
            if ([part isKindOfClass:UIView.class] && [self respondsToSelector:setter]) {
                ((void (*)(id, SEL, UIView *))objc_msgSend)(self, setter, nil);
                [part removeFromSuperview];
            }
        }
    }
    if (OriginalPageHeaderLayout) ((void (*)(id, SEL))OriginalPageHeaderLayout)(self, _cmd);
    if (THBPageBarRemoved(self)) {
        THBFixContentsFrame(self);
        UIView *combo = THBCombo(self);
        if (combo) THBArrangePage(combo);
    }
}

// The page: hide YouTube's frosted background behind the bar, place the blur, and arrange the list.
static void THBComboLayout(UIView *self, SEL _cmd) {
    if (OriginalComboLayout) ((void (*)(id, SEL))OriginalComboLayout)(self, _cmd);
    Ivar blurIvar = class_getInstanceVariable(object_getClass(self), "_blurContainerView");
    UIView *frosting = blurIvar ? object_getIvar(self, blurIvar) : nil;
    if (THBHiddenHeader(self) == nil) {
        ((UIView *)objc_getAssociatedObject(self, THBBlurKey)).hidden = YES;
        ((UIView *)objc_getAssociatedObject(self, THBTitleKey)).hidden = YES;
        if ([frosting isKindOfClass:UIView.class] && THBFlagged(frosting)) THBSetFlag(frosting, NO); // YouTube's bar is back
        return;
    }
    if ([frosting isKindOfClass:UIView.class] && !THBFlagged(frosting)) THBSetFlag(frosting, YES);
    THBPlaceBlur(self);
    THBArrangePage(self);
}

// After a refresh YouTube scrolls the list to content y 0, which ignores the room we added above it.
static IMP OriginalResetOffset;

static void THBResetOffset(UIView *self, SEL _cmd) {
    if (OriginalResetOffset) ((void (*)(id, SEL))OriginalResetOffset)(self, _cmd);
    UIView *child = THBCall(self, @"childView");
    if (THBHiddenHeader(self) == nil || self.window == nil || ![child isKindOfClass:UIView.class]) return;
    UIScrollView *list = THBMainList(child, self.window);
    CGFloat top = -list.adjustedContentInset.top;
    if (list && !list.isTracking && list.contentOffset.y > top && list.contentOffset.y <= 0.5) {
        list.contentOffset = CGPointMake(list.contentOffset.x, top);
    }
}

BOOL TBHTopBarHiddenByUs(UIView *view) {
    return THBFlagged(view);
}

__attribute__((constructor)) static void THBInit(void) {
    if (!YTGFeatureEnabled(YTGTopBarKey)) return;
    @autoreleasepool {
        Class header = NSClassFromString(@"YTHeaderView");
        Class combo = NSClassFromString(@"YTHeaderContentComboView");
        if (header == Nil || combo == Nil) return;
        if (!TBHHookMethod(header, @"scrollHeaderViewWithOffset:", (IMP)THBScrollHeader, &OriginalScrollHeader)) return;
        TBHHookMethod(header, @"resetHeaderParamsForStatusBarUpdate", (IMP)THBResetParams, &OriginalResetParams);
        TBHHookMethod(header, @"setHeaderParams", (IMP)THBSetParams, &OriginalSetParams);
        TBHHookMethod(header, @"canScrollNavHeaderDown", (IMP)THBCanScrollDown, &OriginalCanScrollDown);
        TBHHookMethod(header, @"layoutSubviews", (IMP)THBHeaderLayout, &OriginalHeaderLayout);
        TBHHookMethod(combo, @"layoutSubviews", (IMP)THBComboLayout, &OriginalComboLayout);
        Class feed = NSClassFromString(@"YTAsyncCollectionView");
        if (feed) TBHHookMethod(feed, @"layoutSubviews", (IMP)THBListLayout, &OriginalListLayout);
        TBHHookMethod(combo, @"resetScrollViewInsetOffset", (IMP)THBResetOffset, &OriginalResetOffset);
        TBHHookMethod(UIScrollView.class, @"setContentInsetAdjustmentBehavior:", (IMP)THBSetAdjustment, &OriginalSetAdjustment);
        THBHookEffectiveBase();
        Class pageHeader = NSClassFromString(@"YTVariableHeightHeaderView");
        if (pageHeader) {
            TBHHookMethod(pageHeader, @"setHeaderHeight:subheaderHeight:topOffset:animated:", (IMP)THBSetHeaderSizes, &OriginalSetHeaderSizes);
            TBHHookMethod(pageHeader, @"layoutSubviews", (IMP)THBPageHeaderLayout, &OriginalPageHeaderLayout);
            IMP partImps[3] = { (IMP)THBSetPart0, (IMP)THBSetPart1, (IMP)THBSetPart2 };
            for (int i = 0; i < 3; i++) TBHHookMethod(pageHeader, THBPartSetters[i], partImps[i], &OriginalSetPart[i]);
            THBHookSizeGetters(pageHeader);
        }
    }
}
