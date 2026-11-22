#import "NBZArtistLists.h"
#import "NBZProviders.h"
#import "NBZUtil.h"

NSString *const NBZListSoulOverAI = @"Soul Over AI";
NSString *const NBZListZoundhub = @"Zoundhub";

static NSString *const kSoulURL = @"https://raw.githubusercontent.com/xoundbyte/soul-over-ai/main/dist/artists.json";
static NSString *const kZoundhubURL = @"https://zoundhub.com/data/artists-all.json";
// Zoundhub rates artists 1-5; anything below this is never stored.
static const NSInteger kZoundhubFloor = 3;

@interface NBZArtistLists ()
// list name -> (normalised artist name -> rating)
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *entries;
@property (nonatomic, strong) NSMutableSet<NSString *> *inFlight;
@end

@implementation NBZArtistLists

+ (instancetype)shared {
    static NBZArtistLists *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NBZArtistLists new]; });
    return s;
}

#pragma mark - Storage

static NSString *NBZListsDirectory(void) {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [base stringByAppendingPathComponent:@"Nibblez"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *NBZListFile(NSString *list) {
    NSString *name = [list isEqualToString:NBZListZoundhub] ? @"zoundhub.json" : @"soul-over-ai.json";
    return [NBZListsDirectory() stringByAppendingPathComponent:name];
}

static NSString *NBZListDefaultsKey(NSString *list, NSString *field) {
    return [NSString stringWithFormat:@"nbz.list.%@.%@", [list isEqualToString:NBZListZoundhub] ? @"zoundhub" : @"soul", field];
}

static NSDictionary<NSString *, NSNumber *> *NBZReadList(NSString *list) {
    NSData *data = [NSData dataWithContentsOfFile:NBZListFile(list)];
    if (!data) return @{};
    NSArray *pairs = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![pairs isKindOfClass:[NSArray class]]) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:pairs.count];
    for (NSArray *pair in pairs) {
        if ([pair isKindOfClass:[NSArray class]] && pair.count == 2 && [pair[0] isKindOfClass:[NSString class]]) {
            out[pair[0]] = pair[1];
        }
    }
    return out;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _entries = [NSMutableDictionary dictionary];
        _inFlight = [NSMutableSet set];
        // Earlier versions kept the list inside the preferences plist.
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults removeObjectForKey:@"nbz.block.community"];
        [defaults removeObjectForKey:@"nbz.block.community.refreshed"];
    }
    return self;
}

#pragma mark - Settings

static BOOL NBZListEnabled(NSString *list) {
    return [list isEqualToString:NBZListZoundhub] ? NBZBool(NBZKeyBlockZoundhub, NO) : NBZBool(NBZKeyBlockCommunity, YES);
}

static NSInteger NBZZoundhubMinRating(void) {
    NSInteger value = [NBZString(NBZKeyZoundhubMinRating) integerValue];
    return value >= kZoundhubFloor && value <= 5 ? value : 5;
}

#pragma mark - Fetching

- (void)start {
    for (NSString *list in @[NBZListSoulOverAI, NBZListZoundhub]) {
        self.entries[list] = NBZReadList(list);
    }
    NBZLog(@"artist lists loaded: %lu Soul Over AI, %lu Zoundhub",
           (unsigned long)self.entries[NBZListSoulOverAI].count, (unsigned long)self.entries[NBZListZoundhub].count);
    [self updateEnabledLists:nil];
    [[NSNotificationCenter defaultCenter] addObserverForName:NBZDefaultsDidChangeNotification object:nil
                                                       queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(__unused NSNotification *note) {
        // A list that was just switched on and has nothing yet.
        for (NSString *list in @[NBZListSoulOverAI, NBZListZoundhub]) {
            if (NBZListEnabled(list) && !self.entries[list].count) [self fetchList:list force:NO completion:nil];
        }
    }];
}

- (void)refresh:(void (^)(BOOL, NSString *))completion {
    [self updateEnabledLists:completion];
}

- (void)updateEnabledLists:(void (^)(BOOL, NSString *))completion {
    NSMutableArray *lists = [NSMutableArray array];
    for (NSString *list in @[NBZListSoulOverAI, NBZListZoundhub]) {
        if (NBZListEnabled(list)) [lists addObject:list];
    }
    if (!lists.count) {
        if (completion) completion(YES, @"No AI list is switched on");
        return;
    }
    __block NSInteger pending = lists.count;
    __block NSInteger failed = 0;
    __block NSString *firstError = nil;
    for (NSString *list in lists) {
        [self fetchList:list force:completion != nil completion:^(BOOL ok, NSString *message) {
            if (!ok) { failed++; if (!firstError) firstError = [NSString stringWithFormat:@"%@: %@", list, message]; }
            if (--pending == 0 && completion) {
                completion(failed == 0, failed ? firstError : [NSString stringWithFormat:@"%lu artists flagged", (unsigned long)[self totalActiveCount]]);
            }
        }];
    }
}

