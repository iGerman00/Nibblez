#import "NBZMetadata.h"

static NSString *NBZApply(NSString *s, NSArray<NSString *> *patterns) {
    NSString *out = s;
    for (NSString *pattern in patterns) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                             options:NSRegularExpressionCaseInsensitive
                                                                               error:nil];
        out = [re stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:@""];
    }
    return [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

static NSArray<NSString *> *NBZRemasterLiveRules(void) {
    return @[
        // "(2011 Remaster)", "[Remastered]", "(Digital Remaster 2009)"
        @"\\s*[\\(\\[]\\s*(\\d{4}\\s+)?(digital\\s+)?remaster(ed)?(\\s+(version|edition))?(\\s+\\d{4})?\\s*[\\)\\]]",
        // " - 2009 Remaster", " - Remastered 2011"
        @"\\s+[-\\u2013\\u2014]\\s+(\\d{4}\\s+)?(digital\\s+)?remaster(ed)?.*$",
        // " - Live at ...", "(Live)"
        @"\\s+[-\\u2013\\u2014]\\s+live\\b.*$",
        @"\\s*\\(live\\)\\s*$",
    ];
}

NSString *NBZCleanTitle(NSString *title, BOOL hasAlbum) {
    NSString *out = NBZApply(title, NBZRemasterLiveRules());
    if (!hasAlbum) {
        out = NBZApply(out, @[
            @"\\s*[\\(\\[\\u3010\\uFF08]\\s*(official\\s+)?(music\\s+video|lyric\\s+video|video|audio|lyrics?|visuali[sz]er|hd|hq|mv|pv|m/v)\\s*[\\)\\]\\u3011\\uFF09]",
            @"\\s*[\\[\\u3010][^\\]\\u3011]*[\\]\\u3011]",
            @"\\s*\\|.*$",
        ]);
    }
    return out.length ? out : title;
}

NSString *NBZCleanAlbum(NSString *album) {
    NSString *out = NBZApply(album, NBZRemasterLiveRules());
    return out.length ? out : album;
}

NSString *NBZCleanArtist(NSString *artist) {
    NSString *out = NBZApply(artist, @[@"\\s*[-\\u2013]\\s*topic\\s*$"]);
    return out.length ? out : artist;
}
