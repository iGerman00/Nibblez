#import <Foundation/Foundation.h>
#import "NBZProviders.h"

NS_ASSUME_NONNULL_BEGIN

@interface NBZScrobbler : NSObject

+ (instancetype)shared;

@property (nonatomic, strong, readonly, nullable) NBZTrack *currentTrack;
@property (nonatomic, strong, readonly) id<NBZScrobbleProvider> activeProvider;
@property (nonatomic, copy, readonly) NSString *lastStatus;

- (void)start;
- (void)stop;
- (NSUInteger)queuedCount;

// Forces submission of what is playing right now, ignoring the threshold.
// Used by the "Test" row in settings.
- (void)forceScrobbleCurrentTrack;

@end

NS_ASSUME_NONNULL_END
