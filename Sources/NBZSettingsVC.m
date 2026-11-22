#import "NBZArtistLists.h"
#import "NBZLogo.h"
#import "NBZSettingsVC.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import "NBZBlocklist.h"
#import "NBZProviders.h"
#import "NBZScrobble.h"
#import "NBZUtil.h"

typedef NS_ENUM(NSInteger, NBZRowKind) {
    NBZRowKindSwitch,
    NBZRowKindValue,
    NBZRowKindAction,
};

@interface NBZRow : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *subtitle;
@property (nonatomic, copy, nullable) NSString *key;      // preference key for switches
@property (nonatomic) BOOL switchValue;
@property (nonatomic) BOOL switchDefault;
@property (nonatomic) NBZRowKind kind;
@property (nonatomic, copy, nullable) void (^handler)(void);
+ (instancetype)row:(NSString *)title subtitle:(nullable NSString *)subtitle kind:(NBZRowKind)kind;
@end

@implementation NBZRow
+ (instancetype)row:(NSString *)title subtitle:(NSString *)subtitle kind:(NBZRowKind)kind {
    NBZRow *r = [NBZRow new];
    r.title = title;
    r.subtitle = subtitle;
    r.kind = kind;
    return r;
}
@end

#pragma mark - Blocked artists list

@interface NBZBlockedArtistsViewController : UITableViewController <UIDocumentPickerDelegate>
@property (nonatomic, copy) NSArray<NBZBlockedArtist *> *entries;
@property (nonatomic, copy) NSArray<NBZBlockedArtist *> *allowed;
@end

@implementation NBZBlockedArtistsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Blocked Artists";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(addArtist)];
    [self reload];
}

- (void)reload {
    self.entries = [[NBZBlocklist shared] userBlockedEntries];
    self.allowed = [[NBZBlocklist shared] allowedEntries];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.allowed.count ? 3 : 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 1 && self.entries.count) return @"Blocked";
    if (section == 2) return @"Always allowed";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;
    return section == 1 ? self.entries.count : self.allowed.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"Import takes a Nibblez export, a JSON list, or a text file with one artist name, "
               @"channel ID (UC…) or channel link per line. Imported rules are added to the list.";
    }
    if (section == 2) return @"Allowed artists are never skipped, even when the AI artist list names them.";
    return self.entries.count ? @"Artists blocked from the player are matched by channel, so renames "
                                @"and same-name artists do not matter. Name rules match the credited name."
                              : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        BOOL import = indexPath.row == 0;
        cell.textLabel.text = import ? @"Import…" : @"Export…";
        cell.textLabel.textColor = self.view.tintColor;
        cell.imageView.image = [UIImage systemImageNamed:import ? @"square.and.arrow.down" : @"square.and.arrow.up"];
        return cell;
    }
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NBZBlockedArtist *entry = indexPath.section == 1 ? self.entries[indexPath.row] : self.allowed[indexPath.row];
    cell.textLabel.text = entry.name;
    cell.detailTextLabel.text = entry.channelID ? [@"Channel " stringByAppendingString:entry.channelID] : @"Name";
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section >= 1;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
                                            forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete || indexPath.section < 1) return;
    if (indexPath.section == 1) [[NBZBlocklist shared] removeEntry:self.entries[indexPath.row]];
    else [[NBZBlocklist shared] removeAllowedEntry:self.allowed[indexPath.row]];
    [self reload];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 0) return;
    if (indexPath.row == 0) [self importList];
    else [self exportListFromCell:[tableView cellForRowAtIndexPath:indexPath]];
}

