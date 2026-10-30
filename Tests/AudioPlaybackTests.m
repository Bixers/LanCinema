#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MobileVLCKit/MobileVLCKit.h>
#import "../App/Connection.h"
#import "../App/AudioOutput.h"

@interface PlayerController : UIViewController
@property(nonatomic, copy) NSDictionary *item;
@property(nonatomic, strong) VLCMediaPlayer *player;
@property(nonatomic, strong) LCAudioOutput *audioOutput;
- (NSString *)progressKey;
- (void)seekToTime:(double)seconds;
- (void)togglePlay;
- (void)applyPlaybackRate;
- (void)stopPlayer;
- (void)audioInterrupted:(NSNotification *)note;
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
    PlayerController *controller = [PlayerController new];
    controller.item = @{@"path": @"演示文件夹/时间戳偏移测试.ts", @"name": @"Audio regression.ts"};
    [NSUserDefaults.standardUserDefaults setDouble:position forKey:controller.progressKey];
    controller.modalPresentationStyle = UIModalPresentationFullScreen;
    [self.window.rootViewController presentViewController:controller animated:NO completion:nil];
    XCTAssertNotNil(controller.audioOutput);
    [controller.audioOutput beginRenderProbe];
    NSLog(@"AUDIO_OPEN app=%ld scene=%ld player=%ld prepared=%@ preparing=%@ pending_active=%@", (long)UIApplication.sharedApplication.applicationState, (long)self.window.windowScene.activationState, (long)controller.player.state, [controller valueForKey:@"prepared"], [controller valueForKey:@"preparing"], [controller valueForKey:@"resumeAfterBackground"]);
    return controller;
}
- (double)checkSound:(PlayerController *)controller label:(NSString *)label {
    // Observe non-silent PCM rendered by the production AVAudioEngine mixer.
    // This is downstream of decoding and scheduling, with no replacement sink.
    [self advanceRunLoop:2];
    NSLog(@"AUDIO_STATE %@ app=%ld player=%ld media=%d prepared=%@ preparing=%@ pending_active=%@ status=%@", label, (long)UIApplication.sharedApplication.applicationState, (long)controller.player.state, controller.player.media != nil, [controller valueForKey:@"prepared"], [controller valueForKey:@"preparing"], [controller valueForKey:@"resumeAfterBackground"], [[controller valueForKey:@"statusLabel"] text]);
    double delay = controller.audioOutput.renderProbeDelay;
    NSUInteger count = controller.audioOutput.renderedNonSilentBuffers;
    double longestGap = controller.audioOutput.renderProbeLongestGap;
    NSLog(@"AUDIO_RENDER %@ first_non_silent=%.3f longest_gap=%.3f buffers=%lu time=%.3f", label, delay, longestGap, (unsigned long)count, controller.player.time.intValue/1000.0);
    XCTAssertGreaterThanOrEqual(delay, 0, @"Mixer stayed silent: %@", label);
    XCTAssertLessThan(delay, 1.0, @"Audio recovery exceeded one second: %@", label);
    XCTAssertGreaterThan(count, 5, @"Audio did not continue rendering: %@", label);
    XCTAssertLessThan(longestGap, 1.0, @"Mixer lost audio during playback: %@", label);
    return delay;
}
- (void)close:(PlayerController *)controller {
    [controller stopPlayer];
    [controller dismissViewControllerAnimated:NO completion:nil];
    [self advanceRunLoop:.1];
}
- (void)testRenderedAudioAfterOpenSeekPauseAndResume {
    PlayerController *player = [self openAt:0];
    double open = [self checkSound:player label:@"open"];
    [player.audioOutput beginRenderProbe]; [player seekToTime:39];
    double forward = [self checkSound:player label:@"forward"];
    XCTAssertEqualWithAccuracy(player.player.time.intValue/1000.0, 41, 1.5);
    [player.audioOutput beginRenderProbe]; [player seekToTime:12];
    double backward = [self checkSound:player label:@"backward"];
    [player togglePlay];
    [self advanceRunLoop:.5];
    [player.audioOutput beginRenderProbe]; [player togglePlay];
    double unpause = [self checkSound:player label:@"unpause"];
    [player togglePlay];
    [self advanceRunLoop:.3];
    [player seekToTime:20];
    [self advanceRunLoop:.3];
    [player.audioOutput beginRenderProbe]; [player togglePlay];
    double pausedSeek = [self checkSound:player label:@"paused-seek"];
    [player setValue:@2 forKey:@"selectedRate"];
    [player applyPlaybackRate]; [player.audioOutput beginRenderProbe];
    double speed = [self checkSound:player label:@"double-speed"];
    NSNotification *began = [NSNotification notificationWithName:AVAudioSessionInterruptionNotification object:nil userInfo:@{AVAudioSessionInterruptionTypeKey:@(AVAudioSessionInterruptionTypeBegan)}];
    NSNotification *ended = [NSNotification notificationWithName:AVAudioSessionInterruptionNotification object:nil userInfo:@{AVAudioSessionInterruptionTypeKey:@(AVAudioSessionInterruptionTypeEnded), AVAudioSessionInterruptionOptionKey:@(AVAudioSessionInterruptionOptionShouldResume)}];
    [player audioInterrupted:began]; [self advanceRunLoop:.3];
    XCTAssertFalse(player.player.isPlaying);
    [player.audioOutput beginRenderProbe]; [player audioInterrupted:ended];
    [self checkSound:player label:@"interruption"];
    [player togglePlay]; [self advanceRunLoop:.3];
    [player audioInterrupted:began]; [player audioInterrupted:ended];
    [self advanceRunLoop:.3];
    XCTAssertFalse(player.player.isPlaying, @"An interruption must not undo the user's pause");
    [self close:player];
    PlayerController *resumed = [self openAt:23];
    double resume = [self checkSound:resumed label:@"resume"];
    XCTAssertEqualWithAccuracy(resumed.player.time.intValue/1000.0, 25, 1.5);
    [self close:resumed];
    NSLog(@"AUDIO_RENDER summary open=%.3f forward=%.3f backward=%.3f unpause=%.3f paused_seek=%.3f speed=%.3f resume=%.3f", open, forward, backward, unpause, pausedSeek, speed, resume);
}
- (void)tearDown {
    UIViewController *presented = self.window.rootViewController.presentedViewController;
    if ([presented isKindOfClass:PlayerController.class]) [self close:(PlayerController *)presented];
    self.window.hidden = YES;
    self.window = nil;
    [super tearDown];
}
@end
