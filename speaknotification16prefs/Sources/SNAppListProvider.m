#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "SNSharedKeys.h"

static NSString * const kAppsCacheKey = @"cachedVisibleApps_v7";           // New cache key to avoid stale data

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allApplications;
@end

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@end

static id SN_ProxyValueForSelector(id proxy, SEL selector)
{
    if (!proxy || !selector || ![proxy respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(proxy, selector);
}

static NSString *SN_ProxyStringForSelector(id proxy, SEL selector)
{
    id value = SN_ProxyValueForSelector(proxy, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSURL *SN_ProxyURLForSelector(id proxy, SEL selector)
{
    id value = SN_ProxyValueForSelector(proxy, selector);
    return [value isKindOfClass:NSURL.class] ? value : nil;
}

static BOOL SN_ProxyBooleanSelectorIsFalse(id proxy, SEL selector)
{
    if (!proxy || !selector || ![proxy respondsToSelector:selector]) return NO;
    return !((BOOL (*)(id, SEL))objc_msgSend)(proxy, selector);
}

static BOOL SN_ProxyOptionalBooleanSelectorIsFalse(id proxy, SEL selector)
{
    if (!proxy || !selector || ![proxy respondsToSelector:selector]) return YES;
    return !((BOOL (*)(id, SEL))objc_msgSend)(proxy, selector);
}

static id SN_ApplicationProxyForIdentifier(NSString *identifier)
{
    Class proxyClass = objc_getClass("LSApplicationProxy");
    SEL selector = @selector(applicationProxyForIdentifier:);
    if (!proxyClass || ![proxyClass respondsToSelector:selector] || identifier.length == 0) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, selector, identifier);
}

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

static inline BOOL SN_IsNotPlaceholderWatchOrClip(id proxy) {
    return SN_ProxyBooleanSelectorIsFalse(proxy, @selector(isPlaceholder)) &&
           SN_ProxyBooleanSelectorIsFalse(proxy, @selector(isWatchKitApp)) &&
           SN_ProxyBooleanSelectorIsFalse(proxy, @selector(isRemovedSystemApp)) &&
           SN_ProxyOptionalBooleanSelectorIsFalse(proxy, NSSelectorFromString(@"isAppClip"));
}

static inline BOOL SN_IsVisibleThirdPartyApp(id proxy, NSString *bundle, NSString *name) {
    if (bundle.length == 0) return NO;
    if ([bundle hasPrefix:@"com.apple."]) return NO;
    if (name.length == 0) return NO;

    NSURL *bundleURL = SN_ProxyURLForSelector(proxy, @selector(bundleURL));
    if (!bundleURL.isFileURL || ![[bundleURL pathExtension] isEqualToString:@"app"]) return NO;

    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:bundleURL.path isDirectory:&isDirectory] || !isDirectory) return NO;

    return SN_IsNotPlaceholderWatchOrClip(proxy) &&
           SN_ProxyBooleanSelectorIsFalse(proxy, @selector(isRestricted)) &&
           SN_ProxyBooleanSelectorIsFalse(proxy, @selector(isLaunchProhibited));
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
    Class workspaceClass = objc_getClass("LSApplicationWorkspace");
    SEL defaultWorkspace = @selector(defaultWorkspace);
    id ws = (workspaceClass && [workspaceClass respondsToSelector:defaultWorkspace])
        ? ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultWorkspace) : nil;
    NSArray *all = ([ws respondsToSelector:@selector(allApplications)])
        ? ((id (*)(id, SEL))objc_msgSend)(ws, @selector(allApplications)) : @[];

    NSMutableArray<NSDictionary *> *out = [NSMutableArray arrayWithCapacity:all.count];
    NSMutableSet<NSString *> *added = [NSMutableSet set];

    // Third-party apps
    for (id p in all) {
        NSString *bundle = SN_ProxyStringForSelector(p, @selector(bundleIdentifier));
        if (bundle.length == 0) bundle = SN_ProxyStringForSelector(p, @selector(applicationIdentifier));
        NSString *name = SN_ProxyStringForSelector(p, @selector(localizedName));
        if (bundle.length == 0 || name.length == 0) continue;
        if (!SN_IsVisibleThirdPartyApp(p, bundle, name)) continue;
        [out addObject:@{ @"name": name, @"bundle": bundle }];
        [added addObject:bundle];
    }

    // Whitelisted Apple apps explicitly via LSApplicationProxy
    for (NSString *bid in SN_StaticAppleWhitelist()) {
        if ([added containsObject:bid]) continue;
        id proxy = SN_ApplicationProxyForIdentifier(bid);
        if (!proxy) continue;
        if (!SN_IsWhitelistedAppleApp(proxy, bid)) continue;

        NSString *name = SN_ProxyStringForSelector(proxy, @selector(localizedName));
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
