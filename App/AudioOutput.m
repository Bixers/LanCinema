#import "AudioOutput.h"
#import <AVFoundation/AVFoundation.h>
#import <MobileVLCKit/MobileVLCKit.h>
#import <mach/mach_time.h>

// Public libvlc 3 callback API; VLCKit's bridge exposes the owning player.
extern void libvlc_audio_set_callbacks(void *, void (*)(void *, const void *, unsigned, int64_t),
                                     void (*)(void *, int64_t), void (*)(void *, int64_t),
                                     void (*)(void *, int64_t), void (*)(void *), void *);
extern void libvlc_audio_set_format(void *, const char *, unsigned, unsigned);
extern int64_t libvlc_clock(void);
@interface VLCMediaPlayer (LCAudioBridge)
- (void *)libVLCMediaPlayer;
@end

@interface LCAudioOutput ()
@property(nonatomic, strong) AVAudioEngine *engine;
@property(nonatomic, strong) AVAudioPlayerNode *node;
@property(nonatomic, strong) AVAudioFormat *format;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic) BOOL paused;
@property(nonatomic) BOOL scheduled;
@property(nonatomic) BOOL closed;
#if DEBUG
@property(nonatomic) BOOL tapped;
@property(nonatomic) uint64_t probeStart;
@property(nonatomic) uint64_t probeFirst;
@property(nonatomic) NSUInteger probeCount;
@property(nonatomic) uint64_t probeMinimumHost;
@property(nonatomic) uint64_t probeLast;
@property(nonatomic) uint64_t probeLongest;
#endif
- (void)enqueue:(const float *)samples count:(unsigned)count pts:(int64_t)pts;
- (void)setOutputPaused:(BOOL)paused;
- (void)flush;
@end

static void LCPlay(void *opaque, const void *samples, unsigned count, int64_t pts) {
    @autoreleasepool { [(__bridge LCAudioOutput *)opaque enqueue:samples count:count pts:pts]; }
}
static void LCPause(void *opaque, int64_t pts) { [(__bridge LCAudioOutput *)opaque setOutputPaused:YES]; }
static void LCResume(void *opaque, int64_t pts) { [(__bridge LCAudioOutput *)opaque setOutputPaused:NO]; }
static void LCFlush(void *opaque, int64_t pts) { [(__bridge LCAudioOutput *)opaque flush]; }

