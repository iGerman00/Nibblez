#import "NBZPlayerUI.h"
#import "NBZBlocklist.h"
#import "NBZProviders.h"
#import "NBZUtil.h"
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <objc/message.h>

// YTILikeStatus (protobuf enum; INDIFFERENT reads back as 2 on device).
static const int kNBZLikeStatusLike = 0;
static const int kNBZLikeStatusDislike = 1;

// Block/skip timing. One block request owns the state machine until the video
// it was made for has stopped playing or it has given up.
static const NSTimeInterval kNBZPollInterval = 0.1;
static const NSTimeInterval kNBZTransitionTimeout = 1.5;
static const NSTimeInterval kNBZUserCooldown = 3.0;     // repeat taps on the same video
static const NSTimeInterval kNBZGuardCooldown = 10.0;   // guard re-checks the same video
static const NSTimeInterval kNBZFailedCooldown = 60.0;  // after a skip that did not take

typedef NS_ENUM(NSInteger, NBZBlockPhase) {
    NBZBlockPhaseIdle,
    NBZBlockPhaseWaitingForApp,   // dislike sent; the app skips disliked tracks itself
    NBZBlockPhaseWaitingForSkip,  // we pressed the app's next action
};

typedef NS_ENUM(NSInteger, NBZDislikeResult) {
    NBZDislikeSent,
    NBZDislikeAlreadyDisliked,
    NBZDislikeUnavailable,
};

@implementation NBZNowPlaying
@end

@interface NBZPlayerUI ()
@property (nonatomic, weak) UIViewController *playerController;
@property (nonatomic) NBZBlockPhase phase;
@property (nonatomic, copy, nullable) NSString *pendingVideoID;
@property (nonatomic) NSUInteger generation;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *quietUntil;
@end

static id NBZCall(id obj, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static id NBZIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') return nil;
    return object_getIvar(obj, ivar);
}

static NSString *NBZPlainText(id formattedString) {
    id text = NBZCall(formattedString, @"stringWithFormattingRemoved");
    return [text isKindOfClass:[NSString class]] ? text : nil;
}

// Artist runs of the item info link to the artist page
// (browseEndpoint.browseId == UC..., page type MUSIC_PAGE_TYPE_ARTIST).
static void NBZArtistChannels(id formattedString, NSMutableArray *ids, NSMutableArray *names) {
    id runs = NBZCall(formattedString, @"runsArray");
    if (![runs isKindOfClass:[NSArray class]]) return;
    for (id run in runs) {
        id browseID = NBZCall(NBZCall(NBZCall(run, @"navigationEndpoint"), @"browseEndpoint"), @"browseId");
        if (![browseID isKindOfClass:[NSString class]] || ![browseID hasPrefix:@"UC"]) continue;
        if ([ids containsObject:browseID]) continue;
        id text = NBZCall(run, @"text");
        [ids addObject:browseID];
        [names addObject:[text isKindOfClass:[NSString class]] ? text : @""];
    }
}

static IMP nbz_orig_hudShow;
static IMP nbz_orig_mdcShow;
static IMP nbz_orig_likeUpdate;
static IMP nbz_orig_optimisticSkip;

// While set, the app's own toasts are held back so ours (with Unblock) stays.
static NSString *gNBZOwnToastText;
static CFAbsoluteTime gNBZOwnToastUntil;
static NSInteger gNBZSuppressedToasts;

@implementation NBZPlayerUI

+ (instancetype)shared {
    static NBZPlayerUI *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NBZPlayerUI new];
        s.quietUntil = [NSMutableDictionary dictionary];
    });
    return s;
}

#pragma mark - The app's player objects

- (nullable UIViewController *)findPlayerController {
    Class playerClass = NSClassFromString(@"YTMNowPlayingViewController");
    if (!playerClass) return nil;
    NSMutableArray<UIViewController *> *queue = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.rootViewController) [queue addObject:window.rootViewController];
        }
    }
    for (NSUInteger i = 0; i < queue.count && i < 500; i++) {
        UIViewController *vc = queue[i];
        if ([vc isKindOfClass:playerClass]) return vc;
        [queue addObjectsFromArray:vc.childViewControllers];
        if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
    }
    return nil;
}

