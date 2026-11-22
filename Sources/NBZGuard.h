#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Watches the system now-playing item and skips anything that matches the
// blocklist. Independent of the scrobbler so either feature works alone.
@interface NBZGuard : NSObject

+ (instancetype)shared;
- (void)start;

@end

NS_ASSUME_NONNULL_END