@implementation LCAudioOutput
- (instancetype)initWithPlayer:(VLCMediaPlayer *)player {
    if (!(self = [super init])) return nil;
    _queue = dispatch_queue_create("local.bixer.LanCinema.audio", DISPATCH_QUEUE_SERIAL);
    _engine = [AVAudioEngine new];
    _node = [AVAudioPlayerNode new];
    _format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    [_engine attachNode:_node];
    [_engine connect:_node to:_engine.mainMixerNode format:_format];
    [_engine prepare];
    NSError *error;
    if (![_engine startAndReturnError:&error]) return nil;
    libvlc_audio_set_callbacks(player.libVLCMediaPlayer, LCPlay, LCPause, LCResume, LCFlush, NULL, (__bridge void *)self);
    libvlc_audio_set_format(player.libVLCMediaPlayer, "FL32", 48000, 2);
    return self;
}
- (void)enqueue:(const float *)samples count:(unsigned)count pts:(int64_t)pts {
    // libvlc's interleaved float buffer is valid only during this callback.
    if (!samples || count == 0) return;
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.format frameCapacity:count];
    if (!buffer) return;
    buffer.frameLength = count;
    for (unsigned i = 0; i < count; i++) {
        buffer.floatChannelData[0][i] = samples[i*2];
        buffer.floatChannelData[1][i] = samples[i*2+1];
    }
    dispatch_sync(self.queue, ^{
        if (self.closed) return;
        if (!self.engine.isRunning) {
            [self.node stop];
            self.scheduled = NO;
            [AVAudioSession.sharedInstance setActive:YES error:nil];
            if (![self.engine startAndReturnError:nil]) return;
        }
        [self.node scheduleBuffer:buffer completionHandler:nil];
        if (!self.scheduled) {
            self.scheduled = YES;
            if (!self.paused) {
                // Preserve VLC's A/V presentation clock across seeks. Do not
                // add another full network buffer at the device output.
                double delay = MAX(0, (pts - libvlc_clock()) / 1000000.0);
                uint64_t host = mach_absolute_time() + [AVAudioTime hostTimeForSeconds:delay];
#if DEBUG
                @synchronized (self) { self.probeMinimumHost = host; }
#endif
                [self.node playAtTime:[AVAudioTime timeWithHostTime:host]];
            }
        }
    });
}
- (void)setOutputPaused:(BOOL)paused {
    dispatch_sync(self.queue, ^{
        if (self.closed || self.paused == paused) return;
        self.paused = paused;
        if (paused) [self.node pause];
        else if (self.scheduled) {
            [AVAudioSession.sharedInstance setActive:YES error:nil];
            if (!self.engine.isRunning) [self.engine startAndReturnError:nil];
#if DEBUG
            @synchronized (self) { self.probeMinimumHost = mach_absolute_time(); }
#endif
            [self.node play];
        }
    });
}
- (void)flush {
    dispatch_sync(self.queue, ^{
        if (self.closed) return;
        // Seek discards only obsolete PCM. The output engine/session stays warm.
        [self.node stop];
        self.scheduled = NO;
#if DEBUG
        @synchronized (self) {
            self.probeFirst = 0; self.probeCount = 0; self.probeMinimumHost = UINT64_MAX;
            self.probeLast = self.probeStart; self.probeLongest = 0;
        }
#endif
    });
}
- (void)reset {
    [self flush];
    dispatch_sync(self.queue, ^{ self.paused = NO; });
}
- (void)shutdown {
    dispatch_sync(self.queue, ^{
        if (self.closed) return;
        self.closed = YES;
        [self.node stop];
#if DEBUG
        if (self.tapped) [self.engine.mainMixerNode removeTapOnBus:0];
#endif
        [self.engine stop];
    });
}
#if DEBUG
- (void)beginRenderProbe {
    @synchronized (self) {
        self.probeStart = mach_absolute_time(); self.probeFirst = 0; self.probeCount = 0;
        self.probeMinimumHost = self.probeStart;
        self.probeLast = self.probeStart; self.probeLongest = 0;
    }
    if (!self.tapped) {
        self.tapped = YES;
        __weak typeof(self) owner = self;
        [self.engine.mainMixerNode installTapOnBus:0 bufferSize:512 format:nil block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
            LCAudioOutput *s = owner;
            if (!s || !buffer.floatChannelData) return;
            BOOL nonSilent = NO;
            for (AVAudioFrameCount i = 0; i < buffer.frameLength; i++) {
                if (fabsf(buffer.floatChannelData[0][i]) > .003f) { nonSilent = YES; break; }
            }
            if (nonSilent) @synchronized (s) {
                if (!when.isHostTimeValid || when.hostTime < s.probeMinimumHost) return;
                uint64_t now = mach_absolute_time();
                if (!s.probeFirst) s.probeFirst = now;
                s.probeLongest = MAX(s.probeLongest, now-s.probeLast);
                s.probeLast = now;
                s.probeCount++;
            }
        }];
    }
}
- (double)renderProbeDelay {
    @synchronized (self) {
        return self.probeFirst ? [AVAudioTime secondsForHostTime:self.probeFirst-self.probeStart] : -1;
    }
}
- (NSUInteger)renderedNonSilentBuffers { @synchronized (self) { return self.probeCount; } }
- (double)renderProbeLongestGap {
    @synchronized (self) {
        return [AVAudioTime secondsForHostTime:MAX(self.probeLongest, mach_absolute_time()-self.probeLast)];
    }
}
#endif
@end