- (nullable UIViewController *)player {
    UIViewController *player = self.playerController;
    if (!player) {
        player = [self findPlayerController];
        self.playerController = player;
        if (!player) NBZLog(@"player: YTMNowPlayingViewController not found");
    }
    return player;
}

- (nullable id)publishController {
    return NBZIvar([self player], "_playbackPublishController");
}

// The player's own playback position in seconds (what the mini player shows),
// or -1 when it can't be read. The position in the now-playing info is only
// refreshed on state changes, so it goes stale while playing.
- (NSTimeInterval)playbackPosition {
    id publish = [self publishController];
    SEL sel = NSSelectorFromString(@"currentPlaybackVideoMediaTime");
    if (![publish respondsToSelector:sel]) return -1;
    double position = ((double (*)(id, SEL))objc_msgSend)(publish, sel);
    return position >= 0 ? position : -1;
}

- (nullable NSString *)currentVideoID {
    id videoID = NBZCall([self publishController], @"currentVideoID");
    return [videoID isKindOfClass:[NSString class]] && [videoID length] ? videoID : nil;
}

- (nullable NBZNowPlaying *)nowPlaying {
    id publish = [self publishController];
    NSString *videoID = [self currentVideoID];
    if (!videoID) return nil;
    id info = NBZCall(publish, @"nowPlayingItemInfo");
    id infoVideoID = NBZCall(info, @"videoId");
    if (![infoVideoID isKindOfClass:[NSString class]] || ![infoVideoID isEqualToString:videoID]) {
        return nil;  // item info still describes the previous video
    }
    NBZNowPlaying *track = [NBZNowPlaying new];
    track.videoID = videoID;
    track.artist = NBZPlainText(NBZCall(info, @"artist")) ?: @"";
    track.title = NBZPlainText(NBZCall(info, @"track")) ?: @"";
    NSMutableArray *ids = [NSMutableArray array], *names = [NSMutableArray array];
    NBZArtistChannels(NBZCall(info, @"artist"), ids, names);
    track.artistChannelIDs = ids;
    track.artistChannelNames = names;
    for (NSUInteger i = 0; i < ids.count; i++) [[NBZBlocklist shared] learnName:names[i] forChannelID:ids[i]];
    return track;
}

#pragma mark - App actions (each is the app's own entry point)

// Thumbs-down for exactly `videoID`: only sent when the like renderer the
// player holds targets that video, through the same dispatch the dislike
// button uses. Never "whatever is current".
- (NBZDislikeResult)dislikeVideoID:(NSString *)videoID {
    UIViewController *player = [self player];
    id renderer = NBZCall(player, @"likeButtonRenderer");
    id target = NBZCall(NBZCall(renderer, @"target"), @"videoId");
    if (![target isKindOfClass:[NSString class]] || ![target isEqualToString:videoID]) {
        NBZLog(@"dislike: renderer targets %@, not %@; not sending", target, videoID);
        return NBZDislikeUnavailable;
    }
    SEL allowed = NSSelectorFromString(@"likesAllowed");
    if ([renderer respondsToSelector:allowed] && !((BOOL (*)(id, SEL))objc_msgSend)(renderer, allowed)) {
        NBZLog(@"dislike: likes not allowed for %@", videoID);
        return NBZDislikeUnavailable;
    }
    id publish = [self publishController];
    SEL statusSel = NSSelectorFromString(@"currentLikeStatus");
    if ([publish respondsToSelector:statusSel] && [[self currentVideoID] isEqualToString:videoID] &&
        ((int (*)(id, SEL))objc_msgSend)(publish, statusSel) == kNBZLikeStatusDislike) {
        return NBZDislikeAlreadyDisliked;
    }
    SEL dispatchSel = NSSelectorFromString(@"dispatchServiceEndpointForLikeStatus:likeButtonRenderer:");
    if (![player respondsToSelector:dispatchSel]) {
        NBZLog(@"dislike: player has no dispatchServiceEndpointForLikeStatus:likeButtonRenderer:");
        return NBZDislikeUnavailable;
    }
    ((void (*)(id, SEL, int, id))objc_msgSend)(player, dispatchSel, kNBZLikeStatusDislike, renderer);
    NBZLog(@"dislike: sent for %@", videoID);
    return NBZDislikeSent;
}

