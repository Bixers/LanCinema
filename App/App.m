#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MobileVLCKit/MobileVLCKit.h>
#import <math.h>
#import "Connection.h"
#import "AudioOutput.h"
#import "FileSort.h"
#import "VideoGeometry.h"

// Public libvlc frame-step API; use the same owning-player bridge as audio.
extern void libvlc_media_player_next_frame(void *);
@interface VLCMediaPlayer (LCVideoBridge)
- (void *)libVLCMediaPlayer;
@end

static NSString *const HostKey = @"computerHost";
static NSString *const TokenKey = @"computerAccessCode";
static NSString *const RateKey = @"playbackRate";
static NSString *const HoldKey = @"holdPlaybackRate";

static NSURL *ServiceURL(NSString *endpoint, NSString *path) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSURLComponents *c = [NSURLComponents new];
    c.scheme = @"http";
    c.host = [d stringForKey:HostKey] ?: @"127.0.0.1";
    c.port = @8123;
    c.path = endpoint;
    c.queryItems = @[[NSURLQueryItem queryItemWithName:@"path" value:path ?: @""],
                     [NSURLQueryItem queryItemWithName:@"token" value:LCPassword()]];
    return c.URL;
}

static NSString *ClockText(double seconds) {
    NSInteger s = MAX(0, (NSInteger)seconds);
    if (s >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)s/3600, (long)(s/60)%60, (long)s%60];
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)s/60, (long)s%60];
}

static UIButton *SymbolButton(NSString *symbol, NSString *label, id target, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    b.accessibilityLabel = label;
    b.tintColor = UIColor.whiteColor;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.widthAnchor constraintEqualToConstant:48].active = YES;
    [b.heightAnchor constraintEqualToConstant:48].active = YES;
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

@interface PlayerController : UIViewController <VLCMediaPlayerDelegate, UIGestureRecognizerDelegate>
@property(nonatomic, copy) NSDictionary *item;
@property(nonatomic, copy) NSArray<NSDictionary *> *subtitles;
@property(nonatomic, strong) NSURLSessionDataTask *subtitleTask;
@property(nonatomic, strong) NSURLSessionDataTask *playbackTask;
@property(nonatomic) BOOL subtitleFallback;
@property(nonatomic) BOOL preparing;
@property(nonatomic) BOOL prepared;
@property(nonatomic, strong) VLCMediaPlayer *player;
@property(nonatomic, strong) LCAudioOutput *audioOutput;
@property(nonatomic, strong) UIView *canvas;
@property(nonatomic, strong) UIView *videoSurface;
@property(nonatomic, strong) UIButton *fitButton;
@property(nonatomic, strong) NSDictionary *detectedCrop;
@property(nonatomic, strong) NSURLSessionDataTask *cropTask;
@property(nonatomic, copy) NSString *appliedGeometry;
@property(nonatomic) BOOL hasConfiguredCrop;
@property(nonatomic, strong) UIView *header;
@property(nonatomic, strong) UIStackView *footer;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *timeLabel;
@property(nonatomic, strong) UILabel *boostLabel;
@property(nonatomic, strong) UILabel *seekLabel;
@property(nonatomic, strong) UIView *gestureSurface;
@property(nonatomic) BOOL panning;
@property(nonatomic) double panStartTime;
@property(nonatomic) double panTargetTime;
@property(nonatomic) BOOL hasPendingSeek;
@property(nonatomic) double pendingSeekTime;
@property(nonatomic) NSTimeInterval seekIssuedAt;
@property(nonatomic) BOOL waitingForSeekFrames;
@property(nonatomic) NSInteger seekFrameBaseline;
@property(nonatomic) NSInteger lastDisplayedFrames;
@property(nonatomic) double lastPlayableTime;
@property(nonatomic, strong) UIButton *playButton;
@property(nonatomic, strong) UIButton *rateButton;
@property(nonatomic, strong) UISlider *slider;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) float selectedRate;
@property(nonatomic) float holdRate;
@property(nonatomic) BOOL boosting;
@property(nonatomic) BOOL scrubbing;
@property(nonatomic) BOOL restored;
@property(nonatomic) BOOL closed;
@property(nonatomic) BOOL controlsVisible;
@property(nonatomic) BOOL resumeAfterBackground;
@property(nonatomic) BOOL resumeAfterInterruption;
@property(nonatomic) BOOL audioInterruptionActive;
@property(nonatomic) NSTimeInterval controlsTouched;
@property(nonatomic) NSInteger ticks;
@end

