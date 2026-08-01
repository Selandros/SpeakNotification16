// SNMediaControl.h
// Media control utilities: play/pause, volume state, ringer mute state.
// Pure motorics only. No logging here. CPU-cheap APIs.

#import <Foundation/Foundation.h>

#ifndef SNMUTESOURCE_ENUM
#define SNMUTESOURCE_ENUM 1
typedef NS_ENUM(NSUInteger, SNMuteSource) {
    SNMuteSourceUnknown = 0,
    SNMuteSourceNotify
};
#endif

// Volume change callback. keyPath may be "outputVolume", "effectiveVolume", or "sysVolume".
typedef void (*SNVolChangedCB)(const char *keyPath, float value);

@interface SNMediaControl : NSObject

// ===== Callbacks & cached state =====
+ (void)setVolumeChangeCallback:(SNVolChangedCB)cb;              // set once from .xm
+ (float)lastEffectiveVolume;                                    // 0.0–1.0, cached
+ (NSString *)lastOutputPortType;                                 // e.g. AVAudioSessionPortCarAudio, AVAudioSessionPortBluetoothA2DP

// ===== Media controls (pause/resume only; no manual duck) =====
+ (id)_sbmcShared;
+ (BOOL)isNowPlaying;

// Canonical API used by Tweak.xm
+ (BOOL)pauseIfPlayingPhoneMedia;                                 // returns YES if a pause was issued
+ (void)resumeIfPausedPhoneMedia;                                 // resumes if we paused

+ (void)forcePlay;  // plays via SBMediaController even if we did not set the pause token
+ (void)remotePlayForBundle:(NSString *)bundleID;

// Compatibility aliases (kept for older callers)
+ (BOOL)pauseIfPlaying;
+ (void)resumeIfPausedByUs;

// Token/lifecycle helpers
+ (void)resetToken;

// ===== Volume helpers =====
+ (float)currentRingerVolume;                                     // 0.0–1.0
+ (float)currentMediaVolume;                                      // 0.0–1.0

// Optional direct system volume setter (used by Tweak.xm via selector)
+ (void)setSystemOutputVolume:(float)value;                       // 0.0–1.0

// ===== Ringer mute (notify-derived; preserves 0/1 calibration) =====
+ (BOOL)ringerMutedKnown:(BOOL *)outKnown;                                // returns muted; sets outKnown if known
+ (BOOL)ringerMutedKnown:(BOOL *)outKnown source:(SNMuteSource *)outSrc;  // same, plus source
+ (NSString *)muteSourceName:(SNMuteSource)src;                           // "notify" or "unknown"

// Compatibility wrapper: YES only if known & muted
+ (BOOL)isRingerMuted;

@end
