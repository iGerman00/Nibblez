#import "NBZScrobble.h"
#import "NBZUtil.h"
#import "NBZMetadata.h"
#import "NBZPlayerUI.h"
#import <MediaPlayer/MediaPlayer.h>

static const NSTimeInterval kPollInterval = 1.0;
static const NSTimeInterval kNowPlayingDelay = 2.0;
static const NSTimeInterval kResumeResendAfter = 10.0;  // paused this long: tell the service again
static const NSUInteger kMaxQueue = 200;

@interface NBZScrobbler ()
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong, readwrite, nullable) NBZTrack *currentTrack;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id<NBZScrobbleProvider>> *providers;
@property (nonatomic) BOOL scrobbledCurrent;
@property (nonatomic) BOOL nowPlayingSent;
@property (nonatomic) NSTimeInterval lastTick;
@property (nonatomic) double lastElapsed;
@property (nonatomic) NSTimeInterval pausedAt;
@property (nonatomic, copy, readwrite) NSString *lastStatus;
@property (nonatomic) BOOL flushing;
@end

// A rejected request will never succeed on retry (bad data), unlike a network
// error, rate limit or auth problem. One of those must not block the queue.
static BOOL NBZIsPermanentFailure(NSString *error) {
    for (NSString *code in @[@"HTTP 400", @"HTTP 404", @"HTTP 413", @"HTTP 422"]) {
        if ([error hasPrefix:code]) return YES;
    }
    return NO;
}

@implementation NBZScrobbler

+ (instancetype)shared {
    static NBZScrobbler *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NBZScrobbler new]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _providers = [@{
            @"lastfm": [NBZLastFMProvider new],
            @"listenbrainz": [NBZListenBrainzProvider new],
            @"maloja": [NBZMalojaProvider new],
            @"webhook": [NBZWebhookProvider new],
        } mutableCopy];
        _lastStatus = @"Idle";
    }
    return self;
}

- (id<NBZScrobbleProvider>)activeProvider {
    NSString *ident = NBZString(NBZKeyScrobbleProvider) ?: @"lastfm";
    return self.providers[ident] ?: self.providers[@"lastfm"];
}

- (void)start {
    if (self.timer) return;
    NBZLog(@"scrobbler start (provider=%@)", [self.activeProvider displayName]);
    self.timer = [NSTimer timerWithTimeInterval:kPollInterval target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(flushQueue)
                                                 name:UIApplicationDidBecomeActiveNotification object:nil];
    [self flushQueue];
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    [self finalizeCurrentTrack];
    self.currentTrack = nil;
}