- (BOOL)pressNext {
    UIViewController *player = [self player];
    SEL next = NSSelectorFromString(@"didTapNextButton");
    if (![player respondsToSelector:next]) {
        NBZLog(@"skip: player has no didTapNextButton");
        return NO;
    }
    ((void (*)(id, SEL))objc_msgSend)(player, next);
    return YES;
}

#pragma mark - State machine (main thread only)

- (BOOL)beginForVideoID:(NSString *)videoID cooldown:(NSTimeInterval)cooldown source:(NSString *)source {
    if (self.phase != NBZBlockPhaseIdle) {
        NBZLog(@"%@: busy with %@, ignoring %@", source, self.pendingVideoID, videoID);
        return NO;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSNumber *until = self.quietUntil[videoID];
    if (until && now < until.doubleValue) {
        NBZLog(@"%@: %@ handled recently, quiet for %.1fs more", source, videoID, until.doubleValue - now);
        return NO;
    }
    for (NSString *key in self.quietUntil.allKeys) {
        if (self.quietUntil[key].doubleValue < now) [self.quietUntil removeObjectForKey:key];
    }
    self.quietUntil[videoID] = @(now + cooldown);
    self.pendingVideoID = videoID;
    self.generation += 1;
    return YES;
}

- (void)finishVideoID:(NSString *)videoID left:(BOOL)left {
    if (!left) {
        self.quietUntil[videoID] = @(CFAbsoluteTimeGetCurrent() + kNBZFailedCooldown);
        NBZLog(@"block: %@ is still playing after the retry; giving up", videoID);
    } else {
        NBZLog(@"block: %@ has stopped playing", videoID);
    }
    self.phase = NBZBlockPhaseIdle;
    self.pendingVideoID = nil;
    self.generation += 1;
}

// Polls the app's current video ID until it is no longer `videoID`.
- (void)waitForVideoID:(NSString *)videoID toLeaveBy:(CFAbsoluteTime)deadline then:(void (^)(BOOL left))then {
    NSUInteger generation = self.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kNBZPollInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.generation != generation) return;
        NSString *current = [self currentVideoID];
        if (!current || ![current isEqualToString:videoID]) { then(YES); return; }
        if (CFAbsoluteTimeGetCurrent() >= deadline) { then(NO); return; }
        [self waitForVideoID:videoID toLeaveBy:deadline then:then];
    });
}

// One press of the app's next action for `videoID`, verified; `attempt` 0 may
// retry once, attempt 1 is the last.
- (void)skipVideoID:(NSString *)videoID attempt:(NSInteger)attempt {
    if (![[self currentVideoID] isEqualToString:videoID]) {
        [self finishVideoID:videoID left:YES];
        return;
    }
    self.phase = NBZBlockPhaseWaitingForSkip;
    NBZLog(@"skip: %@ (attempt %ld)", videoID, (long)attempt + 1);
    if (![self pressNext]) {
        [self finishVideoID:videoID left:NO];
        return;
    }
    [self waitForVideoID:videoID toLeaveBy:CFAbsoluteTimeGetCurrent() + kNBZTransitionTimeout then:^(BOOL left) {
        if (left || attempt >= 1) {
            [self finishVideoID:videoID left:left];
        } else {
            [self skipVideoID:videoID attempt:attempt + 1];
        }
    }];
}

#pragma mark - Entry points

- (void)actionBarBlockTapped:(id)sender {
    [self blockNowPlaying];
}

