#import "NBZProviders.h"
#import "NBZUtil.h"
#import <CommonCrypto/CommonDigest.h>

NSString *const NBZKeyScrobbleEnabled = @"scrobble.enabled";
NSString *const NBZKeyScrobbleProvider = @"scrobble.provider";
NSString *const NBZKeyLastFMAPIKey = @"lastfm.apikey";
NSString *const NBZKeyLastFMSecret = @"lastfm.secret";
NSString *const NBZKeyLastFMSession = @"lastfm.session";
NSString *const NBZKeyLastFMUser = @"lastfm.user";
NSString *const NBZKeyLBToken = @"listenbrainz.token";
NSString *const NBZKeyLBServer = @"listenbrainz.server";
NSString *const NBZKeyMalojaURL = @"maloja.url";
NSString *const NBZKeyMalojaKey = @"maloja.key";
NSString *const NBZKeyWebhookURL = @"webhook.url";
NSString *const NBZKeyWebhookHeader = @"webhook.header";
NSString *const NBZKeyBlockEnabled = @"block.enabled";
NSString *const NBZKeyBlockCommunity = @"block.community.enabled";
NSString *const NBZKeyBlockZoundhub = @"block.zoundhub.enabled";
NSString *const NBZKeyZoundhubMinRating = @"block.zoundhub.minRating";
NSString *const NBZKeyBlockDislike = @"block.dislike";
NSString *const NBZKeyBlockDislikeRemoteOnly = @"block.dislike.remoteOnly";
NSString *const NBZKeyRemoteFeedback = @"remote.feedback";
NSString *const NBZKeyRemoteMode = @"remote.mode";
NSString *const NBZKeyDislikeOnBlock = @"block.dislikeOnBlock";
NSString *const NBZKeyBlockedArtists = @"block.artists";
NSString *const NBZKeyScrobbleQueue = @"scrobble.queue";

static NSString *NBZURLEncode(NSString *s) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static NSString *NBZMD5(NSString *s) {
    NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *out = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [out appendFormat:@"%02x", digest[i]];
    }
    return out;
}

static NSURLRequest *NBZPost(NSString *urlString, NSDictionary *headers, NSData *body) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 20;
    [req setValue:@"Nibblez/0.1.0" forHTTPHeaderField:@"User-Agent"];
    for (NSString *k in headers) {
        [req setValue:headers[k] forHTTPHeaderField:k];
    }
    req.HTTPBody = body ?: [NSData data];
    return req;
}

static NSURLRequest *NBZGet(NSString *urlString, NSDictionary *headers) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    req.timeoutInterval = 20;
    [req setValue:@"Nibblez/0.1.0" forHTTPHeaderField:@"User-Agent"];
    for (NSString *k in headers) {
        [req setValue:headers[k] forHTTPHeaderField:k];
    }
    return req;
}

static void NBZSend(NSURLRequest *req, void (^completion)(BOOL ok, NSString *message)) {
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) { completion(NO, error.localizedDescription); return; }
                NSInteger code = [(NSHTTPURLResponse *)response statusCode];
                NSString *body = data ? ([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"") : @"";
                if (code >= 200 && code < 300) {
                    completion(YES, body);
                } else {
                    NSString *short_ = body.length > 200 ? [body substringToIndex:200] : body;
                    completion(NO, [NSString stringWithFormat:@"HTTP %ld %@", (long)code, short_]);
                }
            });
        }] resume];
}

#pragma mark - Track

@implementation NBZTrack

- (BOOL)meetsScrobbleThreshold {
    // Web Scrobbler's rule: half the track, at most 4 minutes, at least 30 seconds
    // (30 seconds when the duration is unknown).
    if (self.duration > 0 && self.duration < 30) return NO;
    NSTimeInterval need = self.duration > 0 ? MIN(MAX(self.duration / 2.0, 30), 240) : 30;
    return self.played >= need;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{
        @"title": self.title ?: @"",
        @"artist": self.artist ?: @"",
        @"album": self.album ?: @"",
        @"videoID": self.videoID ?: @"",
        @"duration": @(self.duration),
        @"played": @(self.played),
        @"startedAt": @(self.startedAt),
    };
}

+ (instancetype)trackFromDictionary:(NSDictionary *)d {
    NBZTrack *t = [NBZTrack new];
    t.title = d[@"title"];
    t.artist = d[@"artist"];
    t.album = d[@"album"];
    t.videoID = [d[@"videoID"] length] ? d[@"videoID"] : nil;
    t.duration = [d[@"duration"] doubleValue];
    t.played = [d[@"played"] doubleValue];
    t.startedAt = [d[@"startedAt"] doubleValue];
    return t;
}

@end

#pragma mark - Last.fm