- (void)tick:(NSTimer *)timer {
    if (!NBZBool(NBZKeyScrobbleEnabled, YES)) {
        if (self.currentTrack) [self finalizeCurrentTrack];
        self.currentTrack = nil;
        return;
    }
    NSDictionary *info = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSTimeInterval delta = self.lastTick > 0 ? MIN(now - self.lastTick, 2.0) : 0;
    self.lastTick = now;

    if (![info isKindOfClass:[NSDictionary class]] || info.count == 0) {
        return; // transient gap between tracks; finalize after the next real change
    }

    NSString *title = info[MPMediaItemPropertyTitle];
    NSString *artist = info[MPMediaItemPropertyArtist];
    if (![title isKindOfClass:[NSString class]] || !title.length) return;
    if (![artist isKindOfClass:[NSString class]]) artist = @"";
    NSString *album = info[MPMediaItemPropertyAlbumTitle];
    if (![album isKindOfClass:[NSString class]]) album = @"";

    double rate = [info[MPNowPlayingInfoPropertyPlaybackRate] doubleValue];
    double elapsed = [info[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue];
    double duration = [info[MPMediaItemPropertyPlaybackDuration] doubleValue];

    // The video ID tells apart two uploads with the same title, and is sent to
    // ListenBrainz as the origin URL. Nil while the player is mid-transition.
    NBZNowPlaying *snapshot = [[NBZPlayerUI shared] nowPlaying];
    NSString *videoID = [snapshot.title isEqualToString:title] ? snapshot.videoID : nil;

    NBZTrack *track = self.currentTrack;
    BOOL changed = !track || ![track.rawTitle isEqualToString:title] || ![track.rawArtist isEqualToString:artist]
        || (videoID.length && track.videoID.length && ![track.videoID isEqualToString:videoID]);
    // Same song again (repeat, or replayed from the start) after it counted:
    // elapsed jumped back to the beginning.
    BOOL replayed = !changed && track.meetsScrobbleThreshold && self.lastElapsed - elapsed > 10 && elapsed < 10;
    self.lastElapsed = elapsed;

    if (changed || replayed) {
        [self finalizeCurrentTrack];
        track = [NBZTrack new];
        track.rawTitle = title;
        track.rawArtist = artist;
        track.title = NBZCleanTitle(title, album.length > 0);
        track.artist = NBZCleanArtist(artist);
        track.album = NBZCleanAlbum(album);
        track.duration = duration;
        track.videoID = videoID;
        track.startedAt = (elapsed > 2) ? now - elapsed : now;
        track.played = 0;
        self.currentTrack = track;
        self.scrobbledCurrent = NO;
        self.nowPlayingSent = NO;
        self.pausedAt = 0;
        NBZLog(@"%@: %@ - %@ (%.0fs)", replayed ? @"track replayed" : @"track changed", track.artist, track.title, track.duration);
    }
    if (!track.videoID.length && videoID.length) track.videoID = videoID;

    if (duration > 0) track.duration = duration;
    if (rate > 0) {
        // Coming back from a long pause: services drop "now playing" after a while.
        if (self.pausedAt > 0 && now - self.pausedAt >= kResumeResendAfter) self.nowPlayingSent = NO;
        self.pausedAt = 0;
        track.played += delta;
        if (!self.nowPlayingSent && track.played >= kNowPlayingDelay) {
            self.nowPlayingSent = YES;
            if (self.activeProvider.isConfigured) [self.activeProvider submitNowPlaying:track];
        }
    } else if (self.pausedAt == 0) {
        self.pausedAt = now;
    }
}

- (void)finalizeCurrentTrack {
    NBZTrack *track = self.currentTrack;
    if (!track) return;
    self.currentTrack = nil;
    if (!NBZBool(NBZKeyScrobbleEnabled, YES)) return;
    if (!track.meetsScrobbleThreshold) {
        NBZLog(@"skip scrobble %@ - %@ (played %.0fs of %.0fs)", track.artist, track.title, track.played, track.duration);
        return;
    }
    if (!self.activeProvider.isConfigured) {
        NBZLog(@"scrobble dropped: %@ not configured", [self.activeProvider displayName]);
        return;
    }
    if (self.scrobbledCurrent) return;
    self.scrobbledCurrent = YES;
    [self submit:track];
}

- (void)submit:(NBZTrack *)track {
    NBZLog(@"scrobbling %@ - %@", track.artist, track.title);
    [self.activeProvider scrobble:track completion:^(BOOL ok, NSString *error) {
        if (ok) {
            self.lastStatus = [NSString stringWithFormat:@"Scrobbled %@ - %@", track.artist, track.title];
            NBZLog(@"scrobble ok");
            [self flushQueue];
        } else {
            self.lastStatus = [NSString stringWithFormat:@"Queued: %@", error ?: @"offline"];
            NBZLog(@"scrobble failed (%@), queued", error);
            [self enqueue:track];
        }
    }];
}

- (void)forceScrobbleCurrentTrack {
    NBZTrack *track = self.currentTrack;
    if (!track) {
        self.lastStatus = @"Nothing playing";
        return;
    }
    if (!self.activeProvider.isConfigured) {
        self.lastStatus = [NSString stringWithFormat:@"%@ not configured", [self.activeProvider displayName]];
        return;
    }
    if (track.duration <= 0) track.duration = track.played;
    [self submit:track];
    self.scrobbledCurrent = YES;
}

#pragma mark - Offline queue

- (NSMutableArray *)queue {
    NSArray *q = [[NSUserDefaults standardUserDefaults] arrayForKey:[@"nbz." stringByAppendingString:NBZKeyScrobbleQueue]];
    return q ? [q mutableCopy] : [NSMutableArray array];
}

- (NSUInteger)queuedCount {
    return [self queue].count;
}

- (void)enqueue:(NBZTrack *)track {
    NSMutableArray *q = [self queue];
    if (q.count >= kMaxQueue) [q removeObjectAtIndex:0];
    [q addObject:[track dictionaryRepresentation]];
    [[NSUserDefaults standardUserDefaults] setObject:q forKey:[@"nbz." stringByAppendingString:NBZKeyScrobbleQueue]];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)flushQueue {
    if (self.flushing || !self.activeProvider.isConfigured) return;
    NSMutableArray *q = [self queue];
    if (!q.count) return;
    self.flushing = YES;
    NSDictionary *first = q.firstObject;
    NBZTrack *track = [NBZTrack trackFromDictionary:first];
    [self.activeProvider scrobble:track completion:^(BOOL ok, NSString *error) {
        self.flushing = NO;
        if (!ok && !NBZIsPermanentFailure(error)) {
            NBZLog(@"queue flush stopped: %@", error);
            return;
        }
        if (!ok) NBZLog(@"queue: dropping %@ - %@ (%@)", track.artist, track.title, error);
        NSMutableArray *current = [self queue];
        if (current.count) [current removeObjectAtIndex:0];
        [[NSUserDefaults standardUserDefaults] setObject:current forKey:[@"nbz." stringByAppendingString:NBZKeyScrobbleQueue]];
        [[NSUserDefaults standardUserDefaults] synchronize];
        NBZLog(@"queue flushed one (%lu left)", (unsigned long)current.count);
        if (current.count) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self flushQueue];
            });
        }
    }];
}

@end