@implementation PlayerController
- (BOOL)isTransportStream { return [@[@"ts", @"mts", @"m2ts"] containsObject:[self.item[@"path"] pathExtension].lowercaseString]; }
- (NSString *)progressKey {
    NSString *key = [NSString stringWithFormat:@"progress:%@:%@", [[NSUserDefaults.standardUserDefaults stringForKey:HostKey] stringByAppendingFormat:@":%@", [NSUserDefaults.standardUserDefaults stringForKey:@"libraryID"] ?: @""], self.item[@"path"]];
    // Do not restore positions saved by the TS decoder path that could freeze.
    return [self isTransportStream] ? [key stringByAppendingString:@":ts-indexed-v1"] : key;
}
- (VLCMedia *)playbackMedia {
    [self.audioOutput reset];
    NSURL *url = ServiceURL(@"/media", self.item[@"path"]);
    if ([self isTransportStream]) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        components.queryItems = [components.queryItems arrayByAddingObject:[NSURLQueryItem queryItemWithName:@"prepared" value:@"1"]];
        url = components.URL;
    }
    VLCMedia *media = [VLCMedia mediaWithURL:url];
    // Retain a small jitter buffer for seekable local HTTP media.
    [media addOption:@":network-caching=300"];
    [media addOption:@":audio-time-stretch"];
    // Select the resume point before input/audio output start. Starting at zero
    // and seeking from tick interrupted the first audio and buffered twice.
    double previous = [NSUserDefaults.standardUserDefaults doubleForKey:self.progressKey];
    self.restored = YES;
    if (isfinite(previous) && previous > 3) {
        [media addOption:[NSString stringWithFormat:@":start-time=%.3f", previous]];
        self.pendingSeekTime = previous;
        self.hasPendingSeek = YES;
        self.seekIssuedAt = NSDate.timeIntervalSinceReferenceDate;
        self.waitingForSeekFrames = YES;
        self.seekFrameBaseline = 0;
    }
    return media;
}
- (void)applyPlaybackRate {
    float desired = self.boosting ? self.holdRate : self.selectedRate;
    if (fabsf(self.player.rate - desired) > 0.01f) self.player.rate = desired;
}
- (void)prepareTransportStream {
    if (self.closed) return;
    self.preparing = YES;
    self.playButton.enabled = NO;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:ServiceURL(@"/api/playback", self.item[@"path"])];
    request.timeoutInterval = 15;
    __weak typeof(self) owner = self;
    self.playbackTask = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            PlayerController *s = owner;
            if (!s || s.closed) return;
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            s.preparing = NO;
            s.playButton.enabled = YES;
            if (status == 404) { s.statusLabel.text = @"请更新电脑端文件服务，再打开 TS 视频"; return; }
            if (status != 200 || ![result isKindOfClass:NSDictionary.class]) { s.statusLabel.text = @"准备视频失败，请检查电脑连接后点击播放重试"; return; }
            if ([result[@"state"] isEqual:@"ready"]) {
                s.prepared = YES;
                s.subtitleFallback = [result[@"subtitleFallback"] boolValue];
                s.player.media = [s playbackMedia];
                if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) [s.player play];
                else s.resumeAfterBackground = YES;
            } else if ([result[@"state"] isEqual:@"preparing"] || [result[@"state"] isEqual:@"waiting"]) {
                s.preparing = YES;
                s.playButton.enabled = NO;
                s.statusLabel.text = [result[@"state"] isEqual:@"waiting"] ? @"电脑正在准备其他视频，请稍候…" : @"正在准备视频\n首次打开可能稍久…";
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [owner prepareTransportStream]; });
            } else {
                s.statusLabel.text = [result[@"error"] isKindOfClass:NSString.class] ? result[@"error"] : @"无法准备该视频";
            }
        });
    }];
    [self.playbackTask resume];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.controlsVisible = YES;
    self.controlsTouched = NSDate.timeIntervalSinceReferenceDate;
    self.selectedRate = [NSUserDefaults.standardUserDefaults floatForKey:RateKey];
    if (self.selectedRate < 0.5 || self.selectedRate > 3) self.selectedRate = 1;
    self.holdRate = [NSUserDefaults.standardUserDefaults floatForKey:HoldKey];
    if (self.holdRate != 2 && self.holdRate != 3) self.holdRate = 2;
    self.canvas = [UIView new];
    self.canvas.backgroundColor = UIColor.blackColor;
    self.canvas.clipsToBounds = YES;
    self.videoSurface = [UIView new];
    self.videoSurface.backgroundColor = UIColor.blackColor;
    self.videoSurface.userInteractionEnabled = NO;
    [self.canvas addSubview:self.videoSurface];
    self.canvas.accessibilityIdentifier = @"videoCanvas";
    self.canvas.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.canvas];
    [NSLayoutConstraint activateConstraints:@[
        [self.canvas.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.canvas.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.canvas.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.canvas.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];
    // Keep input independent of VLC's drawable and any views it installs or scales.
    self.gestureSurface = [UIView new];
    self.gestureSurface.accessibilityIdentifier = @"playerGestureSurface";
    self.gestureSurface.isAccessibilityElement = YES;
    self.gestureSurface.accessibilityLabel = @"视频画面";
    self.gestureSurface.accessibilityCustomActions = @[
        [[UIAccessibilityCustomAction alloc] initWithName:@"显示或隐藏播放控制" target:self selector:@selector(accessibilityToggleControls)],
        [[UIAccessibilityCustomAction alloc] initWithName:@"前进十秒" target:self selector:@selector(accessibilitySeekForward)],
        [[UIAccessibilityCustomAction alloc] initWithName:@"后退十秒" target:self selector:@selector(accessibilitySeekBackward)]];
    self.gestureSurface.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.gestureSurface];
    [NSLayoutConstraint activateConstraints:@[
        [self.gestureSurface.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.gestureSurface.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.gestureSurface.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.gestureSurface.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(hold:)];
    hold.minimumPressDuration = 0.35;
    hold.allowableMovement = 10;
    [self.gestureSurface addGestureRecognizer:hold];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panToSeek:)];
    pan.maximumNumberOfTouches = 1;
    pan.delegate = self;
    [pan requireGestureRecognizerToFail:hold];
    [self.gestureSurface addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleControls)];
    [tap requireGestureRecognizerToFail:hold];
    [tap requireGestureRecognizerToFail:pan];
    [self.gestureSurface addGestureRecognizer:tap];

    UIButton *close = SymbolButton(@"xmark", @"关闭播放器", self, @selector(closePlayer));
    UILabel *title = [UILabel new];
    title.text = self.item[@"name"];
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.adjustsFontForContentSizeCategory = YES;
    title.textColor = UIColor.whiteColor;
    title.numberOfLines = 2;
    title.lineBreakMode = NSLineBreakByCharWrapping;
    self.fitButton = SymbolButton(@"arrow.up.left.and.arrow.down.right", @"画面显示方式", self, @selector(fitMenu));
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[close, title, self.fitButton]];
    header.spacing = 12;
    header.alignment = UIStackViewAlignmentCenter;
    header.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    header.layer.cornerRadius = 16;
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:header];
    self.header = header;

    self.boostLabel = [UILabel new];
    self.boostLabel.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightSemibold];
    self.boostLabel.textColor = UIColor.whiteColor;
    self.boostLabel.textAlignment = NSTextAlignmentCenter;
    self.boostLabel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85];
    self.boostLabel.layer.cornerRadius = 18;
    self.boostLabel.clipsToBounds = YES;
    self.boostLabel.hidden = YES;
    self.boostLabel.accessibilityIdentifier = @"boostIndicator";
    self.boostLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.boostLabel];

    self.statusLabel = [UILabel new];
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 3;
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.statusLabel.adjustsFontForContentSizeCategory = YES;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.statusLabel];

    self.seekLabel = [UILabel new];
    self.seekLabel.accessibilityIdentifier = @"seekPreview";
    self.seekLabel.font = [UIFont monospacedDigitSystemFontOfSize:18 weight:UIFontWeightSemibold];
    self.seekLabel.textColor = UIColor.whiteColor;
    self.seekLabel.textAlignment = NSTextAlignmentCenter;
    self.seekLabel.numberOfLines = 2;
    self.seekLabel.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.9];
    self.seekLabel.layer.cornerRadius = 16;
    self.seekLabel.clipsToBounds = YES;
    self.seekLabel.hidden = YES;
    self.seekLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.seekLabel];

    self.slider = [UISlider new];
    self.slider.accessibilityLabel = @"播放进度";
    self.slider.tintColor = UIColor.systemMintColor;
    [self.slider addTarget:self action:@selector(scrubBegin) forControlEvents:UIControlEventTouchDown];
    [self.slider addTarget:self action:@selector(scrubPreview) forControlEvents:UIControlEventValueChanged];
    [self.slider addTarget:self action:@selector(scrubEnd) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    [self.slider addTarget:self action:@selector(scrubCancel) forControlEvents:UIControlEventTouchCancel];
    self.timeLabel = [UILabel new];
    self.timeLabel.accessibilityIdentifier = @"playbackTime";
    self.timeLabel.text = @"00:00 / 00:00";
    self.timeLabel.textColor = UIColor.lightGrayColor;
    self.timeLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];

    self.playButton = SymbolButton(@"pause.fill", @"暂停", self, @selector(togglePlay));
    UIButton *back = SymbolButton(@"gobackward.10", @"后退十秒", self, @selector(backward));
    UIButton *forward = SymbolButton(@"goforward.10", @"前进十秒", self, @selector(forward));
    self.rateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.rateButton.tintColor = UIColor.systemMintColor;
    self.rateButton.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightSemibold];
    self.rateButton.accessibilityLabel = @"播放倍速";
    [self.rateButton.widthAnchor constraintEqualToConstant:72].active = YES;
    [self.rateButton.heightAnchor constraintEqualToConstant:48].active = YES;
    [self.rateButton addTarget:self action:@selector(rateMenuTouched) forControlEvents:UIControlEventTouchDown];
    UIButton *tracks = SymbolButton(@"captions.bubble", @"字幕和音轨", self, @selector(showTracks));
    UIView *spacer = [UIView new];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[back, self.playButton, forward, spacer, self.rateButton, tracks]];
    buttons.spacing = 8;
    buttons.alignment = UIStackViewAlignmentCenter;
    self.footer = [[UIStackView alloc] initWithArrangedSubviews:@[self.slider, self.timeLabel, buttons]];
    self.footer.axis = UILayoutConstraintAxisVertical;
    self.footer.spacing = 4;
    self.footer.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.85];
    self.footer.layer.cornerRadius = 18;
    self.footer.layoutMarginsRelativeArrangement = YES;
    self.footer.layoutMargins = UIEdgeInsetsMake(10, 14, 6, 14);
    self.footer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.footer];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [header.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [header.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [self.footer.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [self.footer.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [self.footer.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
        [self.boostLabel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.boostLabel.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:12],
        [self.boostLabel.widthAnchor constraintEqualToConstant:190],
        [self.boostLabel.heightAnchor constraintEqualToConstant:38],
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [self.statusLabel.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-40],
        [self.seekLabel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.seekLabel.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [self.seekLabel.widthAnchor constraintEqualToConstant:240],
        [self.seekLabel.heightAnchor constraintEqualToConstant:88]]];
    [self rebuildRateMenu];
    NSError *audioError;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback options:0 error:&audioError];
    [[AVAudioSession sharedInstance] setActive:YES error:&audioError];
    // VLC renders subtitles with FreeType, independently of UIKit's font
    // fallback. Use the bundled, UIAppFonts-registered CJK family explicitly.
    self.player = [[VLCMediaPlayer alloc] initWithOptions:@[@"--no-video-title-show",
        @"--text-renderer=freetype", @"--freetype-font=Noto Sans CJK SC",
        @"--freetype-monofont=Noto Sans CJK SC"]];
    self.player.delegate = self;
    self.player.drawable = self.videoSurface;
    self.player.scaleFactor = 0;
    self.audioOutput = [[LCAudioOutput alloc] initWithPlayer:self.player];
    if (![self isTransportStream]) self.player.media = [self playbackMedia];
    // Search results can live below the browser's current folder. Load subtitles beside this video.
    NSString *parent = [self.item[@"path"] stringByDeletingLastPathComponent];
    __weak typeof(self) subtitleOwner = self;
    self.subtitleTask = [NSURLSession.sharedSession dataTaskWithURL:ServiceURL(@"/api/list", parent) completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([(NSHTTPURLResponse *)response statusCode] != 200 || ![json isKindOfClass:NSDictionary.class] || ![json[@"items"] isKindOfClass:NSArray.class]) return;
        NSArray *subs = [json[@"items"] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item, NSDictionary *bindings) { return [item[@"subtitle"] boolValue]; }]];
        dispatch_async(dispatch_get_main_queue(), ^{ if (!subtitleOwner.closed) subtitleOwner.subtitles = subs; });
    }];
    [self.subtitleTask resume];
    self.statusLabel.text = @"正在打开视频…";
    if ([self isTransportStream]) [self prepareTransportStream];
    else [self.player play];
    NSMutableURLRequest *cropRequest = [NSMutableURLRequest requestWithURL:ServiceURL(@"/api/crop", self.item[@"path"])];
    cropRequest.timeoutInterval = 30;
    __weak typeof(self) cropOwner = self;
    self.cropTask = [NSURLSession.sharedSession dataTaskWithRequest:cropRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *crop = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([(NSHTTPURLResponse *)response statusCode] != 200 || ![crop isKindOfClass:NSDictionary.class]) return;
        dispatch_async(dispatch_get_main_queue(), ^{ if (!cropOwner.closed) { cropOwner.detectedCrop = crop; [cropOwner updateVideoLayout]; } });
    }];
    [self.cropTask resume];
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) { [weakSelf tick]; }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background) name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(active) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(audioInterrupted:) name:AVAudioSessionInterruptionNotification object:nil];
    UIApplication.sharedApplication.idleTimerDisabled = YES;
}
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; [self updateVideoLayout]; }
- (NSString *)displayMode {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *mode = [defaults stringForKey:@"videoDisplayMode"];
    if (![@[@"smart", @"fill", @"full"] containsObject:mode]) {
        // Keep an explicit full-frame preference; replace the old default zoom.
        mode = [defaults boolForKey:@"fitEntireVideo"] ? @"full" : @"smart";
        [defaults setObject:mode forKey:@"videoDisplayMode"];
    }
    return mode;
}
- (void)refreshVideoSurfaceLayout {
    if (self.closed) return;
    // VLC 3's iOS output can skip its viewport update when only crop changes.
    // Request ordinary UIKit layout after the asynchronous crop command lands.
    // No transforms, private selectors, decoder restart, or audio reset.
    for (UIView *view in self.videoSurface.subviews) {
        [view setNeedsLayout];
        [view layoutIfNeeded];
    }
}
- (void)updateVideoLayout {
    if (!self.player || self.closed) return;
    NSString *mode = self.displayMode;
    self.fitButton.accessibilityValue = [@{@"smart":@"智能适配", @"fill":@"裁切铺满", @"full":@"完整显示"} objectForKey:mode];
    self.videoSurface.frame = self.canvas.bounds;
    if (!self.player.hasVideoOut) { self.appliedGeometry = nil; return; }
    CGSize video = self.player.videoSize;
    double sar = 1;
    BOOL upright = YES;
    for (NSDictionary *track in self.player.media.tracksInformation) {
        if ([track[VLCMediaTracksInformationType] isEqual:VLCMediaTracksInformationTypeVideo]) {
            double width = [track[VLCMediaTracksInformationVideoWidth] doubleValue];
            double height = [track[VLCMediaTracksInformationVideoHeight] doubleValue];
            if (width > 0 && height > 0) video = CGSizeMake(width, height);
            double numerator = [track[VLCMediaTracksInformationSourceAspectRatio] doubleValue];
            double denominator = [track[VLCMediaTracksInformationSourceAspectRatioDenominator] doubleValue];
            if (numerator > 0 && denominator > 0) sar = numerator/denominator;
            upright = [track[VLCMediaTracksInformationVideoOrientation] integerValue] == VLCMediaOrientationTopLeft;
            break;
        }
    }
    NSString *geometry = LCVideoCropGeometry(mode, video, self.canvas.bounds.size, self.detectedCrop, sar, upright);
    if (![geometry isEqualToString:self.appliedGeometry]) {
        self.appliedGeometry = geometry;
        // Fresh outputs already fit the uncropped source. Avoid reallocating
        // GL buffers during first audio/video startup when there is no crop.
        if (geometry.length == 0 && !self.hasConfiguredCrop) return;
        self.hasConfiguredCrop = YES;
        self.player.videoCropGeometry = (char *)geometry.UTF8String;
        __weak typeof(self) owner = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC/5), dispatch_get_main_queue(), ^{
            PlayerController *s = owner;
            if (!s || s.closed || ![s.appliedGeometry isEqual:geometry]) return;
            [s refreshVideoSurfaceLayout];
            // VLC's paused output can retain its previous crop until a new
            // frame arrives. Advance one frame without resuming audio/playback.
            if (s.player.state == VLCMediaPlayerStatePaused)
                libvlc_media_player_next_frame(s.player.libVLCMediaPlayer);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC/2), dispatch_get_main_queue(), ^{ [owner refreshVideoSurfaceLayout]; });
    }
}
- (void)fitMenu {
    self.controlsTouched = NSDate.timeIntervalSinceReferenceDate;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"画面显示方式" message:@"智能适配：去除检测到的黑边，保留有效画面。\n裁切铺满：铺满屏幕，可能裁掉画面边缘。\n完整显示：保留原始画面和黑边。\n选择会自动保存。" preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *modes = @[@"smart", @"fill", @"full"];
    NSArray *names = @[@"智能适配", @"裁切铺满", @"完整显示"];
    for (NSUInteger index = 0; index < modes.count; index++) {
        NSString *mode = modes[index];
        [sheet addAction:[UIAlertAction actionWithTitle:names[index] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [NSUserDefaults.standardUserDefaults setObject:mode forKey:@"videoDisplayMode"];
            self.controlsTouched = NSDate.timeIntervalSinceReferenceDate;
            [self updateVideoLayout];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.fitButton;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)rebuildRateMenu {
    __weak typeof(self) weakSelf = self;
    NSMutableArray *rates = [NSMutableArray new];
    for (NSNumber *value in @[@0.5, @0.75, @1, @1.25, @1.5, @2, @3]) {
        UIAction *action = [UIAction actionWithTitle:[NSString stringWithFormat:@"%@×", value] image:nil identifier:nil handler:^(UIAction *a) {
            PlayerController *s = weakSelf;
            s.selectedRate = value.floatValue;
            [NSUserDefaults.standardUserDefaults setFloat:s.selectedRate forKey:RateKey];
            [s applyPlaybackRate];
            s.controlsTouched = NSDate.timeIntervalSinceReferenceDate;
            [s rebuildRateMenu];
        }];
        action.state = fabsf(value.floatValue - self.selectedRate) < 0.01 ? UIMenuElementStateOn : UIMenuElementStateOff;
        [rates addObject:action];
    }
    NSMutableArray *holdRates = [NSMutableArray new];
    for (NSNumber *value in @[@2, @3]) {
        UIAction *action = [UIAction actionWithTitle:[NSString stringWithFormat:@"长按 %@×", value] image:nil identifier:nil handler:^(UIAction *a) {
            weakSelf.holdRate = value.floatValue;
            [NSUserDefaults.standardUserDefaults setFloat:value.floatValue forKey:HoldKey];
            [weakSelf rebuildRateMenu];
        }];
        action.state = value.floatValue == self.holdRate ? UIMenuElementStateOn : UIMenuElementStateOff;
        [holdRates addObject:action];
    }
    self.rateButton.menu = [UIMenu menuWithTitle:@"播放倍速" children:@[
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:rates],
        [UIMenu menuWithTitle:@"长按画面，松开恢复" children:holdRates]]];
    self.rateButton.showsMenuAsPrimaryAction = YES;
    [self.rateButton setTitle:[NSString stringWithFormat:@"%g×", self.selectedRate] forState:UIControlStateNormal];
    self.rateButton.accessibilityValue = [NSString stringWithFormat:@"%g×", self.selectedRate];
}
- (void)rateMenuTouched { self.controlsTouched = NSDate.timeIntervalSinceReferenceDate; }
- (void)hold:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan && self.player.isPlaying && !self.scrubbing) {
        self.boosting = YES;
        [self applyPlaybackRate];
        self.boostLabel.text = [NSString stringWithFormat:@"▶▶  %g× 倍速播放", self.holdRate];
        self.boostLabel.hidden = NO;
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    } else if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled || gesture.state == UIGestureRecognizerStateFailed) {
        [self endBoost];
    }
}
- (void)endBoost {
    if (self.boosting) {
        self.boosting = NO;
        [self applyPlaybackRate];
        self.controlsTouched = NSDate.timeIntervalSinceReferenceDate;
    }
    self.boosting = NO;
    self.boostLabel.hidden = YES;
}
- (void)setPlaybackControlsVisible:(BOOL)visible {
    self.controlsVisible = visible;
    self.controlsTouched = NSDate.timeIntervalSinceReferenceDate;
    self.header.hidden = !self.controlsVisible;
    self.footer.hidden = !self.controlsVisible;
    [self setNeedsStatusBarAppearanceUpdate];
}
- (void)toggleControls { [self setPlaybackControlsVisible:!self.controlsVisible]; }
- (BOOL)accessibilityToggleControls { [self toggleControls]; return YES; }
- (BOOL)accessibilitySeekForward { [self forward]; return self.player.isSeekable; }
- (BOOL)accessibilitySeekBackward { [self backward]; return self.player.isSeekable; }
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if ([gesture isKindOfClass:UIPanGestureRecognizer.class]) {
        CGPoint velocity = [(UIPanGestureRecognizer *)gesture velocityInView:self.gestureSurface];
        return fabs(velocity.x) > fabs(velocity.y) * 1.2 && self.player.isSeekable && [self duration] > 0 && !self.boosting;
    }
    return YES;
}
- (void)cancelPanSeek {
    self.panning = NO;
    self.seekLabel.hidden = YES;
    self.controlsTouched = NSDate.timeIntervalSinceReferenceDate;
}
- (void)panToSeek:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self endBoost];
        self.panning = YES;
        self.panStartTime = [self currentPlaybackTime];
    }
    if (self.panning && (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged || gesture.state == UIGestureRecognizerStateEnded)) {
        double duration = [self duration];
        double span = MIN(120, MAX(30, duration * 0.2));
        double delta = [gesture translationInView:self.gestureSurface].x / MAX(1, self.gestureSurface.bounds.size.width) * span;
        self.panTargetTime = MIN(MAX(0, self.panStartTime + delta), MAX(0, duration - 0.25));
        double difference = self.panTargetTime - self.panStartTime;
        self.seekLabel.text = [NSString stringWithFormat:@"%@ %.0f 秒\n%@ / %@", difference >= 0 ? @"快进" : @"后退", fabs(difference), ClockText(self.panTargetTime), ClockText(duration)];
        self.seekLabel.hidden = NO;
        self.slider.value = duration > 0 ? self.panTargetTime / duration : 0;
        self.timeLabel.text = [NSString stringWithFormat:@"%@ / %@", ClockText(self.panTargetTime), ClockText(duration)];
        if (gesture.state == UIGestureRecognizerStateEnded) {
            [self seekToTime:self.panTargetTime];
            [self cancelPanSeek];
        }
    } else if (gesture.state == UIGestureRecognizerStateCancelled || gesture.state == UIGestureRecognizerStateFailed) {
        [self cancelPanSeek];
    }
}
- (BOOL)prefersStatusBarHidden { return !self.controlsVisible; }
- (void)togglePlay {
    [self endBoost];
    self.controlsTouched = NSDate.timeIntervalSinceReferenceDate;
    if (self.audioInterruptionActive) { self.resumeAfterInterruption = !self.resumeAfterInterruption; return; }
    self.resumeAfterInterruption = NO;
    if ([self isTransportStream] && !self.prepared) {
        if (!self.preparing) [self prepareTransportStream];
        return;
    }
    if (self.player.isPlaying) [self.player pause];
    else {
        if (self.player.state == VLCMediaPlayerStateEnded) self.player.position = 0;
        [self.player play];
        [self applyPlaybackRate];
    }
}
- (double)duration { return self.player.media.length.intValue / 1000.0; }
- (double)currentPlaybackTime {
    double actual = MAX(0, self.player.time.intValue / 1000.0);
    // VLC may not publish a new clock while paused. Retain the requested position
    // until the decoder acknowledges it; stop masking an unsuccessful playing seek.
    if (self.hasPendingSeek) {
        if (fabs(actual - self.pendingSeekTime) < 1 || (self.player.isPlaying && NSDate.timeIntervalSinceReferenceDate - self.seekIssuedAt > 5)) self.hasPendingSeek = NO;
        else return self.pendingSeekTime;
    }
    return actual;
}
- (void)seekToTime:(double)seconds {
    double duration = [self duration];
    if (!self.player.isSeekable || duration <= 0) return;
    self.pendingSeekTime = MIN(MAX(seconds, 0), MAX(0, duration - 0.25));
    self.seekIssuedAt = NSDate.timeIntervalSinceReferenceDate;
    self.hasPendingSeek = YES;
    self.waitingForSeekFrames = YES;
    self.seekFrameBaseline = self.player.media.statistics.displayedPictures;
    BOOL wasPaused = self.player.state == VLCMediaPlayerStatePaused;
    self.player.position = self.pendingSeekTime / duration;
    if (wasPaused) [self.player gotoNextFrame];
    self.controlsTouched = NSDate.timeIntervalSinceReferenceDate;
}
- (void)seekBy:(double)offset {
    [self endBoost];
    self.controlsTouched = NSDate.timeIntervalSinceReferenceDate;
    if (self.player.isSeekable && [self duration] > 0) {
        [self seekToTime:[self currentPlaybackTime] + offset];
    }
}
- (void)backward { [self seekBy:-10]; }
- (void)forward { [self seekBy:10]; }
- (void)scrubBegin { [self endBoost]; self.scrubbing = YES; self.controlsTouched = NSDate.timeIntervalSinceReferenceDate; }
- (void)scrubPreview { self.timeLabel.text = [NSString stringWithFormat:@"%@ / %@", ClockText(self.slider.value * [self duration]), ClockText([self duration])]; }
- (void)scrubEnd { [self seekToTime:self.slider.value * [self duration]]; self.scrubbing = NO; self.controlsTouched = NSDate.timeIntervalSinceReferenceDate; }
- (void)scrubCancel { self.scrubbing = NO; self.controlsTouched = NSDate.timeIntervalSinceReferenceDate; }
- (void)saveProgress {
    // A moving clock or requested seek is not evidence that video recovered.
    if (self.restored && self.lastPlayableTime > 0 && self.player.state != VLCMediaPlayerStateEnded) {
        [NSUserDefaults.standardUserDefaults setDouble:self.lastPlayableTime forKey:self.progressKey];
    }
}
- (void)tick {
    if (self.closed) return;
    [self updateVideoLayout];
    double duration = [self duration];
    NSInteger displayed = self.player.media.statistics.displayedPictures;
    double actualTime = MAX(0, self.player.time.intValue / 1000.0);
    if (self.waitingForSeekFrames && displayed > self.seekFrameBaseline + 2 && fabs(actualTime - self.pendingSeekTime) < 8) self.waitingForSeekFrames = NO;
    if (!self.waitingForSeekFrames && displayed > self.lastDisplayedFrames) self.lastPlayableTime = actualTime;
    self.lastDisplayedFrames = displayed;
    self.slider.enabled = self.player.isSeekable && duration > 0;
    self.gestureSurface.accessibilityValue = [NSString stringWithFormat:@"%@ / %@", ClockText([self currentPlaybackTime]), ClockText(duration)];
    if (!self.scrubbing && !self.panning) {
        double time = [self currentPlaybackTime];
        self.slider.value = duration > 0 ? time / duration : self.player.position;
        self.timeLabel.text = [NSString stringWithFormat:@"%@ / %@", ClockText(time), ClockText(duration)];
    }
    [self.playButton setImage:[UIImage systemImageNamed:self.player.isPlaying ? @"pause.fill" : @"play.fill"] forState:UIControlStateNormal];
    self.playButton.accessibilityLabel = self.player.isPlaying ? @"暂停" : @"播放";
    self.playButton.accessibilityValue = self.player.isPlaying ? @"playing" : @"paused";
    self.rateButton.accessibilityValue = [NSString stringWithFormat:@"%g×", self.player.rate];
    BOOL automaticHideEnabled = YES;
#if DEBUG
    // The dedicated hide/tap UI test uses the real timer. Other automation
    // tests isolate their interactions from slow simulator snapshot latency.
    automaticHideEnabled = ![NSProcessInfo.processInfo.arguments containsObject:@"--ui-test-keep-controls"];
#endif
    if (automaticHideEnabled && self.controlsVisible && self.player.isPlaying && !self.scrubbing && !self.panning && !self.boosting && !self.presentedViewController && !UIAccessibilityIsVoiceOverRunning() && NSDate.timeIntervalSinceReferenceDate - self.controlsTouched > 4) [self setPlaybackControlsVisible:NO];
    if (++self.ticks % 20 == 0) [self saveProgress];
}
- (void)mediaPlayerStateChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.closed) return;
        switch (self.player.state) {
            case VLCMediaPlayerStatePlaying:
                self.statusLabel.text = @"";
                [self applyPlaybackRate];
                break;
            case VLCMediaPlayerStateOpening: self.statusLabel.text = @"正在打开视频…"; break;
            case VLCMediaPlayerStateBuffering: self.statusLabel.text = @"正在缓冲…"; break;
            case VLCMediaPlayerStateError:
                [self endBoost];
                self.statusLabel.text = @"播放失败\n请检查电脑连接、访问码或视频格式";
                if (!self.controlsVisible) [self toggleControls];
                break;
            case VLCMediaPlayerStateEnded:
                self.hasPendingSeek = NO;
                [self endBoost];
                [NSUserDefaults.standardUserDefaults removeObjectForKey:self.progressKey];
                self.statusLabel.text = @"播放结束";
                if (!self.controlsVisible) [self toggleControls];
                break;
            case VLCMediaPlayerStatePaused: self.statusLabel.text = @"已暂停"; break;
            default: break;
        }
    });
}
- (void)mediaPlayerTimeChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.player.isPlaying) self.statusLabel.text = @"";
    });
}
- (void)showTracks {
    [self endBoost];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"字幕与音轨" message:self.subtitleFallback ? @"该 TS 的内嵌字幕无法用于播放缓存，仍可选择外挂字幕。" : nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"从头重新播放" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self cancelPanSeek];
        [self.player stop];
        self.hasPendingSeek = NO;
        self.waitingForSeekFrames = NO;
        self.lastPlayableTime = 0;
        self.lastDisplayedFrames = 0;
        self.restored = YES;
        [NSUserDefaults.standardUserDefaults removeObjectForKey:self.progressKey];
        if ([self isTransportStream] && !self.prepared) {
            if (!self.preparing) [self prepareTransportStream];
        } else {
            self.player.media = [self playbackMedia];
            [self.player play];
        }
        [self setPlaybackControlsVisible:YES];
    }]];
    NSArray *audioNames = self.player.audioTrackNames;
    NSArray *audioIDs = self.player.audioTrackIndexes;
    for (NSUInteger i = 0; i < MIN(audioNames.count, audioIDs.count); i++) {
        int track = [audioIDs[i] intValue];
        NSString *name = [NSString stringWithFormat:@"%@音轨 · %@", track == self.player.currentAudioTrackIndex ? @"✓ " : @"", audioNames[i]];
        [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { self.player.currentAudioTrackIndex = track; }]];
    }
    NSArray *subNames = self.player.videoSubTitlesNames;
    NSArray *subIDs = self.player.videoSubTitlesIndexes;
    for (NSUInteger i = 0; i < MIN(subNames.count, subIDs.count); i++) {
        int track = [subIDs[i] intValue];
        NSString *name = [NSString stringWithFormat:@"%@字幕 · %@", track == self.player.currentVideoSubTitleIndex ? @"✓ " : @"", subNames[i]];
        [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { self.player.currentVideoSubTitleIndex = track; }]];
    }
    for (NSDictionary *subtitle in self.subtitles) {
        [sheet addAction:[UIAlertAction actionWithTitle:[@"外挂 · " stringByAppendingString:subtitle[@"name"]] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self.player addPlaybackSlave:ServiceURL(@"/media", subtitle[@"path"]) type:VLCMediaPlaybackSlaveTypeSubtitle enforce:YES];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"关闭字幕" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { self.player.currentVideoSubTitleIndex = -1; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.footer;
    sheet.popoverPresentationController.sourceRect = self.footer.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)background {
#if DEBUG
    NSLog(@"PLAYBACK_LIFECYCLE inactive state=%ld playing=%d", (long)self.player.state, self.player.isPlaying);
#endif
    [self cancelPanSeek];
    [self scrubCancel];
    [self endBoost];
    [self saveProgress];
    self.resumeAfterBackground = self.player.isPlaying;
    if (self.player.isPlaying) [self.player pause];
}
- (void)active {
#if DEBUG
    NSLog(@"PLAYBACK_LIFECYCLE active pending=%d interrupted=%d", self.resumeAfterBackground, self.audioInterruptionActive);
#endif
    if (self.resumeAfterBackground && !self.audioInterruptionActive && !self.closed) { [self.player play]; [self applyPlaybackRate]; }
    if (self.audioInterruptionActive) return;
    self.resumeAfterBackground = NO;
}
- (void)audioInterrupted:(NSNotification *)note {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self audioInterrupted:note]; });
        return;
    }
    if (self.closed) return;
