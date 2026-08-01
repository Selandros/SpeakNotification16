//PerAppListController.m

#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#import "PerAppListController.h"
#import "SNAppListProvider.h"
#import "SNPrefsUtil.h"
#import "SNPreferences.h"


static NSString * const kSNPerAppDisableSoundKey = @"perAppDisableNotificationSound";

// Force-load AltList's PreferenceBundle so its cell styling hooks are active
static inline void SNEnsureAltListBundleLoaded(void)
{
    NSArray<NSString *> *candidates = @[
        @"/var/jb/Library/PreferenceBundles/AltList.bundle",
        @"/Library/PreferenceBundles/AltList.bundle"
    ];
    for (NSString *p in candidates) {
        NSBundle *b = [NSBundle bundleWithPath:p];
        if (b && !b.loaded) { [b load]; }
    }
}

// UIKit private: asks SpringBoardServices for the app icon image
static inline UIImage *SNIconFromUIKitPrivate(NSString *bundleID)
{
    if (!(bundleID && bundleID.length)) return nil;
    SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![UIImage respondsToSelector:sel]) return nil;
    typedef UIImage *(*Fn)(id, SEL, NSString *, NSInteger, CGFloat);
    Fn f = (Fn)objc_msgSend;
    // 2 ~= medium table icon; use main screen scale
    return f([UIImage class], sel, bundleID, 2, [UIScreen mainScreen].scale);
}

// Try multiple LSApplicationProxy icon selectors/variants; works even without AltList.
static inline UIImage *SNIconFromLSProxy(NSString *bundleID)
{
    if (!(bundleID && bundleID.length)) return nil;

    Class LSProxy = NSClassFromString(@"LSApplicationProxy");
    if (!LSProxy) return nil;

    id proxy = ((id (*)(id, SEL, NSString *))objc_msgSend)(LSProxy, @selector(applicationProxyForIdentifier:), bundleID);
    if (!proxy) return nil;

    // Known selectors across iOS versions
    SEL selIconData      = NSSelectorFromString(@"iconDataForVariant:");
    SEL selPrimaryIcon   = NSSelectorFromString(@"primaryIconDataForVariant:");
    SEL selIconDataRole  = NSSelectorFromString(@"iconDataForVariant:role:");
    SEL selPrimaryRole   = NSSelectorFromString(@"primaryIconDataForVariant:role:");

    // Try a wide set of variants (small → large)
    NSInteger variants[] = {2, 60, 120, 180, 6, 3, 1, 20, 40, 100};
    const int vcount = sizeof(variants)/sizeof(variants[0]);

    // role 0 ("primary") is commonly accepted when role is required
    const NSInteger rolePrimary = 0;

    for (int i = 0; i < vcount; i++) {
        NSInteger v = variants[i];
        NSData *data = nil;

        if ([proxy respondsToSelector:selIconData]) {
            data = ((NSData *(*)(id, SEL, NSInteger))objc_msgSend)(proxy, selIconData, v);
        }
        if (!data && [proxy respondsToSelector:selPrimaryIcon]) {
            data = ((NSData *(*)(id, SEL, NSInteger))objc_msgSend)(proxy, selPrimaryIcon, v);
        }
        if (!data && [proxy respondsToSelector:selIconDataRole]) {
            data = ((NSData *(*)(id, SEL, NSInteger, NSInteger))objc_msgSend)(proxy, selIconDataRole, v, rolePrimary);
        }
        if (!data && [proxy respondsToSelector:selPrimaryRole]) {
            data = ((NSData *(*)(id, SEL, NSInteger, NSInteger))objc_msgSend)(proxy, selPrimaryRole, v, rolePrimary);
        }
        if (data.length > 0) {
            UIImage *img = [UIImage imageWithData:data scale:0.0];
            if (img) return img;
        }
    }
    return nil;
}

static inline UIImage *SNAppIconImage(UIImage *source)
{
    if (!source) return nil;

    CGFloat size = 40.0;
    CGRect rect = CGRectMake(0, 0, size, size);
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, 0.0);

    UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:9.0];
    [clip addClip];
    [[UIColor secondarySystemBackgroundColor] setFill];
    UIRectFill(rect);

    CGSize imageSize = source.size;
    if (imageSize.width <= 0.0 || imageSize.height <= 0.0) imageSize = rect.size;
    CGFloat scale = MAX(size / imageSize.width, size / imageSize.height);
    CGSize drawSize = CGSizeMake(imageSize.width * scale, imageSize.height * scale);
    CGRect drawRect = CGRectMake((size - drawSize.width) * 0.5,
                                 (size - drawSize.height) * 0.5,
                                 drawSize.width,
                                 drawSize.height);
    [source drawInRect:drawRect];

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static inline UIImage *SNMonogramIcon(NSString *key, NSString *text)
{
    if (!(text && text.length)) text = @"?";
    NSString *letter = [[text substringToIndex:1] uppercaseString];
    uint32_t h = (uint32_t)key.hash;
    CGFloat hue = (h % 256) / 255.0;
    UIColor *fill = [UIColor colorWithHue:hue saturation:0.55 brightness:0.90 alpha:1.0];
    UIColor *textColor = [UIColor whiteColor];
    CGFloat size = 40.0;
    CGRect rect = CGRectMake(0, 0, size, size);
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, 0.0);
    UIBezierPath *circle = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:9.0];
    [fill setFill];
    [circle fill];
    UIFont *font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: textColor };
    CGSize t = [letter sizeWithAttributes:attrs];
    CGPoint p = CGPointMake((size - t.width) * 0.5, (size - t.height) * 0.5);
    [letter drawAtPoint:p withAttributes:attrs];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