- (void)addArtist {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Block Artist"
                                                                   message:@"Artist name, channel ID (UC…) or channel link"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Name or UC…";
        field.autocapitalizationType = UITextAutocapitalizationTypeWords;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Block" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *text = alert.textFields.firstObject.text;
        if (!text.length) return;
        [[NBZBlocklist shared] addUserEntry:text];
        [self reload];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)exportListFromCell:(UITableViewCell *)cell {
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"nibblez-blocklist.json"]];
    NSError *error = nil;
    if (![[[NBZBlocklist shared] exportData] writeToURL:url options:NSDataWritingAtomic error:&error]) {
        [self showMessage:error.localizedDescription ?: @"Could not write the file"];
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                                                        applicationActivities:nil];
    share.popoverPresentationController.sourceView = cell ?: self.view;
    share.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)importList {
    NSArray<UTType *> *types = @[UTTypeJSON, UTTypePlainText, UTTypeText];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types
                                                                                                         asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (scoped) [url stopAccessingSecurityScopedResource];
    NSString *error = nil;
    NSUInteger added = [[NBZBlocklist shared] importData:data error:&error];
    [self reload];
    [self showMessage:error ?: [NSString stringWithFormat:@"%lu new rule%@ added", (unsigned long)added,
                                                          added == 1 ? @"" : @"s"]];
}

- (void)showMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Blocked Artists"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Settings

#pragma mark - About and acknowledgements

static NSString *const kNBZRepoURL = @"https://github.com/iGerman00/Nibblez";

// A static grouped list of rows, each optionally opening a link.
@interface NBZLinkRow : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *subtitle;
@property (nonatomic, copy, nullable) NSString *url;
+ (instancetype)title:(NSString *)title subtitle:(nullable NSString *)subtitle url:(nullable NSString *)url;
@end

@implementation NBZLinkRow
+ (instancetype)title:(NSString *)title subtitle:(NSString *)subtitle url:(NSString *)url {
    NBZLinkRow *row = [NBZLinkRow new];
    row.title = title;
    row.subtitle = subtitle;
    row.url = url;
    return row;
}
@end

@interface NBZLinksViewController : UITableViewController
@property (nonatomic, copy) NSArray<NSString *> *headers;
@property (nonatomic, copy) NSArray<NSString *> *footers;  // "" for none
@property (nonatomic, copy) NSArray<NSArray<NBZLinkRow *> *> *sections;
@end

@implementation NBZLinksViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.sections[section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *header = self.headers[section];
    return header.length ? header : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSString *footer = self.footers[section];
    return footer.length ? footer : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NBZLinkRow *row = self.sections[indexPath.section][indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = row.title;
    cell.detailTextLabel.text = row.subtitle;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.numberOfLines = 0;
    if (row.url) {
        cell.textLabel.textColor = self.view.tintColor;
        UIImageView *arrow = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.right"]];
        arrow.tintColor = UIColor.tertiaryLabelColor;
        cell.accessoryView = arrow;
    } else {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *url = self.sections[indexPath.section][indexPath.row].url;
    if (url) [[UIApplication sharedApplication] openURL:[NSURL URLWithString:url] options:@{} completionHandler:nil];
}

@end

static UIViewController *NBZAboutViewController(void) {
    NBZLinksViewController *vc = [NBZLinksViewController new];
    vc.title = @"Nibblez";
    vc.headers = @[@"", @""];
    vc.footers = @[@"", @"Mostly AI generated, with human direction, testing and review. Licensed under GPL-3.0."];
    vc.sections = @[
        @[[NBZLinkRow title:@"Version" subtitle:@NIBBLEZ_VERSION url:nil],
          [NBZLinkRow title:@"Queued scrobbles"
                   subtitle:[NSString stringWithFormat:@"%lu", (unsigned long)[[NBZScrobbler shared] queuedCount]] url:nil]],
        @[[NBZLinkRow title:@"Source code" subtitle:@"github.com/iGerman00/Nibblez" url:kNBZRepoURL],
          [NBZLinkRow title:@"Report an issue" subtitle:nil url:[kNBZRepoURL stringByAppendingString:@"/issues"]],
          [NBZLinkRow title:@"License" subtitle:@"GPL-3.0" url:[kNBZRepoURL stringByAppendingString:@"/blob/main/LICENSE"]]],
    ];
    return vc;
}

static UIViewController *NBZAcknowledgementsViewController(void) {
    NBZLinksViewController *vc = [NBZLinksViewController new];
    vc.title = @"Acknowledgements";
    vc.headers = @[@"Artist lists", @"Scrobbling", @"Reference", @"Built with", @"Author"];
    vc.footers = @[@"", @"", @"Thanks for the inspiration and code references!", @"", @""];
    vc.sections = @[
        @[[NBZLinkRow title:@"Zoundhub" subtitle:@"Directory of AI signals for music artists" url:@"https://zoundhub.com"],
          [NBZLinkRow title:@"Soul Over AI" subtitle:@"Community list of AI artists" url:@"https://github.com/xoundbyte/soul-over-ai"]],
        @[[NBZLinkRow title:@"Web Scrobbler" subtitle:@"Scrobble timing and metadata cleanup rules"
                    url:@"https://github.com/web-scrobbler/web-scrobbler"]],
        @[[NBZLinkRow title:@"YTM-AI-Artist-Song-Blocker" subtitle:@"The idea for blocking AI artists"
                    url:@"https://github.com/firemountainpeak-lang/YTM-AI-Artist-Song-Blocker"],
          [NBZLinkRow title:@"YTMusicUltimate" subtitle:nil url:@"https://github.com/dayanch96/YTMusicUltimate"],
          [NBZLinkRow title:@"YTMEnhanced" subtitle:nil url:@"https://github.com/py233/YTMEnhanced"]],
        @[[NBZLinkRow title:@"Theos" subtitle:@"Build system" url:@"https://theos.dev"]],
        @[[NBZLinkRow title:@"iGerman" subtitle:@"github.com/iGerman00" url:@"https://github.com/iGerman00"]],
    ];
    return vc;
}

@interface NBZSettingsViewController ()
@property (nonatomic, strong) NSArray<NSArray<NBZRow *> *> *sections;
@property (nonatomic, copy, nullable) NSString *footerStatus;
@property (nonatomic, strong, nullable) NSIndexPath *busyIndexPath;
@end

@implementation NBZSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Nibblez";
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(dismissSelf)];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reload)
                                                 name:NBZDefaultsDidChangeNotification
                                               object:nil];
    self.tableView.tableHeaderView = [self heroView];
    [self reload];
}

