#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const NBZKeyBlockKeywords;
extern NSString *const NBZKeyBlockTracks;
extern NSString *const NBZKeyBlockedChannels;
extern NSString *const NBZKeyAllowedArtists;

typedef NS_ENUM(NSInteger, NBZBlockMatchKind) {
    NBZBlockMatchChannel,    // user rule, by channel ID
    NBZBlockMatchName,       // user rule, by name
    NBZBlockMatchCommunity,  // downloaded AI artist list
    NBZBlockMatchTitle,      // title / keyword rule
};

// Why a track is blocked. `rule` is the channel ID, the user's name rule, or
// the matched community name.
@interface NBZBlockMatch : NSObject
@property (nonatomic) NBZBlockMatchKind kind;
@property (nonatomic, copy) NSString *rule;
@property (nonatomic, copy, nullable) NSString *list;  // for Community: which list flagged it
@end

// One user rule. Channel rules match the artist's YouTube channel ID (UC...),
// which survives renames, punctuation and same-name artists. Name rules match
// the normalised artist name (or any credited component of it).
@interface NBZBlockedArtist : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, nullable) NSString *channelID;
@end

@interface NBZBlocklist : NSObject

+ (instancetype)shared;

// Returns the UC... channel ID inside `text` (bare ID or any URL holding one).
+ (nullable NSString *)channelIDInString:(NSString *)text;

- (nullable NBZBlockMatch *)matchTrack:(NSString *)title
                                artist:(NSString *)artist
                            channelIDs:(nullable NSArray<NSString *> *)channelIDs;

// Allowlist: overrides every block rule for that artist (channel when known,
// name otherwise). Used for AI-list false positives.
- (void)allowArtist:(NSString *)name channelID:(nullable NSString *)channelID;
- (NSArray<NBZBlockedArtist *> *)allowedEntries;
- (void)removeAllowedEntry:(NBZBlockedArtist *)entry;

// Name rule.
- (void)blockArtist:(NSString *)artist;
- (void)unblockArtist:(NSString *)artist;
// Channel rule when `channelID` is given, name rule otherwise.
- (void)blockArtist:(NSString *)name channelID:(nullable NSString *)channelID;
- (void)unblockArtist:(NSString *)name channelID:(nullable NSString *)channelID;
// Manual entry: a channel ID / channel URL, or an artist name. NO when empty or already present.
- (BOOL)addUserEntry:(NSString *)input;
// Replaces a placeholder name (a rule added by bare ID) once the artist is seen playing.
- (void)learnName:(NSString *)name forChannelID:(NSString *)channelID;

- (NSArray<NBZBlockedArtist *> *)userBlockedEntries;
- (NSArray<NSString *> *)userBlockedArtists;  // name rules only
- (NSUInteger)userRuleCount;
- (void)removeEntry:(NBZBlockedArtist *)entry;

// Export: JSON {"format":"nibblez-blocklist","version":1,"artists":[{"name","channelId"}],...}.
- (NSData *)exportData;
// Import merges. Accepts the export format, a JSON array (strings or
// {name, channelId} objects), or plain text with one name / ID / URL per line.
- (NSUInteger)importData:(NSData *)data error:(NSString *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
