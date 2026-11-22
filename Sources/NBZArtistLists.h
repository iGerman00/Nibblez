#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const NBZListSoulOverAI;
extern NSString *const NBZListZoundhub;

// Downloaded lists of artists flagged as AI. Nothing is bundled: lists are
// fetched on launch (conditionally, with ETag) and kept in the app's own
// Application Support folder, so the same code works for a jailbreak tweak and
// for an injected, sideloaded app. Enabled lists only.
@interface NBZArtistLists : NSObject

+ (instancetype)shared;

// Loads what is on disk, fetches missing or stale lists, and starts watching
// the settings so a list switched on gets downloaded right away.
- (void)start;

// Re-downloads every enabled list. `message` is a one-line summary.
- (void)refresh:(void (^)(BOOL ok, NSString *message))completion;

// Name of the list that flags this normalised artist name, or nil.
- (nullable NSString *)listFlaggingName:(NSString *)normalizedName;

- (NSUInteger)activeCountForList:(NSString *)list;
// "12,345 artists, updated Nov 22" / "Not downloaded yet".
- (NSString *)statusForList:(NSString *)list;
- (NSUInteger)totalActiveCount;

@end

NS_ASSUME_NONNULL_END
