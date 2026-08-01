#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "SNSharedKeys.h"

static NSString * const kAppsCacheKey = @"cachedVisibleApps_v7";           // New cache key to avoid stale data

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allApplications;
@end

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSString *applicationIdentifier;  // bundleID
@property (nonatomic, readonly) NSString *localizedName;
@end

// Apple whitelist (edit here to add more Apple apps)
static inline NSSet<NSString *> *SN_StaticAppleWhitelist(void) {
    static NSSet<NSString *> *wl;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        wl = [NSSet setWithArray:@[
            @"com.apple.MobileSMS",            // Messages
            @"com.apple.mobilemail",           // Mail
            @"com.apple.mobilephone",          // Phone
            @"com.apple.facetime",             // FaceTime
            @"com.apple.mobilecal",            // Calendar
            @"com.apple.reminders",            // Reminders
            @"com.apple.Maps",                 // Maps
            @"com.apple.Home",                 // Home
            @"com.apple.Passbook",             // Wallet
            @"com.apple.tips",                 // Tips
            @"com.apple.weather",              // Weather
            @"com.apple.podcasts",             // Podcaster
            @"com.apple.Fitness",              // Fitness
            @"com.apple.findmy",               // Find
            @"com.apple.Health",               // Health
            @"com.apple.mobilenotes",          // Notes
            @"com.apple.tv",                   // Apple TV
            @"com.apple.mobileslideshow",      // Bilder
            @"com.apple.mobiletimer",          // Clock/Timer
            @"com.apple.Sharing.TVRemoteNotifications", // apple TV remote
            @"com.apple.ScreenTimeAgent",      // ScreenTime !!!
            @"com.apple.ExposureNotification", // ExposureNotifications !!!
            @"corg.coolstar.SileoStore",       // Sileo !!!
            @"com.apple.appstored"             // Appstore !!!!
        ]];
    });
    return wl;
}

// Loose guard: works in Preferences (no bundleURL required)
static inline BOOL SN_IsNotPlaceholderWatchOrClip(id proxy) {
    @try {
        NSNumber *placeholder = nil; @try { placeholder = [proxy valueForKey:@"isPlaceholder"]; } @catch (...) {}
        if ([placeholder isKindOfClass:NSNumber.class] && placeholder.boolValue) return NO;

        NSNumber *isWatch = nil; @try { isWatch = [proxy valueForKey:@"isWatchKitApp"]; } @catch (...) {}
        if ([isWatch isKindOfClass:NSNumber.class] && isWatch.boolValue) return NO;

        NSNumber *isClip = nil; @try { isClip = [proxy valueForKey:@"isAppClip"]; } @catch (...) {}
        if ([isClip isKindOfClass:NSNumber.class] && isClip.boolValue) return NO;

        NSNumber *removed = nil; @try { removed = [proxy valueForKey:@"isRemovedSystemApp"]; } @catch (...) {}
        if ([removed isKindOfClass:NSNumber.class] && removed.boolValue) return NO;

        return YES;
    } @catch (...) {
        return NO;
    }
}

// Third-party: require applicationType == "User" (no bundleURL requirement)
static inline BOOL SN_IsThirdPartyUserApp(id proxy, NSString *bundle) {
    if (bundle.length == 0) return NO;
    if ([bundle hasPrefix:@"com.apple."]) return NO;
    @try {
        NSString *type = [proxy valueForKey:@"applicationType"]; // "User"/"System"/"Internal"
        if (![type isKindOfClass:NSString.class] || ![type isEqualToString:@"User"]) return NO;
    } @catch (...) { return NO; }
    return SN_IsNotPlaceholderWatchOrClip(proxy);
}

// Apple whitelist: allow even if bundleURL missing in Prefs
static inline BOOL SN_IsWhitelistedAppleApp(id proxy, NSString *bundle) {
    if (bundle.length == 0) return NO;
    if (![bundle hasPrefix:@"com.apple."]) return NO;
    if (![SN_StaticAppleWhitelist() containsObject:bundle]) return NO;
    return SN_IsNotPlaceholderWatchOrClip(proxy);
}

// Build full list: third-party first, then Apple whitelist explicitly
static NSArray<NSDictionary *> *SN_BuildVisibleApps(void) {
    id ws = [objc_getClass("LSApplicationWorkspace") defaultWorkspace];
    NSArray *all = ([ws respondsToSelector:@selector(allApplications)]) ? [ws allApplications] : @[];

    NSMutableArray<NSDictionary *> *out = [NSMutableArray arrayWithCapacity:all.count];
    NSMutableSet<NSString *> *added = [NSMutableSet set];

    // Third-party apps
    for (id p in all) {
        NSString *bundle = nil;
        NSString *name   = nil;
        @try { bundle = [p valueForKey:@"applicationIdentifier"]; } @catch (...) {}
        @try { name   = [p valueForKey:@"localizedName"]; } @catch (...) {}
        if (bundle.length == 0 || name.length == 0) continue;
        if (!SN_IsThirdPartyUserApp(p, bundle)) continue;
        [out addObject:@{ @"name": name, @"bundle": bundle }];
        [added addObject:bundle];
    }

    // Whitelisted Apple apps explicitly via LSApplicationProxy
    for (NSString *bid in SN_StaticAppleWhitelist()) {
        if ([added containsObject:bid]) continue;
        id proxy = [objc_getClass("LSApplicationProxy") applicationProxyForIdentifier:bid];
        if (!proxy) continue;
        if (!SN_IsWhitelistedAppleApp(proxy, bid)) continue;

        NSString *name = nil;
        @try { name = [proxy localizedName]; } @catch (...) {}
        if (name.length == 0) name = bid;

        [out addObject:@{ @"name": name, @"bundle": bid }];
        [added addObject:bid];
    }

    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];

    return out;
}

// Public API (cached)
NSArray<NSDictionary *> *SNVisibleNotificationAppList(void) {
    static NSArray<NSDictionary *> *sCached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
        NSArray *fromDefs = [defs objectForKey:kAppsCacheKey];
        if ([fromDefs isKindOfClass:NSArray.class] && fromDefs.count > 0) {
            sCached = [fromDefs copy];
        } else {
            sCached = [SN_BuildVisibleApps() copy];
            [defs setObject:sCached forKey:kAppsCacheKey];
            [defs synchronize];
        }
    });
    return sCached;
}

NSArray<NSDictionary *> *SNVisibleNotificationAppListForceRefresh(void) {
    NSArray *rebuilt = SN_BuildVisibleApps();

    static NSArray<NSDictionary *> *sCached;
    sCached = [rebuilt copy];

    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
    [defs setObject:sCached forKey:kAppsCacheKey];
    [defs synchronize];

    return sCached;
}

// Legacy wrappers (keep old callers working)
NSArray<NSDictionary *> *SNVisibleAppList(void) {
    return SNVisibleNotificationAppList();
}

NSArray<NSDictionary *> *SNVisibleAppListForceRefresh(void) {
    return SNVisibleNotificationAppListForceRefresh();
}