// Logo, name and tagline above the first section. Sized in viewDidLayoutSubviews
// because the height depends on how the tagline wraps at the table's width.
- (UIView *)heroView {
    UIView *hero = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 240)];
    UIImageView *logo = [[UIImageView alloc] initWithImage:NBZLogoImage()];
    logo.tintColor = UIColor.labelColor;
    logo.contentMode = UIViewContentModeScaleAspectFit;
    UILabel *title = [UILabel new];
    title.text = @"Nibblez";
    title.font = [UIFont systemFontOfSize:34 weight:UIFontWeightHeavy];
    title.textColor = UIColor.labelColor;
    title.textAlignment = NSTextAlignmentCenter;
    UILabel *tagline = [UILabel new];
    tagline.text = @"Scrobbling, blocking and better controls with no extra bullshit";
    tagline.font = [UIFont systemFontOfSize:15];
    tagline.textColor = UIColor.secondaryLabelColor;
    tagline.textAlignment = NSTextAlignmentCenter;
    tagline.numberOfLines = 0;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[logo, title, tagline]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8;
    [stack setCustomSpacing:2 afterView:logo];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [hero addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [logo.widthAnchor constraintEqualToConstant:112],
        [logo.heightAnchor constraintEqualToConstant:112],
        [tagline.widthAnchor constraintLessThanOrEqualToConstant:300],
        [stack.topAnchor constraintEqualToAnchor:hero.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor constant:-16],
        [stack.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor constant:-20],
    ]];
    return hero;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *hero = self.tableView.tableHeaderView;
    if (!hero || CGRectGetWidth(self.tableView.bounds) <= 0) return;
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    CGFloat height = [hero systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                         withHorizontalFittingPriority:UILayoutPriorityRequired
                               verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    if (fabs(CGRectGetHeight(hero.frame) - height) > 0.5 || CGRectGetWidth(hero.frame) != width) {
        hero.frame = CGRectMake(0, 0, width, height);
        self.tableView.tableHeaderView = hero;
    }
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reload {
    [self buildSections];
    [self.tableView reloadData];
}

- (void)buildSections {
    NSMutableArray *sections = [NSMutableArray array];
    NBZScrobbler *scrobbler = [NBZScrobbler shared];
    id<NBZScrobbleProvider> provider = scrobbler.activeProvider;

    // Section 0: scrobbling
    NSMutableArray *scrobble = [NSMutableArray array];
    NBZRow *master = [NBZRow row:@"Scrobbling" subtitle:nil kind:NBZRowKindSwitch];
    master.key = NBZKeyScrobbleEnabled;
    master.switchDefault = YES;
    [scrobble addObject:master];

    NBZRow *service = [NBZRow row:@"Service" subtitle:provider.displayName kind:NBZRowKindValue];
    service.handler = ^{ [self chooseProvider]; };
    [scrobble addObject:service];

    NSString *providerID = provider.identifier;
    if ([providerID isEqualToString:@"lastfm"]) {
        NBZRow *creds = [NBZRow row:@"Last.fm API key" subtitle:NBZString(NBZKeyLastFMAPIKey).length ? @"Set" : @"Required"
                              kind:NBZRowKindValue];
        creds.handler = ^{ [self editString:NBZKeyLastFMAPIKey title:@"Last.fm API Key" secure:NO]; };
        [scrobble addObject:creds];

        NBZRow *secret = [NBZRow row:@"Last.fm API secret" subtitle:NBZString(NBZKeyLastFMSecret).length ? @"Set" : @"Required"
                               kind:NBZRowKindValue];
        secret.handler = ^{ [self editString:NBZKeyLastFMSecret title:@"Last.fm API Secret" secure:YES]; };
        [scrobble addObject:secret];

        NBZRow *signIn = [NBZRow row:@"Account" subtitle:provider.configurationSummary kind:NBZRowKindValue];
        signIn.handler = ^{ [self lastFMSignIn]; };
        [scrobble addObject:signIn];
    } else if ([providerID isEqualToString:@"listenbrainz"]) {
        NBZRow *token = [NBZRow row:@"User token" subtitle:NBZString(NBZKeyLBToken).length ? @"Set" : @"Required"
                              kind:NBZRowKindValue];
        token.handler = ^{ [self editString:NBZKeyLBToken title:@"ListenBrainz Token" secure:YES]; };
        [scrobble addObject:token];

        NBZRow *server = [NBZRow row:@"Server" subtitle:NBZString(NBZKeyLBServer) ?: @"api.listenbrainz.org"
                              kind:NBZRowKindValue];
        server.handler = ^{ [self editString:NBZKeyLBServer title:@"Server URL" secure:NO]; };
        [scrobble addObject:server];
    } else if ([providerID isEqualToString:@"maloja"]) {
        NBZRow *url = [NBZRow row:@"Server URL" subtitle:NBZString(NBZKeyMalojaURL) ?: @"Required" kind:NBZRowKindValue];
        url.handler = ^{ [self editString:NBZKeyMalojaURL title:@"Maloja Server URL" secure:NO]; };
        [scrobble addObject:url];

        NBZRow *key = [NBZRow row:@"API key" subtitle:NBZString(NBZKeyMalojaKey).length ? @"Set" : @"Required"
                            kind:NBZRowKindValue];
        key.handler = ^{ [self editString:NBZKeyMalojaKey title:@"Maloja API Key" secure:YES]; };
        [scrobble addObject:key];
    } else {
        NBZRow *url = [NBZRow row:@"Endpoint URL" subtitle:NBZString(NBZKeyWebhookURL) ?: @"Required" kind:NBZRowKindValue];
        url.handler = ^{ [self editString:NBZKeyWebhookURL title:@"Webhook URL" secure:NO]; };
        [scrobble addObject:url];

        NBZRow *header = [NBZRow row:@"Extra header" subtitle:NBZString(NBZKeyWebhookHeader) ?: @"Name: value"
                              kind:NBZRowKindValue];
        header.handler = ^{ [self editString:NBZKeyWebhookHeader title:@"Header (Name: value)" secure:NO]; };
        [scrobble addObject:header];
    }

    NBZRow *test = [NBZRow row:@"Test connection" subtitle:nil kind:NBZRowKindAction];
    test.handler = ^{ [self testConnection]; };
    [scrobble addObject:test];

    NBZRow *scrobbleNow = [NBZRow row:@"Scrobble current track" subtitle:nil kind:NBZRowKindAction];
    scrobbleNow.handler = ^{
        [[NBZScrobbler shared] forceScrobbleCurrentTrack];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self reload];
        });
    };
    [scrobble addObject:scrobbleNow];
    [sections addObject:scrobble];

    // Section 1: blocking
    NSMutableArray *blocking = [NSMutableArray array];
    NBZRow *blockMaster = [NBZRow row:@"Block artists" subtitle:nil kind:NBZRowKindSwitch];
    blockMaster.key = NBZKeyBlockEnabled;
    blockMaster.switchDefault = YES;
    [blocking addObject:blockMaster];

    NBZBlocklist *list = [NBZBlocklist shared];
    NBZArtistLists *lists = [NBZArtistLists shared];
    NBZRow *community = [NBZRow row:@"Soul Over AI list"
                            subtitle:[lists statusForList:NBZListSoulOverAI]
                              kind:NBZRowKindSwitch];
    community.key = NBZKeyBlockCommunity;
    community.switchDefault = YES;
    [blocking addObject:community];

    NBZRow *zoundhub = [NBZRow row:@"Zoundhub list"
                          subtitle:[lists statusForList:NBZListZoundhub]
                            kind:NBZRowKindSwitch];
    zoundhub.key = NBZKeyBlockZoundhub;
    zoundhub.switchDefault = NO;
    [blocking addObject:zoundhub];

    if (NBZBool(NBZKeyBlockZoundhub, NO)) {
        NBZRow *threshold = [NBZRow row:@"Zoundhub threshold"
                               subtitle:[self zoundhubThresholdTitle:NBZString(NBZKeyZoundhubMinRating) ?: @"5"]
                                 kind:NBZRowKindValue];
        threshold.handler = ^{ [self chooseZoundhubThreshold]; };
        [blocking addObject:threshold];
    }

    NBZRow *refresh = [NBZRow row:@"Refresh AI artist lists" subtitle:nil kind:NBZRowKindAction];
    refresh.handler = ^{ [self refreshCommunity]; };
    [blocking addObject:refresh];

    NBZRow *dislike = [NBZRow row:@"Thumbs down blocks artist"
                         subtitle:@"Disliking the playing song blocks its artist"
                           kind:NBZRowKindSwitch];
    dislike.key = NBZKeyBlockDislike;
    dislike.switchDefault = NO;
    [blocking addObject:dislike];
    if (NBZBool(NBZKeyBlockDislike, NO)) {
        NBZRow *remoteOnly = [NBZRow row:@"Only from lock screen button"
                                subtitle:@"In-app thumbs down no longer blocks; the feedback button still does"
                                  kind:NBZRowKindSwitch];
        remoteOnly.key = NBZKeyBlockDislikeRemoteOnly;
        remoteOnly.switchDefault = NO;
        [blocking addObject:remoteOnly];
    }

    NBZRow *dislikeOnBlock = [NBZRow row:@"Dislike the song when blocking"
                               subtitle:@"Sends a thumbs down before skipping, so YouTube learns"
                                 kind:NBZRowKindSwitch];
    dislikeOnBlock.key = NBZKeyDislikeOnBlock;
    dislikeOnBlock.switchDefault = YES;
    [blocking addObject:dislikeOnBlock];

    NBZRow *remote = [NBZRow row:@"Lock screen feedback button"
                        subtitle:@"Star in Control Center / lock screen; also CarPlay, Watch, Siri"
                          kind:NBZRowKindSwitch];
    remote.key = NBZKeyRemoteFeedback;
    remote.switchDefault = NO;
    [blocking addObject:remote];

    if (NBZBool(NBZKeyRemoteFeedback, NO)) {
        NSDictionary *modeNames = @{@"like2dislike": @"Press = like, double = dislike",
                                    @"dislike2like": @"Press = dislike, double = like",
                                    @"like": @"Like only", @"dislike": @"Dislike only"};
        NBZRow *mode = [NBZRow row:@"Star button" subtitle:modeNames[NBZString(NBZKeyRemoteMode) ?: @"like2dislike"]
                             kind:NBZRowKindValue];
        mode.handler = ^{ [self chooseRemoteMode]; };
        [blocking addObject:mode];
    }

    NBZRow *blocked = [NBZRow row:@"Blocked artists"
                         subtitle:[NSString stringWithFormat:@"%lu", (unsigned long)list.userRuleCount]
                           kind:NBZRowKindValue];
    blocked.handler = ^{
        [self.navigationController pushViewController:[NBZBlockedArtistsViewController new] animated:YES];
    };
    [blocking addObject:blocked];
    [sections addObject:blocking];

    // Section 2: about
    NBZRow *about = [NBZRow row:@"About Nibblez" subtitle:@NIBBLEZ_VERSION kind:NBZRowKindValue];
    about.handler = ^{ [self.navigationController pushViewController:NBZAboutViewController() animated:YES]; };
    NBZRow *thanks = [NBZRow row:@"Acknowledgements" subtitle:nil kind:NBZRowKindValue];
    thanks.handler = ^{ [self.navigationController pushViewController:NBZAcknowledgementsViewController() animated:YES]; };
    [sections addObject:@[about, thanks]];

    self.sections = sections;
}

