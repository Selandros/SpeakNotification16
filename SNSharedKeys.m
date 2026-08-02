// SNSharedKeys.m
// Definitions compiled into each target (tweak + prefs).

#import "SNSharedKeys.h"

NSString * const kSNPrefsSuite = @"com.selandros.speaknotification16";
CFStringRef const kSNPrefsNotify = CFSTR("com.selandros.speaknotification16/prefsChanged");
CFStringRef const kSNReleaseCheckNowNotify = CFSTR("com.selandros.speaknotification16/releaseCheckNow");
CFStringRef const kSNReleaseCheckResultNotify = CFSTR("com.selandros.speaknotification16/releaseCheckResult");
CFStringRef const kSNReleaseTokenValidationNowNotify = CFSTR("com.selandros.speaknotification16/releaseTokenValidationNow");
CFStringRef const kSNReleaseTokenClearedNotify = CFSTR("com.selandros.speaknotification16/releaseTokenCleared");
CFStringRef const kSNVoiceStateChangedNotify = CFSTR("com.selandros.speaknotification16/voiceStateChanged");
const BOOL kSNReleaseRepoRequiresToken = NO;
NSString * const kSNPerAppEmojiStripKey = @"perAppStripEmoji";
NSString * const kSNPerAppSpokenCountsKey = @"perAppSpokenCounts";
NSString * const kSNLastSpokenAppIDKey = @"lastSpokenAppID";
NSString * const kSNSelectedVoiceIdentifierByLanguageKey = @"selectedVoiceIdentifierByLanguage";
NSString * const kSNLastUsedVoiceByLanguageKey = @"lastUsedVoiceByLanguage";
NSString * const kBTKey = @"trustedBTDevices";
NSString * const kSSIDsKey = @"trustedSSIDs";

NSString *SNNormalizeVoiceLanguage(NSString *language)
{
    if (![language isKindOfClass:NSString.class]) return @"";
    NSString *raw = [[language stringByReplacingOccurrencesOfString:@"_" withString:@"-"]
                     stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (raw.length == 0) return @"";

    NSArray<NSString *> *parts = [raw componentsSeparatedByString:@"-"];
    NSString *prefix = parts.firstObject.lowercaseString;
    if (prefix.length < 2) return @"";
    if (parts.count == 1) {
        static NSDictionary<NSString *, NSString *> *regions;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            regions = @{
                @"en": @"US", @"sv": @"SE", @"de": @"DE", @"fr": @"FR", @"es": @"ES", @"it": @"IT", @"pt": @"PT",
                @"nl": @"NL", @"da": @"DK", @"nb": @"NO", @"nn": @"NO", @"fi": @"FI", @"is": @"IS", @"pl": @"PL", @"cs": @"CZ",
                @"sk": @"SK", @"sl": @"SI", @"hu": @"HU", @"ro": @"RO", @"bg": @"BG", @"ru": @"RU", @"uk": @"UA",
                @"tr": @"TR", @"el": @"GR", @"he": @"IL", @"ar": @"SA", @"fa": @"IR", @"hi": @"IN", @"bn": @"BD",
                @"ur": @"PK", @"id": @"ID", @"ms": @"MY", @"vi": @"VN", @"th": @"TH", @"ko": @"KR", @"ja": @"JP"
            };
        });
        return [NSString stringWithFormat:@"%@-%@", prefix, regions[prefix] ?: @"US"];
    }

    NSString *part = parts[1];
    if (part.length == 4) {
        NSString *script = [[part substringToIndex:1].uppercaseString stringByAppendingString:[part substringFromIndex:1].lowercaseString];
        if (parts.count > 2 && parts[2].length > 0) {
            return [NSString stringWithFormat:@"%@-%@-%@", prefix, script, parts[2].uppercaseString];
        }
        return [NSString stringWithFormat:@"%@-%@", prefix, script];
    }
    return [NSString stringWithFormat:@"%@-%@", prefix, part.uppercaseString];
}
