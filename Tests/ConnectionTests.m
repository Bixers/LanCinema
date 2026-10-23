#import <XCTest/XCTest.h>
#import <CoreImage/CoreImage.h>
#import "../App/Connection.h"

@interface ConnectionTests : XCTestCase
@end
@implementation ConnectionTests
- (void)testQRCodeImageDecodesConnection {
    NSString *file = [[NSBundle bundleForClass:self.class] pathForResource:@"connection-qr" ofType:@"png"];
    UIImage *image = [UIImage imageWithContentsOfFile:file];
    XCTAssertNotNil(image);
    NSString *value = LCQRCodeFromImage(image);
    XCTAssertNotNil(value);
    XCTAssertEqualObjects(LCParseQR(value)[@"password"], @"abc+& password");
    XCTAssertEqualObjects(LCParseQR(value)[@"host"], @"192.168.1.7");
}
- (void)testPasswordPersistsInKeychain {
    XCTAssertTrue(LCStorePassword(@"ui-test-access-code"));
    XCTAssertEqualObjects(LCPassword(), @"ui-test-access-code");
}
- (void)testRejectsForeignAndMalformedCodes {
    XCTAssertNil(LCParseQR(@"lancinema://connect?v=1&port=8123&password=password"));
    for (NSString *code in @[@"https://example.com/", @"lancinema://connect?v=1&host=8.8.8.8&port=8123&password=password", @"lancinema://connect?v=1&host=192.168.1.2&port=80&password=password", @"lancinema://connect?v=1&host=192.168.1.2&host=192.168.1.3&port=8123&password=password"]) XCTAssertNil(LCParseQR(code));
}
@end
