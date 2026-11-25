#import <Foundation/Foundation.h>
@class VLCMediaPlayer;

// VLC decodes/mixes/time-stretches to stereo PCM. AVAudioEngine owns the
// persistent device output, so a pause does not discard queued audio.
@interface LCAudioOutput : NSObject
- (instancetype)initWithPlayer:(VLCMediaPlayer *)player;
- (void)reset;
- (void)shutdown;
#if DEBUG
- (void)beginRenderProbe;
- (double)renderProbeDelay;
- (double)renderProbeLongestGap;
- (NSUInteger)renderedNonSilentBuffers;
#endif
@end
