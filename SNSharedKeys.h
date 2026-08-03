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
extern NSString * const kWiredAudioDevicesKey;
extern NSString * const kWiredAudioDevicesV2Key;
extern NSString * const kAllowAnyWiredAudioDeviceKey;
extern NSString * const kWiredAudioDiagnosticKey;

#ifdef __cplusplus
extern "C" {
#endif

NSString *SNNormalizeVoiceLanguage(NSString *language);
BOOL SNIsTrustedWiredAudioPortType(NSString *portType);
NSString *SNTrustedWiredAudioPortTypeLabel(NSString *portType);
BOOL SNIsUsableWiredAudioUID(NSString *uid);

#ifdef __cplusplus
}
#endif
