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
extern NSString * const kSNBluetoothDeviceUIDsV1Key;
extern NSString * const kSNA2DPDeviceTuningV1Key;
extern NSString * const kSSIDsKey;
extern NSString * const kWiredAudioDevicesKey;
extern NSString * const kWiredAudioDevicesV2Key;
extern NSString * const kAllowAnyWiredAudioDeviceKey;
extern NSString * const kWiredAudioDiagnosticKey;
extern NSString * const kTrustedConnectionAliasesV1Key;
extern NSString * const kSNPerAppNotificationFiltersV1Key;
extern NSString * const kSNPerAppOnlySpeakMatchingFiltersV1Key;
extern NSString * const kSNQuietHoursEnabledKey;
extern NSString * const kSNQuietHoursStartMinutesKey;
extern NSString * const kSNQuietHoursEndMinutesKey;
extern NSString * const kSNFilterScheduleEnabledKey;
extern NSString * const kSNFilterScheduleStartMinutesKey;
extern NSString * const kSNFilterScheduleEndMinutesKey;
extern NSString * const kSNFilterActiveDuringQuietHoursKey;
extern NSString * const kSNNotificationFilterActionDontSpeak;
extern NSString * const kSNNotificationFilterActionSpeakNotification;
extern NSString * const kSNNotificationFilterActionSpeakMatched;
extern NSString * const kSNNotificationFilterActionSpeakCustom;
extern NSString * const kSNNotificationFilterActionRemoveMatched;

typedef NS_ENUM(NSInteger, SNSharedMinuteDefaults) {
    kSNQuietHoursDefaultStartMinutes = 1320,
    kSNQuietHoursDefaultEndMinutes = 420,
    kSNFilterScheduleDefaultStartMinutes = 480,
    kSNFilterScheduleDefaultEndMinutes = 1020,
};

typedef NS_ENUM(NSUInteger, SNA2DPDefaultTiming) {
    kSNA2DPDefaultWarmupMs = 200,
    kSNA2DPDefaultKeepWarmMs = 1200,
};

#ifdef __cplusplus
extern "C" {
#endif

NSString *SNNormalizeVoiceLanguage(NSString *language);
BOOL SNIsTrustedWiredAudioPortType(NSString *portType);
NSString *SNTrustedWiredAudioPortTypeLabel(NSString *portType);
BOOL SNIsUsableWiredAudioUID(NSString *uid);
NSString *SNCanonicalWiredAudioUID(NSString *portType, NSString *rawUID);
BOOL SNIsUsableBluetoothDeviceUID(NSString *uid);
NSString *SNCanonicalBluetoothDeviceUID(NSString *rawUID);
NSInteger SNCurrentLocalMinuteOfDay(void);
BOOL SNIsMinuteInDailyInterval(NSInteger startMinute, NSInteger endMinute, NSInteger currentMinute);

#ifdef __cplusplus
}
#endif
