#import "NBZBlocklist.h"
#import "NBZArtistLists.h"
#import "NBZProviders.h"
#import "NBZUtil.h"

NSString *const NBZKeyBlockKeywords = @"block.keywords";
NSString *const NBZKeyBlockTracks = @"block.tracks";
NSString *const NBZKeyBlockedChannels = @"block.channels";
NSString *const NBZKeyAllowedArtists = @"block.allowed";

static NSString *NBZPrefKey(NSString *key) { return [@"nbz." stringByAppendingString:key]; }

@implementation NBZBlockedArtist
@end

@implementation NBZBlockMatch
@end

static NSString *const kNBZAllowNamePrefix = @"name:";

@interface NBZBlocklist ()
@property (nonatomic, strong) NSMutableSet<NSString *> *keywords;  // normalised substrings
@property (nonatomic, strong) NSMutableSet<NSString *> *tracks;    // normalised titles
@end

@implementation NBZBlocklist

+ (instancetype)shared {
    static NBZBlocklist *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NBZBlocklist new]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self load];
    }
    return self;
}

- (void)load {
    self.keywords = [NSMutableSet set];
    for (NSString *raw in [[NSUserDefaults standardUserDefaults] arrayForKey:[@"nbz." stringByAppendingString:NBZKeyBlockKeywords]] ?: @[]) {
        NSString *n = NBZNormalizeName(raw);
        if (n.length) [self.keywords addObject:n];
    }
    self.tracks = [NSMutableSet set];
    for (NSString *raw in [[NSUserDefaults standardUserDefaults] arrayForKey:[@"nbz." stringByAppendingString:NBZKeyBlockTracks]] ?: @[]) {
        NSString *n = NBZNormalizeName(raw);
        if (n.length) [self.tracks addObject:n];
    }
}

#pragma mark - User list

+ (NSString *)channelIDInString:(NSString *)text {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"(?<![A-Za-z0-9_-])UC[A-Za-z0-9_-]{22}(?![A-Za-z0-9_-])"
                                                       options:0 error:nil];
    });
    if (!text.length) return nil;
    NSTextCheckingResult *m = [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    return m ? [text substringWithRange:m.range] : nil;
}

- (NSArray<NSString *> *)userBlockedArtists {
    return [[NSUserDefaults standardUserDefaults] arrayForKey:NBZPrefKey(NBZKeyBlockedArtists)] ?: @[];
}

// channel ID -> display name
- (NSDictionary<NSString *, NSString *> *)userBlockedChannels {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:NBZPrefKey(NBZKeyBlockedChannels)];
    return d ?: @{};
}

- (void)saveUserBlockedArtists:(NSArray<NSString *> *)list {
    [[NSUserDefaults standardUserDefaults] setObject:list forKey:NBZPrefKey(NBZKeyBlockedArtists)];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:NBZDefaultsDidChangeNotification object:nil];
}

- (void)saveUserBlockedChannels:(NSDictionary<NSString *, NSString *> *)channels {
    [[NSUserDefaults standardUserDefaults] setObject:channels forKey:NBZPrefKey(NBZKeyBlockedChannels)];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:NBZDefaultsDidChangeNotification object:nil];
}