- (void)blockNowPlaying {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self blockNowPlaying]; });
        return;
    }
    NBZNowPlaying *track = [self nowPlaying];
    if (!track.videoID.length || !track.artist.length) {
        NBZLog(@"block: no consistent now-playing snapshot (video %@)", [self currentVideoID]);
        [self showToast:@"Track is changing, try again"];
        return;
    }
    if (![self beginForVideoID:track.videoID cooldown:kNBZUserCooldown source:@"block"]) return;

    NSString *videoID = track.videoID;
    // The primary credited artist, by channel when the credit links to one.
    NSString *channelID = track.artistChannelIDs.firstObject;
    NSString *artist = channelID && [track.artistChannelNames.firstObject length] ? track.artistChannelNames.firstObject
                                                                                  : track.artist;
    NBZLog(@"block: %@ by %@ (%@, channel %@)", track.title, artist, videoID, channelID ?: @"none");
    [[NBZBlocklist shared] blockArtist:artist channelID:channelID];

    NBZDislikeResult dislike = NBZBool(NBZKeyDislikeOnBlock, YES) ? [self dislikeVideoID:videoID]
                                                                   : NBZDislikeUnavailable;
    NSString *message = dislike == NBZDislikeSent ? [NSString stringWithFormat:@"Blocked %@ · Disliked", artist]
                                                  : [NSString stringWithFormat:@"Blocked %@", artist];
    [self showToast:message actionTitle:@"Unblock" handler:^{
        [[NBZBlocklist shared] unblockArtist:artist channelID:channelID];
        NBZLog(@"block: undone for %@", artist);
    }];

    if (dislike == NBZDislikeSent) {
        // YT Music skips a disliked track on its own when it is still the one
        // playing (-[YTMLikeActionOptimisticHandlerImpl
        // skipCurrentlyPlayingTrackIfMatchesDislikedVideoID:]). Pressing next
        // as well would skip the following track too, so only step in if it
        // did not.
        self.phase = NBZBlockPhaseWaitingForApp;
        [self waitForVideoID:videoID toLeaveBy:CFAbsoluteTimeGetCurrent() + kNBZTransitionTimeout then:^(BOOL left) {
            if (left) [self finishVideoID:videoID left:YES];
            else [self skipVideoID:videoID attempt:1];
        }];
    } else {
        [self skipVideoID:videoID attempt:0];
    }
}

- (void)skipBlockedTrack:(NBZNowPlaying *)track match:(NBZBlockMatch *)match {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self skipBlockedTrack:track match:match]; });
        return;
    }
    if (!track.videoID.length) return;
    if (![self beginForVideoID:track.videoID cooldown:kNBZGuardCooldown source:@"guard"]) return;
    NBZLog(@"guard: %@ by %@ (%@) is blocked (kind %ld, rule %@)", track.title, track.artist, track.videoID,
           (long)match.kind, match.rule);

    NSString *channelID = track.artistChannelIDs.firstObject;
    NSString *artist = channelID && [track.artistChannelNames.firstObject length] ? track.artistChannelNames.firstObject
                                                                                  : track.artist;
    NSString *shown = artist.length ? artist : track.title;
    NSString *rule = match.rule;
    switch (match.kind) {
        case NBZBlockMatchChannel: {
            [self showToast:[NSString stringWithFormat:@"Skipped %@", shown] actionTitle:@"Unblock" handler:^{
                [[NBZBlocklist shared] unblockArtist:shown channelID:rule];
            }];
            break;
        }
        case NBZBlockMatchName: {
            [self showToast:[NSString stringWithFormat:@"Skipped %@", shown] actionTitle:@"Unblock" handler:^{
                [[NBZBlocklist shared] unblockArtist:rule];
            }];
            break;
        }
        case NBZBlockMatchCommunity: {
            [self showToast:[NSString stringWithFormat:@"Skipped %@ · %@", shown, match.list ?: @"AI list"] actionTitle:@"Allow" handler:^{
                [[NBZBlocklist shared] allowArtist:artist channelID:channelID];
            }];
            break;
        }
        case NBZBlockMatchTitle: {
            [self showToast:[NSString stringWithFormat:@"Skipped %@", track.title]];
            break;
        }
    }
    [self skipVideoID:track.videoID attempt:0];
}

#pragma mark - Toast (the app's own HUD)

- (void)showToast:(NSString *)message {
    [self showToast:message actionTitle:nil handler:nil];
}

