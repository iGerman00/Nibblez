#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// What the app's player says is playing, read from one object so the three
// fields always belong to the same track.
@interface NBZNowPlaying : NSObject
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *title;
// Credited artists that link to an artist page, in credit order.
@property (nonatomic, copy) NSArray<NSString *> *artistChannelIDs;
@property (nonatomic, copy) NSArray<NSString *> *artistChannelNames;
@end

@interface NBZPlayerUI : NSObject

+ (instancetype)shared;

// Snapshot from -[YTMPlaybackPublishControllerImpl currentVideoID] and its
// nowPlayingItemInfo. Nil when nothing is loaded or the item info still
// belongs to the previous video (mid-transition). Main thread only.
- (nullable NBZNowPlaying *)nowPlaying;

// User action (action-row pill): block the artist, optionally dislike the
// exact video, then make sure that video stops playing.
- (void)blockNowPlaying;

// Guard action: the playing track matched the blocklist; skip it once.
- (void)skipBlockedTrack:(NBZNowPlaying *)track match:(id)match;  // NBZBlockMatch

// Target of the action-row pill.
- (void)actionBarBlockTapped:(nullable id)sender;

- (void)showToast:(NSString *)message;

// Hooks the app's dislike path (thumbs down blocks artist) and its snackbar
// and HUD managers (keeps our toast up over the app's dislike toast).
- (void)installAppHooks;

// Like/dislike remote commands (lock screen and Control Center star, CarPlay,
// Watch, Siri) and the artwork confirmation shown for them. Gated by the
// "Lock screen feedback button" setting.
- (void)installRemoteCommands;

@end

NS_ASSUME_NONNULL_END
