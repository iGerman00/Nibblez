#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Preference keys (without the nbz. prefix), shared with the settings UI.
extern NSString *const NBZKeyScrobbleEnabled;
extern NSString *const NBZKeyScrobbleProvider;
extern NSString *const NBZKeyLastFMAPIKey;
extern NSString *const NBZKeyLastFMSecret;
extern NSString *const NBZKeyLastFMSession;
extern NSString *const NBZKeyLastFMUser;
extern NSString *const NBZKeyLBToken;
extern NSString *const NBZKeyLBServer;
extern NSString *const NBZKeyMalojaURL;
extern NSString *const NBZKeyMalojaKey;
extern NSString *const NBZKeyWebhookURL;
extern NSString *const NBZKeyWebhookHeader;
extern NSString *const NBZKeyBlockEnabled;
extern NSString *const NBZKeyBlockCommunity;   // Soul Over AI list
extern NSString *const NBZKeyBlockZoundhub;    // Zoundhub list
extern NSString *const NBZKeyZoundhubMinRating; // "3" ... "5"
extern NSString *const NBZKeyBlockDislike;
// Lock screen / Control Center / CarPlay feedback commands, and how the star maps:
// "like2dislike" (tap=like, double=dislike), "dislike2like", "like", "dislike".
// With block.dislike on: only dislikes from the remote feedback button block.
extern NSString *const NBZKeyBlockDislikeRemoteOnly;
extern NSString *const NBZKeyRemoteFeedback;
extern NSString *const NBZKeyRemoteMode;
extern NSString *const NBZKeyDislikeOnBlock;
extern NSString *const NBZKeyBlockedArtists;
extern NSString *const NBZKeyScrobbleQueue;

@interface NBZTrack : NSObject
// Title and artist as the app reports them; title/artist below are the cleaned
// values sent to services.
@property (nonatomic, copy) NSString *rawTitle;
@property (nonatomic, copy) NSString *rawArtist;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *album;
@property (nonatomic, copy, nullable) NSString *videoID;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) NSTimeInterval played;    // seconds actually listened
@property (nonatomic) NSTimeInterval position;  // playback position, from the app
@property (nonatomic) NSTimeInterval startedAt;
@property (nonatomic) BOOL fromQueue;  // a retry of an earlier scrobble, not live playback

- (BOOL)meetsScrobbleThreshold;
- (NSDictionary *)dictionaryRepresentation;
+ (instancetype)trackFromDictionary:(NSDictionary *)dictionary;
@end

@protocol NBZScrobbleProvider <NSObject>
- (NSString *)identifier;
- (NSString *)displayName;
- (BOOL)isConfigured;
- (NSString *)configurationSummary;
- (void)submitNowPlaying:(NBZTrack *)track;
- (void)scrobble:(NBZTrack *)track completion:(void (^)(BOOL ok, NSString *_Nullable error))completion;
- (void)testConnection:(void (^)(BOOL ok, NSString *_Nullable message))completion;
@optional
// Pause/resume of the current track. Only the webhook (Web Scrobbler format) uses it.
- (void)submitPlaybackState:(NBZTrack *)track playing:(BOOL)playing;
@end

@interface NBZLastFMProvider : NSObject <NBZScrobbleProvider>
- (void)authenticateWithUsername:(NSString *)username
                        password:(NSString *)password
                      completion:(void (^)(BOOL ok, NSString *_Nullable message))completion;
@end

@interface NBZListenBrainzProvider : NSObject <NBZScrobbleProvider>
@end

@interface NBZMalojaProvider : NSObject <NBZScrobbleProvider>
@end

@interface NBZWebhookProvider : NSObject <NBZScrobbleProvider>
@end

NS_ASSUME_NONNULL_END