- (void)showToast:(NSString *)message actionTitle:(nullable NSString *)title handler:(nullable dispatch_block_t)handler {
    Class toastClass = NSClassFromString(@"YTMToastController");
    id toast = toastClass ? [[toastClass alloc] init] : nil;
    SEL withAction = NSSelectorFromString(@"showMessage:HUDMessageAction:infoType:duration:");
    Class actionClass = NSClassFromString(@"GOOHUDMessageAction");
    if (title && handler && actionClass && [toast respondsToSelector:withAction]) {
        id action = [actionClass new];
        SEL setTitle = @selector(setTitle:);
        SEL setHandler = NSSelectorFromString(@"setHandler:");
        if ([action respondsToSelector:setTitle] && [action respondsToSelector:setHandler]) {
            ((void (*)(id, SEL, id))objc_msgSend)(action, setTitle, title);
            ((void (*)(id, SEL, id))objc_msgSend)(action, setHandler, handler);
            // The app answers a dislike with its own "we'll tune your
            // recommendations" toast, which would replace this one.
            gNBZOwnToastText = [message copy];
            gNBZOwnToastUntil = CFAbsoluteTimeGetCurrent() + 6.0;
            gNBZSuppressedToasts = 0;
            ((void (*)(id, SEL, id, id, int, CGFloat))objc_msgSend)(toast, withAction, message, action, 0, 6.0);
            return;
        }
    }
    SEL plain = NSSelectorFromString(@"showMessage:");
    if ([toast respondsToSelector:plain]) {
        ((void (*)(id, SEL, id))objc_msgSend)(toast, plain, message);
        return;
    }
    NBZLog(@"toast: %@", message);
}

#pragma mark - Thumbs down blocks artist

// The app disliked `videoID` (player pill, menu, lock screen, anywhere).
// Runs before the app's own handling, so the snapshot is still that video.
- (void)appDislikedVideoID:(NSString *)videoID via:(NSString *)via {
    if (![videoID isKindOfClass:[NSString class]] || !videoID.length) return;
    NBZLog(@"dislike seen via %@: %@", via, videoID);
    if (!NBZBool(NBZKeyBlockDislike, NO)) return;
    if (NBZBool(NBZKeyBlockDislikeRemoteOnly, NO) && CFAbsoluteTimeGetCurrent() > gNBZRemoteDislikeUntil) {
        NBZLog(@"dislike: in-app, remote-only blocking is on; not blocking");
        return;
    }
    if ([self.pendingVideoID isEqualToString:videoID]) return;  // our own Block flow
    static NSString *lastVideoID;
    static CFAbsoluteTime lastAt;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if ([lastVideoID isEqualToString:videoID] && now - lastAt < 5) return;
    lastVideoID = [videoID copy];
    lastAt = now;

    NBZNowPlaying *track = [self nowPlaying];
    if (![track.videoID isEqualToString:videoID]) {
        NBZLog(@"dislike: %@ is not the playing video (%@); artist unknown, not blocking", videoID, track.videoID);
        return;
    }
    NSString *channelID = track.artistChannelIDs.firstObject;
    NSString *artist = channelID && [track.artistChannelNames.firstObject length] ? track.artistChannelNames.firstObject
                                                                                  : track.artist;
    if (!artist.length) return;
    [[NBZBlocklist shared] blockArtist:artist channelID:channelID];
    NBZLog(@"dislike: blocked %@ (channel %@)", artist, channelID ?: @"none");
    [self showToast:[NSString stringWithFormat:@"Blocked %@", artist] actionTitle:@"Unblock" handler:^{
        [[NBZBlocklist shared] unblockArtist:artist channelID:channelID];
        NBZLog(@"dislike: block undone for %@", artist);
    }];
}

static void NBZHook(NSString *className, NSString *selectorName, id block, IMP *original) {
    Class cls = NSClassFromString(className);
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(selectorName)) : NULL;
    if (!method) {
        NBZLog(@"hook: -[%@ %@] missing", className, selectorName);
        return;
    }
    IMP replacement = imp_implementationWithBlock(block);
    *original = method_getImplementation(method);
    if (!class_addMethod(cls, NSSelectorFromString(selectorName), replacement, method_getTypeEncoding(method))) {
        method_setImplementation(method, replacement);
    }
}

// Our toast with an action must stay up long enough to be used. YT Music
// answers a dislike with its own snackbar ("Got it, we'll tune your
// recommendations"); both HUD systems show one message at a time and a newly
// queued one dismisses the visible one. While ours is up, theirs is dropped.
static BOOL NBZHoldBackAppToast(id message, NSString *system) {
    if (!gNBZOwnToastText || CFAbsoluteTimeGetCurrent() >= gNBZOwnToastUntil || gNBZSuppressedToasts >= 2) return NO;
    id text = NBZCall(message, @"text");
    if (![text isKindOfClass:[NSString class]] || [text isEqualToString:gNBZOwnToastText]) return NO;
    gNBZSuppressedToasts++;
    NBZLog(@"toast: held back %@ \"%@\"", system, text);
    return YES;
}

