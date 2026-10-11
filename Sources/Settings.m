// YTGlass settings: a "YTGlass" page in YouTube's settings, listed in the Tweaks group of PoomSmart's
// YouGroupSettings when that's installed (as in YTPlus builds), otherwise right after General.
// One switch per feature; changes apply after restarting YouTube (each feature installs its hooks at launch).

#import "Common.h"

static NSInteger const YTGSection = 'ytgl'; // settings category number (4-char code, like PoomSmart's tweaks)

static NSString *const YTGSearchModeKey = @"YTGlass_SearchMode";
NSString *const YTGTopBarKey = @"YTGlass_HideTopBar";
NSString *const YTGPlayerKey = @"YTGlass_PlayerGlass";

BOOL YTGFeatureEnabled(NSString *key) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : YES; // on unless switched off
}

YTGSearchStyle YTGSearchMode(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:YTGSearchModeKey];
    if ([value respondsToSelector:@selector(integerValue)]) {
        NSInteger mode = [value integerValue];
        if (mode >= YTGSearchOff && mode <= YTGSearchInTabBar) return (YTGSearchStyle)mode;
    }
    return YTGSearchSeparate;
}

static NSString *YTGSearchModeName(YTGSearchStyle mode) {
    switch (mode) {
        case YTGSearchOff: return @"Off";
        case YTGSearchInTabBar: return @"Integrated";
        default: return @"Separate";
    }
}

#pragma mark - Listing the page

// YouGroupSettings adds +[YTSettingsGroupData tweaks]: the mutable list of categories it shows under Tweaks.
static BOOL YTGJoinTweaksGroup(void) {
    Class groupData = NSClassFromString(@"YTSettingsGroupData");
    SEL tweaksSel = NSSelectorFromString(@"tweaks");
    if (groupData == Nil || ![groupData respondsToSelector:tweaksSel]) return NO;
    id tweaks = ((id (*)(id, SEL))objc_msgSend)(groupData, tweaksSel);
    if (![tweaks isKindOfClass:NSMutableArray.class]) return NO;
    if (![tweaks containsObject:@(YTGSection)]) [tweaks addObject:@(YTGSection)];
    return YES;
}

static IMP OriginalCategoryOrder;

static NSArray *YTGCategoryOrder(id self, SEL _cmd) {
    NSArray *order = ((NSArray *(*)(id, SEL))OriginalCategoryOrder)(self, _cmd);
    if ([order containsObject:@(YTGSection)]) return order;
    NSUInteger general = [order indexOfObject:@(1)];
    if (general == NSNotFound) return order;
    NSMutableArray *mutableOrder = [order mutableCopy];
    [mutableOrder insertObject:@(YTGSection) atIndex:general + 1];
    return mutableOrder;
}

static IMP OriginalOrderedCategories;

static NSArray *YTGOrderedCategories(id self, SEL _cmd) {
    NSArray *categories = ((NSArray *(*)(id, SEL))OriginalOrderedCategories)(self, _cmd);
    if (YTGJoinTweaksGroup()) return categories; // YouGroupSettings lists it
    SEL typeSel = NSSelectorFromString(@"type");
    NSUInteger type = [self respondsToSelector:typeSel] ? ((NSUInteger (*)(id, SEL))objc_msgSend)(self, typeSel) : 0;
    if (type != 1 || [categories containsObject:@(YTGSection)]) return categories;
    NSMutableArray *mutableCategories = [categories mutableCopy];
    [mutableCategories insertObject:@(YTGSection) atIndex:0];
    return mutableCategories;
}

#pragma mark - The page

static id YTGSwitch(NSString *title, NSString *description, NSString *key) {
    Class itemClass = NSClassFromString(@"YTSettingsSectionItem");
    SEL sel = NSSelectorFromString(@"switchItemWithTitle:titleDescription:accessibilityIdentifier:switchOn:switchBlock:settingItemId:");
    if (![itemClass respondsToSelector:sel]) return nil;
    BOOL (^block)(id, BOOL) = ^BOOL(__unused id cell, BOOL enabled) {
        [NSUserDefaults.standardUserDefaults setBool:enabled forKey:key];
        return YES;
    };
    return ((id (*)(id, SEL, NSString *, NSString *, NSString *, BOOL, id, int))objc_msgSend)(
        itemClass, sel, title, description, nil, YTGFeatureEnabled(key), block, 0);
}

// A plain row at the bottom of the page (tapping it does nothing).
static id YTGNote(NSString *text) {
    Class itemClass = NSClassFromString(@"YTSettingsSectionItem");
    SEL sel = NSSelectorFromString(@"itemWithTitle:titleDescription:accessibilityIdentifier:detailTextBlock:selectBlock:");
    if (![itemClass respondsToSelector:sel]) return nil;
    BOOL (^select)(id, NSUInteger) = ^BOOL(__unused id cell, __unused NSUInteger arg) { return NO; };
    return ((id (*)(id, SEL, NSString *, NSString *, NSString *, id, id))objc_msgSend)(itemClass, sel, nil, text, nil, nil, select);
}

