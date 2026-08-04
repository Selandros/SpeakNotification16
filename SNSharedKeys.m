// SNSharedKeys.m
// Definitions compiled into each target (tweak + prefs).

#import "SNSharedKeys.h"
#import <AVFoundation/AVFoundation.h>

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
NSString * const kWiredAudioDevicesKey = @"trustedWiredAudioDevices";
NSString * const kWiredAudioDevicesV2Key = @"trustedWiredAudioDevicesV2";
NSString * const kAllowAnyWiredAudioDeviceKey = @"allowAnyWiredAudioDevice";
NSString * const kWiredAudioDiagnosticKey = @"wiredAudioDiagnosticPending";
NSString * const kTrustedConnectionAliasesV1Key = @"trustedConnectionAliasesV1";

NSString *SNTrustedWiredAudioPortTypeLabel(NSString *portType)
{
    if (![portType isKindOfClass:NSString.class] || portType.length == 0) return nil;
    if ([portType isEqualToString:AVAudioSessionPortHeadphones]) return @"Headphones";
    if ([portType isEqualToString:AVAudioSessionPortUSBAudio]) return @"USBAudio";
    if ([portType isEqualToString:AVAudioSessionPortLineOut]) return @"LineOut";
    if ([portType isEqualToString:AVAudioSessionPortHDMI]) return @"HDMI";
    if ([portType isEqualToString:AVAudioSessionPortDisplayPort]) return @"DisplayPort";
    if ([portType isEqualToString:AVAudioSessionPortCarAudio]) return @"CarAudio";
    return nil;
}

BOOL SNIsTrustedWiredAudioPortType(NSString *portType)
{
    return SNTrustedWiredAudioPortTypeLabel(portType).length > 0;
}

BOOL SNIsUsableWiredAudioUID(NSString *uid)
{
    if (![uid isKindOfClass:NSString.class]) return NO;
    NSString *value = [uid stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (value.length == 0) return NO;
    NSArray<NSString *> *placeholders = @[@"-", @"unknown", @"none", @"null", @"n/a", @"default", @"speaker", @"receiver", @"carplay"];
    for (NSString *placeholder in placeholders) {
        if ([value caseInsensitiveCompare:placeholder] == NSOrderedSame) return NO;
    }
    return YES;
}

NSString *SNCanonicalWiredAudioUID(NSString *portType, NSString *rawUID)
{
    if (![rawUID isKindOfClass:NSString.class] || rawUID.length == 0) return @"";
    if (![portType isEqualToString:AVAudioSessionPortCarAudio]) return rawUID;

    static NSRegularExpression *carPlayUIDPattern;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        carPlayUIDPattern = [[NSRegularExpression alloc] initWithPattern:
            @"^([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}-Audio-AudioMain)-[0-9]{6,}$"
            options:0 error:NULL];
    });
    NSTextCheckingResult *match = [carPlayUIDPattern firstMatchInString:rawUID
                                                                  options:0
                                                                    range:NSMakeRange(0, rawUID.length)];
    if (!match || match.numberOfRanges < 2) return rawUID;
    return [rawUID substringWithRange:[match rangeAtIndex:1]];
}

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
