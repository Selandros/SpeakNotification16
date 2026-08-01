// SNSharedKeys.m
// Definitions compiled into each target (tweak + prefs).

#import "SNSharedKeys.h"

NSString * const kSNPrefsSuite = @"com.selandros.speaknotification16";
CFStringRef const kSNPrefsNotify = CFSTR("com.selandros.speaknotification16/prefsChanged");
CFStringRef const kSNReleaseCheckNowNotify = CFSTR("com.selandros.speaknotification16/releaseCheckNow");
CFStringRef const kSNReleaseCheckResultNotify = CFSTR("com.selandros.speaknotification16/releaseCheckResult");
CFStringRef const kSNReleaseTokenValidationNowNotify = CFSTR("com.selandros.speaknotification16/releaseTokenValidationNow");
CFStringRef const kSNReleaseTokenClearedNotify = CFSTR("com.selandros.speaknotification16/releaseTokenCleared");
const BOOL kSNReleaseRepoRequiresToken = NO;
NSString * const kSNPerAppEmojiStripKey = @"perAppStripEmoji";
NSString * const kSNPerAppSpokenCountsKey = @"perAppSpokenCounts";
NSString * const kSNLastSpokenAppIDKey = @"lastSpokenAppID";
NSString * const kBTKey = @"trustedBTDevices";
NSString * const kSSIDsKey = @"trustedSSIDs";