// `force` skips the ETag so the file is replaced even when unchanged.
- (void)fetchList:(NSString *)list force:(BOOL)force completion:(void (^)(BOOL, NSString *))completion {
    if ([self.inFlight containsObject:list]) {
        if (completion) completion(YES, @"Already updating");
        return;
    }
    [self.inFlight addObject:list];
    BOOL zoundhub = [list isEqualToString:NBZListZoundhub];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:zoundhub ? kZoundhubURL : kSoulURL]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:40];
    NSString *etag = [[NSUserDefaults standardUserDefaults] stringForKey:NBZListDefaultsKey(list, @"etag")];
    if (etag && !force && self.entries[list].count) [request setValue:etag forHTTPHeaderField:@"If-None-Match"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger code = [(NSHTTPURLResponse *)response statusCode];
            NSDictionary *parsed = nil;
            NSString *failure = nil;
            if (error) failure = error.localizedDescription;
            else if (code == 304) { /* unchanged */ }
            else if (code < 200 || code >= 300) failure = [NSString stringWithFormat:@"HTTP %ld", (long)code];
            else {
                parsed = [self parse:data zoundhub:zoundhub];
                if (!parsed.count) failure = @"No artists in the downloaded file";
            }
            if (parsed.count) {
                NSMutableArray *pairs = [NSMutableArray arrayWithCapacity:parsed.count];
                [parsed enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSNumber *rating, BOOL *stop) {
                    [pairs addObject:@[name, rating]];
                }];
                NSData *out = [NSJSONSerialization dataWithJSONObject:pairs options:0 error:nil];
                [out writeToFile:NBZListFile(list) options:NSDataWritingAtomic error:nil];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.inFlight removeObject:list];
                NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                if (parsed.count) {
                    self.entries[list] = parsed;
                    NSString *newTag = [(NSHTTPURLResponse *)response allHeaderFields][@"Etag"]
                        ?: [(NSHTTPURLResponse *)response allHeaderFields][@"ETag"];
                    if (newTag) [defaults setObject:newTag forKey:NBZListDefaultsKey(list, @"etag")];
                }
                if (!failure) [defaults setObject:[NSDate date] forKey:NBZListDefaultsKey(list, @"checked")];
                NBZLog(@"artist list %@: %@", list, failure ?: (parsed.count ? [NSString stringWithFormat:@"%lu artists", (unsigned long)parsed.count] : @"unchanged"));
                [[NSNotificationCenter defaultCenter] postNotificationName:NBZDefaultsDidChangeNotification object:nil];
                if (completion) completion(failure == nil, failure ?: @"OK");
            });
        }] resume];
}

// Normalised name -> rating. Runs off the main thread.
- (NSDictionary<NSString *, NSNumber *> *)parse:(NSData *)data zoundhub:(BOOL)zoundhub {
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSArray *items = zoundhub ? ([json isKindOfClass:[NSDictionary class]] ? json[@"artists"] : nil)
                              : ([json isKindOfClass:[NSArray class]] ? json : nil);
    if (![items isKindOfClass:[NSArray class]]) return nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:items.count];
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = item[@"name"];
        if (![name isKindOfClass:[NSString class]] || !name.length) continue;
        NSInteger rating = 5;
        if (zoundhub) {
            rating = [item[@"rating"] integerValue];
            if (rating < kZoundhubFloor) continue;
        } else if ([item[@"removed"] boolValue]) {
            continue;
        }
        NSString *normalized = NBZNormalizeName(name);
        if (!normalized.length) continue;
        NSNumber *existing = out[normalized];
        if (!existing || existing.integerValue < rating) out[normalized] = @(rating);
    }
    return out;
}

#pragma mark - Queries

- (NSString *)listFlaggingName:(NSString *)normalizedName {
    if (NBZListEnabled(NBZListSoulOverAI) && self.entries[NBZListSoulOverAI][normalizedName]) return NBZListSoulOverAI;
    if (NBZListEnabled(NBZListZoundhub)) {
        NSNumber *rating = self.entries[NBZListZoundhub][normalizedName];
        if (rating && rating.integerValue >= NBZZoundhubMinRating()) return NBZListZoundhub;
    }
    return nil;
}

- (NSUInteger)activeCountForList:(NSString *)list {
    NSDictionary<NSString *, NSNumber *> *entries = self.entries[list];
    if (![list isEqualToString:NBZListZoundhub]) return entries.count;
    NSInteger min = NBZZoundhubMinRating();
    NSUInteger count = 0;
    for (NSNumber *rating in entries.objectEnumerator) if (rating.integerValue >= min) count++;
    return count;
}

- (NSUInteger)totalActiveCount {
    NSUInteger total = 0;
    for (NSString *list in @[NBZListSoulOverAI, NBZListZoundhub]) {
        if (NBZListEnabled(list)) total += [self activeCountForList:list];
    }
    return total;
}

- (NSString *)statusForList:(NSString *)list {
    NSUInteger count = [self activeCountForList:list];
    NSDate *checked = [[NSUserDefaults standardUserDefaults] objectForKey:NBZListDefaultsKey(list, @"checked")];
    if (!count && !checked) return self.inFlight.count && [self.inFlight containsObject:list] ? @"Downloading..." : @"Not downloaded yet";
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterNoStyle;
    NSNumberFormatter *number = [NSNumberFormatter new];
    number.numberStyle = NSNumberFormatterDecimalStyle;
    NSString *counted = [NSString stringWithFormat:@"%@ artists", [number stringFromNumber:@(count)]];
    return checked ? [NSString stringWithFormat:@"%@, checked %@", counted, [formatter stringFromDate:checked]] : counted;
}

@end
