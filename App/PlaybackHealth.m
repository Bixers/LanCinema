#import "PlaybackHealth.h"
#import <math.h>
@interface LCPlaybackHealth ()
@property(nonatomic) BOOL pending;
@property(nonatomic) double target;
@property(nonatomic) BOOL retried;
@property(nonatomic) double elapsed;
@property(nonatomic) NSInteger baseline;
@property(nonatomic) double lastSample;
@property(nonatomic) BOOL wasRunning;
@end
@implementation LCPlaybackHealth
- (void)beginSeek:(double)target frames:(NSInteger)frames now:(double)now {
    self.pending = YES; self.target = MAX(0, target); self.baseline = frames;
    self.lastSample = now; self.elapsed = 0; self.retried = NO; self.wasRunning = NO;
}
- (void)beginRecoveryWithFrames:(NSInteger)frames now:(double)now {
    self.baseline = frames; self.lastSample = now; self.elapsed = 0; self.wasRunning = NO; self.retried = YES;
}
- (LCSeekOutcome)observeTime:(double)time frames:(NSInteger)frames now:(double)now running:(BOOL)running rate:(double)rate {
    if (!self.pending) return LCSeekWaiting;
    // Pauses, backgrounding and interruptions consume no recovery budget.
    if (running && self.wasRunning) self.elapsed += MIN(1, MAX(0, now - self.lastSample));
    self.wasRunning = running; self.lastSample = now;
    double tolerance = running ? MAX(2, MIN(6, rate * 1.5)) : 2;
    if (frames > self.baseline && isfinite(time) && fabs(time - self.target) <= tolerance) {
        self.pending = NO; return LCSeekConfirmed;
    }
    if (!running) return LCSeekWaiting;
    if (!self.retried && self.elapsed >= 8) { self.retried = YES; return LCSeekRetry; }
    if (self.retried && self.elapsed >= 12) { self.pending = NO; return LCSeekFailed; }
    return LCSeekWaiting;
}
- (void)cancel { self.pending = NO; }
@end

@interface LCPlaybackDiagnostics ()
@property(nonatomic, strong) NSMutableArray *events;
@property(nonatomic) double started;
@end
@implementation LCPlaybackDiagnostics
- (instancetype)init {
    if ((self = [super init])) { _events = [NSMutableArray new]; _started = NSProcessInfo.processInfo.systemUptime; }
    return self;
}
- (NSDictionary *)numbers:(NSDictionary *)values {
    NSMutableDictionary *safe = [NSMutableDictionary new];
    for (NSString *key in values) if ([values[key] isKindOfClass:NSNumber.class] && isfinite([values[key] doubleValue])) safe[key] = values[key];
    return safe;
}
- (void)record:(NSString *)event values:(NSDictionary<NSString *,NSNumber *> *)values {
    [self.events addObject:@{@"event":event, @"seconds":@(NSProcessInfo.processInfo.systemUptime - self.started), @"values":[self numbers:values]}];
    if (self.events.count > 160) [self.events removeObjectAtIndex:0];
}
- (NSString *)reportWithSnapshot:(NSDictionary<NSString *,NSNumber *> *)snapshot {
    NSDictionary *report = @{@"app": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"test",
                              @"system":NSProcessInfo.processInfo.operatingSystemVersionString,
                              @"snapshot":[self numbers:snapshot], @"events":self.events};
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{}";
}
@end
