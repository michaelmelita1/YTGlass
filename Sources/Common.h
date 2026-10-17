// Shared by the YTGlass sources.
// Pure Objective-C runtime swizzling: no CydiaSubstrate / ElleKit dependency.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Replaces -[cls selectorName] with replacement and hands back the previous implementation.
// The method is added on cls first, so an inherited implementation isn't replaced for every subclass.
static inline BOOL TBHHookMethod(Class cls, NSString *selectorName, IMP replacement, IMP *original) {
    SEL selector = NSSelectorFromString(selectorName);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (method == NULL || replacement == NULL) return NO;
    IMP previous = method_getImplementation(method);
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
        method_setImplementation(class_getInstanceMethod(cls, selector), replacement);
    }
    if (original) *original = previous;
    return YES;
}

// Settings.m: feature switches (on unless switched off in YouTube's settings; read at launch).
extern NSString *const YTGTopBarKey; // no top bar, status bar blur, large titles (HideTopBar.m)
extern NSString *const YTGPlayerKey; // Liquid Glass player controls (PlayerGlass.m)
extern NSString *const YTGSlideUpKey; // no slide-up animation when switching tabs (TabAnimation.m)
extern NSString *const YTGGlassTabBarKey;       // our Liquid Glass tab bar, off unless switched on (GlassTabBar.m)
extern NSString *const YTGDeArrowTitlesKey;     // DeArrow community titles (DeArrow.m)
extern NSString *const YTGDeArrowThumbnailsKey; // DeArrow thumbnails (DeArrow.m)
extern NSString *const YTGHideAIKey;            // AiSList blocklist (AiSList.m)
extern NSString *const YTGHideSuspectedAIKey;   // AiSList warnlist (AiSList.m)
BOOL YTGFeatureEnabled(NSString *key);
BOOL YTGOptInEnabled(NSString *key); // off unless switched on
// Settings.m: how search is shown (SearchButton.m).
typedef NS_ENUM(NSInteger, YTGSearchStyle) { YTGSearchOff = 0, YTGSearchSeparate = 1, YTGSearchInTabBar = 2 };
YTGSearchStyle YTGSearchMode(void);

// TabBarAutoHide.m: YouTube's tab bar (YTPivotBarView) on screen, or nil.
UIView *TBHFindBar(void);
// TabBarAutoHide.m: whether a YTPivotBarItemView is the selected tab.
BOOL TBHPivotItemSelected(UIView *item);
// TabBarAutoHide.m: the selected tab's identifier (e.g. FEwhat_to_watch, FElibrary), or nil.
NSString *TBHSelectedTabIdentifier(void);
// TabBarAutoHide.m: the selected tab's label as YouTube shows it (in the app's language), or nil.
NSString *TBHSelectedTabTitle(void);

// HideTopBar.m: YES for a top bar (or wrapper) we made invisible. It still holds the page's search button.
BOOL TBHTopBarHiddenByUs(UIView *view);

// SearchButton.m: opens YouTube's search (taps the top bar's search button).
void YTGOpenSearch(UIView *from);