- (void)installAppHooks {
    // Every like/dislike command updates the like-status entity through here.
    NBZHook(@"YTMLikeEndpointCommandImpl", @"updateEntityWithLikeStatus:videoID:",
        ^(id self, int status, id videoID) {
            if (status == kNBZLikeStatusDislike) {
                [[NBZPlayerUI shared] appDislikedVideoID:videoID via:@"like command"];
            }
            ((void (*)(id, SEL, int, id))nbz_orig_likeUpdate)(self, NSSelectorFromString(@"updateEntityWithLikeStatus:videoID:"),
                                                              status, videoID);
        }, &nbz_orig_likeUpdate);

    // The app's skip-on-dislike; fires for the playing video only.
    NBZHook(@"YTMLikeActionOptimisticHandlerImpl", @"skipCurrentlyPlayingTrackIfMatchesDislikedVideoID:",
        ^(id self, id videoID) {
            [[NBZPlayerUI shared] appDislikedVideoID:videoID via:@"optimistic skip"];
            ((void (*)(id, SEL, id))nbz_orig_optimisticSkip)(self,
                NSSelectorFromString(@"skipCurrentlyPlayingTrackIfMatchesDislikedVideoID:"), videoID);
        }, &nbz_orig_optimisticSkip);

    // All HUD toasts end here. For a few seconds after we show a toast with
    // an action, the app's next two toasts are dropped so ours stays usable.
    NBZHook(@"MDCSnackbarManagerInternal", @"showMessageMainThread:", ^(id self, id message) {
        if (NBZHoldBackAppToast(message, @"snackbar")) return;
        ((void (*)(id, SEL, id))nbz_orig_mdcShow)(self, NSSelectorFromString(@"showMessageMainThread:"), message);
    }, &nbz_orig_mdcShow);
    NBZHook(@"GOOHUDManagerInternal", @"showMessageMainThread:", ^(id self, id message) {
        if (NBZHoldBackAppToast(message, @"HUD")) return;
        ((void (*)(id, SEL, id))nbz_orig_hudShow)(self, NSSelectorFromString(@"showMessageMainThread:"), message);
    }, &nbz_orig_hudShow);
    NBZLog(@"app hooks installed");
}

#pragma mark - Remote commands (lock screen, Control Center, CarPlay, Siri)

static const NSTimeInterval kNBZDoubleTapWindow = 0.3;
static CFAbsoluteTime gNBZRemoteDislikeUntil;  // a dislike we sent for the remote button is in flight
static const NSTimeInterval kNBZFeedbackArtSeconds = 2.5;

// Likes the playing video, or removes the like when it is already liked.
// YES when something was sent; *removed says which.
- (BOOL)toggleLikeVideoID:(NSString *)videoID removed:(BOOL *)removed {
    UIViewController *player = [self player];
    id renderer = NBZCall(player, @"likeButtonRenderer");
    id target = NBZCall(NBZCall(renderer, @"target"), @"videoId");
    if (![target isKindOfClass:[NSString class]] || ![target isEqualToString:videoID]) {
        NBZLog(@"like: renderer targets %@, not %@; not sending", target, videoID);
        return NO;
    }
    SEL dispatchSel = NSSelectorFromString(@"dispatchServiceEndpointForLikeStatus:likeButtonRenderer:");
    if (![player respondsToSelector:dispatchSel]) return NO;
    id publish = [self publishController];
    SEL statusSel = NSSelectorFromString(@"currentLikeStatus");
    int status = [publish respondsToSelector:statusSel] ? ((int (*)(id, SEL))objc_msgSend)(publish, statusSel) : -1;
    *removed = status == kNBZLikeStatusLike;
    int next = *removed ? 2 : kNBZLikeStatusLike;  // 2 = INDIFFERENT
    ((void (*)(id, SEL, int, id))objc_msgSend)(player, dispatchSel, next, renderer);
    NBZLog(@"like: sent status %d for %@ (was %d)", next, videoID, status);
    return YES;
}

