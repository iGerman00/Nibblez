#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Preferences live in the app's own defaults, under the nbz. prefix.
extern NSString *const NBZDefaultsDidChangeNotification;

BOOL NBZBool(NSString *key, BOOL fallback);
NSString *NBZString(NSString *key);
void NBZSetBool(NSString *key, BOOL value);
void NBZSetString(NSString *key, NSString *_Nullable value);

// Logging: NSLog plus a bounded file in the app container so SSH can read it.
void NBZLog(NSString *format, ...);
NSString *NBZLogPath(void);

// Normalisation used by both blocklist matching and metadata cleanup.
NSString *NBZNormalizeName(NSString *s);
NSArray<NSString *> *NBZArtistComponents(NSString *artist);

NS_ASSUME_NONNULL_END
