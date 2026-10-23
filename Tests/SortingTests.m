#import <XCTest/XCTest.h>
#import "../App/FileSort.h"

@interface SortingTests : XCTestCase
@end
@implementation SortingTests
- (NSDictionary *)file:(NSString *)name size:(NSInteger)size modified:(NSNumber *)modified {
    NSMutableDictionary *file = [@{@"name":name, @"path":name, @"directory":@NO, @"size":@(size)} mutableCopy];
    if (modified) file[@"modified"] = modified;
    return file;
}
- (void)testNaturalNamesAndDirectoriesStayFirst {
    NSDictionary *folder = @{@"name":@"z-folder", @"path":@"z-folder", @"directory":@YES, @"size":@0};
    NSArray *files = @[[self file:@"clip10.ts" size:1 modified:nil], [self file:@"clip2.ts" size:2 modified:nil], folder];
    XCTAssertEqualObjects([LCSortedItems(files, @"name", NO) valueForKey:@"name"], (@[@"z-folder", @"clip2.ts", @"clip10.ts"]));
    XCTAssertEqualObjects([LCSortedItems(files, @"name", YES) valueForKey:@"name"], (@[@"z-folder", @"clip10.ts", @"clip2.ts"]));
}
- (void)testSizeOrderAndDuplicateNamesRemainDeterministic {
    NSMutableDictionary *second = [[self file:@"same.ts" size:100 modified:nil] mutableCopy];
    second[@"path"] = @"b/same.ts";
    NSMutableDictionary *first = [second mutableCopy]; first[@"path"] = @"a/same.ts";
    NSArray *files = @[[self file:@"small.ts" size:2 modified:nil], second, first];
    XCTAssertEqualObjects([LCSortedItems(files, @"size", YES) valueForKey:@"path"], (@[@"b/same.ts", @"a/same.ts", @"small.ts"]));
}
- (void)testUnknownDatesFollowKnownDatesInBothDirections {
    NSArray *files = @[[self file:@"missing" size:0 modified:nil], [self file:@"old" size:0 modified:@100], [self file:@"new" size:0 modified:@200]];
    XCTAssertEqualObjects([LCSortedItems(files, @"modified", YES) valueForKey:@"name"], (@[@"new", @"old", @"missing"]));
    XCTAssertEqualObjects([LCSortedItems(files, @"modified", NO) valueForKey:@"name"], (@[@"old", @"new", @"missing"]));
}
- (void)testTypesIgnoreExtensionCase {
    NSArray *files = @[[self file:@"b.TS" size:0 modified:nil], [self file:@"a.ts" size:0 modified:nil], [self file:@"c.mkv" size:0 modified:nil]];
    XCTAssertEqualObjects([LCSortedItems(files, @"type", NO) valueForKey:@"name"], (@[@"c.mkv", @"a.ts", @"b.TS"]));
}
@end