static UIImage *NBZFeedbackImage(NSArray<NSString *> *symbols, NSString *caption) {
    CGSize size = CGSizeMake(600, 600);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIColor colorWithWhite:0.11 alpha:1] setFill];
        UIRectFill(CGRectMake(0, 0, size.width, size.height));
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:200 weight:UIImageSymbolWeightBold];
        CGFloat slot = size.width / symbols.count;
        for (NSUInteger i = 0; i < symbols.count; i++) {
            UIImage *img = [[UIImage systemImageNamed:symbols[i] withConfiguration:cfg]
                            imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
            CGSize is = img.size;
            CGFloat scale = MIN(1, (slot - 40) / is.width);
            CGSize d = CGSizeMake(is.width * scale, is.height * scale);
            [img drawInRect:CGRectMake(slot * i + (slot - d.width) / 2, 200 - d.height / 2, d.width, d.height)];
        }
        NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
        para.alignment = NSTextAlignmentCenter;
        para.lineBreakMode = NSLineBreakByWordWrapping;
        [caption drawInRect:CGRectMake(30, 380, size.width - 60, 160)
             withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:44 weight:UIFontWeightBold],
                              NSForegroundColorAttributeName: UIColor.whiteColor,
                              NSParagraphStyleAttributeName: para}];
    }];
}

// While a confirmation icon is up we own the artwork: the app's now-playing
// updates (track change, cover download, elapsed time) are still received and
// remembered, but published with our icon. On release the newest app state goes
// out as-is, so the real cover is never stale.
static IMP nbz_orig_setInfo;
static MPMediaItemArtwork *gNBZArt;
static NSDictionary *gNBZLatestAppInfo;
static NSInteger gNBZArtGeneration;

static void NBZPublishInfo(MPNowPlayingInfoCenter *center, NSDictionary *info) {
    ((void (*)(id, SEL, id))nbz_orig_setInfo)(center, NSSelectorFromString(@"setNowPlayingInfo:"), info);
}

static void NBZInstallArtworkHook(void) {
    NBZHook(@"MPNowPlayingInfoCenter", @"setNowPlayingInfo:", ^(MPNowPlayingInfoCenter *self, NSDictionary *info) {
        if (gNBZArt && info) {
            gNBZLatestAppInfo = [info copy];
            NSMutableDictionary *held = [info mutableCopy];
            held[MPMediaItemPropertyArtwork] = gNBZArt;
            info = held;
        }
        NBZPublishInfo(self, info);
    }, &nbz_orig_setInfo);
}

- (void)flashFeedbackSymbols:(NSArray<NSString *> *)symbols caption:(NSString *)caption {
    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
    if (!nbz_orig_setInfo) return;
    if (!gNBZArt) {
        gNBZLatestAppInfo = [center.nowPlayingInfo copy];
        if (!gNBZLatestAppInfo) return;
    }
    UIImage *image = NBZFeedbackImage(symbols, caption);
    gNBZArt = [[MPMediaItemArtwork alloc] initWithBoundsSize:image.size
                                              requestHandler:^UIImage *(CGSize size) { return image; }];
    NSMutableDictionary *held = [gNBZLatestAppInfo mutableCopy];
    held[MPMediaItemPropertyArtwork] = gNBZArt;
    NBZPublishInfo(center, held);

    NSInteger generation = ++gNBZArtGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kNBZFeedbackArtSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != gNBZArtGeneration) return;  // a newer confirmation owns it
        NSDictionary *latest = gNBZLatestAppInfo;
        gNBZArt = nil;
        gNBZLatestAppInfo = nil;
        if (latest) NBZPublishInfo(center, latest);
    });
}

