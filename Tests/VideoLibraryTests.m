#import <XCTest/XCTest.h>
#import "../App/VideoLibrary.h"
@interface VideoLibraryTests : XCTestCase
@end
@implementation VideoLibraryTests
- (void)testAllKeywordsMatchWholePath {
    NSArray *items = @[@{@"name":@"Clip.MP4", @"path":@"盘一/中文/Clip.MP4"}, @{@"name":@"Clip.MP4", @"path":@"盘二/其他/Clip.MP4"}];
    XCTAssertEqual(LCFilterVideoItems(items, @"\n  ").count, 2);
    XCTAssertEqual(LCFilterVideoItems(items, @"中文 ＣＬＩＰ").count, 1);
    XCTAssertEqual(LCFilterVideoItems(items, @"盘二 clip").count, 1);
    XCTAssertEqual(LCFilterVideoItems(items, @"中文 other").count, 0);
}
- (void)testShuffleCoversEveryItemAndAvoidsBoundaryRepeat {
    NSMutableArray *items = [NSMutableArray new];
    for (NSInteger i=0;i<50;i++) [items addObject:@{@"path":[NSString stringWithFormat:@"%ld", (long)i]}];
    LCVideoShuffle *bag = [[LCVideoShuffle alloc] initWithItems:items]; NSString *previous;
    for (NSInteger round=0;round<4;round++) {
        NSMutableSet *paths = [NSMutableSet new];
        for (NSInteger i=0;i<50;i++) { NSString *path = [bag next][@"path"]; XCTAssertNotEqualObjects(path, previous); [paths addObject:path]; previous = path; }
        XCTAssertEqual(paths.count, 50);
    }
    XCTAssertNil([[[LCVideoShuffle alloc] initWithItems:@[]] next]);
    LCVideoShuffle *single = [[LCVideoShuffle alloc] initWithItems:@[items[0]]];
    XCTAssertEqualObjects([single next], [single next]);
}
@end