- (NSArray<NBZBlockedArtist *> *)userBlockedEntries {
    NSMutableArray *out = [NSMutableArray array];
    NSDictionary *channels = self.userBlockedChannels;
    for (NSString *cid in channels) {
        NBZBlockedArtist *e = [NBZBlockedArtist new];
        e.channelID = cid;
        e.name = [channels[cid] isKindOfClass:[NSString class]] && [channels[cid] length] ? channels[cid] : cid;
        [out addObject:e];
    }
    for (NSString *name in self.userBlockedArtists) {
        NBZBlockedArtist *e = [NBZBlockedArtist new];
        e.name = name;
        [out addObject:e];
    }
    [out sortUsingComparator:^NSComparisonResult(NBZBlockedArtist *a, NBZBlockedArtist *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return out;
}

- (NSUInteger)userRuleCount {
    return self.userBlockedChannels.count + self.userBlockedArtists.count;
}

- (BOOL)addName:(NSString *)artist {
    NSString *trimmed = [artist stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length || !NBZNormalizeName(trimmed).length) return NO;
    NSMutableArray *list = [self.userBlockedArtists mutableCopy];
    for (NSString *existing in list) {
        if ([NBZNormalizeName(existing) isEqualToString:NBZNormalizeName(trimmed)]) return NO;
    }
    [list addObject:trimmed];
    [list sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    [self removeAllowedKey:[kNBZAllowNamePrefix stringByAppendingString:NBZNormalizeName(trimmed)]];
    [self saveUserBlockedArtists:list];
    NBZLog(@"blocked artist name: %@", trimmed);
    return YES;
}

- (BOOL)addChannel:(NSString *)channelID name:(NSString *)name {
    if (!channelID.length) return NO;
    NSMutableDictionary *channels = [self.userBlockedChannels mutableCopy];
    NSString *existing = channels[channelID];
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (existing && (!trimmed.length || [existing isEqualToString:trimmed] || ![existing isEqualToString:channelID])) {
        return NO;
    }
    channels[channelID] = trimmed.length ? trimmed : channelID;
    [self removeAllowedKey:channelID];
    [self saveUserBlockedChannels:channels];
    NBZLog(@"blocked artist channel: %@ (%@)", channelID, channels[channelID]);
    return existing == nil;
}

- (void)blockArtist:(NSString *)artist {
    [self addName:artist];
}

- (void)blockArtist:(NSString *)name channelID:(NSString *)channelID {
    if (channelID.length) [self addChannel:channelID name:name];
    else [self addName:name];
}

- (BOOL)addUserEntry:(NSString *)input {
    NSString *cid = [NBZBlocklist channelIDInString:input];
    if (cid) return [self addChannel:cid name:@""];
    return [self addName:input];
}

- (void)learnName:(NSString *)name forChannelID:(NSString *)channelID {
    NSDictionary *channels = self.userBlockedChannels;
    if (!name.length || ![channels[channelID] isEqualToString:channelID]) return;
    NSMutableDictionary *m = [channels mutableCopy];
    m[channelID] = name;
    [self saveUserBlockedChannels:m];
    NBZLog(@"blocked channel %@ is %@", channelID, name);
}

- (void)unblockArtist:(NSString *)artist {
    NSString *needle = NBZNormalizeName(artist);
    NSMutableArray *list = [self.userBlockedArtists mutableCopy];
    NSIndexSet *toRemove = [list indexesOfObjectsPassingTest:^BOOL(NSString *obj, NSUInteger idx, BOOL *stop) {
        return [NBZNormalizeName(obj) isEqualToString:needle];
    }];
    if (!toRemove.count) return;
    [list removeObjectsAtIndexes:toRemove];
    [self saveUserBlockedArtists:list];
    NBZLog(@"unblocked artist: %@", artist);
}

- (void)unblockArtist:(NSString *)name channelID:(NSString *)channelID {
    if (!channelID.length) {
        [self unblockArtist:name];
        return;
    }
    NSMutableDictionary *channels = [self.userBlockedChannels mutableCopy];
    if (!channels[channelID]) return;
    [channels removeObjectForKey:channelID];
    [self saveUserBlockedChannels:channels];
    NBZLog(@"unblocked channel: %@ (%@)", channelID, name);
}

- (void)removeEntry:(NBZBlockedArtist *)entry {
    [self unblockArtist:entry.name channelID:entry.channelID];
}

#pragma mark - Import / export

- (NSData *)exportData {
    NSMutableArray *artists = [NSMutableArray array];
    for (NBZBlockedArtist *e in self.userBlockedEntries) {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObject:e.name forKey:@"name"];
        if (e.channelID) d[@"channelId"] = e.channelID;
        [artists addObject:d];
    }
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *root = @{
        @"format": @"nibblez-blocklist",
        @"version": @1,
        @"artists": artists,
        @"keywords": [ud arrayForKey:NBZPrefKey(NBZKeyBlockKeywords)] ?: @[],
        @"tracks": [ud arrayForKey:NBZPrefKey(NBZKeyBlockTracks)] ?: @[],
    };
    return [NSJSONSerialization dataWithJSONObject:root
                                           options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                             error:nil] ?: [NSData data];
}

- (NSUInteger)importObject:(id)obj {
    if ([obj isKindOfClass:[NSString class]]) return [self addUserEntry:obj] ? 1 : 0;
    if (![obj isKindOfClass:[NSDictionary class]]) return 0;
    NSString *name = [obj[@"name"] isKindOfClass:[NSString class]] ? obj[@"name"] : @"";
    id rawID = obj[@"channelId"] ?: obj[@"channelID"] ?: obj[@"ucid"] ?: obj[@"id"];
    NSString *cid = [rawID isKindOfClass:[NSString class]] ? [NBZBlocklist channelIDInString:rawID] : nil;
    if (cid) return [self addChannel:cid name:name] ? 1 : 0;
    return name.length && [self addName:name] ? 1 : 0;
}

- (NSUInteger)importData:(NSData *)data error:(NSString **)error {
    if (!data.length) {
        if (error) *error = @"The file is empty";
        return 0;
    }
    NSUInteger added = 0;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([json isKindOfClass:[NSDictionary class]] && [json[@"artists"] isKindOfClass:[NSArray class]]) {
        for (id entry in json[@"artists"]) added += [self importObject:entry];
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        for (NSString *key in @[NBZKeyBlockKeywords, NBZKeyBlockTracks]) {
            NSString *jsonKey = [key isEqualToString:NBZKeyBlockKeywords] ? @"keywords" : @"tracks";
            if (![json[jsonKey] isKindOfClass:[NSArray class]]) continue;
            NSMutableOrderedSet *merged = [NSMutableOrderedSet orderedSetWithArray:[ud arrayForKey:NBZPrefKey(key)] ?: @[]];
            for (id v in json[jsonKey]) if ([v isKindOfClass:[NSString class]] && [v length]) [merged addObject:v];
            [ud setObject:merged.array forKey:NBZPrefKey(key)];
        }
        [self load];
    } else if ([json isKindOfClass:[NSArray class]]) {
        for (id entry in json) added += [self importObject:entry];
    } else {
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) {
            if (error) *error = @"Not a JSON or UTF-8 text file";
            return 0;
        }
        for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (!t.length || [t hasPrefix:@"#"]) continue;
            added += [self addUserEntry:t] ? 1 : 0;
        }
    }
    NBZLog(@"import: %lu new rules", (unsigned long)added);
    return added;
}

