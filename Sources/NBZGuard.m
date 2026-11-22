#import "NBZGuard.h"
#import "NBZBlocklist.h"
#import "NBZPlayerUI.h"
#import "NBZProviders.h"
#import "NBZUtil.h"
#import <MediaPlayer/MediaPlayer.h>

@interface NBZGuard ()
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation NBZGuard

+ (instancetype)shared {
    static NBZGuard *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NBZGuard new]; });
    return s;
}

- (void)start {
    if (self.timer) return;
    self.timer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    NBZLog(@"guard started");
}

- (void)tick:(NSTimer *)timer {
    if (!NBZBool(NBZKeyBlockEnabled, YES)) return;
    double rate = [[MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] doubleValue];
    if (rate <= 0) return;

    // Same snapshot and same state machine as the Block pill: a guard skip and
    // a user block for one video can never both act on it.
    NBZNowPlaying *track = [[NBZPlayerUI shared] nowPlaying];
    if (!track) return;
    NBZBlockMatch *match = [[NBZBlocklist shared] matchTrack:track.title artist:track.artist
                                                  channelIDs:track.artistChannelIDs];
    if (!match) return;
    [[NBZPlayerUI shared] skipBlockedTrack:track match:match];
}

@end
