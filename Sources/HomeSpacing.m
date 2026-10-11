// HomeSpacing
// Home's feed has 8pt spacer rows (ELMCellNode) between its videos, and YTPlus's ad blocking leaves more
// behind (several at the top, two between some videos); Subscriptions has none, so Home's videos sat further
// apart. Home's layout (YTTopAlignGridCollectionViewLayout) is asked as usual, then the spacer rows are given
// no height and everything below them moves up. The rows' own sizes are left alone: Texture needs them.
//
// Pure Objective-C runtime swizzling: no CydiaSubstrate / ElleKit dependency.

#import "Common.h"

static const void *HSHomeKey = &HSHomeKey;     // feed -> @YES/@NO: Home's feed (decided once)
static const void *HSSpacersKey = &HSSpacersKey; // layout -> HSSpacers

static BOOL HSIsHomeFeed(UIView *list) {
    NSNumber *decided = list ? objc_getAssociatedObject(list, HSHomeKey) : nil;
    if (decided) return decided.boolValue;
    NSString *tab = TBHSelectedTabIdentifier();
    // Home is the first tab, so its feed can be laid out before the tab bar can be read.
    BOOL home = tab == nil || [tab isEqualToString:@"FEwhat_to_watch"];
    if (list.window && tab) objc_setAssociatedObject(list, HSHomeKey, @(home), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return home;
}

// The spacer rows of one layout pass: their index paths, and for each (top to bottom) its bottom edge and the
// height removed up to and including it, so any row's shift is a binary search.
@interface HSSpacers : NSObject
@property (nonatomic, strong) NSSet<NSIndexPath *> *paths;
@property (nonatomic, strong) NSData *bottoms, *removed; // CGFloat arrays
@property (nonatomic, assign) CGFloat total;
@end

@implementation HSSpacers
@end

static IMP OriginalPrepare, OriginalElementsInRect, OriginalItemAttributes, OriginalContentSize;

static CGFloat HSRemovedAbove(HSSpacers *spacers, CGFloat y) {
    const CGFloat *bottoms = spacers.bottoms.bytes, *removed = spacers.removed.bytes;
    NSInteger low = 0, high = (NSInteger)(spacers.bottoms.length / sizeof(CGFloat)) - 1, last = -1;
    while (low <= high) {
        NSInteger mid = (low + high) / 2;
        if (bottoms[mid] <= y + 0.01) { last = mid; low = mid + 1; }
        else high = mid - 1;
    }
    return last >= 0 ? removed[last] : 0.0;
}

static UICollectionViewLayoutAttributes *HSMoved(UICollectionViewLayoutAttributes *attributes, HSSpacers *spacers) {
    UICollectionViewLayoutAttributes *moved = [attributes copy];
    CGRect frame = moved.frame;
    frame.origin.y -= HSRemovedAbove(spacers, CGRectGetMinY(frame));
    if (attributes.representedElementCategory == UICollectionElementCategoryCell && [spacers.paths containsObject:attributes.indexPath]) {
        frame.size.height = 0.0;
        moved.hidden = YES;
    }
    moved.frame = frame;
    return moved;
}

static void HSPrepare(UICollectionViewLayout *self, SEL _cmd) {
    ((void (*)(id, SEL))OriginalPrepare)(self, _cmd);
    UICollectionView *list = self.collectionView;
    objc_setAssociatedObject(self, HSSpacersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (list == nil || !HSIsHomeFeed(list)) return;
    static Class spacerClass;
    if (spacerClass == Nil) spacerClass = NSClassFromString(@"ELMCellNode");
    SEL nodeSel = NSSelectorFromString(@"nodeForItemAtIndexPath:");
    if (spacerClass == Nil || ![list respondsToSelector:nodeSel]) return;
    CGSize content = ((CGSize (*)(id, SEL))OriginalContentSize)(self, @selector(collectionViewContentSize));
    NSArray<UICollectionViewLayoutAttributes *> *all = ((NSArray * (*)(id, SEL, CGRect))OriginalElementsInRect)(
        self, @selector(layoutAttributesForElementsInRect:), CGRectMake(0.0, 0.0, MAX(content.width, 1.0), content.height));
    NSMutableArray<UICollectionViewLayoutAttributes *> *found = [NSMutableArray array];
    for (UICollectionViewLayoutAttributes *attributes in all) {
        if (attributes.representedElementCategory != UICollectionElementCategoryCell) continue;
        CGFloat height = CGRectGetHeight(attributes.frame);
        if (height <= 0.0 || height > 8.5) continue;
        id node = ((id (*)(id, SEL, id))objc_msgSend)(list, nodeSel, attributes.indexPath);
        if ([node isKindOfClass:spacerClass]) [found addObject:attributes];
    }
    if (found.count == 0) return;
    [found sortUsingComparator:^NSComparisonResult(UICollectionViewLayoutAttributes *a, UICollectionViewLayoutAttributes *b) {
        return [@(CGRectGetMinY(a.frame)) compare:@(CGRectGetMinY(b.frame))];
    }];
    NSMutableData *bottoms = [NSMutableData dataWithLength:found.count * sizeof(CGFloat)];
    NSMutableData *removed = [NSMutableData dataWithLength:found.count * sizeof(CGFloat)];
    NSMutableSet<NSIndexPath *> *paths = [NSMutableSet setWithCapacity:found.count];
    CGFloat total = 0.0;
    for (NSUInteger i = 0; i < found.count; i++) {
        total += CGRectGetHeight(found[i].frame);
        ((CGFloat *)bottoms.mutableBytes)[i] = CGRectGetMaxY(found[i].frame);
        ((CGFloat *)removed.mutableBytes)[i] = total;
        [paths addObject:found[i].indexPath];
    }
    HSSpacers *spacers = [HSSpacers new];
    spacers.paths = paths;
    spacers.bottoms = bottoms;
    spacers.removed = removed;
    spacers.total = total;
    objc_setAssociatedObject(self, HSSpacersKey, spacers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSArray *HSElementsInRect(UICollectionViewLayout *self, SEL _cmd, CGRect rect) {
    HSSpacers *spacers = objc_getAssociatedObject(self, HSSpacersKey);
    if (spacers == nil) return ((NSArray * (*)(id, SEL, CGRect))OriginalElementsInRect)(self, _cmd, rect);
    CGRect wider = rect;
    wider.size.height += spacers.total;
    NSArray<UICollectionViewLayoutAttributes *> *found = ((NSArray * (*)(id, SEL, CGRect))OriginalElementsInRect)(self, _cmd, wider);
    NSMutableArray *moved = [NSMutableArray arrayWithCapacity:found.count];
    for (UICollectionViewLayoutAttributes *attributes in found) {
        UICollectionViewLayoutAttributes *item = HSMoved(attributes, spacers);
        if (CGRectIntersectsRect(item.frame, rect) || CGRectGetHeight(item.frame) == 0.0) [moved addObject:item];
    }
    return moved;
}

static UICollectionViewLayoutAttributes *HSItemAttributes(UICollectionViewLayout *self, SEL _cmd, NSIndexPath *path) {
    UICollectionViewLayoutAttributes *attributes = ((id (*)(id, SEL, id))OriginalItemAttributes)(self, _cmd, path);
    HSSpacers *spacers = objc_getAssociatedObject(self, HSSpacersKey);
    return spacers && attributes ? HSMoved(attributes, spacers) : attributes;
}

static CGSize HSContentSize(UICollectionViewLayout *self, SEL _cmd) {
    CGSize size = ((CGSize (*)(id, SEL))OriginalContentSize)(self, _cmd);
    HSSpacers *spacers = objc_getAssociatedObject(self, HSSpacersKey);
    if (spacers) size.height = MAX(0.0, size.height - spacers.total);
    return size;
}

__attribute__((constructor)) static void HSInit(void) {
    @autoreleasepool {
        Class layout = NSClassFromString(@"YTTopAlignGridCollectionViewLayout");
        if (layout == Nil) return;
        TBHHookMethod(layout, @"prepareLayout", (IMP)HSPrepare, &OriginalPrepare);
        TBHHookMethod(layout, @"layoutAttributesForElementsInRect:", (IMP)HSElementsInRect, &OriginalElementsInRect);
        TBHHookMethod(layout, @"layoutAttributesForItemAtIndexPath:", (IMP)HSItemAttributes, &OriginalItemAttributes);
        TBHHookMethod(layout, @"collectionViewContentSize", (IMP)HSContentSize, &OriginalContentSize);
    }
}
