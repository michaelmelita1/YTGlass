// TEMPORARY DIAGNOSTIC (0.2.0~debug20): the stuck player. Lines go to Documents/YTGlass-diag.log in YouTube's folder
// (copied off the phone with devicectl), with the time of day, so they can be matched to when the player got stuck.
// Logs every change a YTGlass feature makes (marked with the video page it happened in, if any) and, once a second,
// the state of the video page and the list under the video.

#import "Common.h"

void YTGDWrite(NSString *line) {
    static NSFileHandle *file;
    static NSDateFormatter *clock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"YTGlass-diag.log"];
        [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil]; // fresh each launch
        file = [NSFileHandle fileHandleForWritingAtPath:path];
        clock = [NSDateFormatter new];
        clock.dateFormat = @"HH:mm:ss.SSS";
    });
    @synchronized (file) {
        NSString *stamped = [NSString stringWithFormat:@"%@ %@\n", [clock stringFromDate:NSDate.date], line];
        [file writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]];
    }
}

// The outermost YTWatch… view or controller view around view, or nil when it isn't in the video page.
NSString *YTGDWatchOf(UIView *view) {
    NSString *found = nil;
    for (UIView *v = view; v != nil; v = v.superview) {
        NSString *name = NSStringFromClass(v.class);
        if ([name hasPrefix:@"YTWatch"]) found = name;
    }
    return found;
}

void YTGDAct(NSString *feature, UIView *view, NSString *what) {
    // The same line at most every 3 seconds: layout passes repeat them many times a second.
    static NSMutableDictionary<NSString *, NSNumber *> *last;
    if (last == nil) last = [NSMutableDictionary dictionary];
    NSString *watch = view ? YTGDWatchOf(view) : nil;
    NSString *line = [NSString stringWithFormat:@"%@%@: %@%@", watch ? @"!! " : @"", feature, what,
                      watch ? [NSString stringWithFormat:@" [in %@]", watch] : @""];
    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *then = last[line];
    if (then && now - then.doubleValue < 3.0) return;
    last[line] = @(now);
    YTGDWrite(line);
}

#pragma mark - The video page, once a second

static void YTGDFind(UIView *view, Class cls, NSMutableArray<UIView *> *found, NSInteger budget[1]) {
    if (budget[0]-- <= 0) return;
    if ([view isKindOfClass:cls]) { [found addObject:view]; return; }
    for (UIView *subview in view.subviews) YTGDFind(subview, cls, found, budget);
}

static NSString *YTGDListState(UIView *root) {
    NSMutableArray<UIView *> *lists = [NSMutableArray array];
    NSInteger budget[1] = { 4000 };
    YTGDFind(root, UICollectionView.class, lists, budget);
    UICollectionView *list = nil;
    for (UICollectionView *candidate in lists) {
        if (candidate.window == nil || candidate.hidden || candidate.alpha < 0.01 || candidate.pagingEnabled) continue;
        if (list == nil || CGRectGetHeight(candidate.bounds) > CGRectGetHeight(list.bounds)) list = candidate;
    }
    if (list == nil) return @"no list";
    NSMutableArray<NSString *> *cells = [NSMutableArray array];
    NSArray<UICollectionViewCell *> *visible = [list.visibleCells sortedArrayUsingComparator:^NSComparisonResult(UICollectionViewCell *a, UICollectionViewCell *b) {
        return [@(CGRectGetMinY(a.frame)) compare:@(CGRectGetMinY(b.frame))];
    }];
    for (UICollectionViewCell *cell in visible) {
        if (cells.count >= 4) break;
        [cells addObject:[NSString stringWithFormat:@"%@(%.0f)", NSStringFromClass(cell.class), CGRectGetHeight(cell.frame)]];
    }
    return [NSString stringWithFormat:@"list %@ h%.0f cells %lu content %.0f inset %.0f/%.0f offset %.0f first %@",
            NSStringFromClass(list.class), CGRectGetHeight(list.bounds), (unsigned long)list.visibleCells.count,
            list.contentSize.height, list.contentInset.top, list.adjustedContentInset.top, list.contentOffset.y,
            [cells componentsJoinedByString:@" "]];
}

static void YTGDWatchTick(void) {
    static NSString *lastState;
    static Class watchClass;
    if (watchClass == Nil) watchClass = NSClassFromString(@"YTWatchView");
    NSMutableArray<UIView *> *watches = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            NSInteger budget[1] = { 6000 };
            if (watchClass) YTGDFind(window, watchClass, watches, budget);
        }
    }
    UIView *watch = nil;
    for (UIView *v in watches) if (v.window && !v.hidden && v.alpha > 0.01) watch = v;
    NSString *state;
    if (watch == nil) {
        state = @"no video page";
    } else {
        CGRect frame = [watch convertRect:watch.bounds toView:nil];
        UIView *bar = TBHFindBar();
        state = [NSString stringWithFormat:@"video page %.0f,%.0f %.0fx%.0f, tab bar %@; %@", CGRectGetMinX(frame), CGRectGetMinY(frame),
                 CGRectGetWidth(frame), CGRectGetHeight(frame), bar == nil ? @"none" : (bar.window && !bar.hidden && bar.alpha > 0.01 ? @"shown" : @"hidden"),
                 YTGDListState(watch)];
    }
    if ([state isEqualToString:lastState]) return;
    lastState = state;
    YTGDWrite([@"STATE " stringByAppendingString:state]);
}

__attribute__((constructor)) static void YTGDInit(void) {
    YTGDWrite([NSString stringWithFormat:@"launch YTGlass %s", YTG_VERSION]);
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray<NSString *> *settings = [NSMutableArray array];
    for (NSString *key in [defaults.dictionaryRepresentation.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if ([key hasPrefix:@"YTGlass_"] && ![key hasPrefix:@"YTGlass_Hook "] && ![key containsString:@"DeArrowBranding"]) {
            [settings addObject:[NSString stringWithFormat:@"%@=%@", [key substringFromIndex:8], [defaults objectForKey:key]]];
        }
    }
    YTGDWrite([@"settings " stringByAppendingString:[settings componentsJoinedByString:@" "]]);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) { YTGDWatchTick(); }];
    });
}
