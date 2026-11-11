#import "PlaybackHistory.h"
#import "UserSync.h"
#import <math.h>

static NSString *const HistoryKey = @"playbackHistoryV1";
NSString *LCProgressKey(NSString *host, NSString *library, NSString *path) {
    NSString *key = [NSString stringWithFormat:@"progress:%@:%@:%@", host ?: @"", library ?: @"", path ?: @""];
    return [@[@"ts", @"mts", @"m2ts"] containsObject:path.pathExtension.lowercaseString] ? [key stringByAppendingString:@":ts-indexed-v1"] : key;
}
@interface LCPlaybackHistory ()
@property(nonatomic, strong) NSUserDefaults *defaults;
@end
@implementation LCPlaybackHistory
+ (instancetype)shared {
    static LCPlaybackHistory *store; static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [[self alloc] initWithDefaults:NSUserDefaults.standardUserDefaults]; });
    return store;
}
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) _defaults = defaults;
    return self;
}
- (NSArray<NSDictionary *> *)allRecords {
    NSArray *stored = [self.defaults arrayForKey:HistoryKey];
    NSMutableArray *valid = [NSMutableArray new];
    for (id r in stored) {
        if (![r isKindOfClass:NSDictionary.class] || ![r[@"item"] isKindOfClass:NSDictionary.class] ||
            ![r[@"item"][@"path"] isKindOfClass:NSString.class] || ![r[@"host"] isKindOfClass:NSString.class] ||
            ![r[@"library"] isKindOfClass:NSString.class] || ![r[@"position"] isKindOfClass:NSNumber.class] ||
            ![r[@"updated"] isKindOfClass:NSNumber.class]) continue;
        if (isfinite([r[@"position"] doubleValue]) && [r[@"position"] doubleValue] > 0) [valid addObject:r];
    }
    return [valid sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"updated" ascending:NO]]];
}
- (BOOL)record:(NSDictionary *)r matchesHost:(NSString *)host library:(NSString *)library {
    return [r[@"host"] isEqual:host ?: @""] && [r[@"library"] isEqual:library ?: @""];
}
- (NSArray<NSDictionary *> *)recordsForHost:(NSString *)host library:(NSString *)library {
    NSMutableArray *result = [NSMutableArray new];
    for (NSDictionary *r in [self allRecords]) if ([self record:r matchesHost:host library:library]) [result addObject:r];
    return result;
}
- (double)positionForItem:(NSDictionary *)item host:(NSString *)host library:(NSString *)library {
    for (NSDictionary *r in [self recordsForHost:host library:library]) {
        if (![r[@"item"][@"path"] isEqual:item[@"path"]]) continue;
        // A file replaced at the same path must not inherit the old seek point.
        for (NSString *field in @[@"size", @"thumbnailVersion", @"modified"]) {
            if (item[field] && r[@"item"][field] && ![item[field] isEqual:r[@"item"][field]]) {
                [self removePath:item[@"path"] host:host library:library];
                return 0;
            }
        }
        return [r[@"position"] doubleValue];
    }
    // Migrate legacy progress lazily after the video next renders frames.
    double legacy = [self.defaults doubleForKey:LCProgressKey(host, library, item[@"path"])];
    return isfinite(legacy) && legacy > 0 ? legacy : 0;
}
- (void)removePath:(NSString *)path host:(NSString *)host library:(NSString *)library {
    LCQueueUserChange(self.defaults, @"history", path, nil, host, library);
    NSMutableArray *records = [[self allRecords] mutableCopy];
    NSIndexSet *matches = [records indexesOfObjectsPassingTest:^BOOL(NSDictionary *r, NSUInteger i, BOOL *stop) {
        return [self record:r matchesHost:host library:library] && [r[@"item"][@"path"] isEqual:path];
    }];
    [records removeObjectsAtIndexes:matches];
    [self.defaults setObject:records forKey:HistoryKey];
    [self.defaults removeObjectForKey:LCProgressKey(host, library, path)];
}
- (void)saveItem:(NSDictionary *)item host:(NSString *)host library:(NSString *)library position:(double)position duration:(double)duration {
    if (![item[@"path"] isKindOfClass:NSString.class] || ![item[@"path"] length] || !isfinite(position) || position <= 0) return;
    if (!isfinite(duration) || duration < 0) duration = 0;
    if (duration > 0) position = MIN(position, MAX(0, duration - .25));
    NSMutableDictionary *metadata = [NSMutableDictionary new];
    for (NSString *field in @[@"path", @"name", @"size", @"modified", @"thumbnailVersion", @"video"]) {
        id value = item[field];
        if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) metadata[field] = value;
    }
    metadata[@"name"] = metadata[@"name"] ?: [item[@"path"] lastPathComponent];
    metadata[@"video"] = @YES;
    NSNumber *updated = @(NSDate.date.timeIntervalSince1970);
    LCQueueUserChange(self.defaults, @"history", item[@"path"], @{@"item":metadata, @"position":@(position), @"duration":@(duration), @"updated":updated}, host, library);
    NSMutableArray *records = [[self allRecords] mutableCopy];
    NSIndexSet *matches = [records indexesOfObjectsPassingTest:^BOOL(NSDictionary *r, NSUInteger i, BOOL *stop) {
        return [self record:r matchesHost:host library:library] && [r[@"item"][@"path"] isEqual:item[@"path"]];
    }];
    [records removeObjectsAtIndexes:matches];
    [records insertObject:@{@"host":host ?: @"", @"library":library ?: @"", @"item":metadata,
                           @"position":@(position), @"duration":@(duration), @"updated":updated} atIndex:0];
    if (records.count > 100) {
        for (NSDictionary *old in [records subarrayWithRange:NSMakeRange(100, records.count - 100)])
            [self.defaults removeObjectForKey:LCProgressKey(old[@"host"], old[@"library"], old[@"item"][@"path"])];
        [records removeObjectsInRange:NSMakeRange(100, records.count - 100)];
    }
    [self.defaults setObject:records forKey:HistoryKey];
    [self.defaults setDouble:position forKey:LCProgressKey(host, library, item[@"path"])];
}
@end
