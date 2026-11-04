#import "FileThumbnail.h"

@interface LCFileThumbnail ()
@property(nonatomic, strong) UIImageView *preview;
@property(nonatomic, strong) UIImageView *fallback;
@property(nonatomic, strong) NSURL *URL;
@property(nonatomic, copy) NSString *key;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSInteger retries;
@property(nonatomic) BOOL finished;
@end

@implementation LCFileThumbnail
+ (NSCache *)images {
    static NSCache *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.totalCostLimit = 16*1024*1024; cache.countLimit = 200; });
    return cache;
}
+ (NSURLSession *)session {
    static NSURLSession *session; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.HTTPMaximumConnectionsPerHost = 2;
        config.timeoutIntervalForRequest = 22;
        config.timeoutIntervalForResource = 30;
        config.URLCache = nil;
        session = [NSURLSession sessionWithConfiguration:config];
    });
    return session;
}
- (instancetype)initWithSymbol:(NSString *)symbol color:(UIColor *)color large:(BOOL)large URL:(NSURL *)URL cacheKey:(NSString *)key {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.URL = URL; self.key = key;
        self.isAccessibilityElement = NO;
        self.preview = [UIImageView new];
        self.preview.contentMode = UIViewContentModeScaleAspectFit;
        self.preview.clipsToBounds = YES;
        self.preview.layer.cornerRadius = large ? 4 : 2;
        self.preview.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.preview];
        self.fallback = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
        self.fallback.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:large ? 48 : 24];
        self.fallback.tintColor = color;
        self.fallback.contentMode = UIViewContentModeScaleAspectFit;
        self.fallback.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.fallback];
        [NSLayoutConstraint activateConstraints:@[
            [self.preview.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.preview.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.preview.topAnchor constraintEqualToAnchor:self.topAnchor],
            [self.preview.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [self.fallback.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [self.fallback.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.fallback.widthAnchor constraintEqualToConstant:large ? 64 : 30],
            [self.fallback.heightAnchor constraintEqualToConstant:large ? 60 : 32]]];
    }
    return self;
}
- (void)showImage:(UIImage *)image {
    self.preview.image = image;
    self.fallback.hidden = YES;
    self.finished = YES;
    // Kept out of spoken labels; UI tests also inspect actual rendered pixels.
    self.accessibilityIdentifier = @"video-thumbnail-ready";
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) { [self loadPreview]; }
    else { ++self.generation; [self.task cancel]; self.task = nil; self.retries = 0; }
}
- (void)loadPreview {
    if (!self.window || !self.URL || self.finished || self.task) return;
    UIImage *cached = [LCFileThumbnail.images objectForKey:self.key];
    if (cached) { [self showImage:cached]; return; }
    NSUInteger generation = ++self.generation;
    __weak typeof(self) owner = self;
    self.task = [LCFileThumbnail.session dataTaskWithURL:self.URL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        UIImage *image = status == 200 && [response.MIMEType isEqualToString:@"image/jpeg"] && data.length <= 256*1024 ? [UIImage imageWithData:data] : nil;
        image = [image imageByPreparingForDisplay] ?: image;
        dispatch_async(dispatch_get_main_queue(), ^{
            LCFileThumbnail *view = owner;
            if (!view || generation != view.generation) return;
            view.task = nil;
            if (image) {
                [LCFileThumbnail.images setObject:image forKey:view.key cost:(NSUInteger)(image.size.width*image.size.height*4)];
                [view showImage:image];
            } else if ((status == 503 || (error && error.code != NSURLErrorCancelled)) && view.retries < 3 && view.window) {
                view.retries++;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (2*view.retries)*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    LCFileThumbnail *pending = owner;
                    if (pending && pending.generation == generation) [pending loadPreview];
                });
            }
        });
    }];
    self.task.priority = NSURLSessionTaskPriorityLow;
    [self.task resume];
}
- (void)dealloc { [self.task cancel]; }
@end
