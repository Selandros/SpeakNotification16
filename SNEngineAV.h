// SNEngineAV.h
// Audio engine session control for TTS: prepare/activate/teardown.
// Pure motorics only. No logging here. CPU-cheap APIs.

#import <Foundation/Foundation.h>
#import "SNMixPolicy.h"
#import <AVFAudio/AVAudioSession.h>

FOUNDATION_EXPORT NSString * const kSNEngineAVDidFinish;
FOUNDATION_EXPORT NSString * const kSNEngineAVDidCancel;
FOUNDATION_EXPORT NSString * const kSNEngineAVDidSelectVoice;
FOUNDATION_EXPORT NSString * const kSNEngineAVUserInfoTailSec;
FOUNDATION_EXPORT NSString * const kSNEngineAVUserInfoRouteType;
FOUNDATION_EXPORT NSString * const kSNEngineAVUserInfoLang;
FOUNDATION_EXPORT NSString * const kSNEngineAVUserInfoVoiceName;
FOUNDATION_EXPORT NSString * const kSNEngineAVUserInfoVoiceIdentifier;
FOUNDATION_EXPORT NSString * const kSNEngineAVUserInfoVoiceSource;
FOUNDATION_EXPORT NSString * const kSNEngineAVUserInfoTerminalReason;
FOUNDATION_EXPORT NSString * const kSNEngineAVUserInfoTransaction;

typedef void (^SNA2DPWarmupCompletion)(uint64_t transaction,
                                       BOOL completed,
                                       NSString *reason,
                                       uint64_t elapsedMs);
typedef BOOL (^SNA2DPWarmupStartGuard)(uint64_t transaction);
typedef void (^SNA2DPWarmupStartCompletion)(uint64_t transaction,
                                             BOOL playerInitialized,
                                             BOOL preparedToPlay,
                                             BOOL playResult,
                                             BOOL isPlaying,
                                             NSUInteger bufferBytes,
                                             double sampleRate,
                                             NSString *failureStage,
                                             NSString *failureError);

#ifdef __cplusplus
extern "C" {
#endif

double SNEngineAVLastKeepaliveSec(void);

#ifdef __cplusplus
}
#endif

#ifndef SN_HAVE_CURRENT_PORT_HELPER
#define SN_HAVE_CURRENT_PORT_HELPER 1
// Returns AVAudioSession.currentRoute first output portType, safe and cheap.
static inline NSString *sn_current_port(void) {
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        AVAudioSessionRouteDescription *r = s.currentRoute;
        AVAudioSessionPortDescription *o = r.outputs.firstObject;
        return o.portType ?: @"";
    } @catch (...) {
        return @"";
    }
}
#endif


@interface SNEngineAV : NSObject

// Convenience: prepares and activates with DuckOthers only when duckMode==YES.
+ (BOOL)activateForTTSWithDuck:(BOOL)duckMode;

// Singleton (internal use).
+ (instancetype)shared;

// Speak a single prompt. Title may be nil/empty; lang is BCP-47 (e.g., "sv-SE").
+ (BOOL)speakTitle:(NSString *)title body:(NSString *)body lang:(NSString *)lang;
+ (BOOL)speakTitle:(NSString *)title body:(NSString *)body lang:(NSString *)lang transaction:(uint64_t)txn;

// Stop any ongoing TTS promptly (idempotent).
+ (void)stop;
+ (void)stopTransaction:(uint64_t)txn;

// Back-compat no-ops (safe to call; do nothing if already configured).
+ (void)sn_prepareSessionIfNeeded;
+ (void)sn_deactivateSessionIfActive;

// Prepare AudioSession for an upcoming TTS prompt.
// Returns YES if session/category/mode configured.
// 'route' selects suitable category/mode (e.g., VoicePrompt for CarPlay/HFP).
// If 'duckOthers' is YES, sets DuckOthers option (no manual ramp here).
+ (BOOL)prepareVoicePromptForRoute:(SNMixRouteKind)route
                       duckOthers:(BOOL)duckOthers;

// Activate prepared AudioSession for immediate TTS playback.
// Safe if already active.
+ (BOOL)activateForTTS;

// Plays a short in-memory zero-PCM WAV before TTS. Completion always runs on main.
+ (BOOL)beginA2DPWarmupForTransaction:(uint64_t)transaction
                              duration:(NSTimeInterval)duration
                           bufferBytes:(NSUInteger *)outBufferBytes
                            sampleRate:(double *)outSampleRate
                   playerInitialized:(BOOL *)outPlayerInitialized
                      preparedToPlay:(BOOL *)outPreparedToPlay
                         playerPlaying:(BOOL *)outPlayerPlaying
                          startGuard:(SNA2DPWarmupStartGuard)startGuard
                     startCompletion:(SNA2DPWarmupStartCompletion)startCompletion
                          failureStage:(NSString **)outFailureStage
                          failureError:(NSString **)outFailureError
                            completion:(SNA2DPWarmupCompletion)completion;

// Deactivate/cleanup after TTS fully done (or aborted).
// Must use AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation as primary resume.
// Idempotent.
+ (void)teardownVoicePrompt;

// Instance variant used internally/by SNCancellation.
- (void)stopNow;
- (void)stopNowForTransaction:(uint64_t)txn;

@end