static inline UIImage *SNIconFromIconsCache(NSString *bundleID)
{
    static NSString * const kIconsCacheDir = @"/var/mobile/Library/Caches/com.apple.IconsCache";
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:kIconsCacheDir isDirectory:&isDir] || !isDir) return nil;
    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:kIconsCacheDir error:nil];
    if (!(files && files.count)) return nil;

    NSPredicate *starts = [NSPredicate predicateWithBlock:^BOOL(NSString *name, NSDictionary *_) {
        return [name hasPrefix:bundleID];
    }];
    NSPredicate *contains = [NSPredicate predicateWithBlock:^BOOL(NSString *name, NSDictionary *_) {
        return [name containsString:bundleID];
    }];

    NSArray<NSString *> *candidates = [files filteredArrayUsingPredicate:starts];
    if (candidates.count == 0) candidates = [files filteredArrayUsingPredicate:contains];
    if (candidates.count == 0) return nil;

    NSString *chosen = nil;
    for (NSString *n in candidates) {
        if ([n hasSuffix:@".png"] && ([n containsString:@"@2x"] || [n containsString:@"60x60"] || [n containsString:@"120x120"])) { chosen = n; break; }
    }
    if (!chosen) { for (NSString *n in candidates) { if ([n hasSuffix:@".png"]) { chosen = n; break; } } }
    if (!chosen) return nil;

    NSString *path = [kIconsCacheDir stringByAppendingPathComponent:chosen];
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!(data && data.length)) return nil;

    return [UIImage imageWithData:data scale:0.0];
}

static inline BOOL SNPerAppSpeakEnabled(NSString *bundleID)
{
    NSString *bid = [SNPrefsUtil normalizeBID:bundleID];
    if (bid.length == 0) return NO;

    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSArray *allowed = [SNPrefsUtil normalizeIDArray:[defs objectForKey:@"allowedAppIDs"]];
    return [allowed containsObject:bid];
}

static inline void SNSetPerAppSpeakEnabled(NSString *bundleID, BOOL enabled)
{
    NSString *bid = [SNPrefsUtil normalizeBID:bundleID];
    if (bid.length == 0) return;

    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSMutableArray *allowed = [[SNPrefsUtil normalizeIDArray:[defs objectForKey:@"allowedAppIDs"]] mutableCopy];
    if (!allowed) allowed = [NSMutableArray array];

    if (enabled) {
        if (![allowed containsObject:bid]) [allowed addObject:bid];
    } else {
        [allowed removeObject:bid];
    }

    [defs setObject:[SNPrefsUtil normalizeIDArray:allowed] forKey:@"allowedAppIDs"];
    [defs setBool:YES forKey:@"allowedSeededOnce"];
    [defs synchronize];
    [SNPrefsUtil postPrefsChanged];
}

static inline unsigned long long SNPerAppSpokenCount(NSString *bundleID)
{
    NSString *bid = [SNPrefsUtil normalizeBID:bundleID];
    if (bid.length == 0) return 0;

    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSDictionary *counts = [defs dictionaryForKey:kSNPerAppSpokenCountsKey];
    NSNumber *value = [counts isKindOfClass:NSDictionary.class] ? counts[bid] : nil;
    return [value respondsToSelector:@selector(unsignedLongLongValue)] ? value.unsignedLongLongValue : 0;
}

static inline NSString *SNPerAppLastReadBundleID(void)
{
    NSUserDefaults *defs = [SNPrefsUtil suite];
    return [SNPrefsUtil normalizeBID:[defs stringForKey:kSNLastSpokenAppIDKey]];
}



static inline unsigned long long SNSpokenCountForBundleInCounts(NSDictionary *counts, NSString *bundleID)
{
    NSString *bid = [SNPrefsUtil normalizeBID:bundleID];
    NSNumber *value = ([counts isKindOfClass:NSDictionary.class] && bid.length) ? counts[bid] : nil;
    return [value respondsToSelector:@selector(unsignedLongLongValue)] ? value.unsignedLongLongValue : 0;
}

static inline NSArray<NSDictionary *> *SNSortedAppsByReadCount(NSArray<NSDictionary *> *apps)
{
    if (![apps isKindOfClass:NSArray.class] || apps.count == 0) return apps ?: @[];

    NSDictionary *counts = [[SNPrefsUtil suite] dictionaryForKey:kSNPerAppSpokenCountsKey];
    return [apps sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        unsigned long long ac = SNSpokenCountForBundleInCounts(counts, a[@"bundle"]);
        unsigned long long bc = SNSpokenCountForBundleInCounts(counts, b[@"bundle"]);
        if (ac > bc) return NSOrderedAscending;
        if (ac < bc) return NSOrderedDescending;

        NSString *an = [a[@"name"] isKindOfClass:NSString.class] ? a[@"name"] : @"";
        NSString *bn = [b[@"name"] isKindOfClass:NSString.class] ? b[@"name"] : @"";
        NSComparisonResult byName = [an localizedCaseInsensitiveCompare:bn];
        if (byName != NSOrderedSame) return byName;

        NSString *ab = [a[@"bundle"] isKindOfClass:NSString.class] ? a[@"bundle"] : @"";
        NSString *bb = [b[@"bundle"] isKindOfClass:NSString.class] ? b[@"bundle"] : @"";
        return [ab localizedCaseInsensitiveCompare:bb];
    }];
}

@interface SNPerAppSwitchCell : PSTableCell
@property (nonatomic, strong) UISwitch *speakSwitch;
@property (nonatomic, copy) NSString *bundleID;
@end

@implementation SNPerAppSwitchCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier
{
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        _speakSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
        [_speakSwitch addTarget:self action:@selector(sn_switchChanged:) forControlEvents:UIControlEventValueChanged];
        self.accessoryView = _speakSwitch;
    }
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier
{
    [super refreshCellContentsWithSpecifier:specifier];

    self.bundleID = [specifier propertyForKey:@"id"];
    self.speakSwitch.on = SNPerAppSpeakEnabled(self.bundleID);
    self.accessoryView = self.speakSwitch;

    NSString *status = [specifier propertyForKey:@"spokenStatusText"];
    self.detailTextLabel.text = status;
    self.detailTextLabel.textColor = [UIColor secondaryLabelColor];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    self.imageView.layer.cornerRadius = 9.0;
    self.imageView.layer.masksToBounds = YES;
    self.imageView.contentMode = UIViewContentModeScaleAspectFill;
}

