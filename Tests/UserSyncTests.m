#import <XCTest/XCTest.h>
#import "../App/UserSync.h"
#import "../App/Favorites.h"

@interface UserSyncTests : XCTestCase
@property(nonatomic, strong) NSUserDefaults *defaults;
@property(nonatomic, strong) LCUserSyncStore *store;
@property(nonatomic, copy) NSString *suite;
@end
@implementation UserSyncTests
- (void)setUp {
    self.suite = [@"sync-tests." stringByAppendingString:NSUUID.UUID.UUIDString];
    self.defaults = [[NSUserDefaults alloc] initWithSuiteName:self.suite];
    self.store = [[LCUserSyncStore alloc] initWithDefaults:self.defaults];
}
- (void)tearDown { [self.defaults removePersistentDomainForName:self.suite]; }
- (NSDictionary *)value { return @{@"item":@{@"path":@"A/movie.mkv", @"name":@"movie.mkv", @"video":@YES, @"directory":@NO}, @"updated":@100}; }
- (NSDictionary *)response:(NSDictionary *)request records:(NSArray *)records revision:(NSNumber *)revision {
    return @{@"protocol":@1, @"serverID":@"pc-identity", @"libraryID":@"lib", @"revision":revision,
             @"acknowledged":[request[@"operations"] valueForKey:@"id"], @"records":records};
}
- (NSDictionary *)record:(BOOL)deleted revision:(NSNumber *)revision {
    return @{@"kind":@"favorite", @"key":@"A/movie.mkv", @"deleted":@(deleted), @"revision":revision, @"value":self.value};
}
- (void)handshake:(NSString *)host {
    NSDictionary *request = [self.store requestForHost:host library:@"lib"];
    XCTAssertEqual([request[@"operations"] count], 0);
    XCTAssertTrue([self.store applyResponse:[self response:request records:@[] revision:@0] request:request host:host library:@"lib"]);
}
- (void)testMigrationBackupHandshakeAndDurableQueue {
    LCFavorites *favorites = [[LCFavorites alloc] initWithDefaults:self.defaults];
    [favorites addItem:self.value[@"item"] host:@"pc" library:@"lib"];
    NSArray *original = [self.defaults arrayForKey:@"favoritesV1"];
    [self handshake:@"pc"];
    XCTAssertEqualObjects([self.defaults dictionaryForKey:@"userSyncMigrationBackupV1"][@"favoritesV1"], original);
    self.store = [[LCUserSyncStore alloc] initWithDefaults:self.defaults];
    NSDictionary *request = [self.store requestForHost:@"pc" library:@"lib"];
    XCTAssertEqual([request[@"operations"] count], 1);
    XCTAssertEqualObjects(request[@"operations"][0][@"mode"], @"seed");
    XCTAssertTrue([self.store applyResponse:[self response:request records:@[[self record:NO revision:@1]] revision:@1] request:request host:@"pc" library:@"lib"]);
    XCTAssertEqual([self.store pendingForHost:@"pc" library:@"lib"], 0);
    XCTAssertTrue([favorites containsPath:@"A/movie.mkv" host:@"pc" library:@"lib"]);
    XCTAssertEqualObjects([self.defaults dictionaryForKey:@"userSyncMigrationBackupV1"][@"favoritesV1"], original);
}
- (void)testAcknowledgementCannotDropANewerLocalEdit {
    [self handshake:@"pc"];
    [self.store queueKind:@"favorite" key:@"A/movie.mkv" value:self.value host:@"pc" library:@"lib"];
    NSDictionary *sent = [self.store requestForHost:@"pc" library:@"lib"];
    // C comparisons box as NSNumber integers; the wire protocol needs a JSON
    // boolean even after the operation has round-tripped through defaults.
    NSDictionary *wire = [NSJSONSerialization JSONObjectWithData:[NSJSONSerialization dataWithJSONObject:sent options:0 error:nil] options:0 error:nil];
    XCTAssertEqual(CFGetTypeID((__bridge CFTypeRef)wire[@"operations"][0][@"deleted"]), CFBooleanGetTypeID());
    [self.store queueKind:@"favorite" key:@"A/movie.mkv" value:nil host:@"pc" library:@"lib"];
    XCTAssertTrue([self.store applyResponse:[self response:sent records:@[[self record:NO revision:@1]] revision:@1] request:sent host:@"pc" library:@"lib"]);
    NSDictionary *next = [self.store requestForHost:@"pc" library:@"lib"];
    XCTAssertEqual([next[@"operations"] count], 1);
    XCTAssertTrue([next[@"operations"][0][@"deleted"] boolValue]);
    XCTAssertEqual(CFGetTypeID((__bridge CFTypeRef)next[@"operations"][0][@"deleted"]), CFBooleanGetTypeID());
    XCTAssertNotEqualObjects(sent[@"operations"][0][@"id"], next[@"operations"][0][@"id"]);
}
- (void)testRemoteTombstoneWinsOverInitialSeed {
    LCFavorites *favorites = [[LCFavorites alloc] initWithDefaults:self.defaults];
    [favorites addItem:self.value[@"item"] host:@"pc" library:@"lib"];
    [self handshake:@"pc"];
    NSDictionary *request = [self.store requestForHost:@"pc" library:@"lib"];
    XCTAssertTrue([self.store applyResponse:[self response:request records:@[[self record:YES revision:@2]] revision:@2] request:request host:@"pc" library:@"lib"]);
    XCTAssertFalse([favorites containsPath:@"A/movie.mkv" host:@"pc" library:@"lib"]);
    XCTAssertEqual([[self.defaults dictionaryForKey:@"userSyncMigrationBackupV1"][@"favoritesV1"] count], 1);
}
- (void)testMovingIPCarriesOfflineEditBeforeNewSeeds {
    [self handshake:@"old-pc"];
    [self.store queueKind:@"favorite" key:@"A/movie.mkv" value:nil host:@"old-pc" library:@"lib"];
    LCFavorites *favorites = [[LCFavorites alloc] initWithDefaults:self.defaults];
    [favorites addItem:self.value[@"item"] host:@"new-pc" library:@"lib"];
    [self handshake:@"new-pc"];
    NSDictionary *request = [self.store requestForHost:@"new-pc" library:@"lib"];
    XCTAssertEqual([request[@"operations"] count], 1);
    XCTAssertEqualObjects(request[@"operations"][0][@"mode"], @"edit");
    XCTAssertTrue([request[@"operations"][0][@"deleted"] boolValue]);
    XCTAssertEqual([self.store pendingForHost:@"old-pc" library:@"lib"], 0);
}
- (void)testWrongServerAndMalformedResponseRetainLocalData {
    [self handshake:@"pc"];
    [self.store queueKind:@"favorite" key:@"A/movie.mkv" value:self.value host:@"pc" library:@"lib"];
    NSDictionary *request = [self.store requestForHost:@"pc" library:@"lib"];
    NSMutableDictionary *response = [[self response:request records:@[] revision:@1] mutableCopy];
    response[@"serverID"] = @"another-pc";
    XCTAssertFalse([self.store applyResponse:response request:request host:@"pc" library:@"lib"]);
    response[@"serverID"] = @"pc-identity";
    response[@"records"] = @[@{@"kind":@"favorite", @"key":@"A/movie.mkv", @"revision":@1, @"deleted":@NO,
        @"value":@{@"item":@{@"path":@"A/movie.mkv", @"name":@"movie.mkv", @"video":@{}}, @"updated":@100}}];
    XCTAssertFalse([self.store applyResponse:response request:request host:@"pc" library:@"lib"]);
    response[@"records"] = @[@{@"kind":@"preference", @"key":@"computerHost", @"revision":@1, @"deleted":@YES}];
    XCTAssertFalse([self.store applyResponse:response request:request host:@"pc" library:@"lib"]);
    XCTAssertEqual([self.store pendingForHost:@"pc" library:@"lib"], 1);
}
- (void)testTSLegacyProgressMigrates {
    [self.defaults setDouble:45 forKey:@"progress:pc:lib:folder/movie.ts:ts-indexed-v1"];
    [self handshake:@"pc"];
    NSDictionary *request = [self.store requestForHost:@"pc" library:@"lib"];
    XCTAssertEqual([request[@"operations"] count], 1);
    XCTAssertEqualObjects(request[@"operations"][0][@"key"], @"folder/movie.ts");
    XCTAssertEqualObjects(request[@"operations"][0][@"value"][@"position"], @45);
}
@end