#pragma mark - Allowlist

// key: channel ID, or "name:" + normalised name -> display name
- (NSDictionary<NSString *, NSString *> *)allowed {
    return [[NSUserDefaults standardUserDefaults] dictionaryForKey:NBZPrefKey(NBZKeyAllowedArtists)] ?: @{};
}

- (void)saveAllowed:(NSDictionary *)allowed {
    [[NSUserDefaults standardUserDefaults] setObject:allowed forKey:NBZPrefKey(NBZKeyAllowedArtists)];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:NBZDefaultsDidChangeNotification object:nil];
}

- (void)removeAllowedKey:(NSString *)key {
    NSMutableDictionary *allowed = [self.allowed mutableCopy];
    if (!allowed[key]) return;
    [allowed removeObjectForKey:key];
    [self saveAllowed:allowed];
}

- (void)allowArtist:(NSString *)name channelID:(NSString *)channelID {
    NSString *key = channelID.length ? channelID : [kNBZAllowNamePrefix stringByAppendingString:NBZNormalizeName(name)];
    if ([key isEqualToString:kNBZAllowNamePrefix]) return;
    NSMutableDictionary *allowed = [self.allowed mutableCopy];
    allowed[key] = name.length ? name : key;
    [self saveAllowed:allowed];
    NBZLog(@"allowed artist: %@ (%@)", name, key);
}

- (NSArray<NBZBlockedArtist *> *)allowedEntries {
    NSMutableArray *out = [NSMutableArray array];
    NSDictionary *allowed = self.allowed;
    for (NSString *key in allowed) {
        NBZBlockedArtist *e = [NBZBlockedArtist new];
        e.name = allowed[key];
        e.channelID = [key hasPrefix:kNBZAllowNamePrefix] ? nil : key;
        [out addObject:e];
    }
    [out sortUsingComparator:^NSComparisonResult(NBZBlockedArtist *a, NBZBlockedArtist *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return out;
}

- (void)removeAllowedEntry:(NBZBlockedArtist *)entry {
    [self removeAllowedKey:entry.channelID.length ? entry.channelID
                                                  : [kNBZAllowNamePrefix stringByAppendingString:NBZNormalizeName(entry.name)]];
}

#pragma mark - Matching

static NBZBlockMatch *NBZMatch(NBZBlockMatchKind kind, NSString *rule) {
    NBZBlockMatch *m = [NBZBlockMatch new];
    m.kind = kind;
    m.rule = rule ?: @"";
    return m;
}

- (NBZBlockMatch *)matchTrack:(NSString *)title artist:(NSString *)artist channelIDs:(NSArray<NSString *> *)channelIDs {
    if (!NBZBool(NBZKeyBlockEnabled, YES)) return nil;
    NSArray<NSString *> *components = NBZArtistComponents(artist ?: @"");

    NSDictionary *allowed = self.allowed;
    for (NSString *cid in channelIDs) if (allowed[cid]) return nil;
    for (NSString *component in components) {
        if (allowed[[kNBZAllowNamePrefix stringByAppendingString:component]]) return nil;
    }

    NSDictionary *channels = self.userBlockedChannels;
    for (NSString *cid in channelIDs) if (channels[cid]) return NBZMatch(NBZBlockMatchChannel, cid);

    NSString *normTitle = NBZNormalizeName(title);
    if (normTitle.length) {
        if ([self.tracks containsObject:normTitle]) return NBZMatch(NBZBlockMatchTitle, normTitle);
        for (NSString *kw in self.keywords) {
            if (kw.length > 2 && [normTitle containsString:kw]) return NBZMatch(NBZBlockMatchTitle, kw);
        }
    }

    NSArray<NSString *> *names = self.userBlockedArtists;
    for (NSString *component in components) {
        for (NSString *blocked in names) {
            if ([component isEqualToString:NBZNormalizeName(blocked)]) return NBZMatch(NBZBlockMatchName, blocked);
        }
        NSString *list = [[NBZArtistLists shared] listFlaggingName:component];
        if (list) {
            NBZBlockMatch *match = NBZMatch(NBZBlockMatchCommunity, component);
            match.list = list;
            return match;
        }
    }
    return nil;
}

@end