- (void)sn_switchChanged:(UISwitch *)sender
{
    SNSetPerAppSpeakEnabled(self.bundleID, sender.on);
}

@end

// AltList constants (avoid headers): 2 ~= medium icon size
#ifndef ALTIconSizeMedium
#define ALTIconSizeMedium 2
#endif

// Try to dlopen AltList and/or load the framework bundle, then return ALTApplicationList shared instance.
static inline id SNLoadAltListShared(void)
{
    Class ALT = NSClassFromString(@"ALTApplicationList");
    if (!ALT) {
        // Direct binaries (rootless + classic)
        const char *bins[] = {
            "/var/jb/Library/Frameworks/AltList.framework/AltList",
            "/var/jb/usr/lib/AltList.framework/AltList",
            "/usr/lib/AltList.framework/AltList",
            "/Library/Frameworks/AltList.framework/AltList",
            "/var/jb/usr/lib/libaltlist.dylib",
            "/usr/lib/libaltlist.dylib"
        };
        for (unsigned i = 0; i < sizeof(bins)/sizeof(bins[0]); i++) {
            void *h = dlopen(bins[i], RTLD_NOW);
            if (h) break;
        }

        // If still missing, try loading the framework bundle directly
        if (!(ALT = NSClassFromString(@"ALTApplicationList"))) {
            NSArray<NSString *> *bundles = @[
                @"/var/jb/Library/Frameworks/AltList.framework",
                @"/var/jb/usr/lib/AltList.framework",
                @"/usr/lib/AltList.framework",
                @"/Library/Frameworks/AltList.framework"
            ];
            for (NSString *p in bundles) {
                NSBundle *b = [NSBundle bundleWithPath:p];
                if ([b load]) break;
            }
            ALT = NSClassFromString(@"ALTApplicationList");
        }
    }
    if (ALT && [ALT respondsToSelector:@selector(sharedApplicationList)]) {
        return ((id (*)(id, SEL))objc_msgSend)(ALT, @selector(sharedApplicationList));
    }
    return nil;
}


@interface PerAppListController () <UISearchBarDelegate>
@property (nonatomic, strong) NSArray<NSDictionary *> *allApps;    // full list {name,bundle}
@property (nonatomic, strong) NSArray<NSDictionary *> *shownApps;  // filtered list
@property (nonatomic, strong) UISearchBar *searchBar;
@end

@implementation PerAppListController {
    NSCache<NSString *, UIImage *> *_iconCache;
    id _alt; // ALTApplicationList at runtime (optional)
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _iconCache = [NSCache new];
        _iconCache.countLimit = 200;
        _alt = SNLoadAltListShared(); // will dlopen if present
    }
    return self;
}

// Returns the effective format for a bundle (per-app if set, else global/legacy/fallback)
static inline NSString *SNEffectiveFormatForBundle(NSString *bundleID)
{
    NSUserDefaults *defs = [SNPrefsUtil suite];
    if (bundleID.length > 0) {
        NSDictionary *per = [defs objectForKey:@"perAppFormats"];
        NSString *p = ([per isKindOfClass:NSDictionary.class] ? per[bundleID] : nil);
        if ([p isKindOfClass:NSString.class]) {
            NSString *trim = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trim.length > 0) return trim;
        }
    }
    NSString *g = [defs stringForKey:@"globalFormat"];
    if (g && g.length > 0) return g;
    NSString *legacy = [defs stringForKey:@"messageFormat"];
    if (legacy && legacy.length > 0) return legacy;
    return @"{APP}: {TITLE}: {BODY}";
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    SNEnsureAltListBundleLoaded();

    // One-time migration: messageFormat -> globalFormat (no logging, pure motorics)
    NSUserDefaults *defs = [SNPrefsUtil suite];
    id glob = [defs objectForKey:@"globalFormat"];
    if (![glob isKindOfClass:NSString.class]) {
        NSString *legacy = [defs stringForKey:@"messageFormat"];
        if (legacy.length) {
            [defs setObject:legacy forKey:@"globalFormat"];
        } else {
            [defs setObject:@"{APP}: {TITLE}: {BODY}" forKey:@"globalFormat"];
        }
        [defs synchronize];
    }

    [SNPrefsUtil normalizePrefsIfNeeded];

    if (![self isDetailMode]) {
        self.title = @"Installed apps";
        [self setupSearchBar];
    } else {
        self.title = (self.specifier.name ?: @"App");
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if ([self isDetailMode]) {
        self.title = (self.specifier.name ?: @"App");
    } else if (_specifiers) {
        [self reloadListSpecifiers];
    }
}

- (BOOL)isDetailMode
{
    NSNumber *flag = [self.specifier propertyForKey:@"isAppDetail"];
    return flag.boolValue; // only true for rows we create for per-app detail
}

- (NSArray *)specifiers
{
    NSArray *built = [self isDetailMode] ? [self buildDetailSpecifiers] : [self buildListSpecifiers];
    [self setSpecifiers:[built mutableCopy]]; // PSListController expects NSMutableArray*
    return _specifiers;
}

#pragma mark - Search (list mode)

- (void)setupSearchBar
{
    UISearchBar *sb = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.table.bounds.size.width, 56)];
    sb.placeholder = @"Search apps";
    sb.autocapitalizationType = UITextAutocapitalizationTypeNone;
    sb.autocorrectionType = UITextAutocorrectionTypeNo;
    sb.delegate = self;
    self.searchBar = sb;
    self.table.tableHeaderView = sb;
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    [self applyFilter:searchText];
    [self reloadListSpecifiers];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    [searchBar resignFirstResponder];
}

