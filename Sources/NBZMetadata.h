#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Cleanup applied to what is sent to scrobbling services, modelled on the
// metadata-filter rules Web Scrobbler uses for YouTube Music. Blocking works on
// the unmodified names, so it is not affected.

// Strips remaster and live suffixes; for tracks without an album (plain videos)
// also "(Official Video)", "(Lyrics)", "[...]" and trailing "| ..." noise.
NSString *NBZCleanTitle(NSString *title, BOOL hasAlbum);
NSString *NBZCleanAlbum(NSString *album);
// Removes the " - Topic" suffix of auto-generated artist channels.
NSString *NBZCleanArtist(NSString *artist);

NS_ASSUME_NONNULL_END
