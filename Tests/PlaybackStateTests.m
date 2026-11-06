#import <XCTest/XCTest.h>
#import "../App/PlaybackHistory.h"
#import "../App/PlaybackHealth.h"

@interface PlaybackStateTests : XCTestCase
@property(nonatomic, strong) NSUserDefaults *defaults;
@property(nonatomic, strong) LCPlaybackHistory *history;
@property(nonatomic, copy) NSString *suite;
@end
@implementation PlaybackStateTests
- (void)setUp {
    self.suite = [@"history-tests." stringByAppendingString:NSUUID.UUID.UUIDString];
    self.defaults = [[NSUserDefaults alloc] initWithSuiteName:self.suite];
    self.history = [[LCPlaybackHistory alloc] initWithDefaults:self.defaults];
}
- (void)tearDown { [self.defaults removePersistentDomainForName:self.suite]; }
- (NSDictionary *)item { return @{@"path":@"A/影片.ts", @"name":@"影片.ts", @"size":@123, @"modified":@1, @"thumbnailVersion":@"v1"}; }
- (void)testHistoryPersistsAndSeparatesLibraries {
    [self.history saveItem:self.item host:@"pc" library:@"root" position:23 duration:100];
    LCPlaybackHistory *reloaded = [[LCPlaybackHistory alloc] initWithDefaults:self.defaults];
    XCTAssertEqualWithAccuracy([reloaded positionForItem:self.item host:@"pc" library:@"root"], 23, .001);
    XCTAssertEqual([reloaded recordsForHost:@"pc" library:@"root"].count, 1);
    XCTAssertEqual([reloaded recordsForHost:@"other" library:@"root"].count, 0);
    XCTAssertEqual([reloaded recordsForHost:@"pc" library:@"new-root"].count, 0);
    XCTAssertEqualWithAccuracy([self.defaults doubleForKey:LCProgressKey(@"pc", @"root", self.item[@"path"])], 23, .001);
}
- (void)testReplacementInvalidatesResumeAndRemovalClearsLegacy {
    [self.history saveItem:self.item host:@"pc" library:@"root" position:23 duration:100];
    NSMutableDictionary *replacement = [self.item mutableCopy]; replacement[@"size"] = @456;
    XCTAssertEqual([self.history positionForItem:replacement host:@"pc" library:@"root"], 0);
    XCTAssertEqual([self.history recordsForHost:@"pc" library:@"root"].count, 0);
    [self.history saveItem:self.item host:@"pc" library:@"root" position:12 duration:100];
    [self.history removePath:self.item[@"path"] host:@"pc" library:@"root"];
    XCTAssertEqual([self.history positionForItem:self.item host:@"pc" library:@"root"], 0);
}
- (void)testHistoryBoundAndLegacyTSMigration {
    NSString *key = LCProgressKey(@"pc", @"root", self.item[@"path"]);
    XCTAssertTrue([key hasSuffix:@":ts-indexed-v1"]);
    [self.defaults setDouble:14 forKey:key];
    XCTAssertEqual([self.history positionForItem:self.item host:@"pc" library:@"root"], 14);
    for (NSInteger i=0; i<105; i++) [self.history saveItem:@{@"path":[NSString stringWithFormat:@"%ld.mkv",(long)i]} host:@"pc" library:@"root" position:i+1 duration:200];
    NSArray *records = [self.history recordsForHost:@"pc" library:@"root"];
    XCTAssertEqual(records.count, 100);
    XCTAssertEqualObjects(records.firstObject[@"item"][@"path"], @"104.mkv");
    XCTAssertEqual([self.defaults doubleForKey:LCProgressKey(@"pc",@"root",@"0.mkv")], 0);
    [self.history saveItem:self.item host:@"pc" library:@"root" position:NAN duration:100];
    XCTAssertEqual([self.history recordsForHost:@"pc" library:@"root"].count, 100);
}
- (void)testClockWithoutFramesCannotConfirmSeek {
    LCPlaybackHealth *health = [LCPlaybackHealth new];
    [health beginSeek:40 frames:100 now:0];
    XCTAssertEqual([health observeTime:40 frames:100 now:.25 running:YES rate:1], LCSeekWaiting);
    XCTAssertTrue(health.pending);
    XCTAssertEqual([health observeTime:40.5 frames:110 now:.5 running:YES rate:1], LCSeekConfirmed);
    XCTAssertFalse(health.pending);
}
- (void)testLatestSeekWinsAndPausedFrameCanConfirm {
    LCPlaybackHealth *health = [LCPlaybackHealth new];
    [health beginSeek:40 frames:100 now:0];
    [health beginSeek:12 frames:110 now:1];
    XCTAssertEqual([health observeTime:40 frames:120 now:1.25 running:YES rate:1], LCSeekWaiting);
    XCTAssertEqual([health observeTime:12 frames:121 now:1.5 running:NO rate:1], LCSeekConfirmed);
    XCTAssertEqual(health.target, 12);
}
- (void)testTimeoutRetriesOnceThenFailsAndPauseExcludesBudget {
    LCPlaybackHealth *health = [LCPlaybackHealth new];
    [health beginSeek:40 frames:100 now:0];
    for (NSInteger t=0; t<30; t++) XCTAssertEqual([health observeTime:40 frames:100 now:t running:NO rate:1], LCSeekWaiting);
    for (NSInteger t=30; t<38; t++) XCTAssertEqual([health observeTime:40 frames:100 now:t running:YES rate:1], LCSeekWaiting);
    XCTAssertEqual([health observeTime:40 frames:100 now:38 running:YES rate:1], LCSeekRetry);
    [health beginRecoveryWithFrames:0 now:38];
    for (NSInteger t=38; t<50; t++) XCTAssertEqual([health observeTime:40 frames:0 now:t running:YES rate:1], LCSeekWaiting);
    XCTAssertEqual([health observeTime:40 frames:0 now:50 running:YES rate:1], LCSeekFailed);
    XCTAssertFalse(health.pending);
    XCTAssertEqual([health observeTime:40 frames:0 now:100 running:YES rate:1], LCSeekWaiting);
}
- (void)testDiagnosticReportIsBoundedAndExcludesStringValues {
    LCPlaybackDiagnostics *diagnostics = [LCPlaybackDiagnostics new];
    for (NSInteger i=0; i<200; i++) [diagnostics record:@"seek" values:@{@"target":@(i)}];
    NSString *text = [diagnostics reportWithSnapshot:(id)@{@"token":@"secret-password", @"url":@"http://private/media", @"duration":@60}];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    XCTAssertEqual([json[@"events"] count], 160);
    XCTAssertFalse([text containsString:@"secret-password"]);
    XCTAssertFalse([text containsString:@"http://private"]);
    XCTAssertEqualObjects(json[@"snapshot"][@"duration"], @60);
}
@end
