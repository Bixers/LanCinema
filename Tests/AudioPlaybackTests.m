#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MobileVLCKit/MobileVLCKit.h>
#import "../App/Connection.h"
#import "../App/PlaybackTiming.h"
#import "../App/PlaybackHistory.h"
#import "../App/PlaybackHealth.h"

@interface PlayerController : UIViewController
@property(nonatomic, copy) NSDictionary *item;
@property(nonatomic, strong) VLCMediaPlayer *player;
- (NSString *)progressKey;
- (void)seekToTime:(double)seconds;
- (void)togglePlay;
- (void)applyPlaybackRate;
- (void)stopPlayer;
- (void)audioInterrupted:(NSNotification *)note;
- (double)duration;
- (BOOL)canSeek;
- (void)restartPlaybackAt:(double)seconds;
- (void)saveProgress;
- (double)currentPlaybackTime;
- (void)changePreviewSegment;
- (void)watchFullVideo;
@end

@interface AudioPlaybackTests : XCTestCase
@property(nonatomic, strong) UIWindow *window;
@end
@implementation AudioPlaybackTests
- (void)advanceRunLoop:(double)seconds {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (until.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:MIN(.02, until.timeIntervalSinceNow)]];
    }
}
- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    // A person opens a video from an active app. Do not include XCTest's
    // foreground handoff from its UI runner in playback recovery measurements.
    NSDate *activeDeadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (UIApplication.sharedApplication.applicationState != UIApplicationStateActive && activeDeadline.timeIntervalSinceNow > 0)
        [self advanceRunLoop:.05];
    XCTAssertEqual(UIApplication.sharedApplication.applicationState, UIApplicationStateActive);
    [NSUserDefaults.standardUserDefaults setObject:@"127.0.0.1" forKey:@"computerHost"];
    [NSUserDefaults.standardUserDefaults setFloat:1 forKey:@"playbackRate"];
    XCTAssertTrue(LCStorePassword(@"ui-test-access-code"));
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
            break;
        }
    }
    XCTAssertNotNil(self.window);
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    NSString *path = [@"演示文件夹/时间戳偏移测试.ts" stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:8123/api/playback?token=ui-test-access-code&path=%@", path]];
    BOOL ready = NO;
    for (NSInteger attempt = 0; attempt < 50 && !ready; attempt++) {
        XCTestExpectation *response = [self expectationWithDescription:@"Prepare TS fixture"];
        __block NSDictionary *result;
        [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
            if (data) result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            [response fulfill];
        }] resume];
        [self waitForExpectationsWithTimeout:5 handler:nil];
        ready = [result[@"state"] isEqual:@"ready"];
        if (!ready) [self advanceRunLoop:.1];
    }
    XCTAssertTrue(ready);
}
- (PlayerController *)openAt:(double)position {
    return [self openAt:position preview:NO];
}
- (PlayerController *)openAt:(double)position preview:(BOOL)preview {
    PlayerController *controller = [PlayerController new];
    controller.item = @{@"path": @"演示文件夹/时间戳偏移测试.ts", @"name": @"Audio regression.ts"};
    [controller setValue:@(preview) forKey:@"previewMode"];
    if (!preview) {
        [LCPlaybackHistory.shared removePath:controller.item[@"path"] host:@"127.0.0.1" library:[NSUserDefaults.standardUserDefaults stringForKey:@"libraryID"]];
        [NSUserDefaults.standardUserDefaults setDouble:position forKey:controller.progressKey];
    }
    controller.modalPresentationStyle = UIModalPresentationFullScreen;
    XCTestExpectation *presented = [self expectationWithDescription:@"Player presentation finished"];
    [self.window.rootViewController presentViewController:controller animated:NO completion:^{ [presented fulfill]; }];
    [self waitForExpectationsWithTimeout:5 handler:nil];

    NSLog(@"AUDIO_OPEN app=%ld scene=%ld player=%ld prepared=%@ preparing=%@ pending_active=%@", (long)UIApplication.sharedApplication.applicationState, (long)self.window.windowScene.activationState, (long)controller.player.state, [controller valueForKey:@"prepared"], [controller valueForKey:@"preparing"], [controller valueForKey:@"resumeAfterBackground"]);
    return controller;
}
- (double)checkPlaybackProgress:(PlayerController *)controller label:(NSString *)label {
    // Native VLC owns the AudioUnit and A/V clock. These checks verify audio
    // decoding and displayed video advance together, not physical lip-sync.
    // Hardware presentation requires the synchronized flash/tone fixture.
    // An asynchronous reopen replaces media and resets its counters. Compare
    // two samples of the new input, never a new decoder with the old totals.
    [self advanceRunLoop:2];
    VLCMedia *observed = controller.player.media;
    uint64_t initialAudio = observed.statistics.decodedAudio;
    uint64_t initialPictures = observed.statistics.displayedPictures;
    [self advanceRunLoop:1];
    uint64_t audio = controller.player.media.statistics.decodedAudio;
    uint64_t pictures = controller.player.media.statistics.displayedPictures;
    NSLog(@"NATIVE_AV %@ audio=%llu pictures=%llu position=%.3f delay_us=%ld", label,
          audio, pictures, controller.player.time.intValue/1000.0,
          (long)controller.player.currentAudioPlaybackDelay);
    XCTAssertGreaterThan(audio, initialAudio, @"Audio decoding did not advance: %@", label);
    XCTAssertEqual(controller.player.media, observed, @"Input changed during the observation: %@", label);
    XCTAssertGreaterThan(pictures, initialPictures, @"Video frames did not advance: %@", label);
    XCTAssertGreaterThanOrEqual(controller.player.currentAudioTrackIndex, 0);
    XCTAssertTrue(controller.player.isPlaying);
    return 3;
}
- (void)close:(PlayerController *)controller {
    [controller stopPlayer];
    XCTestExpectation *dismissed = [self expectationWithDescription:@"Player dismissal finished"];
    [controller dismissViewControllerAnimated:NO completion:^{ [dismissed fulfill]; }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
}
- (void)testNativeAudioAndVideoAfterOpenSeekPauseAndResume {
    PlayerController *player = [self openAt:0];
    double open = [self checkPlaybackProgress:player label:@"open"];
    [player seekToTime:39];
    double forward = [self checkPlaybackProgress:player label:@"forward"];
    XCTAssertEqualWithAccuracy(player.player.time.intValue/1000.0, 41, 1.5);
    [player seekToTime:12];
    double backward = [self checkPlaybackProgress:player label:@"backward"];
    [player togglePlay];
    [self advanceRunLoop:.5];
    [player togglePlay];
    double unpause = [self checkPlaybackProgress:player label:@"unpause"];
    [player togglePlay];
    [self advanceRunLoop:.3];
    [player seekToTime:20];
    [self advanceRunLoop:.3];
    [player togglePlay];
    double pausedSeek = [self checkPlaybackProgress:player label:@"paused-seek"];
    [player setValue:@2 forKey:@"selectedRate"];
    [player applyPlaybackRate];
    double speed = [self checkPlaybackProgress:player label:@"double-speed"];
    NSNotification *began = [NSNotification notificationWithName:AVAudioSessionInterruptionNotification object:nil userInfo:@{AVAudioSessionInterruptionTypeKey:@(AVAudioSessionInterruptionTypeBegan)}];
    NSNotification *ended = [NSNotification notificationWithName:AVAudioSessionInterruptionNotification object:nil userInfo:@{AVAudioSessionInterruptionTypeKey:@(AVAudioSessionInterruptionTypeEnded), AVAudioSessionInterruptionOptionKey:@(AVAudioSessionInterruptionOptionShouldResume)}];
    [player audioInterrupted:began]; [self advanceRunLoop:.3];
    XCTAssertFalse(player.player.isPlaying);
    [player audioInterrupted:ended];
    [self checkPlaybackProgress:player label:@"interruption"];
    [player togglePlay]; [self advanceRunLoop:.3];
    [player audioInterrupted:began]; [player audioInterrupted:ended];
    [self advanceRunLoop:.3];
    XCTAssertFalse(player.player.isPlaying, @"An interruption must not undo the user's pause");
    XCTAssertFalse([[player valueForKey:@"wantsPlayback"] boolValue], @"The recovery watchdog must preserve the pause too");
    [self close:player];
    PlayerController *resumed = [self openAt:23];
    double resume = [self checkPlaybackProgress:resumed label:@"resume"];
    XCTAssertEqualWithAccuracy(resumed.player.time.intValue/1000.0, 25, 1.5);
    [self close:resumed];
    NSLog(@"NATIVE_AV observation_windows open=%.3f forward=%.3f backward=%.3f unpause=%.3f paused_seek=%.3f speed=%.3f resume=%.3f", open, forward, backward, unpause, pausedSeek, speed, resume);
}
- (void)testAudioAndSeekingAfterNaturalEnd {
    PlayerController *player = [self openAt:0];
    [self advanceRunLoop:3];
    XCTAssertTrue([player canSeek]);
    [player seekToTime:[player duration] - 1];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:12];
    while (![[player valueForKey:@"playbackEnded"] boolValue] && deadline.timeIntervalSinceNow > 0)
        [self advanceRunLoop:.05];
    XCTAssertTrue([[player valueForKey:@"playbackEnded"] boolValue]);
    XCTAssertTrue([player canSeek], @"Ended media must remain seekable in the app");
    XCTAssertGreaterThan([player duration], 59);
    [player setValue:@"演示文件夹/中文字幕验证.srt" forKey:@"selectedExternalSubtitle"];

    [player seekToTime:12];
    [self checkPlaybackProgress:player label:@"seek-after-end"];
    XCTAssertEqualWithAccuracy(player.player.time.intValue / 1000.0, 14, 1.5);
    XCTAssertFalse([[player valueForKey:@"playbackEnded"] boolValue]);
    NSLog(@"REPLAY_SUBTITLE tracks=%@ selected=%d", player.player.videoSubTitlesNames, player.player.currentVideoSubTitleIndex);
    XCTAssertGreaterThanOrEqual(player.player.currentVideoSubTitleIndex, 0);
    [self close:player];
}
- (void)testRapidSeeksAndUnconfirmedPositionNeverSaved {
    PlayerController *p = [self openAt:0]; [self advanceRunLoop:3];

    [p seekToTime:42]; [p seekToTime:8]; [p seekToTime:28];
    [self checkPlaybackProgress:p label:@"rapid-latest-seek"];
    XCTAssertEqualWithAccuracy(p.player.time.intValue/1000.0, 30, 1.5);
    [p saveProgress];
    double confirmed = [NSUserDefaults.standardUserDefaults doubleForKey:p.progressKey];
    XCTAssertGreaterThan(confirmed, 27);
    [p togglePlay]; [self advanceRunLoop:.3];
    [p seekToTime:50]; [p saveProgress];
    XCTAssertEqualWithAccuracy([NSUserDefaults.standardUserDefaults doubleForKey:p.progressKey], confirmed, .5);
    [self advanceRunLoop:1];
    XCTAssertFalse(p.player.isPlaying);
    [p togglePlay]; [self advanceRunLoop:1];
    XCTAssertEqualWithAccuracy(p.player.time.intValue/1000.0, 51, 1.5);
    [self close:p];
}
- (void)testInputRecoveryPreservesPauseAndSpeed {
    PlayerController *p = [self openAt:0]; [self advanceRunLoop:3];
    [p setValue:@2 forKey:@"selectedRate"]; [p applyPlaybackRate];
    [p restartPlaybackAt:20]; [self checkPlaybackProgress:p label:@"recovery-at-double-speed"];
    XCTAssertTrue(p.player.isPlaying);
    XCTAssertEqualWithAccuracy(p.player.rate, 2, .01);
    double settled = p.player.time.intValue/1000.0;
    XCTAssertGreaterThanOrEqual(settled, 20);
    XCTAssertLessThan(settled, 30);
    [self advanceRunLoop:1];
    XCTAssertEqualWithAccuracy(p.player.time.intValue/1000.0 - settled, 2, .8);
    [p togglePlay]; [self advanceRunLoop:.3];
    [p restartPlaybackAt:12]; [self advanceRunLoop:2];
    XCTAssertFalse(p.player.isPlaying, @"Manual recovery must preserve a user pause");
    XCTAssertGreaterThan(p.player.media.statistics.displayedPictures, 0);
    XCTAssertEqualWithAccuracy([p currentPlaybackTime], 12, 2);
    [p togglePlay]; [self advanceRunLoop:1];
    XCTAssertEqualWithAccuracy(p.player.time.intValue/1000.0, 14, 2);
    [self close:p];
}
- (void)testCalibrationReappliedAfterInputReplacement {
    PlayerController *p = [self openAt:0]; [self checkPlaybackProgress:p label:@"calibration-open"];
    LCSetAudioDelayMilliseconds(p.progressKey, 150);
    [p restartPlaybackAt:20]; [self checkPlaybackProgress:p label:@"calibration-reopen"];
    XCTAssertEqual(p.player.currentAudioPlaybackDelay, 150000);
    [p seekToTime:10]; [self checkPlaybackProgress:p label:@"calibration-seek"];
    XCTAssertEqual(p.player.currentAudioPlaybackDelay, 150000);
    LCSetAudioDelayMilliseconds(p.progressKey, 0); [self close:p];
}
- (void)testClosePreparingPreviewThenImmediatelyOpenFullVideo {
    PlayerController *preview = [self openAt:0 preview:YES];
    // UIKit must finish dismissal before its presenter can accept another
    // controller. Native audio teardown remains asynchronous across this gap.
    [self close:preview];
    PlayerController *full = [self openAt:0];
    [self checkPlaybackProgress:full label:@"close-preparing-open-full"];
    XCTAssertTrue([[preview valueForKey:@"closed"] boolValue]);
    XCTAssertFalse([[full valueForKey:@"closed"] boolValue]);
    [self close:full];
}
- (void)testPreviewBoundsHistoryIsolationAndSameInputFullPlayback {
    NSString *library = [NSUserDefaults.standardUserDefaults stringForKey:@"libraryID"] ?: @"";
    NSDictionary *item = @{@"path":@"演示文件夹/时间戳偏移测试.ts", @"name":@"Audio regression.ts"};
    [LCPlaybackHistory.shared saveItem:item host:@"127.0.0.1" library:library position:7 duration:60];
    PlayerController *p = [self openAt:0 preview:YES]; [self advanceRunLoop:5];
    XCTAssertTrue(p.player.isPlaying);
    NSArray *clips = [p valueForKey:@"previewClips"]; XCTAssertGreaterThan(clips.count, 1);
    NSUInteger first = [[p valueForKey:@"previewIndex"] unsignedIntegerValue];
    [p changePreviewSegment]; [self checkPlaybackProgress:p label:@"preview-change-segment"];
    NSUInteger second = [[p valueForKey:@"previewIndex"] unsignedIntegerValue]; XCTAssertNotEqual(first, second);
    double end = [clips[second][@"end"] doubleValue];
    [p seekToTime:end-.8]; [self advanceRunLoop:4];
    XCTAssertTrue([[p valueForKey:@"previewFinished"] boolValue]); XCTAssertFalse(p.player.isPlaying);
    XCTAssertLessThan(p.player.time.intValue/1000., end+1);
    [p saveProgress];
    XCTAssertEqualWithAccuracy([LCPlaybackHistory.shared positionForItem:item host:@"127.0.0.1" library:library], 7, .01);
    [p changePreviewSegment]; [self checkPlaybackProgress:p label:@"preview-another-segment"];
    VLCMedia *input = p.player.media;
    [p watchFullVideo];
    XCTAssertEqual(p.player.media, input, @"Watching full video should retain the running input and clock");
    XCTAssertFalse([[p valueForKey:@"previewMode"] boolValue]);
    [self checkPlaybackProgress:p label:@"preview-to-full"]; [p saveProgress];
    XCTAssertGreaterThan([LCPlaybackHistory.shared positionForItem:item host:@"127.0.0.1" library:library], 7);
    [self close:p];
}
- (void)tearDown {
    UIViewController *presented = self.window.rootViewController.presentedViewController;
    if ([presented isKindOfClass:PlayerController.class]) [self close:(PlayerController *)presented];
    self.window.hidden = YES;
    self.window = nil;
    [super tearDown];
}
@end
