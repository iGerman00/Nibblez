#import "NBZUtil.h"

NSString *const NBZDefaultsDidChangeNotification = @"com.nibblez.settings-changed";

static NSString *const kPrefix = @"nbz.";
static const unsigned long long kLogMaxBytes = 512 * 1024;

BOOL NBZBool(NSString *key, BOOL fallback) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:[kPrefix stringByAppendingString:key]];
    return v ? [v boolValue] : fallback;
}

NSString *NBZString(NSString *key) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:[kPrefix stringByAppendingString:key]];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

void NBZSetBool(NSString *key, BOOL value) {
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:[kPrefix stringByAppendingString:key]];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:NBZDefaultsDidChangeNotification object:nil];
}

void NBZSetString(NSString *key, NSString *value) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (value) {
        [d setObject:value forKey:[kPrefix stringByAppendingString:key]];
    } else {
        [d removeObjectForKey:[kPrefix stringByAppendingString:key]];
    }
    [d synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:NBZDefaultsDidChangeNotification object:nil];
}

NSString *NBZLogPath(void) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"nibblez.log"];
}

void NBZLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[Nibblez] %@", msg);

    static NSDateFormatter *df;
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"HH:mm:ss.SSS";
        q = dispatch_queue_create("com.nibblez.log", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(q, ^{
        NSString *path = NBZLogPath();
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        if ([attrs fileSize] > kLogMaxBytes) {
            [fm removeItemAtPath:path error:nil];
        }
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    });
}

NSString *NBZNormalizeName(NSString *s) {
    if (!s.length) return @"";
    NSString *t = [s decomposedStringWithCanonicalMapping];
    t = [t lowercaseString];
    // Strip the "Artist - Topic" auto-generated channel suffix.
    for (NSString *suffix in @[@" - topic", @" -topic"]) {
        if ([t hasSuffix:suffix]) {
            t = [t substringToIndex:t.length - suffix.length];
        }
    }
    NSMutableString *out = [NSMutableString stringWithCapacity:t.length];
    NSCharacterSet *keep = [NSCharacterSet alphanumericCharacterSet];
    BOOL lastSpace = NO;
    for (NSUInteger i = 0; i < t.length; i++) {
        unichar c = [t characterAtIndex:i];
        if ([keep characterIsMember:c]) {
            [out appendFormat:@"%C", c];
            lastSpace = NO;
        } else if (!lastSpace) {
            [out appendString:@" "];
            lastSpace = YES;
        }
    }
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

// "A feat. B", "A & B", "A, B", "A x B" all yield their individual names, plus
// the whole normalised string, so blocking "A" catches "A feat. B" but blocking
// "A feat B" still matches exactly.
NSArray<NSString *> *NBZArtistComponents(NSString *artist) {
    if (!artist.length) return @[];
    NSString *lower = [artist lowercaseString];
    NSArray *separators = @[@" feat. ", @" feat ", @" featuring ", @" ft. ", @" ft ", @" & ", @" x ", @", ", @"/", @" and "];
    NSMutableArray *parts = [NSMutableArray arrayWithObject:lower];
    for (NSString *sep in separators) {
        NSMutableArray *next = [NSMutableArray array];
        for (NSString *p in parts) {
            [next addObjectsFromArray:[p componentsSeparatedByString:sep]];
        }
        parts = next;
    }
    NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSet];
    [set addObject:NBZNormalizeName(artist)];
    for (NSString *p in parts) {
        NSString *n = NBZNormalizeName(p);
        if (n.length) [set addObject:n];
    }
    [set removeObject:@""];
    return set.array;
}
