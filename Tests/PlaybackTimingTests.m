#import <XCTest/XCTest.h>
#import "../App/PlaybackTiming.h"

@interface PlaybackTimingTests : XCTestCase
@end
@implementation PlaybackTimingTests
- (void)testCalibrationIsScopedAndBounded {
    NSString *first = NSUUID.UUID.UUIDString, *second = NSUUID.UUID.UUIDString;
    XCTAssertEqual(LCAudioDelayMilliseconds(first), 0);
    LCSetAudioDelayMilliseconds(first, 50);
    XCTAssertEqual(LCAudioDelayMilliseconds(first), 50);
    XCTAssertEqual(LCAudioDelayMilliseconds(second), 0);
    LCSetAudioDelayMilliseconds(first, -250);
    XCTAssertEqual(LCAudioDelayMilliseconds(first), -250);
    LCSetAudioDelayMilliseconds(first, NSIntegerMax);
    XCTAssertEqual(LCAudioDelayMilliseconds(first), 2000);
    LCSetAudioDelayMilliseconds(first, NSIntegerMin);
    XCTAssertEqual(LCAudioDelayMilliseconds(first), -2000);
    LCSetAudioDelayMilliseconds(first, 0);
    XCTAssertEqual(LCAudioDelayMilliseconds(first), 0);
}
@end
