#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, LCSeekOutcome) { LCSeekWaiting, LCSeekConfirmed, LCSeekRetry, LCSeekFailed };
@interface LCPlaybackHealth : NSObject
@property(nonatomic, readonly) BOOL pending;
@property(nonatomic, readonly) double target;
@property(nonatomic, readonly) BOOL retried;
@property(nonatomic, readonly) double elapsed;
- (void)beginSeek:(double)target frames:(NSInteger)frames now:(double)now;
- (void)beginRecoveryWithFrames:(NSInteger)frames now:(double)now;
- (LCSeekOutcome)observeTime:(double)time frames:(NSInteger)frames now:(double)now running:(BOOL)running rate:(double)rate;
- (void)cancel;
@end

// Numeric-only event fields deliberately exclude URLs, tokens and media names.
@interface LCPlaybackDiagnostics : NSObject
- (void)record:(NSString *)event values:(NSDictionary<NSString *, NSNumber *> *)values;
- (NSString *)reportWithSnapshot:(NSDictionary<NSString *, NSNumber *> *)snapshot;
@end
