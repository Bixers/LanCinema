#import <XCTest/XCTest.h>
#import "../App/VideoGeometry.h"

@interface VideoGeometryTests : XCTestCase
@end
@implementation VideoGeometryTests
- (NSDictionary *)crop {
    return @{@"width":@720, @"height":@1280, @"x":@100, @"y":@180, @"w":@300, @"h":@500};
}
- (void)testSmartRemovesOnlyDetectedBordersIncludingOffCenterPicture {
    XCTAssertEqualObjects(LCVideoCropGeometry(@"smart", CGSizeMake(720,1280), CGSizeMake(402,874), self.crop, 1, YES), @"100+180+320+600");
    XCTAssertEqualObjects(LCVideoCropGeometry(@"full", CGSizeMake(720,1280), CGSizeMake(402,874), self.crop, 1, YES), @"");
}
- (void)testExplicitFillUsesSampleAspectRatio {
    // Anamorphic pixels are twice as wide: a square screen needs 250x500.
    XCTAssertEqualObjects(LCVideoCropGeometry(@"fill", CGSizeMake(720,1280), CGSizeMake(400,400), self.crop, 2, YES), @"125+180+345+600");
}
- (void)testInvalidOrRotatedDetectionKeepsFullPictureInSmartMode {
    NSMutableDictionary *invalid = self.crop.mutableCopy;
    invalid[@"x"] = @600;
    for (NSDictionary *crop in @[invalid, @{}, @{@"width":@1}]) {
        XCTAssertEqualObjects(LCVideoCropGeometry(@"smart", CGSizeMake(720,1280), CGSizeMake(400,800), crop, 1, YES), @"");
    }
    XCTAssertEqualObjects(LCVideoCropGeometry(@"smart", CGSizeMake(720,1280), CGSizeMake(400,800), self.crop, 1, NO), @"");
    XCTAssertEqualObjects(LCVideoCropGeometry(@"fill", CGSizeMake(720,1280), CGSizeMake(400,800), self.crop, 1, NO), @"40000:80000");
}
@end
