#import <XCTest/XCTest.h>
#import <CoreImage/CoreImage.h>
#import "../App/Connection.h"

@interface ConnectionTests : XCTestCase
@end
@implementation ConnectionTests
- (void)testHTTPQueryPreservesPlusAndExistingEscapes {
    NSURLComponents *components = [NSURLComponents componentsWithString:@"http://127.0.0.1:8123/media"];
    NSString *path = @"中文+ 空格/&%#视频%2B+.mkv";
    NSString *password = @"a+b &%#密码";
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"path" value:path],
                             [NSURLQueryItem queryItemWithName:@"token" value:password]];
    NSURL *url = LCURLForHTTPQuery(components);
    // Rebuilding queryItems (TS preparation and search) decodes '+' again.
    components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    components.queryItems = [components.queryItems arrayByAddingObject:[NSURLQueryItem queryItemWithName:@"q" value:@"C++ %2B"]];
    url = LCURLForHTTPQuery(components);
    NSURLComponents *result = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    XCTAssertFalse([result.percentEncodedQuery containsString:@"+"]);
    XCTAssertTrue([result.percentEncodedQuery containsString:@"%2B"]);
    XCTAssertTrue([result.percentEncodedQuery containsString:@"%252B"]);
    NSMutableDictionary *values = [NSMutableDictionary new];
    for (NSURLQueryItem *item in result.queryItems) values[item.name] = item.value;
    XCTAssertEqualObjects(values[@"path"], path);
    XCTAssertEqualObjects(values[@"token"], password);
    XCTAssertEqualObjects(values[@"q"], @"C++ %2B");
}
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
