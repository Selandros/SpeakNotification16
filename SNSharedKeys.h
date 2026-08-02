// SNSharedKeys.h
// Shared constants used by both tweak and prefs. Pure constants.

#import <Foundation/Foundation.h>

extern NSString * const kSNPrefsSuite;
extern CFStringRef const kSNPrefsNotify;
extern CFStringRef const kSNReleaseCheckNowNotify;
extern CFStringRef const kSNReleaseCheckResultNotify;
extern CFStringRef const kSNReleaseTokenValidationNowNotify;
extern CFStringRef const kSNReleaseTokenClearedNotify;
extern CFStringRef const kSNVoiceStateChangedNotify;
extern const BOOL kSNReleaseRepoRequiresToken;
extern NSString * const kSNPerAppEmojiStripKey;
extern NSString * const kSNPerAppSpokenCountsKey;
extern NSString * const kSNLastSpokenAppIDKey;
extern NSString * const kSNSelectedVoiceIdentifierByLanguageKey;
extern NSString * const kSNLastUsedVoiceByLanguageKey;
extern NSString * const kBTKey;
extern NSString * const kSSIDsKey;

NSString *SNNormalizeVoiceLanguage(NSString *language);
