#import <XCTest/XCTest.h>
#import <Vision/Vision.h>

@interface PlaybackTests : XCTestCase
@property(nonatomic, strong) XCUIApplication *app;
@end

@implementation PlaybackTests
- (void)setUp {
    self.continueAfterFailure = NO;
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
    self.app = [XCUIApplication new];
    self.app.launchArguments = [self.name containsString:@"testControlsAutoHideAndTapToggle"] ? @[@"--ui-test"] : @[@"--ui-test", @"--ui-test-keep-controls"];
    [self.app launch];
}
- (void)tearDown {
    if (self.testRun.failureCount) {
        [self capture:@"failure-screen"];
        XCTAttachment *tree = [XCTAttachment attachmentWithString:self.app.debugDescription];
        tree.name = @"failure-accessibility-tree";
        tree.lifetime = XCTAttachmentLifetimeKeepAlways;
        [self addAttachment:tree];
    }
    // A failed landscape assertion must not rotate later portrait-only checks.
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
    [super tearDown];
}
- (void)capture:(NSString *)name {
    XCTAttachment *a = [XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    a.name = name;
    a.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:a];
}
- (XCUIElement *)visibleButton:(NSString *)name {
    XCUIElementQuery *query = [self.app.buttons matchingIdentifier:name];
    // UIKit exposes an offscreen accessibility proxy for sticky table headers.
    // Use the actual hit-testable control, not the first duplicate in the tree.
    for (XCUIElement *element in query.allElementsBoundByIndex.reverseObjectEnumerator) {
        if (element.isHittable) return element;
    }
    return query.firstMatch;
}
- (void)showPlayerControls {
    XCUICoordinate *center = [self.app coordinateWithNormalizedOffset:CGVectorMake(.5,.5)];
    XCUIElement *close = self.app.buttons[@"关闭播放器"];
    if (!close.exists || !close.isHittable) [center tap];
}
- (void)closePlayback {
    [self showPlayerControls];
    // Freeze the hide timer before the slower XCTest snapshot/tap sequence.
    if (self.app.buttons[@"暂停"].isHittable) [self.app.buttons[@"暂停"] tap];
    [self.app.buttons[@"关闭播放器"] tap];
}
- (void)testContinueWatchingPersistenceAndCompletion {
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:20]);
    [self.app.buttons[@"continueWatching"] tap];
    NSPredicate *emptyHistory = [NSPredicate predicateWithFormat:@"label CONTAINS %@", @"还没有未看完"];
    XCTAssertTrue([self.app.staticTexts matchingPredicate:emptyHistory].firstMatch.exists);
    [self capture:@"history-empty"];
    [[self.app.navigationBars.buttons elementBoundByIndex:0] tap];
    [self.app.staticTexts[@"演示文件夹"] tap];
    [self.app.staticTexts[@"时间戳偏移测试.ts"] tap];
    [self waitForPlaybackSecondsFrom:1 to:20];
    [self.app.sliders[@"播放进度"] adjustToNormalizedSliderPosition:.3];
    [self waitForPlaybackSecondsFrom:16 to:26];
    [self assertVideoFramesAdvance:@"history-confirmed-frames"];
    [self closePlayback];
    [self.app.buttons[@"continueWatching"] tap];
    XCTAssertTrue([self.app.staticTexts[@"时间戳偏移测试.ts"] waitForExistenceWithTimeout:10]);
    XCTAssertTrue(self.app.buttons[@"编辑"].exists);
    [self capture:@"history-portrait"];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    [self capture:@"history-landscape"];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
    [self.app terminate]; self.app.launchArguments = @[@"--ui-test-keep-controls"]; [self.app launch];
    XCTAssertTrue([self.app.buttons[@"continueWatching"] waitForExistenceWithTimeout:20]);
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:20]);
    [self.app.buttons[@"continueWatching"] tap];
    [self.app.staticTexts[@"时间戳偏移测试.ts"] tap];
    [self waitForPlaybackSecondsFrom:16 to:40];
    [self assertVideoFramesAdvance:@"history-resumed-frames"];
    [self.app.sliders[@"播放进度"] adjustToNormalizedSliderPosition:.98];
    XCTAssertTrue([self.app.buttons[@"重新播放"] waitForExistenceWithTimeout:15]);
    [self closePlayback];
    XCTAssertFalse(self.app.staticTexts[@"时间戳偏移测试.ts"].exists);
    [self capture:@"history-completed-removed"];
}
- (void)favoriteElement:(XCUIElement *)element action:(NSString *)action {
    XCTAssertTrue([element waitForExistenceWithTimeout:15]);
    [element pressForDuration:1.1];
    XCUIElement *command = self.app.buttons[action];
    XCTAssertTrue([command waitForExistenceWithTimeout:5]);
    [command tap];
}
- (void)testFavoritesDetailsPersistenceAndOpen {
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:20]);
    [self.app.buttons[@"favorites"] tap];
    NSPredicate *emptyFavorites = [NSPredicate predicateWithFormat:@"label CONTAINS %@", @"还没有收藏"];
    XCTAssertTrue([self.app.staticTexts matchingPredicate:emptyFavorites].firstMatch.exists);
    [self capture:@"favorites-empty"];
    [[self.app.navigationBars.buttons elementBoundByIndex:0] tap];
    [self favoriteElement:self.app.staticTexts[@"演示文件夹"] action:@"加入收藏"];
    XCTAssertTrue(self.app.staticTexts[@"已收藏"].exists);
    [self capture:@"favorites-browser-details"];
    [self.app.staticTexts[@"演示文件夹"] tap];
    [self favoriteElement:self.app.staticTexts[@"时间戳偏移测试.ts"] action:@"加入收藏"];
    [self.app.buttons[@"favorites"] tap];
    XCTAssertEqual(self.app.tables[@"favoritesList"].cells.count, 2);
    [self capture:@"favorites-portrait"];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    [self capture:@"favorites-landscape"];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
    [self.app terminate]; self.app.launchArguments = @[@"--ui-test-keep-controls"]; [self.app launch];
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:20]);
    [self.app.buttons[@"favorites"] tap];
    XCTAssertEqual(self.app.tables[@"favoritesList"].cells.count, 2);
    [self.app.staticTexts[@"演示文件夹"] tap];
    XCTAssertTrue([self.app.staticTexts[@"下一层"] waitForExistenceWithTimeout:15]);
    [[self.app.navigationBars.buttons elementBoundByIndex:0] tap];
    XCTAssertTrue([self.app.tables[@"favoritesList"] waitForExistenceWithTimeout:5]);
    [self.app.staticTexts[@"时间戳偏移测试.ts"] tap];
    [self waitForPlaybackSecondsFrom:1 to:30];
    [self assertVideoFramesAdvance:@"favorites-open-video"];
    [self closePlayback];
    [[self.app.cells containingType:XCUIElementTypeStaticText identifier:@"时间戳偏移测试.ts"].firstMatch swipeLeft];
    [self.app.buttons[@"取消收藏"] tap];
    XCTAssertEqual(self.app.tables[@"favoritesList"].cells.count, 1);
    [self.app.buttons[@"编辑"] tap];
    // The standard editing delete control opens the localized confirmation.
    XCUIElement *deleteButton = self.app.cells.firstMatch.buttons.firstMatch;
    [deleteButton tap];
    [self.app.buttons[@"取消收藏"] tap];
    XCTAssertEqual(self.app.tables[@"favoritesList"].cells.count, 0);
    [[self.app.navigationBars.buttons elementBoundByIndex:0] tap];
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:15]);
    XCTAssertFalse(self.app.staticTexts[@"已收藏"].exists);
}
- (void)testFavoritesIconsSearchAndRemove {
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:20]);
    [[self visibleButton:@"文件视图"] tap]; [[self visibleButton:@"图标"] tap];
    [self favoriteElement:[self visibleButton:@"演示文件夹"] action:@"加入收藏"];
    XCTAssertTrue([[self visibleButton:@"演示文件夹"].value containsString:@"已收藏"]);
    [self capture:@"favorites-browser-icons"];
    [self favoriteElement:[self visibleButton:@"演示文件夹"] action:@"取消收藏"];
    XCTAssertFalse([[self visibleButton:@"演示文件夹"].value containsString:@"已收藏"]);
    [self.app.searchFields.firstMatch tap]; [self.app.searchFields.firstMatch typeText:@"重复名称.mkv\n"];
    XCUIElementQuery *hits = [self.app.buttons matchingIdentifier:@"重复名称.mkv"];
    XCTAssertTrue([hits.firstMatch waitForExistenceWithTimeout:20]);
    XCTAssertEqual(hits.count, 2);
    [self favoriteElement:hits.firstMatch action:@"加入收藏"];
    NSUInteger saved = 0;
    for (XCUIElement *hit in hits.allElementsBoundByIndex) if ([(NSString *)hit.value containsString:@"已收藏"]) saved++;
    XCTAssertEqual(saved, 1);
    [self capture:@"favorites-search"];
    [self.app terminate]; self.app.launchArguments = @[]; [self.app launch];
    XCTAssertTrue([[self visibleButton:@"演示文件夹"] waitForExistenceWithTimeout:20]);
    [self.app.buttons[@"favorites"] tap];
    XCTAssertEqual(self.app.tables[@"favoritesList"].cells.count, 1);
    XCTAssertTrue(self.app.staticTexts[@"重复名称.mkv"].exists);
    NSPredicate *parentPath = [NSPredicate predicateWithFormat:@"label CONTAINS %@", @"位置：符号+ &%# 测试/"];
    XCTAssertTrue([self.app.staticTexts matchingPredicate:parentPath].firstMatch.exists);
}
- (void)testFavoritesAccessibleAppearance {
    NSString *longFolder = @"这是用于检查完整换行显示的长文件夹名称包含中文和English并且不应该出现省略号这些文字都应当可见";
    XCTAssertTrue([self.app.staticTexts[longFolder] waitForExistenceWithTimeout:20]);
    [self favoriteElement:self.app.staticTexts[longFolder] action:@"加入收藏"];
    [self.app terminate]; self.app.launchArguments = @[@"--ui-test-dark", @"--ui-test-large"]; [self.app launch];
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:20]);
    [self.app.buttons[@"favorites"] tap];
    XCTAssertTrue([self.app.staticTexts[longFolder] waitForExistenceWithTimeout:5]);
    XCTAssertFalse(self.app.staticTexts[@"favoritesFootnote"].isHittable, @"Instructions must stay after the long row, not pin over it");
    [self capture:@"favorites-dark-large"];
    for (NSInteger i = 0; i < 5 && !self.app.staticTexts[@"favoritesFootnote"].isHittable; i++) [self.app.tables.firstMatch swipeUp];
    XCTAssertTrue(self.app.staticTexts[@"favoritesFootnote"].isHittable);
    [self capture:@"favorites-dark-footer"];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    [self.app.tables.firstMatch swipeDown]; [self capture:@"favorites-dark-landscape"];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
    [self.app.tables.firstMatch swipeDown];
    [self.app.cells.firstMatch swipeLeft]; [self.app.buttons[@"取消收藏"] tap];
    [self capture:@"favorites-dark-empty"];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    [self capture:@"favorites-dark-empty-landscape"];
}
- (void)testDiagnosticsAndHistoryAccessibleAppearance {
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:20]);
    [self.app.staticTexts[@"演示文件夹"] tap];
    XCUIElement *movie = [self.app.cells containingType:XCUIElementTypeStaticText identifier:@"测试视频.mkv"].firstMatch;
    XCTAssertTrue([movie waitForExistenceWithTimeout:10]);
    // Keep the row clear of iOS 26's floating search and toolbar before tapping.
    for (NSInteger i = 0; i < 5 && CGRectGetMaxY(movie.frame) > self.app.frame.size.height - 180; i++) {
        [[self.app coordinateWithNormalizedOffset:CGVectorMake(.5,.65)] pressForDuration:.05
            thenDragToCoordinate:[self.app coordinateWithNormalizedOffset:CGVectorMake(.5,.4)]];
    }
    [self capture:@"diagnostics-movie-selection"];
    [movie tap];
    XCTAssertTrue([self.app.otherElements[@"playerGestureSurface"] waitForExistenceWithTimeout:10]);
    [self waitForPlaybackSecondsFrom:3 to:30];
    [self.app.buttons[@"暂停"] tap];
    [self.app.buttons[@"播放诊断"] tap];
    XCTAssertTrue([self.app.textViews[@"diagnosticReport"] waitForExistenceWithTimeout:5]);
    [self.app.buttons[@"检查连接"] tap];
    NSPredicate *checked = [NSPredicate predicateWithFormat:@"value CONTAINS %@", @"HTTP 206"];
    [self expectationForPredicate:checked evaluatedWithObject:self.app.textViews[@"diagnosticReport"] handler:nil];
    [self waitForExpectationsWithTimeout:12 handler:nil];
    [self capture:@"diagnostics-portrait"];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    [self capture:@"diagnostics-landscape"];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
    [self.app.buttons[@"重新打开视频"] tap];
    XCTAssertTrue([self.app.buttons[@"播放"] waitForExistenceWithTimeout:12]);
    [self closePlayback];
    [self.app terminate]; self.app.launchArguments = @[@"--ui-test-dark", @"--ui-test-large", @"--ui-test-keep-controls"]; [self.app launch];
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:20]);
    [self.app.buttons[@"continueWatching"] tap];
    XCTAssertTrue([self.app.staticTexts[@"测试视频.mkv"] waitForExistenceWithTimeout:5]);
    [self capture:@"history-dark-large"];
    [self.app.tables.firstMatch swipeUp];
    [self capture:@"history-dark-footer"];
    [self.app.tables.firstMatch swipeDown];
    [[self.app.cells elementBoundByIndex:0] swipeLeft];
    [self.app.buttons[@"移除记录"] tap];
    XCTAssertFalse(self.app.staticTexts[@"测试视频.mkv"].exists);
    [self capture:@"history-dark-empty"];
}
- (void)testChineseExternalSubtitleRendering {
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:20]);
    [self.app.staticTexts[@"演示文件夹"] tap];
    XCUIElement *movie = self.app.staticTexts[@"字幕字形测试.mkv"];
    XCTAssertTrue([movie waitForExistenceWithTimeout:10]);
    [movie tap];
    [self waitForPlaybackSecondsFrom:1 to:50];
    [self.app.buttons[@"字幕和音轨"] tap];
    [self.app.buttons[@"外挂 · 中文字幕验证.srt"] tap];
    [[self.app coordinateWithNormalizedOffset:CGVectorMake(.5,.5)] tap];
    [self assertReadableChineseSubtitle:@"chinese-subtitle-rendered"];
    [self closePlayback];
}
- (void)assertReadableChineseSubtitle:(NSString *)name {
    BOOL recognized = NO;
    for (NSInteger attempt = 0; attempt < 8 && !recognized; attempt++) {
        XCTestExpectation *settled = [self expectationWithDescription:@"Subtitle frame rendered"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [settled fulfill]; });
        [self waitForExpectationsWithTimeout:3 handler:nil];
        VNRecognizeTextRequest *request = [VNRecognizeTextRequest new];
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        request.recognitionLanguages = @[@"zh-Hans", @"zh-Hant", @"en-US"];
        request.usesLanguageCorrection = NO;
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:self.app.screenshot.image.CGImage options:@{}];
        NSError *error;
        XCTAssertTrue([handler performRequests:@[request] error:&error], @"%@", error);
        NSMutableString *text = [NSMutableString new];
        for (VNRecognizedTextObservation *line in request.results) [text appendString:[line topCandidates:1].firstObject.string ?: @""];
        NSString *compact = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];
        NSLog(@"SUBTITLE_OCR %@", compact);
        recognized = ([compact containsString:@"中文字幕显示正常"] || [compact containsString:@"中文字幕顯示正常"]) &&
                     ([compact containsString:@"繁體字幕測試成功"] || [compact containsString:@"繁体字幕测试成功"]);
    }
    [self capture:name];
    XCTAssertTrue(recognized, @"Rendered subtitle must contain readable Chinese, not missing-glyph squares");
}
- (void)testSmartCropKeepsSubtitlesVisible {
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:20]);
    [self.app.staticTexts[@"演示文件夹"] tap];
    [self.app.staticTexts[@"偏心黑边字幕测试.mkv"] tap];
    [self waitForPlaybackSecondsFrom:1 to:50];
    [self.app.buttons[@"字幕和音轨"] tap];
    [self.app.buttons[@"外挂 · 偏心画面字幕.srt"] tap];
    [[self.app coordinateWithNormalizedOffset:CGVectorMake(.5,.5)] tap];
    [self assertReadableChineseSubtitle:@"smart-subtitle-fit"];
    [self showPlayerControls];
    [self.app.buttons[@"画面显示方式"] tap];
    [self.app.buttons[@"裁切铺满"] tap];
    [[self.app coordinateWithNormalizedOffset:CGVectorMake(.5,.5)] tap];
    [self assertReadableChineseSubtitle:@"smart-subtitle-fill"];
    [self showPlayerControls];
    [self.app.buttons[@"画面显示方式"] tap];
    [self.app.buttons[@"完整显示"] tap];
    [[self.app coordinateWithNormalizedOffset:CGVectorMake(.5,.5)] tap];
    [self assertReadableChineseSubtitle:@"smart-subtitle-full"];
    [self closePlayback];
}
- (void)testSortingMenuAndSavedChoice {
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:20]);
    XCUIElement *sort = self.app.buttons[@"排序"];
    [sort tap];
    [self capture:@"sorting-menu"];
    [self.app.buttons[@"大小"] tap];
    [sort tap];
    [self.app.buttons[@"从大到小"] tap];
    XCTAssertEqualObjects(sort.value, @"大小 · 从大到小");
    [self.app.staticTexts[@"演示文件夹"] tap];
    XCTAssertEqualObjects(sort.value, @"大小 · 从大到小");
    XCTAssertTrue([self.app.cells elementBoundByIndex:0].staticTexts[@"下一层"].exists);
    [sort tap];
    [self.app.buttons[@"修改时间"] tap];
    XCTAssertEqualObjects(sort.value, @"修改时间 · 最新在前");
    [self capture:@"sorting-modified"];
    [self.app terminate];
    // Preserve the defaults written by the real sorting menu across relaunch.
    self.app.launchArguments = @[];
    [self.app launch];
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:20]);
    XCTAssertEqualObjects(self.app.buttons[@"排序"].value, @"修改时间 · 最新在前");
    [self.app terminate];
    self.app.launchArguments = @[@"--ui-test-dark", @"--ui-test-large"];
    [self.app launch];
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:20]);
    [self.app.staticTexts[@"演示文件夹"] tap];
    [self capture:@"sorting-dark-large-list"];
    [self.app.buttons[@"排序"] tap];
    [self capture:@"sorting-dark-large-menu"];
    XCTAssertTrue(self.app.buttons[@"修改时间"].exists);
}
- (NSData *)videoPixels {
    CGImageRef image = self.app.screenshot.image.CGImage;
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    // Both moving fixtures are 16:9. Sample the middle 80% of the
    // actual fitted picture, excluding the intentional portrait letterboxing.
    CGFloat pictureHeight = MIN((CGFloat)height, width*9.0/16.0);
    CGImageRef crop = CGImageCreateWithImageInRect(image, CGRectMake(width*.1, (height-pictureHeight*.8)/2, width*.8, pictureHeight*.8));
    NSMutableData *pixels = [NSMutableData dataWithLength:64*64*4];
    CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, 64, 64, 8, 64*4, colors, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(context, CGRectMake(0,0,64,64), crop);
    CGContextRelease(context); CGColorSpaceRelease(colors); CGImageRelease(crop);
    return pixels;
}
- (void)assertVideoFramesAdvance:(NSString *)name {
    NSData *previous = [self videoPixels];
    BOOL moving = NO;
    for (NSInteger attempt = 0; attempt < 8 && !moving; attempt++) {
        XCTestExpectation *delay = [self expectationWithDescription:@"Observe decoded video frames"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [delay fulfill]; });
        [self waitForExpectationsWithTimeout:3 handler:nil];
        NSData *current = [self videoPixels];
        const unsigned char *a = previous.bytes, *b = current.bytes;
        NSUInteger changed = 0, colorful = 0, previousColorful = 0;
        for (NSUInteger i = 0; i < 64*64; i++) {
            if (MAX(b[i*4], MAX(b[i*4+1], b[i*4+2])) - MIN(b[i*4], MIN(b[i*4+1], b[i*4+2])) > 60) colorful++;
            if (MAX(a[i*4], MAX(a[i*4+1], a[i*4+2])) - MIN(a[i*4], MIN(a[i*4+1], a[i*4+2])) > 60) previousColorful++;
            if (abs(a[i*4]-b[i*4]) + abs(a[i*4+1]-b[i*4+1]) + abs(a[i*4+2]-b[i*4+2]) > 75) changed++;
        }
        // testsrc2 fills this crop with saturated colors. Gray decoder corruption
        // must fail even when a small undamaged part of the frame keeps moving.
        moving = colorful > 64*64*.8 && previousColorful > 64*64*.8 && changed > 64*64*.025;
        NSLog(@"Video pixels %@: color %.3f previous %.3f motion %.3f", name, colorful/4096.0, previousColorful/4096.0, changed/4096.0);
        previous = current;
    }
    [self capture:name];
    XCTAssertTrue(moving, @"Decoded video stayed frozen or gray: %@", name);
}
- (void)waitForPlaybackSecondsFrom:(double)minimum to:(double)maximum {
    XCUIElement *time = self.app.otherElements[@"playerGestureSurface"];
    NSPredicate *position = [NSPredicate predicateWithBlock:^BOOL(XCUIElement *element, NSDictionary *bindings) {
        if (!element.exists) return NO;
        NSArray *parts = [[element.value componentsSeparatedByString:@" / "].firstObject componentsSeparatedByString:@":"];
        if (parts.count != 2) return NO;
        double seconds = [parts[0] doubleValue] * 60 + [parts[1] doubleValue];
        return seconds >= minimum && seconds <= maximum;
    }];
    [self expectationForPredicate:position evaluatedWithObject:time handler:nil];
    [self waitForExpectationsWithTimeout:15 handler:nil];
    NSLog(@"Playback time verified: %@ (expected %.0f–%.0f seconds)", time.value, minimum, maximum);
}
- (double)displayedPlaybackSeconds {
    NSArray *parts = [[self.app.otherElements[@"playerGestureSurface"].value componentsSeparatedByString:@" / "].firstObject componentsSeparatedByString:@":"];
    XCTAssertEqual(parts.count, 2);
    return [parts[0] doubleValue] * 60 + [parts[1] doubleValue];
}
- (void)waitForControlsVisible:(BOOL)visible {
    XCUIElement *close = self.app.buttons[@"关闭播放器"];
    NSPredicate *visibility = [NSPredicate predicateWithBlock:^BOOL(XCUIElement *element, NSDictionary *bindings) {
        return element.isHittable == visible && self.app.sliders[@"播放进度"].isHittable == visible;
    }];
    [self expectationForPredicate:visibility evaluatedWithObject:close handler:nil];
    [self waitForExpectationsWithTimeout:9 handler:nil];
}
- (void)openTransportStream {
    XCUIElement *folder = self.app.staticTexts[@"演示文件夹"];
    XCTAssertTrue([folder waitForExistenceWithTimeout:20]);
    [folder tap];
    [self.app.staticTexts[@"时间戳偏移测试.ts"] tap];
    [self waitForPlaybackSecondsFrom:1 to:50];
    // The real auto-hide test starts by waiting for hidden controls. Snapshot
    // calls can consume its four-second timer, so inspect enabled state only
    // in the other tests that deliberately keep the controls visible.
    if (![self.name containsString:@"testControlsAutoHideAndTapToggle"]) {
        [self showPlayerControls];
        XCTAssertTrue(self.app.sliders[@"播放进度"].enabled);
    }
}
- (void)testControlsAutoHideAndTapToggle {
    [self openTransportStream];
    [self waitForControlsVisible:NO];
    [self capture:@"controls-auto-hidden"];
    XCUICoordinate *center = [self.app coordinateWithNormalizedOffset:CGVectorMake(.5,.5)];
    [center tap];
    [self waitForControlsVisible:YES];
    [center tap];
    [self waitForControlsVisible:NO];
    [center tap];
    [self waitForControlsVisible:YES];
    [self.app.buttons[@"播放倍速"] tap];
    [self.app.buttons[@"1.5×"] tap];
    // Opening a speed menu must not leave a 30-second hiding delay behind.
    [self waitForControlsVisible:NO];
    [center tap];
    [self waitForControlsVisible:YES];
    [self.app.buttons[@"暂停"] tap];
    [center tap];
    [self waitForControlsVisible:NO];
    [center tap];
    [self waitForControlsVisible:YES];
    XCTAssertTrue(self.app.buttons[@"播放"].exists);
    XCTAssertTrue(self.app.sliders[@"播放进度"].enabled);
    [self capture:@"controls-tap-revealed"];
    [self closePlayback];
}
- (void)testExplorerAppearanceCaptures {
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:20]);
    [self capture:@"explorer-details-portrait"];
    [[self visibleButton:@"文件视图"] tap];
    [[self visibleButton:@"图标"] tap];
    [self capture:@"explorer-icons-portrait"];
    [[self visibleButton:@"演示文件夹"] tap];
    XCTAssertTrue([[self visibleButton:@"下一层"] waitForExistenceWithTimeout:10]);
    [[self visibleButton:@"文件视图"] tap];
    [[self visibleButton:@"详细信息"] tap];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    [self capture:@"explorer-details-landscape"];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
    [self.app terminate];
    self.app.launchArguments = @[@"--ui-test-dark", @"--ui-test-large"];
    [self.app launch];
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:20]);
    [self capture:@"explorer-details-dark-large"];
    [[self visibleButton:@"文件视图"] tap];
    [[self visibleButton:@"图标"] tap];
    [self capture:@"explorer-icons-dark-large"];
}
- (void)assertThumbnailPixels:(XCUIElement *)tile {
    BOOL hasFrame = NO;
    for (NSInteger attempt = 0; attempt < 12 && !hasFrame; attempt++) {
        CGImageRef source = tile.screenshot.image.CGImage;
        CGFloat width = CGImageGetWidth(source);
        // Sample only the cover area, excluding the filename and metadata.
        CGImageRef crop = CGImageCreateWithImageInRect(source, CGRectMake(width*.15, width*.12, width*.7, width*.3));
        unsigned char pixels[32*32*4] = {0};
        CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(pixels, 32, 32, 8, 32*4, color, kCGImageAlphaPremultipliedLast);
        CGContextDrawImage(context, CGRectMake(0,0,32,32), crop);
        NSUInteger red = 0, green = 0, blue = 0;
        for (NSUInteger i = 0; i < 32*32; i++) {
            int r = pixels[i*4], g = pixels[i*4+1], b = pixels[i*4+2];
            red += r > 130 && r > g+40 && r > b+40;
            green += g > 130 && g > r+40 && g > b+40;
            blue += b > 130 && b > r+40 && b > g+40;
        }
        CGContextRelease(context); CGColorSpaceRelease(color); CGImageRelease(crop);
        hasFrame = red > 30 && green > 30 && blue > 30;
        if (!hasFrame) {
            XCTestExpectation *wait = [self expectationWithDescription:@"Visible video thumbnail arrives"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [wait fulfill]; });
            [self waitForExpectationsWithTimeout:3 handler:nil];
        }
    }
    XCTAssertTrue(hasFrame, @"The tile must show multicolor video pixels, not the generic teal play icon: %@", tile.label);
}
- (void)testVideoThumbnails {
    XCTAssertTrue([self.app.staticTexts[@"符号+ &%# 测试"] waitForExistenceWithTimeout:20]);
    [self.app.staticTexts[@"符号+ &%# 测试"] tap];
    XCTAssertTrue([self.app.staticTexts[@"封面预览"] waitForExistenceWithTimeout:10]);
    [self.app.staticTexts[@"封面预览"] tap];
    [[self visibleButton:@"文件视图"] tap];
    [[self visibleButton:@"图标"] tap];
    XCUIElement *mkv = [self visibleButton:@"横屏视频.mkv"];
    XCUIElement *ts = [self visibleButton:@"长名称视频完整换行与封面同时显示.ts"];
    XCTAssertTrue([mkv waitForExistenceWithTimeout:10]);
    [self assertThumbnailPixels:mkv];
    [self assertThumbnailPixels:ts];
    XCTAssertTrue([self visibleButton:@"无法取帧.mp4"].exists);
    XCTAssertTrue([self visibleButton:@"字幕.srt"].exists);
    [self capture:@"thumbnails-icons-portrait"];
    [[self visibleButton:@"文件视图"] tap];
    [[self visibleButton:@"详细信息"] tap];
    [self capture:@"thumbnails-details-portrait"];
    [[self visibleButton:@"文件视图"] tap];
    [[self visibleButton:@"图标"] tap];
    // Cell recreation must restore the correct previews without losing labels.
    [self assertThumbnailPixels:[self visibleButton:@"横屏视频.mkv"]];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    [self capture:@"thumbnails-icons-landscape"];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
    [[self visibleButton:@"横屏视频.mkv"] tap];
    [self waitForPlaybackSecondsFrom:1 to:50];
    [self assertVideoFramesAdvance:@"thumbnail-open-video"];
    [self closePlayback];
}
- (void)testExplorerViewsNavigationAndPersistence {
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:20]);
    XCTAssertEqualObjects([self visibleButton:@"文件视图"].value, @"详细信息");
    XCTAssertFalse([self visibleButton:@"上一级文件夹"].enabled);
    [self capture:@"explorer-details-portrait"];
    [[self visibleButton:@"按大小排序"] tap];
    XCTAssertEqualObjects([self visibleButton:@"排序"].value, @"大小 · 从小到大");
    [[self visibleButton:@"按大小排序"] tap];
    XCTAssertEqualObjects([self visibleButton:@"排序"].value, @"大小 · 从大到小");
    [[self visibleButton:@"文件视图"] tap];
    [[self visibleButton:@"图标"] tap];
    XCTAssertTrue([self visibleButton:@"演示文件夹"].exists);
    [self capture:@"explorer-icons-portrait"];
    [[self visibleButton:@"演示文件夹"] tap];
    XCTAssertTrue([[self visibleButton:@"下一层"] waitForExistenceWithTimeout:10]);
    [[self visibleButton:@"下一层"] tap];
    // The committed nested fixture contains Git's placeholder, so it is not empty.
    XCTAssertTrue([[self visibleButton:@".gitkeep"] waitForExistenceWithTimeout:10]);
    XCTAssertTrue([[self visibleButton:@"文件夹路径"].value hasSuffix:@"演示文件夹/下一层"]);
    [[self visibleButton:@"文件夹路径"] tap];
    [[self visibleButton:@"演示文件夹"] tap];
    XCTAssertTrue([[self visibleButton:@"下一层"] waitForExistenceWithTimeout:10]);
    [[self visibleButton:@"上一级文件夹"] tap];
    XCTAssertTrue([[self visibleButton:@"演示文件夹"] waitForExistenceWithTimeout:10]);
    [self.app terminate];
    self.app.launchArguments = @[];
    [self.app launch];
    XCTAssertTrue([[self visibleButton:@"演示文件夹"] waitForExistenceWithTimeout:20]);
    XCTAssertEqualObjects([self visibleButton:@"文件视图"].value, @"图标");
    XCTAssertEqualObjects([self visibleButton:@"排序"].value, @"大小 · 从大到小");
    // Search from the restored icon view, including same-named files in two parents.
    [self.app.searchFields.firstMatch tap];
    [self.app.searchFields.firstMatch typeText:@"重复名称.mkv"];
    XCUIElementQuery *hits = [self.app.buttons matchingIdentifier:@"重复名称.mkv"];
    XCTAssertTrue([hits.firstMatch waitForExistenceWithTimeout:20]);
    XCTAssertEqual(hits.count, 2);
    NSMutableSet *locations = [NSMutableSet new];
    for (XCUIElement *hit in hits.allElementsBoundByIndex) {
        NSString *value = hit.value;
        XCTAssertTrue([value containsString:@"MKV 视频"]);
        XCTAssertTrue([value containsString:@"MB"]);
        if ([value hasSuffix:@"位置：符号+ &%# 测试/A"]) [locations addObject:@"A"];
        if ([value hasSuffix:@"位置：符号+ &%# 测试/B"]) [locations addObject:@"B"];
    }
    XCTAssertEqual(locations.count, 2, @"VoiceOver must distinguish identical filenames by their parent path");
    [self capture:@"explorer-icons-search-accessibility"];
    XCUIElement *video = hits.firstMatch;
    [video tap];
    [self waitForPlaybackSecondsFrom:1 to:50];
    [self assertVideoFramesAdvance:@"explorer-icon-playback"];
    [self closePlayback];
    NSString *spoken = [self visibleButton:@"重复名称.mkv"].value;
    // Either result is selectable; at least the played tile retains spoken progress.
    BOOL hasProgress = NO;
    for (XCUIElement *hit in hits.allElementsBoundByIndex) if ([(NSString *)hit.value containsString:@"上次"]) hasProgress = YES;
    XCTAssertTrue(hasProgress, @"%@", spoken);
}
- (void)testCompactLandscapeControlsAndRotation {
    [self openTransportStream];
    [self.app.buttons[@"暂停"] tap];
    CGFloat portraitHeight = self.app.otherElements[@"playerFooter"].frame.size.height;
    for (NSNumber *orientation in @[@(UIDeviceOrientationLandscapeLeft), @(UIDeviceOrientationLandscapeRight)]) {
        XCUIDevice.sharedDevice.orientation = orientation.integerValue;
        XCUIElement *footer = self.app.otherElements[@"playerFooter"];
        NSPredicate *compact = [NSPredicate predicateWithBlock:^BOOL(XCUIElement *element, NSDictionary *bindings) {
            return element.exists && element.frame.size.width > 500 && element.frame.size.height <= 60;
        }];
        [self expectationForPredicate:compact evaluatedWithObject:footer handler:nil];
        [self waitForExpectationsWithTimeout:10 handler:nil];
        XCTestExpectation *rotation = [self expectationWithDescription:@"Rotation compositor settled"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [rotation fulfill]; });
        [self waitForExpectationsWithTimeout:4 handler:nil];
        XCTAssertLessThan(footer.frame.size.height, portraitHeight * .65);
        for (NSString *label in @[@"关闭播放器", @"播放", @"后退十秒", @"前进十秒", @"播放倍速", @"字幕和音轨"])
            XCTAssertTrue(self.app.buttons[label].isHittable, @"%@ must remain accessible", label);
        XCTAssertGreaterThan(self.app.sliders[@"播放进度"].frame.size.width, 120);
        [self capture:orientation.integerValue == UIDeviceOrientationLandscapeLeft ? @"compact-landscape-left" : @"compact-landscape-right"];
    }
    [[self.app coordinateWithNormalizedOffset:CGVectorMake(.5,.5)] tap];
    [self waitForControlsVisible:NO];
    XCTAssertFalse(self.app.staticTexts[@"已暂停"].exists);
    [self capture:@"compact-paused-clean-picture"];
    [[self.app coordinateWithNormalizedOffset:CGVectorMake(.5,.5)] tap];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
    [self waitForControlsVisible:YES];
    XCTAssertGreaterThan(self.app.otherElements[@"playerFooter"].frame.size.height, 80);
    [self closePlayback];
}
- (void)finishCurrentVideo {
    [self showPlayerControls];
    [self.app.sliders[@"播放进度"] adjustToNormalizedSliderPosition:1];
    XCTAssertTrue([self.app.buttons[@"重新播放"] waitForExistenceWithTimeout:15]);
    XCTAssertTrue(self.app.sliders[@"播放进度"].enabled);
    [self capture:@"ended-seekable-timeline"];
}
- (void)testSeekAndReplayAfterVideoEnds {
    [self openTransportStream];
    [self finishCurrentVideo];
    [self.app.sliders[@"播放进度"] adjustToNormalizedSliderPosition:.3];
    [self waitForPlaybackSecondsFrom:15 to:25];
    [self assertVideoFramesAdvance:@"ended-slider-recovered-video"];
    [self finishCurrentVideo];
    XCUICoordinate *right = [self.app coordinateWithNormalizedOffset:CGVectorMake(.75,.5)];
    XCUICoordinate *left = [self.app coordinateWithNormalizedOffset:CGVectorMake(.25,.5)];
    [right pressForDuration:.05 thenDragToCoordinate:left];
    [self waitForPlaybackSecondsFrom:42 to:52];
    [self assertVideoFramesAdvance:@"ended-pan-recovered-video"];
    [self finishCurrentVideo];
    [self.app.buttons[@"重新播放"] tap];
    [self waitForPlaybackSecondsFrom:1 to:10];
    [self assertVideoFramesAdvance:@"ended-replay-from-start"];
    [self closePlayback];
}
- (void)testSubtitleAndSpeedSurviveEndRecovery {
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:20]);
    [self.app.staticTexts[@"演示文件夹"] tap];
    [self.app.staticTexts[@"字幕字形测试.mkv"] tap];
    [self waitForPlaybackSecondsFrom:1 to:50];
    [self.app.buttons[@"字幕和音轨"] tap];
    [self.app.buttons[@"外挂 · 中文字幕验证.srt"] tap];
    [self.app.buttons[@"播放倍速"] tap];
    [self.app.buttons[@"1.5×"] tap];
    [self finishCurrentVideo];
    [self.app.sliders[@"播放进度"] adjustToNormalizedSliderPosition:.2];
    [self waitForPlaybackSecondsFrom:10 to:22];
    XCTAssertEqualObjects(self.app.buttons[@"播放倍速"].value, @"1.5×");
    [[self.app coordinateWithNormalizedOffset:CGVectorMake(.5,.5)] tap];
    [self assertReadableChineseSubtitle:@"ended-subtitle-restored"];
    [self closePlayback];
}
- (void)testHorizontalCanvasSeekingWithoutGestureConflicts {
    [self openTransportStream];
    [self.app.buttons[@"暂停"] tap];
    [self.app.sliders[@"播放进度"] adjustToNormalizedSliderPosition:.3];
    // XCTest's synthesized slider drag can land a few points from its nominal
    // fraction. Measure the settled anchor, then verify canvas seek deltas.
    [self waitForPlaybackSecondsFrom:15 to:22];
    double anchor = [self displayedPlaybackSeconds];
    XCUICoordinate *left = [self.app coordinateWithNormalizedOffset:CGVectorMake(.25,.5)];
    XCUICoordinate *right = [self.app coordinateWithNormalizedOffset:CGVectorMake(.75,.5)];
    [left pressForDuration:.05 thenDragToCoordinate:right];
    [self waitForPlaybackSecondsFrom:anchor+13 to:anchor+17];
    XCTAssertTrue(self.app.buttons[@"播放"].exists);
    XCTAssertFalse(self.app.staticTexts[@"seekPreview"].exists);
    [self capture:@"canvas-seek-forward"];
    [right pressForDuration:.05 thenDragToCoordinate:left];
    [self waitForPlaybackSecondsFrom:anchor-2 to:anchor+2];
    [self capture:@"canvas-seek-backward"];
    // Vertical movement must not become a seek or a tap.
    XCUICoordinate *lower = [self.app coordinateWithNormalizedOffset:CGVectorMake(.5,.65)];
    XCUICoordinate *upper = [self.app coordinateWithNormalizedOffset:CGVectorMake(.5,.35)];
    [lower pressForDuration:.05 thenDragToCoordinate:upper];
    [self waitForPlaybackSecondsFrom:anchor-2 to:anchor+2];
    XCUICoordinate *center = [self.app coordinateWithNormalizedOffset:CGVectorMake(.5,.5)];
    [center tap];
    [self waitForControlsVisible:NO];
    [left pressForDuration:.05 thenDragToCoordinate:right];
    [self waitForControlsVisible:NO];
    [center tap];
    [self waitForControlsVisible:YES];
    [self waitForPlaybackSecondsFrom:anchor+13 to:anchor+17];
    // The next long press still restores speed and does not toggle controls.
    [self.app.buttons[@"播放"] tap];
    [self waitForPlaybackSecondsFrom:anchor+16 to:anchor+24];
    [self assertVideoFramesAdvance:@"canvas-seek-video-moving"];
    if (!self.app.buttons[@"播放倍速"].isHittable) [center tap];
    [center pressForDuration:1];
    XCTAssertFalse(self.app.staticTexts[@"boostIndicator"].exists);
    [self expectationForPredicate:[NSPredicate predicateWithFormat:@"value == '1×'"] evaluatedWithObject:self.app.buttons[@"播放倍速"] handler:nil];
    [self waitForExpectationsWithTimeout:3 handler:nil];
    [self waitForControlsVisible:YES];
    [self closePlayback];
}
- (void)testTransportStreamDurationSeekingAndResume {
    XCUIElement *folder = self.app.staticTexts[@"演示文件夹"];
    XCTAssertTrue([folder waitForExistenceWithTimeout:20]);
    [folder tap];
    XCUIElement *movie = self.app.staticTexts[@"时间戳偏移测试.ts"];
    XCTAssertTrue([movie waitForExistenceWithTimeout:10]);
    [movie tap];
    XCUIElement *slider = self.app.sliders[@"播放进度"];
    [self waitForPlaybackSecondsFrom:1 to:50];
    NSString *duration = [self.app.otherElements[@"playerGestureSurface"].value componentsSeparatedByString:@" / "].lastObject;
    XCTAssertTrue(([@[@"00:59", @"01:00", @"01:01"] containsObject:duration]), @"Unexpected TS duration: %@", duration);
    [self showPlayerControls];
    XCTAssertTrue(slider.enabled);
    [slider adjustToNormalizedSliderPosition:.65];
    [self waitForPlaybackSecondsFrom:36 to:45];
    [self assertVideoFramesAdvance:@"ts-seek-forward"];
    [self showPlayerControls];
    [slider adjustToNormalizedSliderPosition:.2];
    [self waitForPlaybackSecondsFrom:10 to:17];
    [self assertVideoFramesAdvance:@"ts-seek-backward"];
    // Playback must advance after seeking, not just update the scrubber's preview.
    [self waitForPlaybackSecondsFrom:16 to:30];
    if (!self.app.buttons[@"关闭播放器"].isHittable) [[self.app coordinateWithNormalizedOffset:CGVectorMake(.5,.5)] tap];
    [self closePlayback];
    [movie tap];
    [self waitForPlaybackSecondsFrom:16 to:40];
    [self assertVideoFramesAdvance:@"ts-resume"];
    [self showPlayerControls];
    [self.app.buttons[@"暂停"] tap];
    [self.app.buttons[@"字幕和音轨"] tap];
    [self.app.buttons[@"从头重新播放"] tap];
    [self waitForPlaybackSecondsFrom:0 to:8];
    [self assertVideoFramesAdvance:@"ts-restart-from-beginning"];
    if (!self.app.buttons[@"关闭播放器"].isHittable) [[self.app coordinateWithNormalizedOffset:CGVectorMake(.5,.5)] tap];
    [self closePlayback];
}
- (void)testNestedBrowsingPlaybackAndHoldRestoration {
    XCUIElement *folder = self.app.staticTexts[@"演示文件夹"];
    XCTAssertTrue([folder waitForExistenceWithTimeout:20]);
    [self capture:@"library-light"];
    [folder tap];
    XCUIElement *movie = self.app.staticTexts[@"测试视频.mkv"];
    XCTAssertTrue([movie waitForExistenceWithTimeout:10]);
    [self capture:@"nested-folder"];
    [movie tap];
    [self waitForPlaybackSecondsFrom:1 to:50];
    [self showPlayerControls];
    XCUIElement *pause = self.app.buttons[@"暂停"];
    NSPredicate *playing = [NSPredicate predicateWithFormat:@"value == 'playing'"];
    [self expectationForPredicate:playing evaluatedWithObject:pause handler:nil];
    [self waitForExpectationsWithTimeout:20 handler:nil];
    XCUIElement *speed = self.app.buttons[@"播放倍速"];
    [speed tap];
    [self.app.buttons[@"1.5×"] tap];
    [self expectationForPredicate:[NSPredicate predicateWithFormat:@"value == '1.5×'"] evaluatedWithObject:speed handler:nil];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    [self capture:@"player-controls"];
    // A real press/release goes through the long-press recognizer and must retain the user's base speed.
    XCUICoordinate *center = [self.app coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.5)];
    [center pressForDuration:1.5];
    XCTAssertFalse(self.app.staticTexts[@"boostIndicator"].exists);
    [self expectationForPredicate:[NSPredicate predicateWithFormat:@"value == '1.5×'"] evaluatedWithObject:speed handler:nil];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    if (!pause.isHittable) [center tap];
    [pause tap];
    XCTAssertTrue([self.app.staticTexts[@"已暂停"] waitForExistenceWithTimeout:5]);
    [[XCUIDevice sharedDevice] setOrientation:UIDeviceOrientationLandscapeLeft];
    XCTestExpectation *settled = [self expectationWithDescription:@"Native rotation settled"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [settled fulfill]; });
    [self waitForExpectationsWithTimeout:5 handler:nil];
    // XCTest reports the application frame in the device's portrait coordinate space.
    // Verify the actual orientation and reachability of both top and bottom controls.
    XCTAssertEqual(XCUIDevice.sharedDevice.orientation, UIDeviceOrientationLandscapeLeft);
    XCTAssertTrue(self.app.buttons[@"关闭播放器"].isHittable);
    XCTAssertTrue(self.app.buttons[@"播放"].isHittable);
    [self capture:@"player-landscape"];
    [self closePlayback];
    XCTAssertTrue([movie waitForExistenceWithTimeout:5]);
    [[XCUIDevice sharedDevice] setOrientation:UIDeviceOrientationPortrait];
}
- (void)testFolderSearch {
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:20]);
    XCUIElement *search = self.app.searchFields.firstMatch;
    [search tap];
    [search typeText:@"no-match"];
    XCTAssertTrue([self.app.staticTexts[@"没有匹配的文件"] waitForExistenceWithTimeout:5]);
    [self capture:@"empty-search"];
}
- (void)testSpecialCharacterFolderSearchAndPlayback {
    XCUIElement *folder = self.app.staticTexts[@"符号+ &%# 测试"];
    XCTAssertTrue([folder waitForExistenceWithTimeout:20]);
    [folder tap];
    XCTAssertTrue([self.app.staticTexts[@"视频+ &%# 测试.mkv"] waitForExistenceWithTimeout:10]);
    [self.app.searchFields.firstMatch tap];
    [self.app.searchFields.firstMatch typeText:@"+"];
    [self expectationForPredicate:[NSPredicate predicateWithFormat:@"exists == NO"]
             evaluatedWithObject:self.app.staticTexts[@"视频 空格.mkv"] handler:nil];
    [self waitForExpectationsWithTimeout:10 handler:nil];
    XCTAssertTrue([self.app.staticTexts[@"视频+ &%# 测试.ts"] waitForExistenceWithTimeout:10]);
    [self capture:@"special-characters-search"];
    for (NSString *name in @[@"视频+ &%# 测试.mkv", @"视频+ &%# 测试.ts"]) {
        [self.app.staticTexts[name] tap];
        [self waitForPlaybackSecondsFrom:1 to:50];
        [self assertVideoFramesAdvance:@"special-characters-playing"];
        [self.app.sliders[@"播放进度"] adjustToNormalizedSliderPosition:.5];
        [self waitForPlaybackSecondsFrom:26 to:38];
        [self assertVideoFramesAdvance:@"special-characters-seek"];
        [self closePlayback];
    }
}
- (void)testConnectionSettingsAndPersistence {
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:20]);
    [self.app.buttons[@"电脑连接设置"] tap];
    XCTAssertTrue([self.app.buttons[@"密码连接"] waitForExistenceWithTimeout:5]);
    [self capture:@"connection-password"];
    [self.app.buttons[@"扫码连接"] tap];
    XCTAssertTrue(self.app.buttons[@"扫描电脑二维码"].exists);
    [self capture:@"connection-qr"];
    [self.app.buttons[@"密码连接"] tap];
    [self.app.buttons[@"连接"] tap];
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:15]);
    [self.app terminate];
    self.app.launchArguments = @[@"--keep-settings"];
    [self.app launch];
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:20]);
}
- (void)waitForPictureCoverageFrom:(double)minimum to:(double)maximum {
    BOOL matched = NO;
    for (NSInteger attempt = 0; attempt < 8 && !matched; attempt++) {
        CGImageRef image = self.app.screenshot.image.CGImage;
        unsigned char pixels[64*128*4] = {0};
        CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(pixels, 64, 128, 8, 64*4, colors, kCGImageAlphaPremultipliedLast);
        CGContextDrawImage(context, CGRectMake(0,0,64,128), image);
        CGContextRelease(context); CGColorSpaceRelease(colors);
        NSUInteger colorful = 0;
        for (NSUInteger i = 0; i < 64*128; i++) {
            unsigned char *p = pixels+i*4;
            if (MAX(p[0], MAX(p[1],p[2]))-MIN(p[0], MIN(p[1],p[2])) > 60) colorful++;
        }
        double coverage = colorful/(64.0*128);
        NSLog(@"CROP_COVERAGE %.3f expected %.2f–%.2f", coverage, minimum, maximum);
        matched = coverage >= minimum && coverage <= maximum;
        if (!matched) {
            XCTestExpectation *frame = [self expectationWithDescription:@"Paused crop refresh"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [frame fulfill]; });
            [self waitForExpectationsWithTimeout:3 handler:nil];
        }
    }
    XCTAssertTrue(matched, @"Displayed pixels must match the selected crop mode while paused");
    XCTAssertTrue(self.app.buttons[@"播放"].exists, @"Changing display mode must keep playback paused");
}
- (void)testAutomaticFillAndSavedDisplayMode {
    XCUIElement *movie = self.app.staticTexts[@"黑边竖屏测试.mkv"];
    XCTAssertTrue([movie waitForExistenceWithTimeout:20]);
    [movie tap];
    [self waitForPlaybackSecondsFrom:1 to:50];
    XCUIElement *pause = self.app.buttons[@"暂停"];
    // Allow the local crop probe to finish and then reveal the controls.
    XCTestExpectation *probe = [self expectationWithDescription:@"Black borders analyzed"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [probe fulfill]; });
    [self waitForExpectationsWithTimeout:6 handler:nil];
    XCUIElement *fit = self.app.buttons[@"画面显示方式"];
    if (!fit.isHittable) [[self.app coordinateWithNormalizedOffset:CGVectorMake(.5,.5)] tap];
    [pause tap];
    XCTAssertEqualObjects(fit.value, @"智能适配");
    [self waitForPictureCoverageFrom:.4 to:.7];
    // Check actual pixels: the colorful synthetic subject must occupy the center,
    // rather than a black frame or the original tiny rectangle within black bars.
    CGImageRef image = self.app.screenshot.image.CGImage;
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    unsigned char *pixels = calloc(width*height, 4);
    CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, width*4, colors, kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(context, CGRectMake(0,0,width,height), image);
    NSUInteger colorful = 0, sampled = 0;
    for (size_t y = height/4; y < height*3/4; y += 8) for (size_t x = width/4; x < width*3/4; x += 8) {
        unsigned char *p = pixels+(y*width+x)*4;
        if (MAX(p[0], MAX(p[1],p[2]))-MIN(p[0],MIN(p[1],p[2])) > 60) colorful++;
        sampled++;
    }
    CGContextRelease(context); CGColorSpaceRelease(colors); free(pixels);
    XCTAssertGreaterThan((double)colorful/sampled, 0.35);
    [self waitForPictureCoverageFrom:.4 to:.7];
    double pausedTime = [self displayedPlaybackSeconds];
    [self capture:@"smart-vertical-fit"];
    [fit tap];
    [self capture:@"smart-display-menu"];
    [self.app.buttons[@"裁切铺满"] tap];
    XCTAssertEqualObjects(fit.value, @"裁切铺满");
    [self waitForPictureCoverageFrom:.7 to:1];
    [self capture:@"smart-vertical-fill"];
    [fit tap];
    [self.app.buttons[@"完整显示"] tap];
    XCTAssertEqualObjects(fit.value, @"完整显示");
    [self waitForPictureCoverageFrom:0 to:.12];
    XCTAssertLessThan(fabs([self displayedPlaybackSeconds]-pausedTime), 1.1);
    [self capture:@"smart-vertical-full"];
    [self closePlayback];
    [movie tap];
    XCTAssertTrue([fit waitForExistenceWithTimeout:20]);
    XCTAssertEqualObjects(fit.value, @"完整显示");
    [fit tap];
    [self.app.buttons[@"智能适配"] tap];
    [self closePlayback];
}
- (void)testRecursiveSearchAndWrappedNames {
    NSString *longFolder = @"这是用于检查完整换行显示的长文件夹名称包含中文和English并且不应该出现省略号这些文字都应当可见";
    NSString *longFile = @"这是一个非常长的视频文件名称用于确认自动增加行高并显示全部文字而不是截断或省略名称_完整显示测试.mkv";
    XCUIElement *folder = self.app.staticTexts[longFolder];
    XCTAssertTrue([folder waitForExistenceWithTimeout:20]);
    XCTAssertGreaterThan(folder.frame.size.height, 44);
    [self capture:@"long-folder-wrapped"];
    [folder tap];
    XCUIElement *file = self.app.staticTexts[longFile];
    XCTAssertTrue([file waitForExistenceWithTimeout:10]);
    XCTAssertGreaterThan(file.frame.size.height, 44);
    [self capture:@"long-file-wrapped"];
    [self.app.navigationBars.buttons.firstMatch tap];
    XCTAssertTrue([self.app.staticTexts[@"演示文件夹"] waitForExistenceWithTimeout:10]);
    XCUIElement *search = self.app.searchFields.firstMatch;
    [search tap];
    [search typeText:@".mkv"];
    XCUIElement *nestedMovie = self.app.staticTexts[@"测试视频.mkv"];
    XCTAssertTrue([nestedMovie waitForExistenceWithTimeout:10]);
    XCTAssertTrue(self.app.staticTexts[longFile].exists);
    [self capture:@"recursive-search"];
    [nestedMovie tap];
    [self waitForPlaybackSecondsFrom:1 to:50];
    [self assertVideoFramesAdvance:@"search-video-moving"];
    [self capture:@"play-from-search"];
    [self closePlayback];
}
@end