@interface NBZLastFMProvider ()
- (NSMutableDictionary *)signedParameters:(NSMutableDictionary *)params;
- (void)callMethod:(NSString *)method parameters:(NSDictionary *)params completion:(void (^)(BOOL ok, id _Nullable json, NSString *_Nullable error))completion;
@end

@implementation NBZLastFMProvider

- (NSString *)identifier { return @"lastfm"; }
- (NSString *)displayName { return @"Last.fm"; }

- (BOOL)isConfigured {
    return NBZString(NBZKeyLastFMSession).length > 0
        && NBZString(NBZKeyLastFMAPIKey).length > 0
        && NBZString(NBZKeyLastFMSecret).length > 0;
}

- (NSString *)configurationSummary {
    if (self.isConfigured) {
        return [NSString stringWithFormat:@"Connected as %@", NBZString(NBZKeyLastFMUser) ?: @"?"];
    }
    if (NBZString(NBZKeyLastFMSession).length) return @"Session saved, API credentials missing";
    return @"Not connected";
}

- (NSMutableDictionary *)signedParameters:(NSMutableDictionary *)params {
    params[@"api_key"] = NBZString(NBZKeyLastFMAPIKey) ?: @"";
    params[@"format"] = @"json";
    NSMutableString *base = [NSMutableString string];
    for (NSString *k in [[params allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        [base appendFormat:@"%@%@", k, params[k]];
    }
    [base appendString:NBZString(NBZKeyLastFMSecret) ?: @""];
    params[@"api_sig"] = NBZMD5(base);
    return params;
}

- (void)callMethod:(NSString *)method parameters:(NSDictionary *)params completion:(void (^)(BOOL, id, NSString *))completion {
    NSMutableDictionary *all = [params mutableCopy] ?: [NSMutableDictionary dictionary];
    all[@"method"] = method;
    [self signedParameters:all];
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSString *k in all) {
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", NBZURLEncode(k), NBZURLEncode([all[k] description])]];
    }
    NSData *body = [[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
    NSURLRequest *req = NBZPost(@"https://ws.audioscrobbler.com/2.0/",
                                @{@"Content-Type": @"application/x-www-form-urlencoded"}, body);
    NBZSend(req, ^(BOOL ok, NSString *message) {
        if (!ok) { completion(NO, nil, message); return; }
        NSError *jsonErr = nil;
        id json = message.length ? [NSJSONSerialization JSONObjectWithData:[message dataUsingEncoding:NSUTF8StringEncoding]
                                                                   options:0 error:&jsonErr] : nil;
        if (jsonErr) { completion(NO, nil, jsonErr.localizedDescription); return; }
        completion(YES, json, nil);
    });
}

- (void)authenticateWithUsername:(NSString *)username password:(NSString *)password completion:(void (^)(BOOL, NSString *))completion {
    if (!NBZString(NBZKeyLastFMAPIKey).length || !NBZString(NBZKeyLastFMSecret).length) {
        completion(NO, @"Set the Last.fm API key and secret first");
        return;
    }
    [self callMethod:@"auth.getMobileSession"
          parameters:@{@"username": username ?: @"", @"password": password ?: @""}
          completion:^(BOOL ok, id json, NSString *error) {
        NSString *key = json[@"session"][@"key"];
        if (ok && [key isKindOfClass:[NSString class]] && key.length) {
            NBZSetString(NBZKeyLastFMUser, username);
            NBZSetString(NBZKeyLastFMSession, key);
            completion(YES, [NSString stringWithFormat:@"Signed in as %@", username]);
        } else {
            NSString *msg = [json[@"message"] isKindOfClass:[NSString class]] ? json[@"message"] : (error ?: @"Sign-in failed");
            completion(NO, msg);
        }
    }];
}

- (void)submitNowPlaying:(NBZTrack *)track {
    if (!self.isConfigured || !track.title.length || !track.artist.length) return;
    [self callMethod:@"track.updateNowPlaying"
          parameters:@{
              @"artist": track.artist,
              @"track": track.title,
              @"album": track.album ?: @"",
              @"duration": [NSString stringWithFormat:@"%ld", (long)track.duration],
              @"sk": NBZString(NBZKeyLastFMSession),
          }
          completion:^(BOOL ok, id json, NSString *error) {
        NBZLog(@"last.fm now-playing %@: %@", ok ? @"ok" : @"failed", error ?: @"");
    }];
}

- (void)scrobble:(NBZTrack *)track completion:(void (^)(BOOL, NSString *))completion {
    if (!self.isConfigured) { completion(NO, @"Last.fm not configured"); return; }
    NSString *ts = [NSString stringWithFormat:@"%ld", (long)track.startedAt];
    [self callMethod:@"track.scrobble"
          parameters:@{
              @"artist": track.artist ?: @"",
              @"track": track.title ?: @"",
              @"album": track.album ?: @"",
              @"duration": [NSString stringWithFormat:@"%ld", (long)track.duration],
              @"timestamp": ts,
              @"sk": NBZString(NBZKeyLastFMSession),
          }
          completion:^(BOOL ok, id json, NSString *error) {
        NSDictionary *ignored = json[@"scrobbles"][@"@attr"];
        if (ok && [ignored[@"ignored"] integerValue] > 0) {
            completion(NO, @"Rejected by Last.fm (ignored scrobble)");
            return;
        }
        if (!ok && [json[@"error"] integerValue] == 9) {
            // Invalid session key: drop it so the UI shows "not connected".
            NBZSetString(NBZKeyLastFMSession, nil);
        }
        completion(ok, error ?: [json[@"message"] description]);
    }];
}

- (void)testConnection:(void (^)(BOOL, NSString *))completion {
    if (!self.isConfigured) { completion(NO, self.configurationSummary); return; }
    [self callMethod:@"user.getInfo" parameters:@{@"sk": NBZString(NBZKeyLastFMSession)}
          completion:^(BOOL ok, id json, NSString *error) {
        NSString *name = json[@"user"][@"name"];
        if (ok && [name isKindOfClass:[NSString class]]) {
            NBZSetString(NBZKeyLastFMUser, name);
            completion(YES, [NSString stringWithFormat:@"Connected as %@", name]);
        } else {
            completion(NO, error ?: json[@"message"] ?: @"Failed");
        }
    }];
}

@end

#pragma mark - ListenBrainz

@implementation NBZListenBrainzProvider

- (NSString *)identifier { return @"listenbrainz"; }
- (NSString *)displayName { return @"ListenBrainz"; }

- (NSString *)server {
    NSString *s = NBZString(NBZKeyLBServer);
    return s.length ? s : @"https://api.listenbrainz.org";
}

- (BOOL)isConfigured { return NBZString(NBZKeyLBToken).length > 0; }

- (NSString *)configurationSummary {
    return self.isConfigured ? @"Token saved" : @"Not connected";
}

- (void)submitListen:(NBZTrack *)track type:(NSString *)type completion:(void (^)(BOOL, NSString *))completion {
    NSMutableDictionary *meta = [@{
        @"artist_name": track.artist ?: @"",
        @"track_name": track.title ?: @"",
    } mutableCopy];
    if (track.album.length) meta[@"release_name"] = track.album;
    NSMutableDictionary *info = [@{
        @"media_player": @"YouTube Music",
        @"submission_client": @"Nibblez",
        @"submission_client_version": @NIBBLEZ_VERSION,
        @"music_service": @"music.youtube.com",
    } mutableCopy];
    if (track.duration > 0) info[@"duration_ms"] = @((long)(track.duration * 1000));
    if (track.videoID.length) info[@"origin_url"] = [@"https://music.youtube.com/watch?v=" stringByAppendingString:track.videoID];
    meta[@"additional_info"] = info;

    NSDictionary *payload = @{
        @"listen_type": type,
        @"payload": @[ (type == nil || [type isEqualToString:@"playing_now"])
            ? @{@"track_metadata": meta}
            : @{@"listened_at": @((long)track.startedAt), @"track_metadata": meta} ],
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSURLRequest *req = NBZPost([self.server stringByAppendingString:@"/1/submit-listens"],
        @{@"Authorization": [@"Token " stringByAppendingString:NBZString(NBZKeyLBToken) ?: @""],
          @"Content-Type": @"application/json"}, body);
    NBZSend(req, completion);
}

- (void)submitNowPlaying:(NBZTrack *)track {
    if (!self.isConfigured) return;
    [self submitListen:track type:@"playing_now" completion:^(BOOL ok, NSString *message) {
        if (!ok) NBZLog(@"listenbrainz now-playing failed: %@", message);
    }];
}

- (void)scrobble:(NBZTrack *)track completion:(void (^)(BOOL, NSString *))completion {
    if (!self.isConfigured) { completion(NO, @"ListenBrainz not configured"); return; }
    [self submitListen:track type:@"single" completion:completion];
}

- (void)testConnection:(void (^)(BOOL, NSString *))completion {
    if (!self.isConfigured) { completion(NO, @"No token"); return; }
    NSURLRequest *req = NBZGet([self.server stringByAppendingString:@"/1/validate-token"],
        @{@"Authorization": [@"Token " stringByAppendingString:NBZString(NBZKeyLBToken)]});
    NBZSend(req, ^(BOOL ok, NSString *message) {
        completion(ok, ok ? @"Token valid" : message);
    });
}

@end

#pragma mark - Maloja

@implementation NBZMalojaProvider

- (NSString *)identifier { return @"maloja"; }
- (NSString *)displayName { return @"Maloja"; }

- (BOOL)isConfigured {
    return NBZString(NBZKeyMalojaURL).length > 0 && NBZString(NBZKeyMalojaKey).length > 0;
}

- (NSString *)configurationSummary {
    return self.isConfigured ? NBZString(NBZKeyMalojaURL) : @"Not configured";
}

- (void)submit:(NBZTrack *)track nowPlaying:(BOOL)nowPlaying completion:(void (^)(BOOL, NSString *))completion {
    NSString *base = [NBZString(NBZKeyMalojaURL) stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSMutableString *url = [NSMutableString stringWithFormat:@"%@/apis/mlj_1/newscrobble?key=%@", base, NBZURLEncode(NBZString(NBZKeyMalojaKey) ?: @"")];
    [url appendFormat:@"&artist=%@&title=%@", NBZURLEncode(track.artist ?: @""), NBZURLEncode(track.title ?: @"")];
    if (track.album.length) [url appendFormat:@"&album=%@", NBZURLEncode(track.album)];
    if (track.duration > 0) [url appendFormat:@"&duration=%@", @((long)track.duration)];
    if (nowPlaying) {
        [url appendString:@"&time=-1"];
    } else {
        [url appendFormat:@"&time=%ld", (long)track.startedAt];
    }
    NBZSend(NBZGet(url, @{}), completion);
}

- (void)submitNowPlaying:(NBZTrack *)track {
    if (!self.isConfigured) return;
    [self submit:track nowPlaying:YES completion:^(BOOL ok, NSString *message) {
        if (!ok) NBZLog(@"maloja now-playing failed: %@", message);
    }];
}

- (void)scrobble:(NBZTrack *)track completion:(void (^)(BOOL, NSString *))completion {
    if (!self.isConfigured) { completion(NO, @"Maloja not configured"); return; }
    [self submit:track nowPlaying:NO completion:completion];
}

- (void)testConnection:(void (^)(BOOL, NSString *))completion {
    NSString *base = [NBZString(NBZKeyMalojaURL) stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    if (!base.length) { completion(NO, @"No server URL"); return; }
    NBZSend(NBZGet([base stringByAppendingString:@"/apis/mlj_1/serverinfo"], @{}), ^(BOOL ok, NSString *message) {
        completion(ok, ok ? @"Server reachable" : message);
    });
}

@end

#pragma mark - Webhook

@implementation NBZWebhookProvider

- (NSString *)identifier { return @"webhook"; }
- (NSString *)displayName { return @"Webhook"; }

- (BOOL)isConfigured { return NBZString(NBZKeyWebhookURL).length > 0; }

- (NSString *)configurationSummary { return NBZString(NBZKeyWebhookURL) ?: @"Not configured"; }

- (void)post:(NSDictionary *)payload completion:(void (^)(BOOL, NSString *))completion {
    NSString *urlString = NBZString(NBZKeyWebhookURL);
    if (!urlString.length) { completion(NO, @"No webhook URL"); return; }
    urlString = [urlString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // Accept "host:port/path" typed by hand and assume plain HTTP.
    if ([urlString rangeOfString:@"://"].location == NSNotFound) {
        urlString = [@"http://" stringByAppendingString:urlString];
    }
    NSDictionary *headers = @{@"Content-Type": @"application/json"};
    NSString *extra = NBZString(NBZKeyWebhookHeader);
    if (extra.length) {
        NSRange colon = [extra rangeOfString:@":"];
        if (colon.location != NSNotFound) {
            headers = @{@"Content-Type": @"application/json",
                        [extra substringToIndex:colon.location] : [extra substringFromIndex:colon.location + 1]};
        }
    }
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NBZSend(NBZPost(urlString, headers, body), completion);
}

- (void)submitNowPlaying:(NBZTrack *)track {
    if (!self.isConfigured) return;
    NSMutableDictionary *p = [track.dictionaryRepresentation mutableCopy];
    p[@"event"] = @"nowplaying";
    p[@"client"] = @"Nibblez/0.1.0";
    [self post:p completion:^(BOOL ok, NSString *message) {
        if (!ok) NBZLog(@"webhook now-playing failed: %@", message);
    }];
}

- (void)scrobble:(NBZTrack *)track completion:(void (^)(BOOL, NSString *))completion {
    if (!self.isConfigured) { completion(NO, @"Webhook not configured"); return; }
    NSMutableDictionary *p = [track.dictionaryRepresentation mutableCopy];
    p[@"event"] = @"scrobble";
    p[@"timestamp"] = @((long)track.startedAt);
    p[@"client"] = @"Nibblez/0.1.0";
    [self post:p completion:completion];
}

- (void)testConnection:(void (^)(BOOL, NSString *))completion {
    NSMutableDictionary *p = [@{@"event": @"ping", @"client": @"Nibblez/0.1.0"} mutableCopy];
    [self post:p completion:^(BOOL ok, NSString *message) {
        completion(ok, ok ? @"Webhook accepted the ping" : message);
    }];
}

@end