- (void)applyFilter:(NSString *)query
{
    if (query.length == 0) {
        self.shownApps = self.allApps;
        return;
    }
    NSString *q = [[query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *a in self.allApps) {
        NSString *name = [a[@"name"] lowercaseString];
        NSString *bid  = [a[@"bundle"] lowercaseString];
        if ((name && [name containsString:q]) || (bid && [bid containsString:q])) {
            [out addObject:a];
        }
    }
    self.shownApps = out;
}

#pragma mark - List mode

- (NSDictionary *)appItemForBundleID:(NSString *)bundleID
{
    NSString *target = [SNPrefsUtil normalizeBID:bundleID];
    if (target.length == 0) return nil;

    for (NSDictionary *item in self.allApps) {
        NSString *bid = [SNPrefsUtil normalizeBID:item[@"bundle"]];
        if ([bid isEqualToString:target]) return item;
    }

    return @{ @"name": target, @"bundle": target };
}

- (PSSpecifier *)lastReadSpecifierForItem:(NSDictionary *)item
{
    NSString *name = item[@"name"] ?: @"Last read app";
    NSString *bid = item[@"bundle"] ?: @"";

    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:name
                                                     target:self set:NULL get:NULL
                                                     detail:[PerAppListController class]
                                                       cell:PSLinkCell
                                                       edit:Nil];
    Class subCell = NSClassFromString(@"SNPerAppSwitchCell");
    if (subCell) [sp setProperty:subCell forKey:@"cellClass"];

    [sp setProperty:bid forKey:@"applicationBundleID"];
    [sp setProperty:bid forKey:@"bundleIdentifier"];
    [sp setProperty:bid forKey:@"displayIdentifier"];
    [sp setProperty:bid forKey:@"id"];
    [sp setProperty:name forKey:@"name"];
    [sp setProperty:@YES forKey:@"isAppDetail"];
    [sp setProperty:@"Last read" forKey:@"label2"];

    unsigned long long spokenCount = SNPerAppSpokenCount(bid);
    [sp setProperty:[NSString stringWithFormat:@"Last read • %llu read", spokenCount] forKey:@"spokenStatusText"];

    UIImage *img = [_iconCache objectForKey:bid];
    if (!img) {
        if (_alt) {
            SEL selDisp = @selector(iconOfSize:forDisplayIdentifier:);
            SEL selBund = @selector(iconOfSize:forBundleIdentifier:);
            typedef UIImage *(*AltIconDisp)(id, SEL, NSInteger, NSString *);
            typedef UIImage *(*AltIconBund)(id, SEL, NSInteger, NSString *);
            if ([_alt respondsToSelector:selDisp]) img = ((AltIconDisp)objc_msgSend)(_alt, selDisp, 2, bid);
            if (!img && [_alt respondsToSelector:selBund]) img = ((AltIconBund)objc_msgSend)(_alt, selBund, 2, bid);
        }
        if (!img) img = SNIconFromUIKitPrivate(bid);
        if (!img) img = SNIconFromLSProxy(bid);
        if (!img) img = SNIconFromIconsCache(bid);
        if (!img) img = SNMonogramIcon(bid, name);
        img = SNAppIconImage(img);
        if (img) [_iconCache setObject:img forKey:bid];
    }
    if (img) [sp setProperty:img forKey:@"iconImage"];

    return sp;
}

- (NSArray *)buildListSpecifiers
{
    NSMutableArray *specs = [NSMutableArray array];

    // Build fresh list in Prefs process
    self.allApps = SNSortedAppsByReadCount(SNVisibleAppListForceRefresh());
    if (self.allApps.count == 0) {
        // Fallback to cached (in case first force returns empty in this process)
        self.allApps = SNSortedAppsByReadCount(SNVisibleAppList());
    }

    // Seed allowed once from whatever list we have (whitelist semantics)
    [self seedAllowedOnceIfNeededWith:self.allApps];

    if (self.allApps.count == 0) {
        PSSpecifier *g = [PSSpecifier preferenceSpecifierNamed:@"Installed apps"
                                                        target:self set:NULL get:NULL
                                                        detail:Nil cell:PSGroupCell edit:Nil];
        [g setProperty:@"No apps available." forKey:@"footerText"];
        [specs addObject:g];
        return [specs copy];
    }

    NSString *activeQuery = self.searchBar.text ?: @"";
    if (activeQuery.length > 0) {
        [self applyFilter:activeQuery];
    } else {
        self.shownApps = self.allApps;
    }

    NSString *lastReadBundleID = SNPerAppLastReadBundleID();
    NSDictionary *lastReadItem = [self appItemForBundleID:lastReadBundleID];
    if (lastReadItem) {
        PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"Last read"
                                                            target:self set:NULL get:NULL
                                                            detail:Nil cell:PSGroupCell edit:Nil];
        [group setProperty:@"The latest app that actually spoke a notification." forKey:@"footerText"];
        [specs addObject:group];
        [specs addObject:[self lastReadSpecifierForItem:lastReadItem]];
    }

    PSSpecifier *bulkGroup = [PSSpecifier preferenceSpecifierNamed:@"Bulk actions"
                                                            target:self set:NULL get:NULL
                                                            detail:Nil cell:PSGroupCell edit:Nil];
    [bulkGroup setProperty:@"Turn speaking on or off for every installed app." forKey:@"footerText"];
    [specs addObject:bulkGroup];

    PSSpecifier *enableAll = [PSSpecifier preferenceSpecifierNamed:@"Enable all apps"
                                                            target:self set:NULL get:NULL
                                                            detail:Nil cell:PSButtonCell edit:Nil];
    enableAll.buttonAction = @selector(enableAllApps);
    [specs addObject:enableAll];

    PSSpecifier *disableAll = [PSSpecifier preferenceSpecifierNamed:@"Disable all apps"
                                                             target:self set:NULL get:NULL
                                                             detail:Nil cell:PSButtonCell edit:Nil];
    disableAll.buttonAction = @selector(disableAllApps);
    [specs addObject:disableAll];

    PSSpecifier *resetCounters = [PSSpecifier preferenceSpecifierNamed:@"Reset read counters…"
                                                                target:self set:NULL get:NULL
                                                                detail:Nil cell:PSButtonCell edit:Nil];
    resetCounters.buttonAction = @selector(resetReadCounters);
    [specs addObject:resetCounters];

    PSSpecifier *allGroup = [PSSpecifier preferenceSpecifierNamed:@"All apps"
                                                           target:self set:NULL get:NULL
                                                           detail:Nil cell:PSGroupCell edit:Nil];
    [specs addObject:allGroup];

    for (NSDictionary *item in self.shownApps) {
        NSString *name = item[@"name"];
        NSString *bid  = item[@"bundle"];
        if (lastReadBundleID.length && [[SNPrefsUtil normalizeBID:bid] isEqualToString:lastReadBundleID]) {
            continue;
        }

        PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:name
                                                         target:self set:NULL get:NULL
                                                         detail:[PerAppListController class]
                                                           cell:PSLinkCell
                                                           edit:Nil];
        Class subCell = NSClassFromString(@"SNPerAppSwitchCell");
        if (subCell) { [sp setProperty:subCell forKey:@"cellClass"]; }
        
        [sp setProperty:@YES forKey:@"useAltListIcon"];
        [sp setProperty:bid forKey:@"applicationBundleID"];
        [sp setProperty:bid forKey:@"bundleIdentifier"];
        [sp setProperty:bid forKey:@"displayIdentifier"];
        [sp setProperty:bid forKey:@"id"];
        [sp setProperty:name forKey:@"name"];
        [sp setProperty:@YES forKey:@"isAppDetail"];
        NSString *badge = [self badgeForBundle:bid];
        unsigned long long spokenCount = SNPerAppSpokenCount(bid);
        [sp setProperty:badge forKey:@"label2"];
        [sp setProperty:[NSString stringWithFormat:@"%llu read", spokenCount] forKey:@"spokenStatusText"];

    // Optional subtitle shows the bundle id below the title
    [sp setProperty:bid forKey:@"subtitle"];