#if DEBUG
    NSLog(@"PLAYBACK_LIFECYCLE interruption type=%@ options=%@ state=%ld", note.userInfo[AVAudioSessionInterruptionTypeKey], note.userInfo[AVAudioSessionInterruptionOptionKey], (long)self.player.state);
#endif
    if ([note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan) {
        if (!self.audioInterruptionActive) self.resumeAfterInterruption = self.player.isPlaying || self.resumeAfterBackground || self.player.state == VLCMediaPlayerStateOpening || self.player.state == VLCMediaPlayerStateBuffering;
        self.audioInterruptionActive = YES;
        [self endBoost];
        [self.player pause];
        self.resumeAfterBackground = NO;
    } else {
        BOOL resume = self.resumeAfterInterruption && ([note.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue] & AVAudioSessionInterruptionOptionShouldResume);
        self.audioInterruptionActive = NO;
        self.resumeAfterInterruption = NO;
        if (resume) {
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                [AVAudioSession.sharedInstance setActive:YES error:nil];
                [self.player play];
                [self applyPlaybackRate];
            } else self.resumeAfterBackground = YES;
        }
    }
}
- (void)closePlayer {
    [self stopPlayer];
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)stopPlayer {
    if (self.closed) return;
    [self endBoost];
    [self saveProgress];
    self.closed = YES;
    [self.subtitleTask cancel];
    [self.playbackTask cancel];
    [self.cropTask cancel];
    [self.timer invalidate];
    self.timer = nil;
    self.player.delegate = nil;
    [self.player stop];
    [self.audioOutput shutdown];
    self.player.drawable = nil;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    UIApplication.sharedApplication.idleTimerDisabled = NO;
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || !self.presentingViewController) [self stopPlayer];
}
- (void)dealloc { [self.timer invalidate]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end

@interface BrowserController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic, copy) NSString *folder;
@property(nonatomic, copy) NSArray<NSDictionary *> *items;
@property(nonatomic, copy) NSArray<NSDictionary *> *visibleItems;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSTimer *searchTimer;
@property(nonatomic, strong) UILabel *message;
@property(nonatomic, strong) UIButton *connectButton;
@property(nonatomic) NSInteger generation;
@property(nonatomic) NSInteger skippedSearchItems;
@property(nonatomic) BOOL itemsLoaded;
@property(nonatomic, strong) UIBarButtonItem *sortButton;
@end