// Search: Off / Separate button / In the tab bar, on its own page like YouTube's other choices.
static id YTGSearchPicker(id manager, id settingsViewController) {
    Class itemClass = NSClassFromString(@"YTSettingsSectionItem");
    Class pickerClass = NSClassFromString(@"YTSettingsPickerViewController");
    SEL itemSel = NSSelectorFromString(@"itemWithTitle:titleDescription:accessibilityIdentifier:detailTextBlock:selectBlock:");
    SEL rowSel = NSSelectorFromString(@"checkmarkItemWithTitle:titleDescription:selectBlock:");
    SEL pickerSel = NSSelectorFromString(@"initWithNavTitle:pickerSectionTitle:rows:selectedItemIndex:parentResponder:");
    if (![itemClass respondsToSelector:itemSel] || ![itemClass respondsToSelector:rowSel] || ![pickerClass instancesRespondToSelector:pickerSel]) return nil;
    NSString *description = @"Adds Search to the tab bar.";
    NSString *(^detail)(void) = ^NSString *(void) { return YTGSearchModeName(YTGSearchMode()); };
    BOOL (^select)(id, NSUInteger) = ^BOOL(__unused id cell, __unused NSUInteger arg) {
        NSMutableArray *rows = [NSMutableArray array];
        for (NSInteger mode = YTGSearchOff; mode <= YTGSearchInTabBar; mode++) {
            BOOL (^choose)(id, NSUInteger) = ^BOOL(__unused id rowCell, __unused NSUInteger rowArg) {
                [NSUserDefaults.standardUserDefaults setInteger:mode forKey:YTGSearchModeKey];
                if ([settingsViewController respondsToSelector:@selector(reloadData)]) [settingsViewController reloadData];
                return YES;
            };
            id row = ((id (*)(id, SEL, NSString *, NSString *, id))objc_msgSend)(itemClass, rowSel, YTGSearchModeName((YTGSearchStyle)mode), nil, choose);
            if (row) [rows addObject:row];
        }
        SEL responderSel = NSSelectorFromString(@"parentResponder");
        id responder = [manager respondsToSelector:responderSel] ? ((id (*)(id, SEL))objc_msgSend)(manager, responderSel) : nil;
        id picker = ((id (*)(id, SEL, NSString *, NSString *, NSArray *, NSUInteger, id))objc_msgSend)(
            [pickerClass alloc], pickerSel, @"Search", nil, rows, (NSUInteger)YTGSearchMode(), responder);
        SEL push = NSSelectorFromString(@"pushViewController:");
        if (picker && [settingsViewController respondsToSelector:push]) ((void (*)(id, SEL, id))objc_msgSend)(settingsViewController, push, picker);
        return YES;
    };
    return ((id (*)(id, SEL, NSString *, NSString *, NSString *, id, id))objc_msgSend)(itemClass, itemSel, @"Search", description, nil, detail, select);
}

static IMP OriginalUpdateSection;

static void YTGUpdateSection(id self, SEL _cmd, NSUInteger category, id entry) {
    if (category != YTGSection) {
        ((void (*)(id, SEL, NSUInteger, id))OriginalUpdateSection)(self, _cmd, category, entry);
        return;
    }
    id delegate = nil;
    @try { delegate = [self valueForKey:@"_settingsViewControllerDelegate"]; } @catch (__unused NSException *e) {}
    NSArray *items = [@[
        YTGSearchPicker(self, delegate) ?: NSNull.null,
        YTGSwitch(@"Hide Navigation bar",
                  @"Removes the navigation bar and styles it like a native app.", YTGTopBarKey) ?: NSNull.null,
        YTGSwitch(@"Liquid Glass player",
                  @"Liquid Glass video player controls.", YTGPlayerKey) ?: NSNull.null,
        YTGNote(@"Restart YouTube to apply changes.") ?: NSNull.null,
    ] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self != %@", NSNull.null]];
    SEL withIcon = NSSelectorFromString(@"setSectionItems:forCategory:title:icon:titleDescription:headerHidden:");
    SEL withoutIcon = NSSelectorFromString(@"setSectionItems:forCategory:title:titleDescription:headerHidden:");
    if ([delegate respondsToSelector:withIcon]) {
        ((void (*)(id, SEL, NSArray *, NSUInteger, NSString *, id, NSString *, BOOL))objc_msgSend)(delegate, withIcon, items, YTGSection, @"YTGlass", nil, nil, NO);
    } else if ([delegate respondsToSelector:withoutIcon]) {
        ((void (*)(id, SEL, NSArray *, NSUInteger, NSString *, NSString *, BOOL))objc_msgSend)(delegate, withoutIcon, items, YTGSection, @"YTGlass", nil, NO);
    }
}

__attribute__((constructor)) static void YTGSettingsInit(void) {
    @autoreleasepool {
        Class presentation = NSClassFromString(@"YTAppSettingsPresentationData");
        if (presentation) TBHHookMethod(object_getClass(presentation), @"settingsCategoryOrder", (IMP)YTGCategoryOrder, &OriginalCategoryOrder);
        TBHHookMethod(NSClassFromString(@"YTSettingsGroupData"), @"orderedCategories", (IMP)YTGOrderedCategories, &OriginalOrderedCategories);
        TBHHookMethod(NSClassFromString(@"YTSettingsSectionItemManager"), @"updateSectionForCategory:withEntry:", (IMP)YTGUpdateSection, &OriginalUpdateSection);
        // YouGroupSettings adds its list in its own constructor; join it once every library has loaded.
        dispatch_async(dispatch_get_main_queue(), ^{ YTGJoinTweaksGroup(); });
    }
}