// One feedback action from a remote command. Disliking goes through the app's
// own path, so "Thumbs down blocks artist" applies exactly as for the in-app button.
- (void)performRemoteFeedback:(BOOL)dislike {
    NBZNowPlaying *track = [self nowPlaying];
    if (!track.videoID.length) {
        [self showToast:@"Track is changing, try again"];
        return;
    }
    NSString *who = track.artistChannelNames.firstObject.length ? track.artistChannelNames.firstObject : track.artist;
    if (dislike) {
        BOOL blocks = NBZBool(NBZKeyBlockDislike, NO) && who.length;
        NSArray *symbols = blocks ? @[@"hand.thumbsdown.fill", @"hand.raised.fill"] : @[@"hand.thumbsdown.fill"];
        NSString *caption = blocks ? [NSString stringWithFormat:@"Disliked · %@ blocked", who] : @"Disliked";
        // Confirmation first: the app skips the track a moment after the dislike.
        [self flashFeedbackSymbols:symbols caption:caption];
        gNBZRemoteDislikeUntil = CFAbsoluteTimeGetCurrent() + 2;
        NBZDislikeResult result = [self dislikeVideoID:track.videoID];
        NBZLog(@"remote: dislike -> %ld", (long)result);
        if (result == NBZDislikeUnavailable) {
            gNBZRemoteDislikeUntil = 0;
            [self showToast:@"Can't dislike this track"];
            return;
        }
    } else {
        BOOL removed = NO;
        BOOL sent = [self toggleLikeVideoID:track.videoID removed:&removed];
        NBZLog(@"remote: like -> %d removed %d", sent, removed);
        if (!sent) { [self showToast:@"Can't like this track"]; return; }
        [self flashFeedbackSymbols:@[removed ? @"hand.thumbsup" : @"hand.thumbsup.fill"]
                           caption:removed ? @"Like removed" : @"Liked"];
    }
}

// The star (likeCommand) is the only feedback button the system draws, so it
// carries the mapping from NBZKeyRemoteMode, with double press as the second action.
- (void)starInvoked {
    NSString *mode = NBZString(NBZKeyRemoteMode) ?: @"like2dislike";
    if ([mode isEqualToString:@"like"]) { [self performRemoteFeedback:NO]; return; }
    if ([mode isEqualToString:@"dislike"]) { [self performRemoteFeedback:YES]; return; }
    BOOL singleIsLike = [mode isEqualToString:@"like2dislike"];
    static NSInteger pending;
    if (pending > 0) {
        pending = 0;  // cancels the scheduled single action
        [self performRemoteFeedback:singleIsLike];  // double: the other action
        return;
    }
    pending = 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kNBZDoubleTapWindow * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (pending == 0) return;
        pending = 0;
        [self performRemoteFeedback:!singleIsLike];
    });
}

- (void)applyRemoteCommandPrefs {
    BOOL on = NBZBool(NBZKeyRemoteFeedback, NO);
    NSString *mode = NBZString(NBZKeyRemoteMode) ?: @"like2dislike";
    MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
    center.likeCommand.enabled = on;
    center.dislikeCommand.enabled = on;
    NSString *title = [mode isEqualToString:@"like"] ? @"Like" : [mode isEqualToString:@"dislike"] ? @"Dislike" : @"Like / Dislike";
    center.likeCommand.localizedTitle = title;
    center.likeCommand.localizedShortTitle = title;
    center.dislikeCommand.localizedTitle = @"Dislike";
    center.dislikeCommand.localizedShortTitle = @"Dislike";
    center.likeCommand.active = NO;
    center.dislikeCommand.active = NO;
}

- (void)installRemoteCommands {
    MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
    [center.likeCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        if (!NBZBool(NBZKeyRemoteFeedback, NO)) return MPRemoteCommandHandlerStatusCommandFailed;
        dispatch_async(dispatch_get_main_queue(), ^{ [self starInvoked]; });
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [center.dislikeCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        if (!NBZBool(NBZKeyRemoteFeedback, NO)) return MPRemoteCommandHandlerStatusCommandFailed;
        dispatch_async(dispatch_get_main_queue(), ^{ [self performRemoteFeedback:YES]; });
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    NBZInstallArtworkHook();
    [self applyRemoteCommandPrefs];
    [[NSNotificationCenter defaultCenter] addObserverForName:NBZDefaultsDidChangeNotification object:nil
                                                       queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(__unused NSNotification *note) { [self applyRemoteCommandPrefs]; }];
    NBZLog(@"remote feedback commands registered (%@)", NBZBool(NBZKeyRemoteFeedback, NO) ? @"on" : @"off");
}

@end