@implementation BrowserController
- (instancetype)initWithFolder:(NSString *)folder title:(NSString *)title {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { self.folder = folder; self.title = title; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.items = @[];
    self.visibleItems = @[];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 76;
    self.tableView.sectionHeaderHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedSectionHeaderHeight = 44;
    self.navigationItem.largeTitleDisplayMode = self.folder.length ? UINavigationItemLargeTitleDisplayModeNever : UINavigationItemLargeTitleDisplayModeAutomatic;
    UIBarButtonItem *connection = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"network"] style:UIBarButtonItemStylePlain target:self action:@selector(settings)];
    connection.accessibilityLabel = @"电脑连接设置";
    self.sortButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"] menu:nil];
    self.sortButton.accessibilityLabel = @"排序";
    self.navigationItem.rightBarButtonItems = @[connection, self.sortButton];
    [self updateSortMenu];
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"搜索此文件夹及子文件夹";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(loadFolder) forControlEvents:UIControlEventValueChanged];
    self.message = [UILabel new];
    self.message.textAlignment = NSTextAlignmentCenter;
    self.message.numberOfLines = 0;
    self.message.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.message.adjustsFontForContentSizeCategory = YES;
    self.message.textColor = UIColor.secondaryLabelColor;
    self.connectButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
    config.title = @"连接电脑";
    config.image = [UIImage systemImageNamed:@"network"];
    config.imagePadding = 8;
    config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    config.contentInsets = NSDirectionalEdgeInsetsMake(14, 24, 14, 24);
    self.connectButton.configuration = config;
    [self.connectButton addTarget:self action:@selector(settings) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *empty = [[UIStackView alloc] initWithArrangedSubviews:@[self.message, self.connectButton]];
    empty.axis = UILayoutConstraintAxisVertical;
    empty.alignment = UIStackViewAlignmentCenter;
    empty.spacing = 24;
    empty.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *background = [UIView new];
    [background addSubview:empty];
    [NSLayoutConstraint activateConstraints:@[
        [empty.centerXAnchor constraintEqualToAnchor:background.centerXAnchor],
        [empty.centerYAnchor constraintEqualToAnchor:background.centerYAnchor],
        [empty.widthAnchor constraintLessThanOrEqualToAnchor:background.widthAnchor constant:-48]]];
    self.tableView.backgroundView = background;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateSortMenu];
    [self loadFolder];
}
- (NSString *)sortKey {
    NSString *key = [NSUserDefaults.standardUserDefaults stringForKey:@"fileSortKey"];
    return [@[@"name", @"size", @"modified", @"type"] containsObject:key ?: @""] ? key : @"name";
}
- (NSString *)sortDescription {
    NSString *key = [self sortKey];
    BOOL descending = [NSUserDefaults.standardUserDefaults boolForKey:@"fileSortDescending"];
    NSString *name = @{@"name":@"文件名", @"size":@"大小", @"modified":@"修改时间", @"type":@"类型"}[key];
    NSString *direction = [key isEqual:@"modified"] ? (descending ? @"最新在前" : @"最早在前") : ([key isEqual:@"size"] ? (descending ? @"从大到小" : @"从小到大") : (descending ? @"降序" : @"升序"));
    return [NSString stringWithFormat:@"%@ · %@", name, direction];
}
- (void)applyFileSort {
    self.visibleItems = LCSortedItems(self.visibleItems, [self sortKey], [NSUserDefaults.standardUserDefaults boolForKey:@"fileSortDescending"]);
    [self updateSortMenu];
    [self.tableView reloadData];
}
- (void)updateSortMenu {
    NSString *key = [self sortKey];
    BOOL descending = [NSUserDefaults.standardUserDefaults boolForKey:@"fileSortDescending"];
    NSMutableArray *fields = [NSMutableArray new];
    NSArray *keys = @[@"name", @"size", @"modified", @"type"];
    NSArray *names = @[@"文件名", @"大小", @"修改时间", @"类型"];
    __weak typeof(self) owner = self;
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSString *field = keys[i];
        UIAction *action = [UIAction actionWithTitle:names[i] image:nil identifier:nil handler:^(UIAction *a) {
            [NSUserDefaults.standardUserDefaults setObject:field forKey:@"fileSortKey"];
            [owner applyFileSort];
        }];
        action.state = [field isEqual:key] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [fields addObject:action];
    }
    NSArray *directions = [key isEqual:@"modified"] ? @[@"最早在前", @"最新在前"] : ([key isEqual:@"size"] ? @[@"从小到大", @"从大到小"] : @[@"升序", @"降序"]);
    NSMutableArray *orders = [NSMutableArray new];
    for (NSUInteger i = 0; i < 2; i++) {
        BOOL reverse = i == 1;
        UIAction *action = [UIAction actionWithTitle:directions[i] image:nil identifier:nil handler:^(UIAction *a) {
            [NSUserDefaults.standardUserDefaults setBool:reverse forKey:@"fileSortDescending"];
            [owner applyFileSort];
        }];
        action.state = reverse == descending ? UIMenuElementStateOn : UIMenuElementStateOff;
        [orders addObject:action];
    }
    self.sortButton.menu = [UIMenu menuWithTitle:@"排序 · 文件夹优先" children:@[
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:fields],
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:orders]]];
    self.sortButton.accessibilityValue = [self sortDescription];
}
- (void)loadFolder {
    [self.searchTimer invalidate];
    self.searchTimer = nil;
    [self.task cancel];
    NSInteger request = ++self.generation;
    NSString *query = [self.navigationItem.searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    BOOL searching = query.length > 0;
    if (!LCPassword().length) {
        self.message.text = @"你的电脑，随身影院\n\n连接同一 Wi-Fi，即可浏览\n电脑共享的文件夹与视频";
        self.connectButton.hidden = NO;
        [self.refreshControl endRefreshing];
        return;
    }
    NSURL *url = ServiceURL(searching ? @"/api/search" : @"/api/list", self.folder);
    if (searching && url) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        components.queryItems = [components.queryItems arrayByAddingObject:[NSURLQueryItem queryItemWithName:@"q" value:query]];
        url = components.URL;
    }
    if (!url) { self.message.text = @"电脑地址无效，请修改连接设置"; [self.refreshControl endRefreshing]; return; }
    self.message.text = searching ? @"正在搜索此文件夹\n及所有子文件夹…" : (self.items.count ? @"" : @"正在读取文件夹…");
    self.connectButton.hidden = YES;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = searching ? 120 : 15;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    __weak typeof(self) weakSelf = self;
    self.task = [NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        dispatch_async(dispatch_get_main_queue(), ^{
            BrowserController *s = weakSelf;
            if (!s || request != s.generation) return;
            [s.refreshControl endRefreshing];
            if (status == 200 && [json isKindOfClass:NSDictionary.class] && [json[@"items"] isKindOfClass:NSArray.class]) {
                if ([json[@"root"] isKindOfClass:NSString.class]) [NSUserDefaults.standardUserDefaults setObject:json[@"root"] forKey:@"sharedRoot"];
                if ([json[@"libraryID"] isKindOfClass:NSString.class]) [NSUserDefaults.standardUserDefaults setObject:json[@"libraryID"] forKey:@"libraryID"];
                if (!searching) { s.items = json[@"items"]; s.itemsLoaded = YES; }
                s.visibleItems = json[@"items"];
                s.skippedSearchItems = searching ? [json[@"skipped"] integerValue] : 0;
                s.message.text = s.visibleItems.count ? @"" : (searching ? @"没有匹配的文件" : @"这个文件夹是空的");
                if (!s.visibleItems.count && s.skippedSearchItems > 0) s.message.text = @"没有找到匹配项\n部分目录或文件无法读取";
                [s applyFileSort];
            } else if (error.code != NSURLErrorCancelled) {
                if (!searching) { s.items = @[]; s.itemsLoaded = NO; }
                s.visibleItems = @[];
                s.connectButton.hidden = NO;
                [s.tableView reloadData];
                s.message.text = status == 401 ? @"密码不正确\n请修改右上角连接设置" : (status == 404 ? (searching ? @"搜索服务或目录不可用\n请更新并重启电脑文件服务" : @"文件夹不存在或已被移动\n返回上一层后刷新") : @"无法读取电脑文件\n\n请检查连接与电脑端服务\n下拉重试，或点击右上角修改连接");
            }
        });
    }];
    [self.task resume];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)search {
    [self.searchTimer invalidate];
    [self.task cancel];
    ++self.generation;
    self.skippedSearchItems = 0;
    NSString *query = [search.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (!query.length) {
        if (!self.itemsLoaded) { [self loadFolder]; return; }
        self.visibleItems = self.items;
        self.message.text = self.visibleItems.count ? @"" : @"这个文件夹是空的";
    } else {
        self.visibleItems = @[];
        self.message.text = @"正在搜索此文件夹\n及所有子文件夹…";
        __weak typeof(self) weakSelf = self;
        self.searchTimer = [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:NO block:^(NSTimer *timer) { [weakSelf loadFolder]; }];
    }
    self.connectButton.hidden = YES;
    [self applyFileSort];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.visibleItems.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return self.folder.length ? self.folder : [[NSUserDefaults.standardUserDefaults stringForKey:@"sharedRoot"] ?: @"共享文件夹" stringByAppendingString:@" · 只读文件库"]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.navigationItem.searchController.searchBar.text.length) {
        NSString *summary = [NSString stringWithFormat:@"搜索当前文件夹及所有子文件夹 · %lu 项", (unsigned long)self.visibleItems.count];
        if (self.skippedSearchItems > 0) summary = [summary stringByAppendingFormat:@"\n%ld 个项目无法读取或不在搜索范围内", (long)self.skippedSearchItems];
        return [summary stringByAppendingFormat:@"\n%@ · 文件夹优先", [self sortDescription]];
    }
    return [NSString stringWithFormat:@"%@ · 文件夹优先\n点击文件夹进入 · 点击视频播放", [self sortDescription]];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"file"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"file"];
    NSDictionary *item = self.visibleItems[indexPath.row];
    BOOL folder = [item[@"directory"] boolValue];
    BOOL video = [item[@"video"] boolValue];
    cell.textLabel.text = item[@"name"];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.lineBreakMode = NSLineBreakByCharWrapping;
    cell.detailTextLabel.text = folder ? @"文件夹" : [NSByteCountFormatter stringFromByteCount:[item[@"size"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile];
    if ([[self sortKey] isEqual:@"modified"]) {
        NSString *date = [item[@"modified"] isKindOfClass:NSNumber.class] ? [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:[item[@"modified"] doubleValue]] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle] : @"修改时间不可用，请更新电脑端";
        cell.detailTextLabel.text = [cell.detailTextLabel.text stringByAppendingFormat:@" · %@", date];
    } else if ([[self sortKey] isEqual:@"type"] && !folder) {
        NSString *extension = [item[@"name"] pathExtension].uppercaseString;
        cell.detailTextLabel.text = [cell.detailTextLabel.text stringByAppendingFormat:@" · %@", extension.length ? extension : @"无扩展名"];
    }
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    if (!folder) {
        NSString *key = [NSString stringWithFormat:@"progress:%@:%@", [[NSUserDefaults.standardUserDefaults stringForKey:HostKey] stringByAppendingFormat:@":%@", [NSUserDefaults.standardUserDefaults stringForKey:@"libraryID"] ?: @""], item[@"path"]];
        double progress = [NSUserDefaults.standardUserDefaults doubleForKey:key];
        if (progress > 0) cell.detailTextLabel.text = [cell.detailTextLabel.text stringByAppendingFormat:@"  ·  上次 %@", ClockText(progress)];
    }
    if (self.navigationItem.searchController.searchBar.text.length) {
        NSString *parent = [item[@"path"] stringByDeletingLastPathComponent];
        cell.detailTextLabel.text = [cell.detailTextLabel.text stringByAppendingFormat:@"\n%@", parent.length ? [[[NSUserDefaults.standardUserDefaults stringForKey:@"sharedRoot"] ?: @"共享文件夹" stringByAppendingString:@"/"] stringByAppendingString:parent] : ([NSUserDefaults.standardUserDefaults stringForKey:@"sharedRoot"] ?: @"共享文件夹")];
    }
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByCharWrapping;
    cell.imageView.image = [UIImage systemImageNamed:folder ? @"folder.fill" : (video ? @"play.rectangle.fill" : @"doc")];
    cell.imageView.tintColor = folder ? UIColor.systemMintColor : UIColor.systemTealColor;
    cell.accessoryType = folder ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return cell;
}
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UILabel *label = ((UITableViewHeaderFooterView *)view).textLabel;
        label.numberOfLines = 0;
        label.lineBreakMode = NSLineBreakByCharWrapping;
    }
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = self.visibleItems[indexPath.row];
    if ([item[@"directory"] boolValue]) {
        BrowserController *next = [[BrowserController alloc] initWithFolder:item[@"path"] title:item[@"name"]];
        [self.navigationController pushViewController:next animated:YES];
    } else if ([item[@"subtitle"] boolValue]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"字幕文件" message:@"先打开视频，再点击播放器中的字幕按钮选择此文件。" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    } else {
        // Unknown extensions may still contain formats VLC can recognize.
        PlayerController *player = [PlayerController new];
        player.item = item;
        NSString *parent = [item[@"path"] stringByDeletingLastPathComponent];
        player.subtitles = [parent isEqualToString:self.folder] ? [self.items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *obj, NSDictionary *bindings) { return [obj[@"subtitle"] boolValue]; }]] : @[];
        player.modalPresentationStyle = UIModalPresentationFullScreen;
        [self.navigationItem.searchController.searchBar resignFirstResponder];
        UIViewController *presenter = self;
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        [presenter presentViewController:player animated:YES completion:nil];
    }
}
- (void)settings {
    ConnectionController *connection = [ConnectionController new];
    __weak typeof(self) weakSelf = self;
    connection.onConnected = ^{
        BrowserController *root = (BrowserController *)weakSelf.navigationController.viewControllers.firstObject;
        [weakSelf.navigationController popToRootViewControllerAnimated:YES];
        root.navigationItem.searchController.searchBar.text = @"";
        root.items = @[]; root.visibleItems = @[]; root.itemsLoaded = NO;
        [root.tableView reloadData]; [root loadFolder];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:connection];
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)dealloc { [self.task cancel]; [self.searchTimer invalidate]; }
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    BrowserController *browser = [[BrowserController alloc] initWithFolder:@"" title:@"局域影院"];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:browser];
    nav.navigationBar.prefersLargeTitles = YES;
    nav.view.tintColor = UIColor.systemTealColor;
    self.window.rootViewController = nav;
#if DEBUG
    NSArray *arguments = NSProcessInfo.processInfo.arguments;
    if ([arguments containsObject:@"--ui-test-dark"]) self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    if ([arguments containsObject:@"--ui-test-large"]) {
        if (@available(iOS 17.0, *)) nav.traitOverrides.preferredContentSizeCategory = UIContentSizeCategoryAccessibilityExtraExtraExtraLarge;
    }
#endif
    [self.window makeKeyAndVisible];
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
#if DEBUG
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--ui-test"]) {
        [NSUserDefaults.standardUserDefaults removePersistentDomainForName:NSBundle.mainBundle.bundleIdentifier];
        [NSUserDefaults.standardUserDefaults setObject:@"127.0.0.1" forKey:HostKey];
        LCStorePassword(@"ui-test-access-code");
    }
#endif
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}
