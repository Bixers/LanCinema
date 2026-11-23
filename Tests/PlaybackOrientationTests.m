#import <XCTest/XCTest.h>
#import "../App/PlaybackOrientation.h"
#import <math.h>

@interface PlaybackOrientationTests : XCTestCase
@end
@implementation PlaybackOrientationTests
- (void)testPortraitRemainsUprightWithEitherPreference {
    for (NSNumber *automatic in @[@NO, @YES]) {
        XCTAssertEqual(LCPlaybackOrientationMask(CGSizeMake(1080,1920), 1, NO, automatic.boolValue), UIInterfaceOrientationMaskPortrait);
        XCTAssertEqual(LCPlaybackOrientationMask(CGSizeMake(1920,1080), 1, YES, automatic.boolValue), UIInterfaceOrientationMaskPortrait);
    }
}
- (void)testLandscapeHonorsPreferenceIncludingRotatedSource {
    for (NSNumber *automatic in @[@NO, @YES]) {
        UIInterfaceOrientationMask expected = automatic.boolValue ? UIInterfaceOrientationMaskLandscape : UIInterfaceOrientationMaskAllButUpsideDown;
        XCTAssertEqual(LCPlaybackOrientationMask(CGSizeMake(1920,1080), 1, NO, automatic.boolValue), expected);
        XCTAssertEqual(LCPlaybackOrientationMask(CGSizeMake(1080,1920), 1, YES, automatic.boolValue), expected);
        XCTAssertEqual(LCPlaybackOrientationMask(CGSizeMake(720,1280), 2, NO, automatic.boolValue), expected);
    }
    XCTAssertEqual(LCPlaybackOrientationMask(CGSizeMake(720,1280), 2, YES, YES), UIInterfaceOrientationMaskPortrait);
}
- (void)testUnusableGeometryStaysUprightAndInvalidPixelAspectFallsBack {
    XCTAssertEqual(LCPlaybackOrientationMask(CGSizeZero, 1, NO, YES), UIInterfaceOrientationMaskPortrait);
    XCTAssertEqual(LCPlaybackOrientationMask(CGSizeMake(NAN,1080), 1, NO, YES), UIInterfaceOrientationMaskPortrait);
    XCTAssertEqual(LCPlaybackOrientationMask(CGSizeMake(720,1280), NAN, NO, YES), UIInterfaceOrientationMaskPortrait);
    XCTAssertEqual(LCPlaybackOrientationMask(CGSizeMake(1920,1080), 0, NO, YES), UIInterfaceOrientationMaskLandscape);
}
@end
