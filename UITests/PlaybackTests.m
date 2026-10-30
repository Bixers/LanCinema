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
    // A failed landscape assertion must not rotate later portrait-only checks.
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationPortrait;
    [super tearDown];
}
- (void)capture:(NSString *)name {
    XCTAttachment *a = [XCTAttachment attachmentWithScreenshot:self.app.screenshot];
    a.name = name;
    a.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:a];
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
    CGImageRef crop = CGImageCreateWithImageInRect(image, CGRectMake(width*.1, height*.3, width*.8, height*.4));
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
    [self showPlayerControls];
    XCTAssertTrue(self.app.sliders[@"播放进度"].enabled);
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
    [self capture:@"controls-tap-revealed"];
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
    [self capture:@"smart-vertical-fit"];
    [fit tap];
    [self capture:@"smart-display-menu"];
    [self.app.buttons[@"裁切铺满"] tap];
    XCTAssertEqualObjects(fit.value, @"裁切铺满");
    [self capture:@"smart-vertical-fill"];
    [fit tap];
    [self.app.buttons[@"完整显示"] tap];
    XCTAssertEqualObjects(fit.value, @"完整显示");
    [self capture:@"vertical-full-frame"];
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