// Lazy icon pipeline: AltList → UIKit private → LSProxy → IconsCache → Monogram
UIImage *cached = [_iconCache objectForKey:bid];
if (cached) {
    [sp setProperty:cached forKey:@"iconImage"];
} else {
    UIImage *img = nil;

    // 1) AltList (if loaded)
    if (_alt) {
        SEL selDisp = @selector(iconOfSize:forDisplayIdentifier:);
        SEL selBund = @selector(iconOfSize:forBundleIdentifier:);
        typedef UIImage *(*AltIconDisp)(id, SEL, NSInteger, NSString *);
        typedef UIImage *(*AltIconBund)(id, SEL, NSInteger, NSString *);
        if ([_alt respondsToSelector:selDisp]) {
            img = ((AltIconDisp)objc_msgSend)(_alt, selDisp, 2, bid);
        }
        if (!img && [_alt respondsToSelector:selBund]) {
            img = ((AltIconBund)objc_msgSend)(_alt, selBund, 2, bid);
        }
    }

    // 2) UIKit private (reliable in Preferences)
    if (!img) img = SNIconFromUIKitPrivate(bid);

    // 3) LSApplicationProxy
    if (!img) img = SNIconFromLSProxy(bid);

    // 4) Diskcache
    if (!img) img = SNIconFromIconsCache(bid);

    // 5) Monogram
    if (!img) img = SNMonogramIcon(bid, name);
    img = SNAppIconImage(img);

    [_iconCache setObject:img forKey:bid];
    [sp setProperty:img forKey:@"iconImage"];

    // Optional async refresh with AltList if it later returns a better image
    if (_alt && ([_alt respondsToSelector:@selector(iconOfSize:forDisplayIdentifier:)] ||
                 [_alt respondsToSelector:@selector(iconOfSize:forBundleIdentifier:)])) {
        __weak typeof(self) weakSelf = self;
        __weak PSSpecifier *weakSp = sp;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            UIImage *real = nil;
            if ([_alt respondsToSelector:@selector(iconOfSize:forDisplayIdentifier:)]) {
                typedef UIImage *(*AltIconDisp)(id, SEL, NSInteger, NSString *);
                real = ((AltIconDisp)objc_msgSend)(_alt, @selector(iconOfSize:forDisplayIdentifier:), 2, bid);
            }
            if (!real && [_alt respondsToSelector:@selector(iconOfSize:forBundleIdentifier:)]) {
                typedef UIImage *(*AltIconBund)(id, SEL, NSInteger, NSString *);
                real = ((AltIconBund)objc_msgSend)(_alt, @selector(iconOfSize:forBundleIdentifier:), 2, bid);
            }
            if (!real) return;
            real = SNAppIconImage(real);
            [_iconCache setObject:real forKey:bid];
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) selfRef = weakSelf;
                if (!selfRef) return;
                [weakSp setProperty:real forKey:@"iconImage"];
                @try { [selfRef reloadSpecifier:weakSp animated:NO]; } @catch (__unused id e) {}
            });
        });
    }
}

    [specs addObject:sp];
}
    return [specs copy];
}

- (void)reloadListSpecifiers
{
    NSArray *built = [self buildListSpecifiers];
    [self setSpecifiers:[built mutableCopy]];
    [self.table reloadData];
}

- (void)enableAllApps
{
    NSMutableSet *allowed = [NSMutableSet set];
    for (NSDictionary *item in self.allApps) {
        NSString *bid = [SNPrefsUtil normalizeBID:item[@"bundle"]];
        if (bid.length) [allowed addObject:bid];
    }

    NSUserDefaults *defs = [SNPrefsUtil suite];
    [defs setObject:[SNPrefsUtil normalizeIDArray:allowed.allObjects] forKey:@"allowedAppIDs"];
    [defs setBool:YES forKey:@"allowedSeededOnce"];
    [defs synchronize];
    [SNPrefsUtil postPrefsChanged];
    [self reloadListSpecifiers];
}

- (void)disableAllApps
{
    NSUserDefaults *defs = [SNPrefsUtil suite];
    [defs setObject:@[] forKey:@"allowedAppIDs"];
    [defs setBool:YES forKey:@"allowedSeededOnce"];
    [defs synchronize];
    [SNPrefsUtil postPrefsChanged];
    [self reloadListSpecifiers];
}

