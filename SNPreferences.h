// SNPreferences.h
// Centralized preferences access. CPU-cheap, no logging here.
// Keys are stored in the suite: com.selandros.speaknotification16

#import <Foundation/Foundation.h>
#import "SNCancellation.h"
#import "SNSharedKeys.h"

NS_ASSUME_NONNULL_BEGIN

// No logging here; pure declarations for cross-TU linkage.
extern NSString * const kKeyCPRouteLockSeconds;   // INT 0–10 (seconds)
extern NSString * const kKeyTTSTailMs;            // INT 0–1000 (milliseconds)
extern NSString * const kKeyPolicyDebounceMs;     // INT 0–500 (milliseconds)
extern NSString * const kKeyInterruptionTailMs;   // INT 0–2000 (milliseconds)

@interface SNPreferences : NSObject

// ===== Singleton =====
+ (instancetype)sharedInstance;
+ (instancetype)shared; // alias

// ===== Generic getters (cheap, defensive) =====
// Defensive read: returns defValue if key not present or wrong type.
- (NSString *)stringForKey:(NSString *)key defaultValue:(NSString *)defValue;
- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)defValue;

// ===== Core behavior toggles =====
// pause: when ON and the now-playing app is phone media → use PAUSE policy
@property (atomic, assign, readonly) BOOL pauseEnabled;

// speechVolume: user slider 0–100 (hysteresis ±1 applied by caller)
@property (atomic, assign, readonly) NSInteger speechVolume;

// useSystemVolume: when ON, raise to at least slider; when OFF, set exact slider value.
@property (atomic, assign, readonly) BOOL useSystemVolume;

// resetVolumeAfterSpeakEnabled: restore captured media volume after the final queued speech.
@property (atomic, assign, readonly) BOOL resetVolumeAfterSpeakEnabled;

// ===== Debug master + domain flags (runtime-controlled) =====
// debugEnabled acts as a master toggle that enables all domains at runtime.
@property (atomic, assign, readonly) BOOL debugEnabled;

@property (atomic, assign, readonly) BOOL debugNotificationEnabled;  // [NOTIF]
@property (atomic, assign, readonly) BOOL debugTTSAVEnabled;         // [TTS-AV]
@property (atomic, assign, readonly) BOOL debugBurstEnabled;         // [BURST]
@property (atomic, assign, readonly) BOOL debugVolEnabled;           // [VOL]
@property (atomic, assign, readonly) BOOL debugCancelEnabled;        // [CANCEL]
@property (atomic, assign, readonly) BOOL debugPolicyEnabled;        // [POLICY]
@property (atomic, assign, readonly) BOOL debugSpeakEnabled;         // [SPEAK]
@property (atomic, assign, readonly) BOOL debugPokeEnabled;          // [POKE]
@property (atomic, assign, readonly) BOOL debugRouteEnabled;         // [ROUTE]
@property (atomic, assign, readonly) BOOL debugEngineEnabled;        // [ENGINE]
@property (atomic, assign, readonly) BOOL debugPrefsEnabled;         // [PREFS]

// ===== Cancel button / interaction mode (persisted) =====
- (SNCancelButtonMode)cancelButtonMode;

// ===== Trusted environment lists =====
// Arrays of allowed SSIDs, Bluetooth devices, and wired audio devices; used to gate TTS playback.
@property (atomic, copy, readonly) NSArray<NSString *> *trustedSSIDs;
@property (atomic, copy, readonly) NSArray<NSString *> *trustedBTDevices;
@property (atomic, copy, readonly) NSArray<NSString *> *trustedWiredAudioDevices;

// ===== Optional message format (global fallback; per-app handled elsewhere) =====
@property (atomic, copy, readonly) NSString *messageFormat;

// ===== Example toggles (kept for compatibility if exposed in Settings UI) =====
@property (atomic, assign, readonly) BOOL quietHoursEnabled;
@property (atomic, assign, readonly) BOOL queueEnabled;
@property (atomic, assign, readonly) BOOL lockscreenPrivacyEnabled;

// ===== Spam/burst control =====
@property (atomic, assign, readonly) BOOL muteSpamEnabled;          // key: "muteSpam"
@property (atomic, assign, readonly) double spamCooldownSeconds;    // key: "spamCooldownSeconds"

// All getters provide validated defaults/clamping to prevent out-of-range values.
- (NSInteger)cpRouteLockSeconds;    // default 5, clamped 0..10
- (NSInteger)ttsTailMs;             // default 300, clamped 0..1000
- (NSInteger)policyDebounceMs;      // default 150, clamped 0..500
- (NSInteger)interruptionTailMs;    // default 1000, clamped 0..2000

// ===== Lifecycle =====
// Begin/stop listening to Darwin notifications for prefs changes
- (void)startObserving;
- (void)stopObserving;

// Force a synchronous reload from CFPreferences
- (void)reload;

// ===== Convenience lookups =====
// Quick checks to see if the current environment is trusted.
- (BOOL)isSSIDTrusted:(nullable NSString *)ssid;
- (BOOL)isBTTrusted:(nullable NSString *)btName;
- (BOOL)isWiredAudioTrusted:(nullable NSString *)deviceName;

// ===== Snapshots =====
// Use this for synchronous reads in the same stack frame. Returns an autoreleased object tied to the cache lifetime. Do not store across asynchronous boundaries.
- (NSDictionary *)snapshot;

// Use this when passing preferences into blocks, queues or timers. Returns an owned copy that you must release yourself after use. Safe for async usage because it is a separate, immutable object.
- (NSDictionary *)newSnapshot;

@end

NS_ASSUME_NONNULL_END