#pragma mark - Actions

- (NSString *)zoundhubThresholdTitle:(NSString *)value {
    if ([value isEqualToString:@"3"]) return @"3 of 5 and up (broad, more false positives)";
    if ([value isEqualToString:@"4"]) return @"4 of 5 and up";
    return @"5 of 5 (strongest signal only)";
}

- (void)chooseZoundhubThreshold {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Zoundhub threshold"
                                                                   message:@"Zoundhub rates artists 1 to 5 from its own heuristic. It is not a verdict on any artist."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *current = NBZString(NBZKeyZoundhubMinRating) ?: @"5";
    for (NSString *value in @[@"5", @"4", @"3"]) {
        NSString *title = [self zoundhubThresholdTitle:value];
        if ([value isEqualToString:current]) title = [title stringByAppendingString:@"  \u2713"];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NBZSetString(NBZKeyZoundhubMinRating, value);
            [self reload];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIView *anchor = self.pickerAnchor ?: self.view;
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(anchor.bounds),
                                                                CGRectGetMidY(anchor.bounds), 1, 1);
    sheet.popoverPresentationController.permittedArrowDirections = 0;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)chooseRemoteMode {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Star button"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *modes = @[@[@"like2dislike", @"Press = like, double = dislike"],
                       @[@"dislike2like", @"Press = dislike, double = like"],
                       @[@"like", @"Like only"], @[@"dislike", @"Dislike only"]];
    NSString *current = NBZString(NBZKeyRemoteMode) ?: @"like2dislike";
    for (NSArray *m in modes) {
        NSString *title = [m[0] isEqualToString:current] ? [m[1] stringByAppendingString:@"  \u2713"] : m[1];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NBZSetString(NBZKeyRemoteMode, m[0]);
            [self reload];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIView *anchor = self.pickerAnchor ?: self.view;
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(anchor.bounds),
                                                                CGRectGetMidY(anchor.bounds), 1, 1);
    sheet.popoverPresentationController.permittedArrowDirections = 0;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)chooseProvider {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Scrobbling service"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSDictionary *names = @{@"lastfm": @"Last.fm", @"listenbrainz": @"ListenBrainz",
                            @"maloja": @"Maloja", @"webhook": @"Webhook"};
    NSString *current = NBZString(NBZKeyScrobbleProvider) ?: @"lastfm";
    for (NSString *ident in @[@"lastfm", @"listenbrainz", @"maloja", @"webhook"]) {
        NSString *title = names[ident];
        if ([ident isEqualToString:current]) title = [title stringByAppendingString:@"  \u2713"];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NBZSetString(NBZKeyScrobbleProvider, ident);
            [self reload];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIView *anchor = self.pickerAnchor ?: self.view;
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(anchor.bounds),
                                                                CGRectGetMidY(anchor.bounds), 1, 1);
    sheet.popoverPresentationController.permittedArrowDirections = 0;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)editString:(NSString *)key title:(NSString *)title secure:(BOOL)secure {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = NBZString(key);
        field.secureTextEntry = secure;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NBZSetString(key, alert.textFields.firstObject.text.length ? alert.textFields.firstObject.text : nil);
        [self reload];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)lastFMSignIn {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Last.fm Sign In" message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = @"Username";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = @"Password";
        f.secureTextEntry = YES;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Sign In" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *user = alert.textFields[0].text;
        NSString *pass = alert.textFields[1].text;
        NBZLastFMProvider *lfm = [NBZLastFMProvider new];
        [lfm authenticateWithUsername:user password:pass completion:^(BOOL ok, NSString *message) {
            [self flash:message ok:ok];
            [self reload];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)testConnection {
    id<NBZScrobbleProvider> provider = [[NBZScrobbler shared] activeProvider];
    [self beginBusy];
    [provider testConnection:^(BOOL ok, NSString *message) {
        [self endBusy];
        if (ok) {
            // Success needs no dialog: the row itself reports the result.
            [self setFooterStatus:[NSString stringWithFormat:@"%@ connected", provider.displayName]];
            [self reload];
        } else {
            [self flash:message ?: @"Connection failed" ok:NO];
        }
    }];
}

- (void)refreshCommunity {
    [self beginBusy];
    [[NBZArtistLists shared] refresh:^(BOOL ok, NSString *message) {
        [self endBusy];
        if (ok) {
            [self setFooterStatus:[NSString stringWithFormat:@"AI artist lists updated (%@)", message]];
            [self reload];
        } else {
            [self flash:[NSString stringWithFormat:@"Refresh failed: %@", message ?: @"unknown error"] ok:NO];
        }
    }];
}

// Spin the accessory of the row that started the work instead of parking a
// "Testing..." alert on screen.
- (void)beginBusy {
    NSIndexPath *ip = self.busyIndexPath;
    if (!ip) return;
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:ip];
    if (!cell) return;
    UIActivityIndicatorView *spinner =
        [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [spinner startAnimating];
    cell.accessoryView = spinner;
}

- (void)endBusy {
    NSIndexPath *ip = self.busyIndexPath;
    if (!ip) return;
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:ip];
    cell.accessoryView = nil;
    self.busyIndexPath = nil;
}

- (void)flash:(NSString *)message ok:(BOOL)ok {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Nibblez"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"Scrobbling", @"Blocking", @"About"][section];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.sections[section].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NBZRow *row = self.sections[indexPath.section][indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = row.title;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    if (row.subtitle.length) {
        cell.detailTextLabel.text = row.subtitle;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    }
    if (row.kind == NBZRowKindSwitch) {
        UISwitch *toggle = [UISwitch new];
        toggle.on = NBZBool(row.key, row.switchDefault);
        toggle.onTintColor = self.view.tintColor;
        __weak typeof(self) weakSelf = self;
        __weak NBZRow *weakRow = row;
        toggle.tag = indexPath.section * 100 + indexPath.row;
        objc_setAssociatedObject(toggle, @selector(setOn:animated:), weakRow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        (void)weakSelf;
    } else if (row.kind == NBZRowKindValue && row.handler) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (row.kind == NBZRowKindAction) {
        cell.textLabel.textColor = self.view.tintColor;
    }
    return cell;
}

- (void)toggleChanged:(UISwitch *)sender {
    NBZRow *row = objc_getAssociatedObject(sender, @selector(setOn:animated:));
    if (row.key) NBZSetBool(row.key, sender.isOn);
    if ([row.key isEqualToString:NBZKeyRemoteFeedback] || [row.key isEqualToString:NBZKeyBlockDislike] ||
        [row.key isEqualToString:NBZKeyBlockZoundhub]) [self reload];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return self.footerStatus ?: [[[NBZScrobbler shared] activeProvider] configurationSummary];
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    // iPad popovers need a real anchor; self.view makes them land off-screen.
    self.pickerAnchor = [tableView cellForRowAtIndexPath:indexPath] ?: self.view;
    self.busyIndexPath = indexPath;
    NBZRow *row = self.sections[indexPath.section][indexPath.row];
    if (row.handler) row.handler();
}

@end