- (void)resetReadCounters
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset read counters?"
                                                                   message:@"This clears read counts and the Last read entry only. App enable states and custom messages are kept."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSUserDefaults *defs = [SNPrefsUtil suite];
        [defs setObject:@{} forKey:kSNPerAppSpokenCountsKey];
        [defs setObject:@"" forKey:kSNLastSpokenAppIDKey];
        [defs synchronize];
        [SNPrefsUtil postPrefsChanged];

        typeof(self) selfRef = weakSelf;
        if (!selfRef) return;
        selfRef.shownApps = nil;
        [selfRef reloadListSpecifiers];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (NSString *)badgeForBundle:(NSString *)bid
{
    NSString *nbid = [SNPrefsUtil normalizeBID:bid];
    NSUserDefaults *defs = [SNPrefsUtil suite];

    NSSet *allowedSet = [NSSet setWithArray:[SNPrefsUtil normalizeIDArray:[defs objectForKey:@"allowedAppIDs"]]];
    NSSet *blockedSet = [NSSet setWithArray:[SNPrefsUtil normalizeIDArray:[defs objectForKey:@"blockAppIDs"]]];

    NSDictionary *per = [SNPrefsUtil normalizePerAppDict:[defs objectForKey:@"perAppFormats"]];
    BOOL hasCustom = ([per[nbid] isKindOfClass:NSString.class] && [((NSString *)per[nbid]) length] > 0);

    BOOL isAllowed = [allowedSet containsObject:nbid];

    if (!isAllowed) return @"Off";
    if ([blockedSet containsObject:nbid]) return hasCustom ? @"While open • Custom" : @"While open";
    if (hasCustom) return @"Custom";
    return @"On";
}

#pragma mark - Seed allowed once

- (void)seedAllowedOnceIfNeededWith:(NSArray<NSDictionary *> *)apps
{
    (void)apps;
    NSUserDefaults *defs = [SNPrefsUtil suite];
    if ([[defs objectForKey:@"allowedSeededOnce"] boolValue]) return;

    NSArray *existing = [SNPrefsUtil normalizeIDArray:[defs objectForKey:@"allowedAppIDs"]];
    [defs setObject:(existing ?: @[]) forKey:@"allowedAppIDs"];
    [defs setBool:YES forKey:@"allowedSeededOnce"];
    [defs synchronize];
    [SNPrefsUtil postPrefsChanged];
}

#pragma mark - Detail mode

- (NSArray *)buildDetailSpecifiers
{
    NSMutableArray *specs = [NSMutableArray array];

    NSString *bundleID = [self.specifier propertyForKey:@"id"];
    NSString *appName  = (self.specifier.name ?: @"App");

    PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:appName
                                                        target:self set:NULL get:NULL
                                                        detail:Nil cell:PSGroupCell edit:Nil];
    [specs addObject:group];

    // Allowed toggle (whitelist)
    PSSpecifier *allow = [PSSpecifier preferenceSpecifierNamed:@"Speak notifications"
                                                        target:self
                                                           set:@selector(setAllow:specifier:)
                                                           get:@selector(getAllow:)
                                                        detail:Nil cell:PSSwitchCell edit:Nil];
    [allow setProperty:bundleID forKey:@"id"];
    [specs addObject:allow];

    PSSpecifier *disableSound = [PSSpecifier preferenceSpecifierNamed:@"Disable notification sound"
                                                               target:self
                                                                  set:@selector(setDisableSound:specifier:)
                                                                  get:@selector(getDisableSound:)
                                                               detail:Nil
                                                                 cell:PSSwitchCell
                                                                 edit:Nil];
    [disableSound setProperty:bundleID forKey:@"id"];
    [disableSound setProperty:@"com.selandros.speaknotification16/prefsChanged" forKey:@"PostNotification"];
    [specs addObject:disableSound];

    // Block-while-open toggle
    PSSpecifier *blockOpen = [PSSpecifier preferenceSpecifierNamed:@"Block when app is open"
                                                            target:self
                                                               set:@selector(setBlockOpen:specifier:)
                                                               get:@selector(getBlockOpen:)
                                                            detail:Nil cell:PSSwitchCell edit:Nil];
    [blockOpen setProperty:bundleID forKey:@"id"];
    [specs addObject:blockOpen];

    // Strip emojis (per-app)
    PSSpecifier *strip = [PSSpecifier preferenceSpecifierNamed:@"Remove emojis"
                                                        target:self
                                                           set:@selector(setStripEmoji:specifier:)
                                                           get:@selector(getStripEmoji:)
                                                        detail:Nil
                                                          cell:PSSwitchCell
                                                          edit:Nil];
    [strip setProperty:bundleID forKey:@"id"];
    [strip setProperty:@"com.selandros.speaknotification16/prefsChanged" forKey:@"PostNotification"];
    [specs addObject:strip];

    PSSpecifier *formatGroup = [PSSpecifier preferenceSpecifierNamed:@"Custom Message"
                                                              target:self set:NULL get:NULL
                                                              detail:Nil cell:PSGroupCell edit:Nil];
    [formatGroup setProperty:@"Custom message overrides the global format. Use Global follows the global format." forKey:@"footerText"];
    [specs addObject:formatGroup];

    PSSpecifier *msg = [PSSpecifier preferenceSpecifierNamed:@""
                                                      target:self
                                                         set:@selector(setMessage:specifier:)
                                                         get:@selector(getMessage:)
                                                      detail:Nil
                                                        cell:PSEditTextCell
                                                        edit:Nil];
    [msg setProperty:@YES forKey:@"noAutoCorrect"];
    [msg setProperty:@YES forKey:@"noAutoCaps"];
    [msg setProperty:@YES forKey:@"isEditable"];
    [msg setProperty:@YES forKey:@"textFieldIsSingleLine"];
    [msg setProperty:@(UIKeyboardTypeDefault) forKey:@"keyboardType"];
    [msg setProperty:bundleID forKey:@"id"];
    [msg setProperty:@"com.selandros.speaknotification16/prefsChanged" forKey:@"PostNotification"];
    [specs addObject:msg];

    NSArray<NSArray *> *formatButtons = @[
        @[@"App", NSStringFromSelector(@selector(insertAppToken))],
        @[@"Title", NSStringFromSelector(@selector(insertTitleToken))],
        @[@"Sender", NSStringFromSelector(@selector(insertSenderToken))],
        @[@"Message", NSStringFromSelector(@selector(insertMessageToken))],
        @[@"Time", NSStringFromSelector(@selector(insertTimeToken))],
        @[@"Use Global", NSStringFromSelector(@selector(useGlobalMessageFormat))],
        @[@"Default", NSStringFromSelector(@selector(useDefaultMessageFormat))]
    ];
    for (NSArray *item in formatButtons) {
        PSSpecifier *button = [PSSpecifier preferenceSpecifierNamed:item[0]
                                                            target:self set:NULL get:NULL
                                                            detail:Nil cell:PSButtonCell edit:Nil];
        button.buttonAction = NSSelectorFromString(item[1]);
        [specs addObject:button];
    }

    PSSpecifier *eff = [PSSpecifier preferenceSpecifierNamed:@"Effective format"
                                                      target:self
                                                         set:NULL
                                                         get:@selector(getEffectiveFormatValue:)
                                                      detail:Nil
                                                        cell:PSStaticTextCell
                                                        edit:Nil];
    [eff setProperty:@"SN_EffectiveFormatCell" forKey:@"id"];
    [eff setProperty:bundleID forKey:@"bundleID"];
    [specs addObject:eff];

    return [specs copy];
}

