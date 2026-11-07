#import <XCTest/XCTest.h>
#import "../App/Favorites.h"

@interface FavoritesTests : XCTestCase
@property(nonatomic, strong) NSUserDefaults *defaults;
@property(nonatomic, strong) LCFavorites *store;
@property(nonatomic, copy) NSString *suite;
@end
@implementation FavoritesTests
- (void)setUp {
    self.suite = [@"favorites-tests." stringByAppendingString:NSUUID.UUID.UUIDString];
    self.defaults = [[NSUserDefaults alloc] initWithSuiteName:self.suite];
    self.store = [[LCFavorites alloc] initWithDefaults:self.defaults];
}
- (void)tearDown { [self.defaults removePersistentDomainForName:self.suite]; }
- (NSDictionary *)video { return @{@"path":@"A/视频+ &%#.mkv", @"name":@"视频+ &%#.mkv", @"video":@YES, @"size":@123}; }
- (void)testPersistenceAndScopeIsolation {
    [self.store addItem:self.video host:@"pc" library:@"root"];
    [self.store addItem:self.video host:@"other" library:@"root"];
    [self.store addItem:self.video host:@"pc" library:@"other-root"];
    LCFavorites *reload = [[LCFavorites alloc] initWithDefaults:self.defaults];
    XCTAssertTrue([reload containsPath:self.video[@"path"] host:@"pc" library:@"root"]);
    XCTAssertEqual([reload recordsForHost:@"pc" library:@"root"].count, 1);
    XCTAssertEqual([reload recordsForHost:@"unconnected" library:@"root"].count, 0);
    [reload removePath:self.video[@"path"] host:@"pc" library:@"root"];
    XCTAssertEqual([reload recordsForHost:@"pc" library:@"root"].count, 0);
    XCTAssertEqual([reload recordsForHost:@"other" library:@"root"].count, 1);
    XCTAssertEqual([reload recordsForHost:@"pc" library:@"other-root"].count, 1);
}
- (void)testFolderOrderingDuplicatesAndIndependentHistory {
    [self.defaults setObject:@[@"keep-history"] forKey:@"playbackHistoryV1"];
    [self.store addItem:self.video host:@"pc" library:@"root"];
    [self.store addItem:@{@"path":@"A", @"directory":@YES} host:@"pc" library:@"root"];
    [self.store addItem:self.video host:@"pc" library:@"root"];
    NSArray *records = [self.store recordsForHost:@"pc" library:@"root"];
    XCTAssertEqual(records.count, 2);
    XCTAssertEqualObjects(records[0][@"item"][@"name"], @"A");
    XCTAssertTrue([records[0][@"item"][@"directory"] boolValue]);
    XCTAssertEqualObjects(records[1][@"item"][@"path"], self.video[@"path"]);
    [self.store removePath:@"A" host:@"pc" library:@"root"];
    XCTAssertEqualObjects([self.defaults arrayForKey:@"playbackHistoryV1"], (@[@"keep-history"]));
}
- (void)testUnsupportedAndCorruptRecordsDoNotCrashOrPersist {
    [self.defaults setObject:@[@"invalid", @{@"host":@"pc", @"library":@"root", @"item":@{@"path":@3}}] forKey:@"favoritesV1"];
    XCTAssertEqual([self.store recordsForHost:@"pc" library:@"root"].count, 0);
    [self.store addItem:@{@"path":@"字幕.srt", @"subtitle":@YES} host:@"pc" library:@"root"];
    [self.store addItem:self.video host:@"pc" library:@""];
    [self.store addItem:@{@"path":@"", @"video":@YES} host:@"pc" library:@"root"];
    XCTAssertEqual([self.store recordsForHost:@"pc" library:@"root"].count, 0);
    [self.store addItem:self.video host:@"pc" library:@"root"];
    XCTAssertEqual([self.store recordsForHost:@"pc" library:@"root"].count, 1);
}
- (void)testFavoritesAreNotEvictedLikePlaybackHistory {
    for (NSInteger i=0; i<110; i++) [self.store addItem:@{@"path":[NSString stringWithFormat:@"%ld.mkv", (long)i], @"video":@YES} host:@"pc" library:@"root"];
    XCTAssertEqual([self.store recordsForHost:@"pc" library:@"root"].count, 110);
    XCTAssertTrue([self.store containsPath:@"0.mkv" host:@"pc" library:@"root"]);
}
@end
