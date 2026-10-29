#import <XCTest/XCTest.h>
#import <CoreText/CoreText.h>

@interface SubtitleFontTests : XCTestCase
@end
@implementation SubtitleFontTests
- (void)testRegisteredSubtitleFontUsesBundledFileAndHasChineseGlyphs {
    NSURL *resource = [NSBundle.mainBundle URLForResource:@"NotoSansCJKsc-Regular" withExtension:@"otf"];
    XCTAssertNotNil(resource);
    CTFontRef font = CTFontCreateWithName(CFSTR("NotoSansCJKsc-Regular"), 24, NULL);
    NSURL *resolved = CFBridgingRelease(CTFontCopyAttribute(font, kCTFontURLAttribute));
    XCTAssertEqualObjects(resolved.URLByResolvingSymlinksInPath.path, resource.URLByResolvingSymlinksInPath.path);
    NSString *sample = @"中文字幕显示正常繁體字幕測試成功こんにちは字幕한국어";
    UniChar characters[sample.length];
    CGGlyph glyphs[sample.length];
    [sample getCharacters:characters range:NSMakeRange(0, sample.length)];
    XCTAssertTrue(CTFontGetGlyphsForCharacters(font, characters, glyphs, sample.length));
    for (NSUInteger i = 0; i < sample.length; i++) XCTAssertNotEqual(glyphs[i], 0);
    CFRelease(font);
}
@end