#pragma mark - GET/SET

- (id)getDisableSound:(PSSpecifier *)spec
{
    NSString *bid = [SNPrefsUtil normalizeBID:[spec propertyForKey:@"id"]];
    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSDictionary *perApp = [defs dictionaryForKey:kSNPerAppDisableSoundKey];
    id value = [perApp isKindOfClass:NSDictionary.class] ? [perApp objectForKey:bid] : nil;
    if ([value isKindOfClass:NSNumber.class]) return @([value boolValue]);

    id global = [defs objectForKey:@"disableNotificationSound"];
    return @([global isKindOfClass:NSNumber.class] ? [global boolValue] : NO);
}

- (void)setDisableSound:(id)value specifier:(PSSpecifier *)spec
{
    NSString *bid = [SNPrefsUtil normalizeBID:[spec propertyForKey:@"id"]];
    if (bid.length == 0) return;

    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSMutableDictionary *perApp = [[defs dictionaryForKey:kSNPerAppDisableSoundKey] mutableCopy];
    if (!perApp) perApp = [NSMutableDictionary dictionary];
    [perApp setObject:@([value boolValue]) forKey:bid];
    [defs setObject:perApp forKey:kSNPerAppDisableSoundKey];
    [defs synchronize];
    [SNPrefsUtil postPrefsChanged];
}

- (id)getStripEmoji:(PSSpecifier *)spec
{
    NSString *bid = [SNPrefsUtil normalizeBID:[spec propertyForKey:@"id"]];
    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSDictionary *per = [defs dictionaryForKey:kSNPerAppEmojiStripKey];
    if (![per isKindOfClass:NSDictionary.class]) return @NO;

    NSNumber *v = per[bid];
    return @([v isKindOfClass:NSNumber.class] ? v.boolValue : NO);
}

- (void)setStripEmoji:(id)value specifier:(PSSpecifier *)spec
{
    NSString *bid = [SNPrefsUtil normalizeBID:[spec propertyForKey:@"id"]];
    BOOL on = [value boolValue];

    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSMutableDictionary *m = [[defs dictionaryForKey:kSNPerAppEmojiStripKey] mutableCopy];
    if (!m) m = [NSMutableDictionary new];

    if (on) {
        m[bid] = @YES;
    } else {
        [m removeObjectForKey:bid];
    }

    [defs setObject:m forKey:kSNPerAppEmojiStripKey];
    [defs synchronize];
    [SNPrefsUtil postPrefsChanged];
}


- (id)getAllow:(PSSpecifier *)spec
{
    NSString *bid = [SNPrefsUtil normalizeBID:[spec propertyForKey:@"id"]];
    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSArray *arr = [SNPrefsUtil normalizeIDArray:[defs objectForKey:@"allowedAppIDs"]];
    return @([arr containsObject:bid]);
}

- (void)setAllow:(id)value specifier:(PSSpecifier *)spec
{
    NSString *bid = [SNPrefsUtil normalizeBID:[spec propertyForKey:@"id"]];
    BOOL on = [value boolValue];

    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSMutableArray *arr = [[SNPrefsUtil normalizeIDArray:[defs objectForKey:@"allowedAppIDs"]] mutableCopy];
    if (!arr) arr = [NSMutableArray array];

    if (on) {
        if (![arr containsObject:bid]) [arr addObject:bid];
    } else {
        [arr removeObject:bid];
    }

    [defs setObject:[SNPrefsUtil normalizeIDArray:arr] forKey:@"allowedAppIDs"];
    [defs setBool:YES forKey:@"allowedSeededOnce"];
    [defs synchronize];
    [SNPrefsUtil postPrefsChanged];
}

- (id)getBlockOpen:(PSSpecifier *)spec
{
    NSString *bid = [SNPrefsUtil normalizeBID:[spec propertyForKey:@"id"]];
    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSArray *arr = [SNPrefsUtil normalizeIDArray:[defs objectForKey:@"blockAppIDs"]];
    return @([arr containsObject:bid]);
}

