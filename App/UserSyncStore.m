#import "UserSync.h"
#import "PlaybackHistory.h"
#import <math.h>

NSNotificationName const LCUserSyncChanged = @"LCUserSyncChanged";
static NSString *const StateKey = @"userSyncV1";
NSArray<NSString *> *LCSyncedPreferenceKeys(void) {
    return @[@"playbackRate", @"holdPlaybackRate", @"videoDisplayMode", @"fileIconView", @"fileSortKey", @"fileSortDescending"];
}
static NSString *ScopeKey(NSString *host, NSString *library) {
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:@[host ?: @"", library ?: @""] options:0 error:nil] encoding:NSUTF8StringEncoding];
}
static NSString *EntryKey(NSString *kind, NSString *key) { return ScopeKey(kind, key); }
static BOOL Number(id v) { return [v isKindOfClass:NSNumber.class] && isfinite([v doubleValue]) && [v doubleValue] >= 0; }
static BOOL ValidPath(id path) {
    if (![path isKindOfClass:NSString.class] || ![path length] || [path length] > 4096 || [path rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\\\\:\0"]].location != NSNotFound) return NO;
    for (NSString *part in [path componentsSeparatedByString:@"/"]) if (!part.length || [part isEqual:@"."] || [part isEqual:@".."]) return NO;
    return YES;
}
static BOOL ValidValue(NSString *kind, NSString *key, id value) {
    if ([kind isEqual:@"preference"]) {
        if ([key isEqual:@"fileIconView"] || [key isEqual:@"fileSortDescending"]) return [value isKindOfClass:NSNumber.class] && ([value doubleValue] == 0 || [value doubleValue] == 1);
        if ([key isEqual:@"playbackRate"]) return Number(value) && [value doubleValue] >= .5 && [value doubleValue] <= 3;
        if ([key isEqual:@"holdPlaybackRate"]) return Number(value) && [value doubleValue] >= 2 && [value doubleValue] <= 3;
        if ([key isEqual:@"fileSortKey"]) return [@[@"name", @"size", @"type", @"modified"] containsObject:value];
        if ([key isEqual:@"videoDisplayMode"]) return [@[@"smart", @"fill", @"full"] containsObject:value];
        return NO;
    }
    if (!ValidPath(key) || ![value isKindOfClass:NSDictionary.class] || ![value[@"item"] isKindOfClass:NSDictionary.class] || !Number(value[@"updated"])) return NO;
    NSDictionary *item = value[@"item"];
    if (![item[@"path"] isEqual:key] || ![item[@"name"] isKindOfClass:NSString.class]) return NO;
    for (NSString *field in @[@"video", @"directory"]) if (item[field] && ![item[field] isKindOfClass:NSNumber.class]) return NO;
    for (NSString *field in @[@"size", @"modified"]) if (item[field] && !Number(item[field])) return NO;
    if (item[@"thumbnailVersion"] && ![item[@"thumbnailVersion"] isKindOfClass:NSString.class]) return NO;
    if ([kind isEqual:@"favorite"]) return [item[@"directory"] boolValue] || [item[@"video"] boolValue];
    return [kind isEqual:@"history"] && Number(value[@"position"]) && [value[@"position"] doubleValue] > 0 && Number(value[@"duration"]);
}
@interface LCUserSyncStore ()
@property(nonatomic, strong) NSUserDefaults *defaults;
@end
@implementation LCUserSyncStore
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults { if ((self = [super init])) _defaults = defaults; return self; }
- (NSMutableDictionary *)state {
    NSMutableDictionary *state = [[self.defaults dictionaryForKey:StateKey] mutableCopy] ?: [NSMutableDictionary new];
    state[@"deviceID"] = state[@"deviceID"] ?: NSUUID.UUID.UUIDString;
    state[@"sequence"] = state[@"sequence"] ?: @0;
    state[@"scopes"] = [state[@"scopes"] mutableCopy] ?: [NSMutableDictionary new];
    return state;
}
- (NSMutableDictionary *)scopeIn:(NSMutableDictionary *)state host:(NSString *)host library:(NSString *)library {
    NSString *key = ScopeKey(host, library);
    NSMutableDictionary *scope = [state[@"scopes"][key] mutableCopy] ?: [NSMutableDictionary new];
    scope[@"pending"] = [scope[@"pending"] mutableCopy] ?: [NSMutableDictionary new];
    scope[@"revisions"] = [scope[@"revisions"] mutableCopy] ?: [NSMutableDictionary new];
    state[@"scopes"][key] = scope;
    return scope;
}
- (void)enqueue:(NSMutableDictionary *)state scope:(NSMutableDictionary *)scope kind:(NSString *)kind key:(NSString *)key value:(id)value seed:(BOOL)seed {
    NSString *entry = EntryKey(kind, key);
    long long seq = [state[@"sequence"] longLongValue] + 1;
    state[@"sequence"] = @(seq);
    NSMutableDictionary *op = [@{@"id":NSUUID.UUID.UUIDString, @"seq":@(seq), @"base":scope[@"revisions"][entry] ?: @0,
                                @"kind":kind, @"key":key, @"mode":seed ? @"seed" : @"edit", @"deleted":@(value == nil)} mutableCopy];
    if (value) op[@"value"] = value;
    scope[@"pending"][entry] = op;
}
- (void)prepare:(NSMutableDictionary *)state scope:(NSMutableDictionary *)scope host:(NSString *)host library:(NSString *)library {
    if ([scope[@"migrated"] boolValue]) return;
    // A separate immutable local snapshot survives all later synchronization.
    if (![self.defaults dictionaryForKey:@"userSyncMigrationBackupV1"]) {
        NSMutableDictionary *backup = [NSMutableDictionary new];
        NSDictionary *all = self.defaults.dictionaryRepresentation;
        for (NSString *key in all) {
            if ([key isEqual:@"favoritesV1"] || [key isEqual:@"playbackHistoryV1"] || [key hasPrefix:@"progress:"] || [LCSyncedPreferenceKeys() containsObject:key]) backup[key] = all[key];
        }
        [self.defaults setObject:backup forKey:@"userSyncMigrationBackupV1"];
    }
    NSMutableSet *historyPaths = [NSMutableSet new];
    for (NSString *kind in @[@"favorite", @"history"]) {
        NSArray *rows = [self.defaults arrayForKey:[kind isEqual:@"favorite"] ? @"favoritesV1" : @"playbackHistoryV1"] ?: @[];
        NSInteger index = rows.count;
        for (id row in rows.reverseObjectEnumerator) {
            index--;
            if (![row isKindOfClass:NSDictionary.class] || ![row[@"host"] isEqual:host] || ![row[@"library"] isEqual:library] || ![row[@"item"] isKindOfClass:NSDictionary.class]) continue;
            NSMutableDictionary *value = [row mutableCopy];
            [value removeObjectForKey:@"host"]; [value removeObjectForKey:@"library"];
            value[@"updated"] = value[@"updated"] ?: @(NSDate.date.timeIntervalSince1970 - index);
            NSString *path = value[@"item"][@"path"];
            if (![path isKindOfClass:NSString.class] || !ValidValue(kind, path, value)) continue;
            [self enqueue:state scope:scope kind:kind key:path value:value seed:YES];
            if ([kind isEqual:@"history"]) [historyPaths addObject:path];
        }
    }
    // Earlier releases saved only per-path progress. Bring those along too.
    NSString *prefix = [NSString stringWithFormat:@"progress:%@:%@:", host, library];
    NSDictionary *all = self.defaults.dictionaryRepresentation;
    for (NSString *key in all) {
        if (![key hasPrefix:prefix] || !Number(all[key]) || [all[key] doubleValue] <= 0) continue;
        NSString *path = [key substringFromIndex:prefix.length];
        if ([path hasSuffix:@":ts-indexed-v1"]) path = [path substringToIndex:path.length - @":ts-indexed-v1".length];
        if (!path.length || [path containsString:@":"] || [historyPaths containsObject:path]) continue;
        NSDictionary *value = @{@"item":@{@"path":path, @"name":path.lastPathComponent, @"video":@YES},
                                @"position":all[key], @"duration":@0, @"updated":@(NSDate.date.timeIntervalSince1970)};
        [self enqueue:state scope:scope kind:@"history" key:path value:value seed:YES];
    }
    for (NSString *key in LCSyncedPreferenceKeys()) {
        id value = [self.defaults objectForKey:key];
        if (value && ValidValue(@"preference", key, value)) [self enqueue:state scope:scope kind:@"preference" key:key value:value seed:YES];
    }
    scope[@"migrated"] = @YES;
}
- (void)queueKind:(NSString *)kind key:(NSString *)key value:(id)value host:(NSString *)host library:(NSString *)library {
    if (!host.length || !library.length || !key.length || (value && !ValidValue(kind, key, value))) return;
    NSMutableDictionary *state = [self state], *scope = [self scopeIn:state host:host library:library];
    [self prepare:state scope:scope host:host library:library];
    [self enqueue:state scope:scope kind:kind key:key value:value seed:NO];
    [self.defaults setObject:state forKey:StateKey];
}
- (NSDictionary *)requestForHost:(NSString *)host library:(NSString *)library {
    NSMutableDictionary *state = [self state], *scope = [self scopeIn:state host:host library:library];
    [self prepare:state scope:scope host:host library:library];
    [self.defaults setObject:state forKey:StateKey];
    // Discover PC identity before sending any local data or advancing its receipt.
    NSArray *ops = scope[@"serverID"] ? [scope[@"pending"] allValues] : @[];
    ops = [ops sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"seq" ascending:YES]]];
    if (ops.count > 200) ops = [ops subarrayWithRange:NSMakeRange(0, 200)];
    NSMutableDictionary *request = [@{@"protocol":@1, @"deviceID":state[@"deviceID"], @"libraryID":library, @"operations":ops} mutableCopy];
    if (scope[@"serverID"]) request[@"serverID"] = scope[@"serverID"];
    return request;
}
- (BOOL)applyResponse:(NSDictionary *)response request:(NSDictionary *)request host:(NSString *)host library:(NSString *)library {
    if (![response isKindOfClass:NSDictionary.class] || ![response[@"protocol"] isEqual:@1] || ![response[@"libraryID"] isEqual:library] ||
        ![response[@"serverID"] isKindOfClass:NSString.class] || ![response[@"serverID"] length] ||
        ![response[@"records"] isKindOfClass:NSArray.class] || ![response[@"acknowledged"] isKindOfClass:NSArray.class] || !Number(response[@"revision"])) return NO;
    NSMutableDictionary *state = [self state], *scope = [self scopeIn:state host:host library:library];
    if (scope[@"serverID"] && ![scope[@"serverID"] isEqual:response[@"serverID"]]) return NO;
    if ([response[@"revision"] longLongValue] < [scope[@"revision"] longLongValue]) return NO;
    for (id r in response[@"records"]) {
        if (![r isKindOfClass:NSDictionary.class] || ![@[@"favorite", @"history", @"preference"] containsObject:r[@"kind"]] ||
            ![r[@"key"] isKindOfClass:NSString.class] || ![r[@"key"] length] || !Number(r[@"revision"]) ||
            ![r[@"deleted"] isKindOfClass:NSNumber.class] || (![r[@"deleted"] boolValue] && !ValidValue(r[@"kind"], r[@"key"], r[@"value"]))) return NO;
        if ([r[@"kind"] isEqual:@"preference"] ? ![LCSyncedPreferenceKeys() containsObject:r[@"key"]] : !ValidPath(r[@"key"])) return NO;
    }
    NSSet *acks = [NSSet setWithArray:response[@"acknowledged"]];
    for (NSDictionary *op in request[@"operations"]) {
        NSString *entry = EntryKey(op[@"kind"], op[@"key"]);
        if ([acks containsObject:op[@"id"]] && [scope[@"pending"][entry][@"id"] isEqual:op[@"id"]]) [scope[@"pending"] removeObjectForKey:entry];
    }
    scope[@"serverID"] = response[@"serverID"];
    // A known server moving to a new IP also carries unsent edits from the old IP.
    for (NSString *otherKey in [state[@"scopes"] allKeys]) {
        if ([otherKey isEqual:ScopeKey(host, library)]) continue;
        NSArray *parts = [NSJSONSerialization JSONObjectWithData:[otherKey dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        NSDictionary *other = state[@"scopes"][otherKey];
        if (parts.count != 2 || ![parts[1] isEqual:library] || ![other[@"serverID"] isEqual:scope[@"serverID"]]) continue;
        for (NSString *entry in other[@"pending"]) {
            NSDictionary *op = other[@"pending"][entry];
            NSDictionary *current = scope[@"pending"][entry];
            BOOL oldEdit = [op[@"mode"] isEqual:@"edit"], newEdit = [current[@"mode"] isEqual:@"edit"];
            if (!current || (oldEdit && !newEdit) || (oldEdit == newEdit && [op[@"seq"] longLongValue] > [current[@"seq"] longLongValue])) {
                // Reissue with a new sequence so a previously used IP cannot
                // strand an offline edit below the PC's per-device receipt.
                [self enqueue:state scope:scope kind:op[@"kind"] key:op[@"key"] value:[op[@"deleted"] boolValue] ? nil : op[@"value"] seed:!oldEdit];
                NSMutableDictionary *moved = [scope[@"pending"][entry] mutableCopy];
                moved[@"base"] = op[@"base"]; scope[@"pending"][entry] = moved;
            }
        }
        NSMutableDictionary *cleared = [other mutableCopy]; cleared[@"pending"] = @{}; state[@"scopes"][otherKey] = cleared;
    }
    NSMutableArray *favorites = [[self.defaults arrayForKey:@"favoritesV1"] mutableCopy] ?: [NSMutableArray new];
    NSMutableArray *history = [[self.defaults arrayForKey:@"playbackHistoryV1"] mutableCopy] ?: [NSMutableArray new];
    // Apply values before acknowledging locally. A crash can then retry safely.
    for (NSDictionary *r in response[@"records"]) {
        NSString *kind = r[@"kind"], *key = r[@"key"], *entry = EntryKey(kind, key);
        scope[@"revisions"][entry] = r[@"revision"];
        if (scope[@"pending"][entry]) continue;
        BOOL deleted = [r[@"deleted"] boolValue];
        if ([kind isEqual:@"preference"]) {
            if (deleted) [self.defaults removeObjectForKey:key]; else [self.defaults setObject:r[@"value"] forKey:key];
            continue;
        }
        NSMutableArray *rows = [kind isEqual:@"favorite"] ? favorites : history;
        NSIndexSet *matches = [rows indexesOfObjectsPassingTest:^BOOL(id row, NSUInteger i, BOOL *stop) {
            return [row isKindOfClass:NSDictionary.class] && [row[@"host"] isEqual:host] && [row[@"library"] isEqual:library] && [row[@"item"] isKindOfClass:NSDictionary.class] && [row[@"item"][@"path"] isEqual:key];
        }];
        [rows removeObjectsAtIndexes:matches];
        if (!deleted) {
            NSMutableDictionary *row = [r[@"value"] mutableCopy]; row[@"host"] = host; row[@"library"] = library;
            NSMutableDictionary *item = [row[@"item"] mutableCopy];
            item[@"directory"] = @([item[@"directory"] boolValue]); item[@"video"] = @([item[@"video"] boolValue]); row[@"item"] = item;
            [rows addObject:row];
        }
        if ([kind isEqual:@"history"]) {
            NSString *progress = LCProgressKey(host, library, key);
            if (deleted) [self.defaults removeObjectForKey:progress]; else [self.defaults setDouble:[r[@"value"][@"position"] doubleValue] forKey:progress];
        }
    }
    NSArray *sort = @[[NSSortDescriptor sortDescriptorWithKey:@"updated" ascending:NO]];
    [favorites sortUsingDescriptors:sort]; [history sortUsingDescriptors:sort];
    // Keep the existing history display bound; server retains the durable records.
    if (history.count > 100) [history removeObjectsInRange:NSMakeRange(100, history.count - 100)];
    [self.defaults setObject:favorites forKey:@"favoritesV1"];
    [self.defaults setObject:history forKey:@"playbackHistoryV1"];
    scope[@"revision"] = response[@"revision"];
    scope[@"lastSync"] = @(NSDate.date.timeIntervalSince1970);
    [self.defaults setObject:state forKey:StateKey];
    return YES;
}
- (NSUInteger)pendingForHost:(NSString *)host library:(NSString *)library {
    return [[self.defaults dictionaryForKey:StateKey][@"scopes"][ScopeKey(host, library)][@"pending"] count];
}
- (NSDate *)lastSyncForHost:(NSString *)host library:(NSString *)library {
    NSNumber *date = [self.defaults dictionaryForKey:StateKey][@"scopes"][ScopeKey(host, library)][@"lastSync"];
    return date ? [NSDate dateWithTimeIntervalSince1970:date.doubleValue] : nil;
}
@end
