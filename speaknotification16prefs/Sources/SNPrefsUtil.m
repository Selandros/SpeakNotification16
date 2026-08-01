#import "SNPrefsUtil.h"
#import <CoreFoundation/CoreFoundation.h>
#import "SNPreferences.h"

@implementation SNPrefsUtil

+ (NSUserDefaults *)suite {
    return [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
}

+ (void)postPrefsChanged {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         kSNPrefsNotify, NULL, NULL, true);
}

+ (NSString *)normalizeBID:(NSString *)s {
    if (![s isKindOfClass:NSString.class] || s.length == 0) return @"";
    NSString *out = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([out hasSuffix:@".notifications"]) {
        out = [out substringToIndex:(out.length - (int)@".notifications".length)];
    }
    NSRange dot = [out rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location != NSNotFound && dot.location + 1 < out.length) {
        NSString *tail = [out substringFromIndex:(dot.location + 1)];
        BOOL digits = YES;
        for (NSUInteger i = 0; i < tail.length; i++) {
            unichar c = [tail characterAtIndex:i];
            if (c < '0' || c > '9') { digits = NO; break; }
        }
        if (digits) out = [out substringToIndex:dot.location];
    }
    return out;
}

+ (NSArray<NSString *> *)normalizeIDArray:(NSArray *)arr {
    if (![arr isKindOfClass:NSArray.class] || arr.count == 0) return @[];
    NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSet];
    for (id x in arr) {
        if (![x isKindOfClass:NSString.class]) continue;
        NSString *n = [self normalizeBID:(NSString *)x];
        if (n.length) [set addObject:n];
    }
    return set.array;
}

+ (NSDictionary<NSString *, NSString *> *)normalizePerAppDict:(NSDictionary *)inDict {
    if (![inDict isKindOfClass:NSDictionary.class] || inDict.count == 0) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:inDict.count];
    for (id k in inDict) {
        if (![k isKindOfClass:NSString.class]) continue;
        id v = inDict[k];
        if (![v isKindOfClass:NSString.class]) continue;
        NSString *key = [self normalizeBID:(NSString *)k];
        NSString *val = [(NSString *)v stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (key.length && val.length && !out[key]) {
            out[key] = val; // First winner in a collision
        }
    }
    return out.copy;
}

+ (void)normalizePrefsIfNeeded {
    NSUserDefaults *d = [self suite];
    if ([d boolForKey:@"idsNormalizedOnce"]) return;

    NSArray *allow = [self normalizeIDArray:[d arrayForKey:@"allowedAppIDs"] ?: @[]];
    NSArray *block = [self normalizeIDArray:[d arrayForKey:@"blockAppIDs"] ?: @[]];
    NSDictionary *per = [self normalizePerAppDict:[d dictionaryForKey:@"perAppFormats"] ?: @{}];

    [d setObject:allow forKey:@"allowedAppIDs"];
    [d setObject:block forKey:@"blockAppIDs"];
    [d setObject:per forKey:@"perAppFormats"];
    [d setBool:YES forKey:@"idsNormalizedOnce"];
    [d synchronize];
    [self postPrefsChanged];
}

@end