- (void)setBlockOpen:(id)value specifier:(PSSpecifier *)spec
{
    NSString *bid = [SNPrefsUtil normalizeBID:[spec propertyForKey:@"id"]];
    BOOL on = [value boolValue];

    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSMutableArray *arr = [[SNPrefsUtil normalizeIDArray:[defs objectForKey:@"blockAppIDs"]] mutableCopy];
    if (!arr) arr = [NSMutableArray array];

    if (on) {
        if (![arr containsObject:bid]) [arr addObject:bid];
    } else {
        [arr removeObject:bid];
    }

    [defs setObject:[SNPrefsUtil normalizeIDArray:arr] forKey:@"blockAppIDs"];
    [defs synchronize];
    [SNPrefsUtil postPrefsChanged];
}

// Return nil so inherited apps show an empty override field
- (id)getMessage:(PSSpecifier *)spec
{
    NSString *bid = [SNPrefsUtil normalizeBID:[spec propertyForKey:@"id"]];
    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSDictionary *per = [SNPrefsUtil normalizePerAppDict:[defs objectForKey:@"perAppFormats"]];
    NSString *msg = [per objectForKey:bid];
    if (![msg isKindOfClass:NSString.class]) return nil;
    NSString *trim = [msg stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return (trim.length ? trim : nil);
}

// Empty/whitespace removes override, so global default takes effect
- (void)setMessage:(id)value specifier:(PSSpecifier *)spec
{
    NSString *bid = [SNPrefsUtil normalizeBID:[spec propertyForKey:@"id"]];
    NSString *raw = [value isKindOfClass:NSString.class] ? (NSString *)value : @"";
    NSString *trim = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSMutableDictionary *m = [[SNPrefsUtil normalizePerAppDict:[defs objectForKey:@"perAppFormats"]] mutableCopy];
    if (!m) m = [NSMutableDictionary new];

    if (trim.length) {
        m[bid] = trim;
    } else {
        [m removeObjectForKey:bid];
    }

    [defs setObject:m forKey:@"perAppFormats"];
    [defs synchronize];
    [SNPrefsUtil postPrefsChanged];
}

static inline NSString *SNPerAppTrimmedMessage(NSString *value)
{
    if (![value isKindOfClass:NSString.class]) return @"";
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static UITextField *SNPerAppFirstResponderTextFieldInView(UIView *view)
{
    if ([view isKindOfClass:UITextField.class] && view.isFirstResponder) return (UITextField *)view;
    for (UIView *subview in view.subviews) {
        UITextField *field = SNPerAppFirstResponderTextFieldInView(subview);
        if (field) return field;
    }
    return nil;
}

- (NSString *)currentDetailBundleID
{
    return [SNPrefsUtil normalizeBID:[self.specifier propertyForKey:@"id"]];
}

- (NSString *)storedMessageForBundleID:(NSString *)bundleID
{
    NSString *bid = [SNPrefsUtil normalizeBID:bundleID];
    if (bid.length == 0) return @"";

    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSDictionary *per = [SNPrefsUtil normalizePerAppDict:[defs objectForKey:@"perAppFormats"]];
    NSString *value = [per objectForKey:bid];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

- (void)saveMessageText:(NSString *)text forBundleID:(NSString *)bundleID
{
    NSString *bid = [SNPrefsUtil normalizeBID:bundleID];
    if (bid.length == 0) return;

    NSString *raw = [text isKindOfClass:NSString.class] ? text : @"";
    NSString *trim = SNPerAppTrimmedMessage(raw);
    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSMutableDictionary *m = [[SNPrefsUtil normalizePerAppDict:[defs objectForKey:@"perAppFormats"]] mutableCopy];
    if (!m) m = [NSMutableDictionary dictionary];

    if (trim.length > 0) {
        m[bid] = raw;
    } else {
        [m removeObjectForKey:bid];
    }

    [defs setObject:m forKey:@"perAppFormats"];
    [defs synchronize];
    [SNPrefsUtil postPrefsChanged];
}

- (NSString *)currentMessageDraftForBundleID:(NSString *)bundleID
{
    UITextField *field = SNPerAppFirstResponderTextFieldInView(self.view ?: self.table);
    if (field && field.isFirstResponder) return field.text ?: @"";
    return [self storedMessageForBundleID:bundleID];
}

- (NSString *)messageByAppendingToken:(NSString *)token toFormat:(NSString *)format
{
    NSString *base = [format isKindOfClass:NSString.class] ? format : @"";
    if (base.length == 0) return token;

    NSCharacterSet *spacing = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    unichar last = [base characterAtIndex:(base.length - 1)];
    NSString *separator = [spacing characterIsMember:last] ? @"" : @" ";
    return [base stringByAppendingFormat:@"%@%@", separator, token];
}

- (void)saveAndReloadMessageText:(NSString *)text
{
    [self saveMessageText:text forBundleID:[self currentDetailBundleID]];
    [self reloadSpecifiers];
}

- (void)insertFormatToken:(NSString *)token
{
    if (![token isKindOfClass:NSString.class] || token.length == 0) return;
    NSString *bid = [self currentDetailBundleID];
    NSString *draft = [self currentMessageDraftForBundleID:bid];
    [self saveAndReloadMessageText:[self messageByAppendingToken:token toFormat:draft]];
}

- (void)insertAppToken { [self insertFormatToken:@"{APP}"]; }
- (void)insertTitleToken { [self insertFormatToken:@"{TITLE}"]; }
- (void)insertSenderToken { [self insertFormatToken:@"{SENDER}"]; }
- (void)insertMessageToken { [self insertFormatToken:@"{BODY}"]; }
- (void)insertTimeToken { [self insertFormatToken:@"{TIME}"]; }

- (void)useGlobalMessageFormat
{
    [self saveAndReloadMessageText:@""];
}

- (void)useDefaultMessageFormat
{
    [self saveAndReloadMessageText:@"{APP}: {TITLE}: {BODY}"];
}

// Read-only value provider: Effective format (per-app if set, else global/legacy/fallback)
- (id)getEffectiveFormatValue:(PSSpecifier *)spec
{
    NSString *bid = [spec propertyForKey:@"bundleID"];
    return SNEffectiveFormatForBundle(bid);
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Release icons on memory pressure; they will be refetched lazily
    [_iconCache removeAllObjects];
}

@end
