// Log file: /var/mobile/Library/Logs/log_speaknotification16.txt

#pragma mark - Imports (System)

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <math.h>
#import <MediaPlayer/MPVolumeView.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <notify.h>
#import <SpringBoardServices/SpringBoardServices.h>
#import <BulletinBoard/BBBulletinRequest.h>
#import <BulletinBoard/BBAction.h>
#import <NaturalLanguage/NaturalLanguage.h>

#pragma mark - Includes (System)

#include <atomic>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <string.h>
#include <sys/time.h>
#include <objc/message.h>

#pragma mark - Imports (Local)

#import "SNLogger.h"
#import "SNDeviceState.h"
#import "SNMediaControl.h"
#import "SNAppState.h"
#import "SNAudioState.h"
#import "SNSystemState.h"
#import "SNNetworkState.h"
#import "SNCallMonitor.h"
#import "SNPreferences.h"
#import "SNStringUtils.h"
#import "SNBurstTracker.h"
#import "SNEngineAV.h"
#import "SNCancellation.h"
#import "SNMixPolicy.h"
#import "SNDuckManager.h"
#import "SNSiriGuard.h"
#import "SNRuntime.h"
#import "SNSharedKeys.h"

static void SNReleaseAlertsStart(void);
static void SNReleaseAlertsPreferencesChanged(void);
static void SNReleaseAlertsHandleBBServerEntry(id server,
                                               id bulletin,
                                               unsigned long long destinations);
static void SNReleaseTokenValidationChanged(CFNotificationCenterRef center,
                                            void *observer,
                                            CFStringRef name,
                                            const void *object,
                                            CFDictionaryRef userInfo);
static void SNReleaseTokenClearedChanged(CFNotificationCenterRef center,
                                         void *observer,
                                         CFStringRef name,
                                         const void *object,
                                         CFDictionaryRef userInfo);
static void SNReleaseAlertsHandleBBServerLifecycle(id server);

#pragma mark - Configuration (Keys & Constants)

static NSString * const kSNDebugKey                = @"debugLoggingEnabled";
static NSString * const kSNTrustedToggleKey        = @"onlyTrustedConnection";
static NSString * const kSNVolSliderKey            = @"speechVolume";
static NSString * const kSNChangeWithButtonsKey    = @"useSystemVolume";
static NSString * const kSNResetVolumeAfterSpeakKey = @"SNResetVolumeAfterSpeakEnabled";
static NSString * const kSNPerAppDisableSoundKey    = @"perAppDisableNotificationSound";
static NSString * const kSNSoundSuppressMigrationKey = @"soundSuppressPerAppMigrationDone";
static NSString * const kSNPauseKey                = @"pause";
static NSString *const kSNPerAppDictKey            = @"perAppFormats";
static NSString *const kSNGlobalFormatKey          = @"globalFormat";
static NSString *gSN_FallbackFormat                = @"{APP}: {TITLE}: {BODY}";

static NSDictionary *gSN_PerAppFormats = nil;
static NSString *gSN_GlobalFormat      = nil;
static NSString *gLastSpeakTitle       = nil;
static NSString *gLastSpeakMsg         = nil;
static NSString *gLastSpeakBCP47       = nil;
static NSString *gLastSpeakAppCtx      = nil;

static inline uint64_t SN_NowMS(void) { return (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0); }

/* Audit timestamps need durations that are stable across wall-clock changes. */
static inline uint64_t SN_AuditNowMS(void)
{
    static mach_timebase_info_data_t timebase = {0, 0};
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        (void)mach_timebase_info(&timebase);
    });
    if (timebase.denom == 0) return 0;

    uint64_t ticks = mach_continuous_time();
    long double nanoseconds = ((long double)ticks * (long double)timebase.numer) /
                              (long double)timebase.denom;
    return (uint64_t)(nanoseconds / 1000000.0L);
}

#pragma mark - Timing & Policy (Global Tunables)

/* ==============================  SPEAK DURATION GUARD (ms)  ==============================
   Protects against engines reporting finish too early; estimates min speak time per length. */
static const NSUInteger kSNMinSpeakBaseMs            = 350;    // Base minimum duration for any utterance
static const NSUInteger kSNMsPerChar                 = 12;     // Added ms per (emoji-stripped) character
static const NSUInteger kSNMinSpeakFloorMs           = 1300;   // Lower clamp for total expected duration
static const NSUInteger kSNMinSpeakCeilMs            = 12000;  // Upper clamp for total expected duration
static const NSUInteger kSNEarlyFinishGuardMs        = 300;    // Extra guard time when checking "too early"
static const NSUInteger kSNEarlyFinishHeadroomMs     = 120;    // Extra headroom if queue is empty on early path
static const NSUInteger kSNEarlyFinishExtraDelayMs   = 180;    // Added delay after early-finish path triggers
static const NSUInteger kSNSafeMinChars              = 3;      // Minimum chars before allowing speak
static const double     kSNDefaultSpamWindowSec      = 12.0;   // Default anti-spam window (s)

/* ==============================  INTERRUPTION / SIRI GUARD  ==============================
   Wait tails after Siri/Maps interruptions before starting new TTS. */
static const NSUInteger kSNSiriInterTailMs           = 0;    // Tail to wait after interruption clears
static const NSUInteger kSNSiriInterTailCapMs        = 0;   // Hard cap on total Siri wait
static const NSUInteger kSNSiriInterTailCarPlayMs    = 0;    // CarPlay-specific pre-start tail
static const NSUInteger kSNSiriInterTailCarPlayCapMs = 0;   // CarPlay-specific tail cap

/* ==============================  QUEUE & POST-SPEAK HEURISTICS  ==========================
   Small timing tweaks around didFinish and back-to-back speaks. */
static const NSUInteger kSNPostSpeakSoftDebounceMs   = 145;    // Soft debounce before next speak
static const NSUInteger kSNGraceAfterFinishMs        = 130;    // Grace window after ENGINE didFinish
static const NSUInteger kSNCancelButtonArmDelayMs    = 900;    // Ignore route/volume settle events right after TTS starts
static const NSUInteger kSNPreSpeakDebounceFastMs    = 80;     // Fast debounce when notif sound disabled

/* ==============================  POST-FINISH HOLD (ms)  ==================================
   Keeps the session alive briefly after finish to improve chaining. */
static const NSUInteger kSNPostFinishHoldEmptyMs     = 0;      // Hold when queue is empty 650
static const NSUInteger kSNPostFinishHoldQueuedMs    = 0;      // Shorter hold when more items are queued 450
static const NSUInteger kSNIdleCooldownAfterFireMs   = 2500;   // Cooldown after idle cleanup fires

/* ==============================  IDLE CLEANUP / COOLDOWN (ms)  ===========================
   When to schedule and how long to cool down after cleanup. */
static const NSUInteger kSNIdleMsDefault             = 1500;   // Idle cleanup delay for other routes
static const NSUInteger kSNIdleMsCarPlay             = 1800;   // Idle cleanup delay when on CarPlay
static const NSUInteger kSNPostCallCooldownMs        = 2500;   // Cooldown after phone call ends

/* ==============================  CARPLAY TUNING  =========================================
   Route/state-specific additions to avoid "tail-eating" or early cutoffs. */
static const double     kSNCarPlayNudgeExtraSec      = 0.50;   // Delay notify-others a bit more
static const NSUInteger kSNCarPlayEarlyFinishExtraMs = 200;    // Early-path extra wait
static const NSUInteger kSNCarPlayExtraHoldMs        = 500;      // Post-finish hold when unlocked 500
static const NSUInteger kSNCarPlayGraceExtraMs       = 500;      // Added to kSNGraceAfterFinishMs 120
static const double     kSNCarPlayResumeExtraSec     = 0.35;   // Resume buffer after CarPlay pause

/* ==============================  GATE & GUARD WINDOWS (ms)  ==============================
   Coalescing and busy-check windows. */
static const NSUInteger kSNSiriBusyWindowMs          = 600;    // Consider Siri busy if (now-last)<600ms
static const NSUInteger kSNIdleCoalesceMs            = 400;    // Coalesce repeated idle-arm attempts

/* ==============================  QUEUE POLICY (items & nudges)  ==========================
   Controls max queue size and timing between progress nudges. */
static const NSUInteger kSNQueueCap                  = 50;     // Max items in queue
static const NSUInteger kSNQueueProgressBackoffMs    = 250;    // Minimum gap between nudges
static const NSUInteger kSNQueueProgressSecondNudgeDeltaMs = 400;  // Extra delay for 2nd nudge
static const NSUInteger kSNQueueProgressNudgeLongMs  = 600;    // Longer nudge for specific states
static const NSUInteger kSNTimerFallbackSlackMs      = 50;     // Extra slack added to fallback timers

/* ==============================  MIX / SESSION  ==========================================
   Duck/pause chain timings and safe confirmation delays. */
static const NSUInteger kSNPreRollMs                 = 200;    // Pre-roll before starting chain
static const NSUInteger kSNPostRollMs                = 0;      // Post-roll after TTS ends 500
static const NSUInteger kSNFailSafeConfirmMs         = 300;    // Failsafe confirmation timeout
static const uint32_t   kSNPauseSettleMs             = 60;     // Pause->TTS settle
static const NSUInteger kSNA2DPAudioPreRollMs        = 400;    // Zero-PCM warm-up before cold A2DP TTS
static const NSUInteger kSNA2DPWarmWindowMs          = 1200;   // Skip repeated warm-ups while the headset route remains warm
static const NSInteger  tsk                          = 1;      // Volume hysteresis steps (% points)
static const double     kSNFallbackPokeDelaySec      = 10.0;   // Last-resort "notify others" after no resume

/* ==============================  RESUME / POKE (timings)  ================================
   Timings for resuming paused media and poking players. */
static const uint32_t   kSNResumeRetryFirstMs        = 300;    // First retry after direct attempt
static const uint32_t   kSNResumeRetrySecondMs       = 900;    // Second retry
static const double     kSNResumeRetryFirstSec       = (kSNResumeRetryFirstMs  / 1000.0);
static const double     kSNResumeRetrySecondSec      = (kSNResumeRetrySecondMs / 1000.0);
static const double     kSNResumeDirectDelaySec      = 0.20;   // Delay before direct resume after cancel
static const NSUInteger kSNResumeCleanupSettleMs     = 150;    // Let completed cancel cleanup settle before resume
static const NSUInteger kSNResumeVerifySameMs        = 250;    // Verify the symmetric SBMediaController resume
static const NSUInteger kSNResumeVerifyTargetMs      = 500;    // Verify the bundle-targeted fallback
static const NSUInteger kSNResumeVerifyForceMs       = 1000;   // Final bounded verification window
static const double     kSNTryNextSpeakDelaySec      = 0.50;   // Delay before next speak
static const double     kSNNotifyOthersNudgeSec      = 0.90;   // Nudge after finish if needed

/* ==============================  IDLE / HOUSEKEEPING HELPERS  ============================
   Busy-wait loop helpers and nudges after finishing. */
static const double     kSNBusyWaitStepSec           = 0.10;   // Polling step while waiting
static const double     kSNBusyWaitMaxSec            = 1.00;   // Max busy-wait duration
static const float      kSNVolDeltaEps               = 0.0025f; // Ignore tiny volume jitters
static const float      kSNVolumeRestoreGuardEps     = 0.03f;   // Preserve explicit user volume changes
static const NSUInteger kSNInternalVolumeSetWindowMs = 750;     // Classify callbacks caused by our own volume set

/* ==============================  LANGUAGE TUNING  ========================================
   Language-specific adjustments to expected TTS duration. */
static const double     kSNSwedishSpeedFactor        = 1.15;   // Stretch expected duration for Swedish

/* ==============================  COMPILE-TIME LIMITS  ====================================
   Small arrays and thresholds used in format resolution and language pick. */
#define SN_FMT_CANDIDATE_COUNT      4    // Format candidates per app (+nil sentinel)


#pragma mark - Debug Flags

// Normal bug triage:
// - gDebugLogs: high-level notification/TTS/volume/queue flow.
// - DEBUG_QUEUE_VERBOSE: queue internals.
// - DEBUG_AUDIO_VERBOSE: AVSession idle/release/resume internals.
// - DEBUG_ENGINE_VERBOSE: engine tail/grace/timeout internals.
// - DEBUG_SOUND_VERBOSE: notification sound suppression internals.
// - DEBUG_PRIVATE_TEXT: logs notification/spoken text; keep disabled unless needed.
static volatile BOOL gDebugLogs = NO;

static BOOL DEBUG_NOTIFICATION = NO;   // [NOTIF]
static BOOL DEBUG_TTS_AV       = NO;   // [TTS-AV]
static BOOL DEBUG_VOL          = NO;   // [VOL]
static BOOL DEBUG_CANCEL       = NO;   // [CANCEL]
static BOOL DEBUG_POLICY       = NO;   // [POLICY]
static BOOL DEBUG_POKE         = NO;   // [POKE]
static BOOL DEBUG_ROUTE        = NO;   // [ROUTE]
static BOOL DEBUG_SPEAK        = NO;   // [SPEAK]
static BOOL DEBUG_APP          = NO;   // [APP]
static BOOL DEBUG_ENGINE       = NO;   // [ENGINE], [TTS]
static BOOL DEBUG_QUEUE        = NO;   // [QUEUE]
static BOOL DEBUG_AUDIO        = NO;   // [AUDIO], [IDLE], [RESUME]
static BOOL DEBUG_SOUND        = NO;   // [SOUND]
static BOOL DEBUG_QUEUE_VERBOSE = NO;  // detailed [QUEUE]
static BOOL DEBUG_AUDIO_VERBOSE = NO;  // detailed [AUDIO], [IDLE], [RESUME]
static BOOL DEBUG_ENGINE_VERBOSE = NO; // detailed [ENGINE], [TTS]
static BOOL DEBUG_SOUND_VERBOSE = NO;  // detailed [SOUND]
static BOOL DEBUG_LANG         = NO;   // [LANG], [VOICE]
static BOOL DEBUG_CALLGATE     = NO;   // [CALLGATE]
static BOOL DEBUG_PRIVATE_TEXT = NO;   // full title/body/spoken text
static BOOL DEBUG_RELEASE_VERBOSE = NO; // internal Release Alerts state

#define DBG_NOTIF_ON        (gDebugLogs || DEBUG_NOTIFICATION)
#define DBG_TTS_ON          (gDebugLogs || DEBUG_TTS_AV)
#define DBG_VOL_ON          (gDebugLogs || DEBUG_VOL)
#define DBG_CANCEL_ON       (gDebugLogs || DEBUG_CANCEL)
#define DBG_POLICY_ON       (gDebugLogs || DEBUG_POLICY)
#define DBG_POKE_ON         (gDebugLogs || DEBUG_POKE)
#define DBG_ROUTE_ON        (gDebugLogs || DEBUG_ROUTE)
#define DBG_SPEAK_ON        (gDebugLogs || DEBUG_SPEAK)
#define DBG_APP_ON          (gDebugLogs || DEBUG_APP)
#define DBG_ENGINE_ON       (gDebugLogs || DEBUG_ENGINE || DEBUG_TTS_AV)
#define DBG_QUEUE_ON        (gDebugLogs || DEBUG_QUEUE)
#define DBG_AUDIO_ON        (gDebugLogs || DEBUG_AUDIO)
#define DBG_SOUND_ON        (gDebugLogs || DEBUG_SOUND)
#define DBG_QUEUE_VERBOSE_ON  (gDebugLogs || DEBUG_QUEUE_VERBOSE)
#define DBG_AUDIO_VERBOSE_ON  (gDebugLogs || DEBUG_AUDIO_VERBOSE)
#define DBG_ENGINE_VERBOSE_ON (gDebugLogs || DEBUG_ENGINE_VERBOSE)
#define DBG_SOUND_VERBOSE_ON  (gDebugLogs || DEBUG_SOUND_VERBOSE)
#define DBG_VOL_VERBOSE_ON    (gDebugLogs || DEBUG_VOL)
#define DBG_CANCEL_VERBOSE_ON (gDebugLogs || DEBUG_CANCEL)
#define DBG_POLICY_VERBOSE_ON (gDebugLogs || DEBUG_POLICY)
#define DBG_LANG_VERBOSE_ON   (gDebugLogs || DEBUG_LANG || DEBUG_SPEAK)
#define DBG_LANG_ON         (gDebugLogs || DEBUG_LANG || DEBUG_SPEAK)
#define DBG_CALLGATE_ON     (gDebugLogs || DEBUG_CALLGATE)
#define DBG_CALLGATE_VERBOSE_ON (gDebugLogs || DEBUG_CALLGATE)
#define DBG_PRIVATE_TEXT_ON (DEBUG_PRIVATE_TEXT)

// Logs only when the provided debug flag is true AND a speak context is active.
#define SNLOG_IF_SPEAKCTX(flag, fmt, ...) \
do { \
    if ((flag) && gSpeakAllowedCtx.load(std::memory_order_acquire)) { \
        SNLOGFMT((fmt), ##__VA_ARGS__); \
    } \
} while (0)

#pragma mark - Global State
static uint64_t gIdleGen = 0;
static uint64_t gIdleArmedGen = 0;
static std::atomic_uint64_t gCancelPostedTxn{0};
static std::atomic_uint64_t gClosedTxn{0};
static std::atomic<bool> gSpeakAllowedCtx{false};
static std::atomic<bool> gResumeAttempted(false);
static std::atomic<bool> gDidReleaseToRinger(false);
static std::atomic<bool> gResumeDone{false};
static std::atomic_uint64_t gCurrentTxn{0};
static std::atomic_uint64_t gResumeCycleTxn{0};
static std::atomic_uint64_t gMediaPauseOwnerTxn{0};
static std::atomic_uint64_t gCancelCleanupTxn{0};
static std::atomic_bool gCancelDuckCleanupDone{true};
static std::atomic_bool gCancelEngineCleanupDone{true};
static std::atomic_bool gCancelResumeScheduled{false};
static volatile BOOL g_sn_postSpeakHold = NO;
static std::atomic<bool> gCooldownSkipLogged(false);
static std::atomic<bool> gDeferReleaseForLast{false};
static std::atomic_bool gBurstDropSinceLastSpeak(false);
static std::atomic<bool> gLastPreflightBlocked(false);
static NSString *gLastRouteAtStart = nil;
static std::atomic_uint64_t gA2DPSessionWarmupAttemptedTxn{0};
static std::atomic_uint64_t gA2DPSessionWarmupPendingTxn{0};
static std::atomic_uint64_t gA2DPWarmUntilMS{0};
static std::atomic_uint64_t gA2DPWarmupAbortedTxn{0};

static os_unfair_lock gSNFormatLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock gLastSpeakLock = OS_UNFAIR_LOCK_INIT;

static BOOL   gPrefEnabledCached = YES;
static BOOL   gPrefSpeakUnlockedCached = NO;
static BOOL   gPrefMuteSpamCached = YES;
static double gPrefSpamWindowCached = 12.0;

static std::atomic_uint64_t gCallCooldownUntilMS{0};
static std::atomic<bool> gCallActive{false};

static volatile BOOL g_snPromptDidStart = NO;

static dispatch_queue_t sTTSQueue = NULL;
static volatile double gWindowSec = kSNDefaultSpamWindowSec;

static SNBurstTracker *gBurstTracker;
static SNDuckManager  *gDuckMgr = nil;
static volatile BOOL gDuckChainAlive = NO;
static std::atomic_uint64_t gCancelAllTxn{0};
static NSString * const kSNAuditSyntheticCancelTerminalKey = @"syntheticCancelTerminal";

static volatile SNDuckMode gLastDuckMode = SNDuckModeDuck;

static BOOL  gPausedBySN = NO;
static std::atomic<bool> gPokeScheduled{false};

static BOOL gRingerSilentIsOne = YES;
static BOOL gRingerPolarityLocked = NO;

static BOOL gPreWasPlaying = NO;
static NSString *gPreNowPlayingBID = nil;

static NSString *gAppFilterMode = nil;
static NSSet<NSString *> *gAllowSet = nil;
static NSSet<NSString *> *gBlockSet = nil;
static BOOL gAllowSeededOnce = NO;
static volatile BOOL gFilterDirty = YES;

static volatile BOOL gSBDeviceLocked = NO;
static volatile BOOL gPrevWasLocked = NO;
static volatile BOOL gSBScreenBlanked = NO;
static volatile BOOL gPrevBlanked = NO;
static BOOL sSN_VolInit = NO;
static float sSN_LastVol = -1.0f;
static std::atomic_uint64_t gLastVolCancelAtMS{0};
static std::atomic_uint64_t gInternalVolumeSetTxn{0};
static std::atomic_uint64_t gInternalVolumeSetUntilMS{0};
static std::atomic_int gInternalVolumeTargetMilli{-1};
static std::atomic_int gInternalVolumeDirection{0};
static std::atomic_uint64_t gLastInternalVolumeTxn{0};
static std::atomic_int gLastInternalVolumeDirection{0};
static std::atomic_int gLastPhysicalVolumeDirection{0};
static std::atomic_bool gLastVolumePolicyChangeWithButtons{false};
static std::atomic_uint64_t gVolumeReleaseWaitTxn{0};
static BOOL gRingerInit = NO;
static BOOL gPrevRingerSilent = NO;

static NSSet *gBlockWhenOpenSet;
static BOOL gFilterCacheValid = NO;

static NSMutableSet<NSString *> *gSeenBulletins = nil;
static dispatch_queue_t gSeenQ = NULL;


static inline void sn_seen_init_once(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gSeenBulletins = [NSMutableSet new];
        gSeenQ = dispatch_queue_create("sn.seen.bulletins", DISPATCH_QUEUE_SERIAL);
    });
}

static inline BOOL sn_seen_check_and_add_once(NSString *bulletinID) {
    if (bulletinID.length == 0) return NO;
    sn_seen_init_once();
    __block BOOL seen = NO;
    dispatch_sync(gSeenQ, ^{
        if ([gSeenBulletins containsObject:bulletinID]) { seen = YES; return; }
        [gSeenBulletins addObject:bulletinID];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (kSNTimerFallbackSlackMs * NSEC_PER_MSEC)),
                   gSeenQ, ^{ [gSeenBulletins removeObject:bulletinID]; });
    return seen;
}

static inline void sn_seen_remove(NSString *bulletinID) {
    if (bulletinID.length == 0 || !gSeenQ) return;
    dispatch_sync(gSeenQ, ^{ [gSeenBulletins removeObject:bulletinID]; });
}

static inline BOOL SN_CallMonitorActive(void) {
    return gCallActive.load(std::memory_order_acquire);
}

#pragma mark - Log-once-per-transaction
static std::atomic_uint64_t gDebounceLoggedTxn{0};
static std::atomic_uint64_t gSiriTailLoggedTxn{0};
/*static std::atomic_uint64_t gSiriWaitLoggedTxn{0};*/

static inline BOOL sn_log_once_txn(std::atomic_uint64_t &slot, uint64_t txn) {
    uint64_t prev = slot.load(std::memory_order_acquire);
    if (prev == txn) return NO;
    slot.store(txn, std::memory_order_release);
    return YES;
}

#pragma mark - Resume Gate

static std::atomic_bool gResumeLogged{false};
static inline BOOL sn_audio_chain_busy_now(void);
static inline BOOL sn_isPhoneMediaNowPlaying(void);
static void sn_audit_playback_snapshot(uint64_t txn, NSString *name, NSString *bundleID, BOOL wasPlaying);
static void sn_audit_resume_not_needed(uint64_t txn);
static void sn_audit_resume_owner(uint64_t txn, NSString *name, NSString *bundleID);
static void sn_audit_resume_handoff(uint64_t fromTxn, uint64_t toTxn);
static void sn_audit_resume_terminal(uint64_t txn, NSString *result, NSString *name, NSString *bundleID);
static void sn_audit_resume_terminal_with_reason(uint64_t txn, NSString *result, NSString *name, NSString *bundleID, NSString *reason);

typedef NS_ENUM(uint8_t, SNResumeMethod) {
    SNResumeMethodSameController = 0,
    SNResumeMethodTargeted,
    SNResumeMethodForce
};

static inline NSString *sn_resume_method_name(SNResumeMethod method)
{
    switch (method) {
        case SNResumeMethodSameController: return @"resumeIfPausedPhoneMedia";
        case SNResumeMethodTargeted:       return @"remotePlayForBundle";
        case SNResumeMethodForce:          return @"forcePlay";
    }
}

static inline BOOL sn_resume_owner_matches(uint64_t txn, NSString *targetBID)
{
    if (!txn || gMediaPauseOwnerTxn.load(std::memory_order_acquire) != txn) return NO;
    if (!gPausedBySN || !gPreWasPlaying) return NO;

    NSString *ownedBID = gPreNowPlayingBID;
    if (targetBID.length || ownedBID.length) {
        return (targetBID.length && ownedBID.length && [targetBID isEqualToString:ownedBID]);
    }
    return YES;
}

static inline void sn_log_resume_skip(uint64_t txn, NSString *reason, NSString *targetBID)
{
    if (!DBG_AUDIO_ON) return;
    SNLOGFMT(@"[RESUME] skip | txn=%llu ownerTxn=%llu reason=%@ target=%@ activeTxn=%llu",
             (unsigned long long)txn,
             (unsigned long long)gMediaPauseOwnerTxn.load(std::memory_order_acquire),
             (reason ?: @"unknown"),
             (targetBID.length ? targetBID : @"-"),
             (unsigned long long)gCurrentTxn.load(std::memory_order_acquire));
}

static inline void sn_resume_state_clear(uint64_t txn, const char *reason)
{
    uint64_t ownerTxn = gMediaPauseOwnerTxn.load(std::memory_order_acquire);
    uint64_t cycleTxn = gResumeCycleTxn.load(std::memory_order_acquire);
    if (txn && ownerTxn && ownerTxn != txn && cycleTxn != txn) return;

    if (DBG_AUDIO_VERBOSE_ON && (ownerTxn || cycleTxn || gResumeAttempted.load(std::memory_order_acquire))) {
        SNLOGFMT(@"[RESUME] state clear | txn=%llu ownerTxn=%llu cycleTxn=%llu reason=%s",
                 (unsigned long long)txn,
                 (unsigned long long)ownerTxn,
                 (unsigned long long)cycleTxn,
                 (reason ?: "unknown"));
    }

    gResumeCycleTxn.store(0, std::memory_order_release);
    gResumeAttempted.store(false, std::memory_order_release);
    gResumeDone.store(true, std::memory_order_release);
    gResumeLogged.store(false, std::memory_order_release);
    gPokeScheduled.store(false, std::memory_order_release);
    gMediaPauseOwnerTxn.store(0, std::memory_order_release);
    gPausedBySN = NO;
    gPreWasPlaying = NO;
    if (gPreNowPlayingBID) {
        [gPreNowPlayingBID release];
        gPreNowPlayingBID = nil;
    }
    [SNMediaControl resetToken];

    if (!txn || gCancelCleanupTxn.load(std::memory_order_acquire) == txn) {
        gCancelCleanupTxn.store(0, std::memory_order_release);
        gCancelDuckCleanupDone.store(true, std::memory_order_release);
        gCancelEngineCleanupDone.store(true, std::memory_order_release);
        gCancelResumeScheduled.store(false, std::memory_order_release);
    }
}

static inline void sn_resume_state_clear_for_new_txn(uint64_t newTxn)
{
    uint64_t ownerTxn = gMediaPauseOwnerTxn.load(std::memory_order_acquire);
    uint64_t cycleTxn = gResumeCycleTxn.load(std::memory_order_acquire);
    if (!ownerTxn && !cycleTxn && !gResumeAttempted.load(std::memory_order_acquire)) return;

    uint64_t auditTxn = ownerTxn ?: cycleTxn;
    if (auditTxn && auditTxn != newTxn) {
        BOOL resumeOwned = (gPausedBySN && gPreWasPlaying);
        if (!resumeOwned) {
            sn_audit_resume_terminal(auditTxn, @"notNeeded", nil, nil);
        } else if (sn_isPhoneMediaNowPlaying()) {
            sn_audit_resume_terminal(auditTxn, @"verified", nil, nil);
        } else {
            sn_audit_resume_terminal_with_reason(auditTxn, @"failed", nil, nil,
                                                 @"newTxnStateClear");
        }
    }

    if (DBG_AUDIO_VERBOSE_ON) {
        SNLOGFMT(@"[RESUME] state clear | newTxn=%llu ownerTxn=%llu cycleTxn=%llu reason=new-txn",
                 (unsigned long long)newTxn,
                 (unsigned long long)ownerTxn,
                 (unsigned long long)cycleTxn);
    }
    sn_resume_state_clear(0, "new-txn");
}

static inline BOOL sn_resume_state_handoff_to_queued_txn(uint64_t txn)
{
    uint64_t ownerTxn = gMediaPauseOwnerTxn.load(std::memory_order_acquire);
    if (!txn || !ownerTxn || !gPausedBySN || !gPreWasPlaying) return NO;
    gMediaPauseOwnerTxn.store(txn, std::memory_order_release);
    sn_audit_resume_handoff(ownerTxn, txn);
    if (DBG_AUDIO_VERBOSE_ON) {
        SNLOGFMT(@"[RESUME] ownership handoff | fromTxn=%llu toTxn=%llu reason=queued-chain",
                 (unsigned long long)ownerTxn,
                 (unsigned long long)txn);
    }
    return YES;
}

static inline void sn_log_resume_verified_once(uint64_t txn, NSString *method, NSString *bid, NSString *name, NSString *route)
{
    bool expected = false;
    if (gResumeLogged.compare_exchange_strong(expected, true, std::memory_order_acq_rel, std::memory_order_relaxed)) {
        if (DBG_AUDIO_ON) {
            SNLOGFMT(@"[RESUME] verified playing=YES | txn=%llu method=%@ nowPlayingApp=%@ (%@) route=%@",
                     (unsigned long long)txn,
                     (method ?: @"-"),
                     (name ?: @"-"),
                     (bid ?: @"-"),
                     (route ?: @"-"));
        }
    }
}

static inline uint64_t sn_resume_cycle_txn(void)
{
    return gMediaPauseOwnerTxn.load(std::memory_order_acquire);
}

static inline NSString *sn_resume_target_bundle_id(void)
{
    if (gPreNowPlayingBID.length && ![gPreNowPlayingBID isEqualToString:@"-"]) {
        return gPreNowPlayingBID;
    }
    NSString *bid = nil, *name = nil, *route = nil; BOOL playing = NO;
    SNAudioNowPlayingProbe(&bid, &name, &playing, &route);
    if (bid.length && ![bid isEqualToString:@"-"] && SNIsPhoneMediaApp(bid)) {
        return bid;
    }
    return nil;
}

static inline void sn_resume_cycle_clear(BOOL success, uint64_t txn, const char *reason)
{
    (void)success;
    sn_resume_state_clear(txn, reason);
}

static BOOL sn_resume_issue_request(NSString *targetBID, SNResumeMethod method, uint64_t txn)
{
    NSString *methodLabel = sn_resume_method_name(method);
    if (!sn_resume_owner_matches(txn, targetBID)) {
        sn_log_resume_skip(txn, @"txnMismatch", targetBID);
        return NO;
    }

    NSString *bid = nil, *name = nil, *route = nil; BOOL playing = NO;
    SNAudioNowPlayingProbe(&bid, &name, &playing, &route);
    if (DBG_AUDIO_ON) {
        BOOL activeDuck = (gDuckMgr ? gDuckMgr.activeDuck : NO);
        BOOL duckDone = gCancelDuckCleanupDone.load(std::memory_order_acquire);
        BOOL engineDone = gCancelEngineCleanupDone.load(std::memory_order_acquire);
        SNLOGFMT(@"[RESUME] request sent | txn=%llu method=%@ target=%@ nowPlayingApp=%@ (%@) route=%@ playing=%d pausedBySN=%d preWasPlaying=%d activeDuck=%d duckCleanup=%d engineCleanup=%d mode=%s",
                 (unsigned long long)txn,
                 (methodLabel ?: @"-"),
                 (targetBID.length ? targetBID : @"-"),
                 (name ?: @"-"),
                 (bid ?: @"-"),
                 (route ?: @"-"),
                 (int)playing,
                 (int)gPausedBySN,
                 (int)gPreWasPlaying,
                 (int)activeDuck,
                 (int)duckDone,
                 (int)engineDone,
                 (gLastDuckMode == SNDuckModePause ? "pause" : "none"));
    }

    BOOL issued = NO;
    @try {
        switch (method) {
            case SNResumeMethodSameController:
                [SNMediaControl resumeIfPausedPhoneMedia];
                issued = YES;
                break;
            case SNResumeMethodTargeted:
                if (targetBID.length) {
                    [SNMediaControl remotePlayForBundle:targetBID];
                    issued = YES;
                }
                break;
            case SNResumeMethodForce:
                [SNMediaControl forcePlay];
                issued = YES;
                break;
        }
    } @catch (...) {}
    return issued;
}

static void sn_resume_verify_stage(uint64_t txn, NSString *targetBID, SNResumeMethod method, int stage)
{
    uint64_t delayMs = (stage == 1 ? kSNResumeVerifySameMs :
                        (stage == 2 ? kSNResumeVerifyTargetMs : kSNResumeVerifyForceMs));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (!gResumeAttempted.load(std::memory_order_acquire)) return;
        if (gResumeCycleTxn.load(std::memory_order_acquire) != txn) return;
        if (!sn_resume_owner_matches(txn, targetBID)) {
            sn_log_resume_skip(txn, @"staleTxn", targetBID);
            return;
        }
        uint64_t activeTxn = gCurrentTxn.load(std::memory_order_acquire);
        if (activeTxn && activeTxn != txn) {
            sn_log_resume_skip(txn, @"staleTxn", targetBID);
            return;
        }
        if (sn_audio_chain_busy_now()) {
            sn_log_resume_skip(txn, @"cleanupNotFinished", targetBID);
            return;
        }

        NSString *bid = nil, *name = nil, *route = nil; BOOL playing = NO;
        SNAudioNowPlayingProbe(&bid, &name, &playing, &route);
        if (playing) {
            sn_audit_resume_terminal(txn, @"verified", name, bid);
            sn_log_resume_verified_once(txn, sn_resume_method_name(method), bid, name, route);
            sn_resume_cycle_clear(YES, txn, "verified");
            return;
        }

        if (DBG_AUDIO_ON) {
            SNLOGFMT(@"[RESUME] failed still playing=NO | txn=%llu stage=%d method=%@ nowPlayingApp=%@ (%@) route=%@ activeDuck=%d duckCleanup=%d engineCleanup=%d",
                     (unsigned long long)txn,
                     stage,
                     sn_resume_method_name(method),
                     (name ?: @"-"),
                     (bid ?: @"-"),
                     (route ?: @"-"),
                     (int)(gDuckMgr ? gDuckMgr.activeDuck : NO),
                     (int)gCancelDuckCleanupDone.load(std::memory_order_acquire),
                     (int)gCancelEngineCleanupDone.load(std::memory_order_acquire));
        }

        if (stage == 1) {
            SNResumeMethod fallback = targetBID.length ? SNResumeMethodTargeted : SNResumeMethodForce;
            (void)sn_resume_issue_request(targetBID, fallback, txn);
            sn_resume_verify_stage(txn, targetBID, fallback, 2);
            return;
        }

        if (stage == 2) {
            (void)sn_resume_issue_request(targetBID, SNResumeMethodForce, txn);
            sn_resume_verify_stage(txn, targetBID, SNResumeMethodForce, 3);
            return;
        }

        if (DBG_AUDIO_ON) {
            SNLOGFMT(@"[RESUME] failed still playing=NO | txn=%llu final=1 method=%@ target=%@",
                     (unsigned long long)txn,
                     sn_resume_method_name(method),
                     (targetBID.length ? targetBID : @"-"));
        }
        sn_audit_resume_terminal(txn, @"failed", name, bid);
        sn_resume_cycle_clear(NO, txn, "final-failure");
    });
}

#pragma mark - Transaction & Grace Window

static std::atomic_uint64_t gGraceScheduledTxn{0};
static std::atomic_uint64_t gSpeakTxnSeq{0};
static inline uint64_t sn_new_txn(void){ return ++gSpeakTxnSeq; }
static std::atomic_uint64_t gStartInFlightTxn{0};
static std::atomic_bool     gQueueDrainInFlight{false};

/* Audit state is keyed by the real TTS transaction. It carries metadata only;
   notification text is never stored here. */
static os_unfair_lock gSNAuditLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary *gSNAuditIntakeRecords = nil;
static NSMutableArray *gSNAuditIntakeOrder = nil;
static NSMutableDictionary *gSNAuditTxnToIntakeKeys = nil;
static NSString * const kSNAuditSeparator = @"--------------------------------------------------------------------------------";
static const NSUInteger kSNAuditIntakeRecordLimit = 256;

static NSString *sn_audit_key(uint64_t txn)
{
    return [NSString stringWithFormat:@"%llu", (unsigned long long)txn];
}

static NSString *sn_audit_intake_key(uint64_t sequence)
{
    return [NSString stringWithFormat:@"%llu", (unsigned long long)sequence];
}

static void sn_audit_prune_locked(void)
{
    while (gSNAuditIntakeOrder.count > kSNAuditIntakeRecordLimit) {
        NSString *evictionKey = nil;
        for (NSString *candidateKey in gSNAuditIntakeOrder) {
            NSDictionary *candidate = gSNAuditIntakeRecords[candidateKey];
            BOOL terminalWithoutTxn = [candidate[@"terminalWithoutTxn"] boolValue];
            BOOL separatorLogged = [candidate[@"separatorLogged"] boolValue];
            if ([candidate[@"terminal"] boolValue] &&
                (!terminalWithoutTxn || separatorLogged || !DBG_NOTIF_ON)) {
                evictionKey = candidateKey;
                break;
            }
        }
        if (!evictionKey) break;
        NSDictionary *evicted = gSNAuditIntakeRecords[evictionKey];
        NSString *txnKey = [evicted[@"txnKey"] isKindOfClass:NSString.class] ? evicted[@"txnKey"] : nil;
        if (txnKey.length) [gSNAuditTxnToIntakeKeys removeObjectForKey:txnKey];
        [gSNAuditIntakeRecords removeObjectForKey:evictionKey];
        [gSNAuditIntakeOrder removeObject:evictionKey];
    }
}

/* Intake records establish a stable notification identity before a TTS
   transaction exists. Later journal phases may link the record to a txn. */
static void sn_audit_begin_intake(uint64_t sequence, NSDictionary *initial)
{
    if (!sequence) return;
    NSMutableDictionary *record = [initial mutableCopy] ?: [[NSMutableDictionary alloc] init];
    record[@"seq"] = @(sequence);
    record[@"intakeMs"] = @(SN_AuditNowMS());
    record[@"txn"] = [NSNull null];
    record[@"state"] = @"intake";
    record[@"terminal"] = @NO;
    record[@"notifLogged"] = @NO;
    record[@"resultLogged"] = @NO;
    record[@"resultFinalizing"] = @NO;
    record[@"separatorLogged"] = @NO;
    record[@"started"] = @NO;
    record[@"speechStartMs"] = @0;
    record[@"routeAtSpeechStart"] = @"notStarted";
    record[@"routeAtFinalResult"] = @"";
    record[@"engineTerminalReceived"] = @NO;

    NSString *key = sn_audit_intake_key(sequence);
    os_unfair_lock_lock(&gSNAuditLock);
    if (!gSNAuditIntakeRecords) gSNAuditIntakeRecords = [[NSMutableDictionary alloc] init];
    if (!gSNAuditIntakeOrder) gSNAuditIntakeOrder = [[NSMutableArray alloc] init];
    if (!gSNAuditIntakeRecords[key]) [gSNAuditIntakeOrder addObject:key];
    gSNAuditIntakeRecords[key] = record;
    sn_audit_prune_locked();
    os_unfair_lock_unlock(&gSNAuditLock);
    [record release];
}

static uint64_t sn_audit_sequence_for_txn(uint64_t txn)
{
    if (!txn) return 0;
    uint64_t sequence = 0;
    os_unfair_lock_lock(&gSNAuditLock);
    NSString *intakeKey = gSNAuditTxnToIntakeKeys[sn_audit_key(txn)];
    sequence = [gSNAuditIntakeRecords[intakeKey][@"seq"] unsignedLongLongValue];
    os_unfair_lock_unlock(&gSNAuditLock);
    return sequence;
}

static BOOL sn_audit_queue_item_matches(uint64_t txn, uint64_t sequence)
{
    if (!txn || !sequence) return NO;
    BOOL matched = NO;
    os_unfair_lock_lock(&gSNAuditLock);
    NSString *txnKey = sn_audit_key(txn);
    NSString *intakeKey = gSNAuditTxnToIntakeKeys[txnKey];
    NSMutableDictionary *record = gSNAuditIntakeRecords[intakeKey];
    if ([record[@"seq"] unsignedLongLongValue] == sequence) {
        record[@"queueIdentityVerified"] = @YES;
        matched = YES;
    }
    os_unfair_lock_unlock(&gSNAuditLock);
    return matched;
}

static BOOL sn_audit_record_enqueue(uint64_t txn,
                                    uint64_t sequence,
                                    NSUInteger position,
                                    uint64_t behindTxn,
                                    const char *reason)
{
    if (!txn || !sequence) return NO;
    BOOL recorded = NO;
    NSString *reasonString = reason ? [NSString stringWithUTF8String:reason] : @"unknown";
    os_unfair_lock_lock(&gSNAuditLock);
    NSString *txnKey = sn_audit_key(txn);
    NSString *intakeKey = gSNAuditTxnToIntakeKeys[txnKey];
    NSMutableDictionary *record = gSNAuditIntakeRecords[intakeKey];
    if ([record[@"seq"] unsignedLongLongValue] == sequence) {
        record[@"queue"] = [NSString stringWithFormat:@"enqueued(position=%lu,behindTxn=%llu,reason=%@)",
                            (unsigned long)position,
                            (unsigned long long)behindTxn,
                            reasonString];
        record[@"queueDecision"] = @"enqueued";
        record[@"originalQueueDecision"] = @"enqueued";
        record[@"queuePositionAtEnqueue"] = @(position);
        record[@"queueOwnerTxn"] = @(behindTxn);
        record[@"enqueueReason"] = reasonString;
        record[@"enqueueMs"] = @(SN_AuditNowMS());
        record[@"action"] = @"queue";
        record[@"result"] = @"enqueued";
        record[@"policy"] = @"pendingUntilStart";
        record[@"voiceName"] = @"pendingUntilStart";
        record[@"voiceIdentifier"] = @"-";
        record[@"voiceSource"] = @"pending";
        record[@"voiceQuality"] = @"-";
        recorded = YES;
    }
    os_unfair_lock_unlock(&gSNAuditLock);
    return recorded;
}

static BOOL sn_audit_record_direct(uint64_t txn)
{
    if (!txn) return NO;
    BOOL shouldEmit = NO;
    os_unfair_lock_lock(&gSNAuditLock);
    NSString *intakeKey = gSNAuditTxnToIntakeKeys[sn_audit_key(txn)];
    NSMutableDictionary *record = gSNAuditIntakeRecords[intakeKey];
    NSString *originalQueueDecision = [record[@"originalQueueDecision"] isKindOfClass:NSString.class]
        ? record[@"originalQueueDecision"] : nil;
    if (record && ![originalQueueDecision isEqualToString:@"enqueued"]) {
        if (originalQueueDecision.length == 0) {
            record[@"queue"] = @"direct";
            record[@"queueDecision"] = @"direct";
            record[@"originalQueueDecision"] = @"direct";
            record[@"decisionMs"] = @(SN_AuditNowMS());
            record[@"action"] = @"speak";
            record[@"result"] = @"allow";
            record[@"voiceName"] = @"pendingUntilStart";
            record[@"voiceIdentifier"] = @"-";
            record[@"voiceSource"] = @"pending";
            record[@"voiceQuality"] = @"-";
        }
        shouldEmit = YES;
    }
    os_unfair_lock_unlock(&gSNAuditLock);
    return shouldEmit;
}

static void sn_audit_begin(uint64_t txn, uint64_t sequence, NSDictionary *initial)
{
    if (!txn || !sequence) return;
    NSString *txnKey = sn_audit_key(txn);
    NSString *intakeKey = sn_audit_intake_key(sequence);
    os_unfair_lock_lock(&gSNAuditLock);
    NSMutableDictionary *record = gSNAuditIntakeRecords[intakeKey];
    if (record) {
        [record addEntriesFromDictionary:initial ?: @{}];
        record[@"txn"] = @(txn);
        record[@"txnKey"] = txnKey;
        record[@"txnAssignedMs"] = @(SN_AuditNowMS());
        record[@"state"] = @"txnAssigned";
        if (!record[@"playbackApp"]) record[@"playbackApp"] = @"-";
        if (!record[@"playbackBundleID"]) record[@"playbackBundleID"] = @"-";
        if (!record[@"preWasPlaying"]) record[@"preWasPlaying"] = @NO;
        if (!record[@"pausedByUs"]) record[@"pausedByUs"] = @NO;
        if (!record[@"pauseMs"]) record[@"pauseMs"] = @0;
        if (!record[@"resumeNeeded"]) record[@"resumeNeeded"] = @NO;
        if (!record[@"resumeOriginTxn"]) record[@"resumeOriginTxn"] = @0;
        if (!record[@"resumeOwnerTxn"]) record[@"resumeOwnerTxn"] = @0;
        if (!record[@"resumeHandoffTxn"]) record[@"resumeHandoffTxn"] = @0;
        if (!record[@"resumeResult"]) record[@"resumeResult"] = @"pending";
        if (!record[@"resumeTerminal"]) record[@"resumeTerminal"] = @NO;
        if (!record[@"resumeTerminalMs"]) record[@"resumeTerminalMs"] = @0;
        if (!record[@"inheritedPlaybackChain"]) record[@"inheritedPlaybackChain"] = @NO;
        if (!record[@"cancelAccepted"]) record[@"cancelAccepted"] = @NO;
        if (!record[@"cancelSource"]) record[@"cancelSource"] = @"-";
        if (!record[@"cancelDetail"]) record[@"cancelDetail"] = @"-";
        if (!record[@"cancelAction"]) record[@"cancelAction"] = @"-";
        if (!record[@"cancelMs"]) record[@"cancelMs"] = @0;
        if (!gSNAuditTxnToIntakeKeys) gSNAuditTxnToIntakeKeys = [[NSMutableDictionary alloc] init];
        gSNAuditTxnToIntakeKeys[txnKey] = intakeKey;
    }
    sn_audit_prune_locked();
    os_unfair_lock_unlock(&gSNAuditLock);
}

static void sn_audit_update(uint64_t txn, NSDictionary *changes)
{
    if (!txn || !changes.count) return;
    os_unfair_lock_lock(&gSNAuditLock);
    NSString *intakeKey = gSNAuditTxnToIntakeKeys[sn_audit_key(txn)];
    NSMutableDictionary *state = gSNAuditIntakeRecords[intakeKey];
    if (state) [state addEntriesFromDictionary:changes];
    os_unfair_lock_unlock(&gSNAuditLock);
}

static void sn_audit_update_sequence(uint64_t sequence, NSDictionary *changes)
{
    if (!sequence || !changes.count) return;
    os_unfair_lock_lock(&gSNAuditLock);
    NSMutableDictionary *state = gSNAuditIntakeRecords[sn_audit_intake_key(sequence)];
    if (state) [state addEntriesFromDictionary:changes];
    os_unfair_lock_unlock(&gSNAuditLock);
}

static void sn_audit_try_finalize_result(uint64_t txn);

/* Engine state is recorded independently from legacy result emission. */
static void sn_audit_record_engine_start(uint64_t txn, NSString *route)
{
    if (!txn) return;
    os_unfair_lock_lock(&gSNAuditLock);
    NSString *intakeKey = gSNAuditTxnToIntakeKeys[sn_audit_key(txn)];
    NSMutableDictionary *record = gSNAuditIntakeRecords[intakeKey];
    if (record && ![record[@"started"] boolValue]) {
        uint64_t now = SN_AuditNowMS();
        NSString *actualRoute = route.length ? route : @"-";
        record[@"started"] = @YES;
        record[@"speechStartMs"] = @(now);
        record[@"startedMs"] = @(now);
        record[@"routeAtSpeechStart"] = actualRoute;
        record[@"route"] = actualRoute;
    }
    os_unfair_lock_unlock(&gSNAuditLock);
}

/* The first accepted engine terminal callback owns terminal audit state. */
static void sn_audit_record_engine_terminal(uint64_t txn,
                                            NSString *outcome,
                                            NSString *reason,
                                            NSString *route)
{
    if (!txn) return;
    BOOL recorded = NO;
    BOOL deferEmptyRejection = NO;
    os_unfair_lock_lock(&gSNAuditLock);
    NSString *intakeKey = gSNAuditTxnToIntakeKeys[sn_audit_key(txn)];
    NSMutableDictionary *record = gSNAuditIntakeRecords[intakeKey];
    if (record && ![record[@"engineTerminalReceived"] boolValue]) {
        NSString *actualRoute = route.length ? route : @"-";
        record[@"engineTerminalReceived"] = @YES;
        record[@"engineOutcome"] = outcome ?: @"unknown";
        record[@"engineReason"] = reason ?: @"unknown";
        record[@"engineTerminalMs"] = @(SN_AuditNowMS());
        record[@"routeAtEngineTerminal"] = actualRoute;
        record[@"routeEnd"] = actualRoute;
        if (![record[@"started"] boolValue]) {
            record[@"started"] = @NO;
            record[@"speechStartMs"] = @0;
            record[@"routeAtSpeechStart"] = @"notStarted";
        }
        recorded = YES;
        deferEmptyRejection = [outcome isEqualToString:@"cancelled"] && [reason isEqualToString:@"empty"];
    }
    os_unfair_lock_unlock(&gSNAuditLock);
    if (recorded && !deferEmptyRejection) sn_audit_try_finalize_result(txn);
}

/* The current synchronous rejection path is an empty utterance wakeup. */
static void sn_audit_record_engine_rejection(uint64_t txn, NSString *route)
{
    if (!txn) return;
    os_unfair_lock_lock(&gSNAuditLock);
    NSString *intakeKey = gSNAuditTxnToIntakeKeys[sn_audit_key(txn)];
    NSMutableDictionary *record = gSNAuditIntakeRecords[intakeKey];
    NSString *priorOutcome = record[@"engineOutcome"];
    NSString *priorReason = record[@"engineReason"];
    BOOL replaceEmptyWakeup = [record[@"engineTerminalReceived"] boolValue] &&
        ![record[@"started"] boolValue] &&
        [priorOutcome isEqualToString:@"cancelled"] &&
        [priorReason isEqualToString:@"empty"];
    if (record && (!record[@"engineTerminalReceived"] || replaceEmptyWakeup)) {
        NSString *actualRoute = route.length ? route : @"-";
        record[@"engineTerminalReceived"] = @YES;
        record[@"engineOutcome"] = @"engineRejected";
        record[@"engineReason"] = @"empty";
        record[@"engineTerminalMs"] = @(SN_AuditNowMS());
        record[@"routeAtEngineTerminal"] = actualRoute;
        record[@"routeEnd"] = actualRoute;
        record[@"started"] = @NO;
        record[@"speechStartMs"] = @0;
        record[@"routeAtSpeechStart"] = @"notStarted";
    }
    os_unfair_lock_unlock(&gSNAuditLock);
}

/* Volume audit records observed ownership without changing volume policy. */
static void sn_audit_volume_prepare(uint64_t txn, float pre, float target, BOOL willSet, BOOL ownsRestore)
{
    if (!txn) return;
    BOOL terminalRecorded = NO;
    os_unfair_lock_lock(&gSNAuditLock);
    NSString *intakeKey = gSNAuditTxnToIntakeKeys[sn_audit_key(txn)];
    NSMutableDictionary *record = gSNAuditIntakeRecords[intakeKey];
    if (record && !record[@"volumeResult"]) {
        record[@"volumeOwned"] = @(ownsRestore && willSet);
        record[@"volumeOriginTxn"] = ownsRestore && willSet ? @(txn) : @0;
        record[@"volumeOwnerTxn"] = ownsRestore && willSet ? @(txn) : @0;
        record[@"volumePre"] = @(pre);
        if (willSet) {
            record[@"volumeTarget"] = @(target);
        } else {
            [record removeObjectForKey:@"volumeTarget"];
        }
        record[@"volumeChangedByUs"] = @NO;
        if (!willSet) {
            record[@"volumeFinal"] = @(pre);
            record[@"volumeResult"] = @"unchanged";
            record[@"volumeTerminal"] = @YES;
            record[@"volumeTerminalMs"] = @(SN_AuditNowMS());
            terminalRecorded = YES;
        } else if (!ownsRestore) {
            record[@"volumeResult"] = @"notOwned";
            record[@"volumeTerminal"] = @YES;
            record[@"volumeTerminalMs"] = @(SN_AuditNowMS());
            terminalRecorded = YES;
        } else {
            record[@"volumeResult"] = @"pending";
            record[@"volumeTerminal"] = @NO;
        }
    }
    os_unfair_lock_unlock(&gSNAuditLock);
    if (terminalRecorded) sn_audit_try_finalize_result(txn);
}

static void sn_audit_volume_capture(uint64_t txn, float pre, float target)
{
    if (!txn) return;
    os_unfair_lock_lock(&gSNAuditLock);
    NSString *intakeKey = gSNAuditTxnToIntakeKeys[sn_audit_key(txn)];
    NSMutableDictionary *record = gSNAuditIntakeRecords[intakeKey];
    if (record && ![record[@"volumeTerminal"] boolValue]) {
        record[@"volumeOwned"] = @YES;
        record[@"volumeOriginTxn"] = @(txn);
        record[@"volumeOwnerTxn"] = @(txn);
        record[@"volumePre"] = @(pre);
        record[@"volumeTarget"] = @(target);
        record[@"volumeCaptureMs"] = @(SN_AuditNowMS());
    }
    os_unfair_lock_unlock(&gSNAuditLock);
}

static void sn_audit_volume_set_requested(uint64_t txn, float target, BOOL restoring)
{
    if (!txn) return;
    os_unfair_lock_lock(&gSNAuditLock);
    NSString *intakeKey = gSNAuditTxnToIntakeKeys[sn_audit_key(txn)];
    NSMutableDictionary *record = gSNAuditIntakeRecords[intakeKey];
    if (record) {
        record[@"volumeSetMs"] = @(SN_AuditNowMS());
        if (restoring) {
            record[@"volumeRestoreTarget"] = @(target);
        } else {
            record[@"volumeTarget"] = @(target);
        }
    }
    os_unfair_lock_unlock(&gSNAuditLock);
}

static void sn_audit_volume_set_confirmed(uint64_t txn, float current, float target)
{
    if (!txn || fabsf(current - target) > kSNVolumeRestoreGuardEps) return;
    os_unfair_lock_lock(&gSNAuditLock);
    NSString *intakeKey = gSNAuditTxnToIntakeKeys[sn_audit_key(txn)];
    NSMutableDictionary *record = gSNAuditIntakeRecords[intakeKey];
    if (record) record[@"volumeChangedByUs"] = @YES;
    os_unfair_lock_unlock(&gSNAuditLock);
}

static void sn_audit_volume_terminal(uint64_t txn, NSString *result, float finalVolume)
{
    if (!txn) return;
    BOOL recorded = NO;
    os_unfair_lock_lock(&gSNAuditLock);
    NSString *intakeKey = gSNAuditTxnToIntakeKeys[sn_audit_key(txn)];
    NSMutableDictionary *record = gSNAuditIntakeRecords[intakeKey];
    if (record && ![record[@"volumeTerminal"] boolValue]) {
        record[@"volumeFinal"] = @(finalVolume);
        record[@"volumeResult"] = result ?: @"unknown";
        record[@"volumeTerminal"] = @YES;
        record[@"volumeTerminalMs"] = @(SN_AuditNowMS());
        recorded = YES;
    }
    os_unfair_lock_unlock(&gSNAuditLock);
    if (recorded) sn_audit_try_finalize_result(txn);
}

static void sn_audit_volume_no_capture(uint64_t txn, float current)
{
    if (!txn) return;
    BOOL recorded = NO;
    os_unfair_lock_lock(&gSNAuditLock);
    NSString *intakeKey = gSNAuditTxnToIntakeKeys[sn_audit_key(txn)];
    NSMutableDictionary *record = gSNAuditIntakeRecords[intakeKey];
    if (record && !record[@"volumeResult"]) {
        record[@"volumeOwned"] = @NO;
        record[@"volumeFinal"] = @(current);
        record[@"volumeResult"] = @"noCapture";
        record[@"volumeTerminal"] = @YES;
        record[@"volumeTerminalMs"] = @(SN_AuditNowMS());
        recorded = YES;
    }
    os_unfair_lock_unlock(&gSNAuditLock);
    if (recorded) sn_audit_try_finalize_result(txn);
}

static void sn_audit_volume_handoff(uint64_t fromTxn,
                                    uint64_t toTxn,
                                    uint64_t originTxn,
                                    float pre,
                                    float target)
{
    if (!fromTxn || !toTxn || !originTxn) return;
    BOOL fromTerminal = NO;
    os_unfair_lock_lock(&gSNAuditLock);
    NSMutableDictionary *from = gSNAuditIntakeRecords[gSNAuditTxnToIntakeKeys[sn_audit_key(fromTxn)]];
    NSMutableDictionary *to = gSNAuditIntakeRecords[gSNAuditTxnToIntakeKeys[sn_audit_key(toTxn)]];
    uint64_t now = SN_AuditNowMS();
    NSNumber *captureMs = from[@"volumeCaptureMs"];
    NSNumber *setMs = from[@"volumeSetMs"];
    NSNumber *changedByUs = from[@"volumeChangedByUs"] ?: @NO;
    if (from && ![from[@"volumeTerminal"] boolValue]) {
        from[@"volumeOwned"] = @YES;
        from[@"volumeOriginTxn"] = @(originTxn);
        from[@"volumeOwnerTxn"] = @(toTxn);
        from[@"volumeHandoffTxn"] = @(toTxn);
        from[@"volumeResult"] = @"handedOff";
        from[@"volumeTerminal"] = @YES;
        from[@"volumeTerminalMs"] = @(now);
        fromTerminal = YES;
    }
    if (to) {
        to[@"volumeOwned"] = @YES;
        to[@"volumeOriginTxn"] = @(originTxn);
        to[@"volumeOwnerTxn"] = @(toTxn);
        to[@"volumeInherited"] = @YES;
        to[@"volumePre"] = @(pre);
        to[@"volumeTarget"] = @(target);
        to[@"volumeChangedByUs"] = changedByUs;
        if (captureMs) to[@"volumeCaptureMs"] = captureMs;
        if (setMs) to[@"volumeSetMs"] = setMs;
        to[@"volumeResult"] = @"pending";
        to[@"volumeTerminal"] = @NO;
    }
    os_unfair_lock_unlock(&gSNAuditLock);
    if (fromTerminal) sn_audit_try_finalize_result(fromTxn);
}

/* Playback audit follows existing pause ownership and verification state. */
static void sn_audit_playback_snapshot(uint64_t txn, NSString *name, NSString *bundleID, BOOL wasPlaying)
{
    if (!txn) return;
    os_unfair_lock_lock(&gSNAuditLock);
    NSMutableDictionary *record = gSNAuditIntakeRecords[gSNAuditTxnToIntakeKeys[sn_audit_key(txn)]];
    if (record) {
        record[@"playbackApp"] = name.length ? name : @"-";
        record[@"playbackBundleID"] = bundleID.length ? bundleID : @"-";
        record[@"preWasPlaying"] = @(wasPlaying);
    }
    os_unfair_lock_unlock(&gSNAuditLock);
}

static void sn_audit_resume_not_needed(uint64_t txn)
{
    if (!txn) return;
    BOOL recorded = NO;
    os_unfair_lock_lock(&gSNAuditLock);
    NSMutableDictionary *record = gSNAuditIntakeRecords[gSNAuditTxnToIntakeKeys[sn_audit_key(txn)]];
    if (record && ![record[@"resumeTerminal"] boolValue] &&
        [record[@"resumeResult"] isEqualToString:@"pending"]) {
        record[@"pausedByUs"] = @NO;
        record[@"resumeNeeded"] = @NO;
        record[@"resumeResult"] = @"notNeeded";
        record[@"resumeTerminal"] = @YES;
        record[@"resumeTerminalMs"] = @(SN_AuditNowMS());
        recorded = YES;
    }
    os_unfair_lock_unlock(&gSNAuditLock);
    if (recorded) sn_audit_try_finalize_result(txn);
}

static void sn_audit_resume_owner(uint64_t txn, NSString *name, NSString *bundleID)
{
    if (!txn) return;
    os_unfair_lock_lock(&gSNAuditLock);
    NSMutableDictionary *record = gSNAuditIntakeRecords[gSNAuditTxnToIntakeKeys[sn_audit_key(txn)]];
    if (record && ![record[@"resumeTerminal"] boolValue]) {
        record[@"playbackApp"] = name.length ? name : (record[@"playbackApp"] ?: @"-");
        record[@"playbackBundleID"] = bundleID.length ? bundleID : (record[@"playbackBundleID"] ?: @"-");
        record[@"preWasPlaying"] = @YES;
        record[@"pausedByUs"] = @YES;
        record[@"pauseMs"] = @(SN_AuditNowMS());
        record[@"resumeNeeded"] = @YES;
        record[@"resumeOriginTxn"] = @(txn);
        record[@"resumeOwnerTxn"] = @(txn);
        record[@"resumeResult"] = @"pending";
        record[@"resumeTerminal"] = @NO;
    }
    os_unfair_lock_unlock(&gSNAuditLock);
}

static void sn_audit_resume_handoff(uint64_t fromTxn, uint64_t toTxn)
{
    if (!fromTxn || !toTxn) return;
    BOOL fromTerminal = NO;
    os_unfair_lock_lock(&gSNAuditLock);
    NSMutableDictionary *from = gSNAuditIntakeRecords[gSNAuditTxnToIntakeKeys[sn_audit_key(fromTxn)]];
    NSMutableDictionary *to = gSNAuditIntakeRecords[gSNAuditTxnToIntakeKeys[sn_audit_key(toTxn)]];
    uint64_t originTxn = [from[@"resumeOriginTxn"] unsignedLongLongValue] ?: fromTxn;
    uint64_t now = SN_AuditNowMS();
    if (from && ![from[@"resumeTerminal"] boolValue]) {
        from[@"resumeNeeded"] = @YES;
        from[@"resumeOriginTxn"] = @(originTxn);
        from[@"resumeOwnerTxn"] = @(toTxn);
        from[@"resumeHandoffTxn"] = @(toTxn);
        from[@"resumeResult"] = @"handedOff";
        from[@"resumeTerminal"] = @YES;
        from[@"resumeTerminalMs"] = @(now);
        fromTerminal = YES;
    }
    if (to && ![to[@"resumeTerminal"] boolValue]) {
        to[@"playbackApp"] = from[@"playbackApp"] ?: @"-";
        to[@"playbackBundleID"] = from[@"playbackBundleID"] ?: @"-";
        to[@"preWasPlaying"] = from[@"preWasPlaying"] ?: @YES;
        to[@"pausedByUs"] = @YES;
        to[@"pauseMs"] = from[@"pauseMs"] ?: @(now);
        to[@"inheritedPlaybackChain"] = @YES;
        to[@"resumeNeeded"] = @YES;
        to[@"resumeOriginTxn"] = @(originTxn);
        to[@"resumeOwnerTxn"] = @(toTxn);
        to[@"resumeResult"] = @"pending";
        to[@"resumeTerminal"] = @NO;
    }
    os_unfair_lock_unlock(&gSNAuditLock);
    if (fromTerminal) sn_audit_try_finalize_result(fromTxn);
}

static void sn_audit_resume_terminal_with_reason(uint64_t txn,
                                                  NSString *result,
                                                  NSString *name,
                                                  NSString *bundleID,
                                                  NSString *reason)
{
    if (!txn) return;
    BOOL recorded = NO;
    os_unfair_lock_lock(&gSNAuditLock);
    NSMutableDictionary *record = gSNAuditIntakeRecords[gSNAuditTxnToIntakeKeys[sn_audit_key(txn)]];
    if (record && ![record[@"resumeTerminal"] boolValue]) {
        if (name.length) record[@"playbackApp"] = name;
        if (bundleID.length) record[@"playbackBundleID"] = bundleID;
        record[@"resumeResult"] = result ?: @"failed";
        if (reason.length) record[@"resumeReason"] = reason;
        record[@"resumeTerminal"] = @YES;
        record[@"resumeTerminalMs"] = @(SN_AuditNowMS());
        recorded = YES;
    }
    os_unfair_lock_unlock(&gSNAuditLock);
    if (recorded) sn_audit_try_finalize_result(txn);
}

static void sn_audit_resume_terminal(uint64_t txn, NSString *result, NSString *name, NSString *bundleID)
{
    sn_audit_resume_terminal_with_reason(txn, result, name, bundleID, nil);
}

/* Queue removal is journal-only. It never substitutes for an engine terminal. */
static void sn_audit_record_queue_terminal(uint64_t txn,
                                           uint64_t sequence,
                                           NSString *outcome,
                                           NSString *reason)
{
    if (!txn || !sequence) return;
    BOOL recorded = NO;
    os_unfair_lock_lock(&gSNAuditLock);
    NSString *intakeKey = gSNAuditTxnToIntakeKeys[sn_audit_key(txn)];
    NSMutableDictionary *record = gSNAuditIntakeRecords[intakeKey];
    if (record && [record[@"seq"] unsignedLongLongValue] == sequence &&
        ![record[@"started"] boolValue] &&
        ![record[@"queueTerminalReceived"] boolValue]) {
        uint64_t now = SN_AuditNowMS();
        record[@"queueTerminalReceived"] = @YES;
        record[@"queueTerminalOutcome"] = outcome.length ? outcome : @"dropped";
        record[@"queueTerminalReason"] = reason.length ? reason : @"unknown";
        record[@"queueTerminalMs"] = @(now);
        record[@"started"] = @NO;
        record[@"speechStartMs"] = @0;
        record[@"routeAtSpeechStart"] = @"notStarted";

        if (![record[@"volumeTerminal"] boolValue] &&
            ![record[@"volumeOwned"] boolValue]) {
            record[@"volumeResult"] = @"notOwned";
            record[@"volumeTerminal"] = @YES;
            record[@"volumeTerminalMs"] = @(now);
        }

        if (![record[@"resumeTerminal"] boolValue] &&
            ![record[@"resumeNeeded"] boolValue] &&
            ![record[@"inheritedPlaybackChain"] boolValue]) {
            record[@"pausedByUs"] = @NO;
            record[@"resumeNeeded"] = @NO;
            record[@"resumeResult"] = @"notNeeded";
            record[@"resumeTerminal"] = @YES;
            record[@"resumeTerminalMs"] = @(now);
        }
        recorded = YES;
    }
    os_unfair_lock_unlock(&gSNAuditLock);
    if (recorded) sn_audit_try_finalize_result(txn);
}

/* The first accepted cancellation is authoritative for the transaction. */
static void sn_audit_record_cancel_accepted(uint64_t txn,
                                            NSString *source,
                                            NSString *detail,
                                            NSString *action)
{
    if (!txn) return;
    os_unfair_lock_lock(&gSNAuditLock);
    NSMutableDictionary *record = gSNAuditIntakeRecords[gSNAuditTxnToIntakeKeys[sn_audit_key(txn)]];
    if (record && ![record[@"cancelAccepted"] boolValue]) {
        record[@"cancelAccepted"] = @YES;
        record[@"cancelSource"] = source.length ? source : @"-";
        record[@"cancelDetail"] = detail.length ? detail : @"-";
        record[@"cancelAction"] = action.length ? action : @"cancel";
        record[@"cancelMs"] = @(SN_AuditNowMS());
    }
    os_unfair_lock_unlock(&gSNAuditLock);
}

/* Accept only the explicit SN_CancelAll terminal for its exact active record. */
static BOOL sn_audit_can_accept_synthetic_cancel_terminal(uint64_t txn)
{
    if (!txn || gCancelAllTxn.load(std::memory_order_acquire) != txn) return NO;
    BOOL accepted = NO;
    os_unfair_lock_lock(&gSNAuditLock);
    NSString *txnKey = sn_audit_key(txn);
    NSString *intakeKey = gSNAuditTxnToIntakeKeys[txnKey];
    NSMutableDictionary *record = gSNAuditIntakeRecords[intakeKey];
    if (record && [record[@"txn"] unsignedLongLongValue] == txn &&
        [record[@"cancelAccepted"] boolValue] &&
        ![record[@"engineTerminalReceived"] boolValue] &&
        ![record[@"resultLogged"] boolValue] &&
        ![record[@"resultFinalizing"] boolValue]) {
        accepted = YES;
    }
    os_unfair_lock_unlock(&gSNAuditLock);
    return accepted;
}

static NSDictionary *sn_audit_snapshot(uint64_t txn, BOOL markNotification)
{
    if (!txn) return nil;
    NSDictionary *copy = nil;
    os_unfair_lock_lock(&gSNAuditLock);
    NSString *intakeKey = gSNAuditTxnToIntakeKeys[sn_audit_key(txn)];
    NSMutableDictionary *state = gSNAuditIntakeRecords[intakeKey];
    BOOL alreadyMarked = [state[@"notifLogged"] boolValue];
    if (state && !alreadyMarked) {
        if (markNotification) state[@"notifLogged"] = @YES;
        copy = [state copy];
    }
    os_unfair_lock_unlock(&gSNAuditLock);
    return [copy autorelease];
}

/* Result helpers are audit-only preparation for the later finalizer. */
static NSDictionary *sn_audit_result_snapshot_for_txn(uint64_t txn) __attribute__((unused));
static NSDictionary *sn_audit_result_readiness(NSDictionary *snapshot) __attribute__((unused));
static NSString *sn_audit_format_result_snapshot(NSDictionary *snapshot,
                                                  uint64_t resultEmissionMs) __attribute__((unused));

static NSDictionary *sn_audit_result_snapshot_for_txn(uint64_t txn)
{
    if (!txn) return nil;
    static NSArray<NSString *> *keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [[NSArray alloc] initWithObjects:
                @"seq", @"txn", @"receivedMs", @"intakeMs", @"createdMs", @"decisionMs", @"enqueueMs",
                @"originalQueueDecision", @"queuePositionAtEnqueue", @"queueOwnerTxn", @"enqueueReason",
                @"queueTerminalReceived", @"queueTerminalOutcome", @"queueTerminalReason", @"queueTerminalMs",
                @"started", @"speechStartMs", @"routeAtSpeechStart", @"engineTerminalReceived",
                @"engineOutcome", @"engineReason", @"engineTerminalMs", @"routeAtEngineTerminal",
                @"routeAtFinalResult", @"lang", @"langReason", @"langDiagnostic", @"voiceName", @"voiceIdentifier",
                @"voiceSource", @"voiceQuality", @"policy", @"inheritedPlaybackChain", @"volumeOwned",
                @"volumeOriginTxn", @"volumeOwnerTxn", @"volumePre", @"volumeTarget", @"volumeRestoreTarget", @"volumeFinal",
                @"volumeChangedByUs", @"volumeResult", @"volumeHandoffTxn", @"volumeTerminal",
                @"volumeTerminalMs", @"playbackApp", @"playbackBundleID", @"preWasPlaying", @"pausedByUs",
                @"resumeNeeded", @"resumeOriginTxn", @"resumeOwnerTxn", @"resumeHandoffTxn", @"resumeResult",
                @"resumeTerminal", @"resumeTerminalMs", @"cancelAccepted", @"cancelSource", @"cancelDetail",
                @"cancelAction", @"cancelMs", @"error", @"resultLogged", @"resultFinalizing", @"separatorLogged", nil];
    });

    NSDictionary *snapshot = nil;
    os_unfair_lock_lock(&gSNAuditLock);
    NSString *intakeKey = gSNAuditTxnToIntakeKeys[sn_audit_key(txn)];
    NSDictionary *record = gSNAuditIntakeRecords[intakeKey];
    if (record) {
        NSMutableDictionary *filtered = [[NSMutableDictionary alloc] initWithCapacity:keys.count];
        for (NSString *key in keys) {
            id value = record[key];
            if (value) filtered[key] = value;
        }
        if (!filtered[@"txn"]) filtered[@"txn"] = @(txn);
        if (filtered[@"seq"]) filtered[@"notificationNumber"] = filtered[@"seq"];
        if (!filtered[@"resultLogged"]) filtered[@"resultLogged"] = @NO;
        if (!filtered[@"separatorLogged"]) filtered[@"separatorLogged"] = @NO;
        snapshot = [filtered copy];
        [filtered release];
    }
    os_unfair_lock_unlock(&gSNAuditLock);
    return [snapshot autorelease];
}

static uint64_t sn_audit_snapshot_u64(NSDictionary *snapshot, NSString *key)
{
    id value = snapshot[key];
    return [value respondsToSelector:@selector(unsignedLongLongValue)] ? [value unsignedLongLongValue] : 0;
}

static NSString *sn_audit_snapshot_string(NSDictionary *snapshot, NSString *key, NSString *fallback)
{
    id value = snapshot[key];
    return [value isKindOfClass:NSString.class] && [(NSString *)value length] ? value : fallback;
}

static BOOL sn_audit_result_value_is_terminal(NSDictionary *snapshot,
                                               NSString *terminalKey,
                                               NSString *resultKey)
{
    NSString *result = sn_audit_snapshot_string(snapshot, resultKey, nil);
    return [snapshot[terminalKey] boolValue] && result.length > 0 && ![result isEqualToString:@"pending"];
}

static NSDictionary *sn_audit_result_readiness(NSDictionary *snapshot)
{
    NSMutableArray<NSString *> *blockers = [[NSMutableArray alloc] init];
    BOOL started = [snapshot[@"started"] boolValue];
    BOOL queueTerminal = [snapshot[@"queueTerminalReceived"] boolValue] && !started;
    BOOL engineTerminal = [snapshot[@"engineTerminalReceived"] boolValue];

    if (!snapshot) {
        [blockers addObject:@"missingRecord"];
    } else if ([snapshot[@"resultLogged"] boolValue]) {
        [blockers addObject:@"alreadyFinalized"];
    } else {
        if (!engineTerminal && !queueTerminal) [blockers addObject:@"noTerminal"];
        if (!sn_audit_result_value_is_terminal(snapshot, @"volumeTerminal", @"volumeResult")) {
            [blockers addObject:@"volumePending"];
        }
        if (!sn_audit_result_value_is_terminal(snapshot, @"resumeTerminal", @"resumeResult")) {
            [blockers addObject:@"resumePending"];
        }
    }

    NSArray *blockerSnapshot = [blockers copy];
    NSDictionary *readiness = [[NSDictionary alloc] initWithObjectsAndKeys:
                               @([blockers count] == 0), @"ready",
                               blockerSnapshot, @"blockers",
                               (queueTerminal ? @"queue" : (engineTerminal ? @"engine" : @"none")), @"terminalBasis",
                               nil];
    [blockerSnapshot release];
    [blockers release];
    return [readiness autorelease];
}

static NSString *sn_audit_elapsed_text(uint64_t endMs, uint64_t startMs)
{
    if (!endMs || !startMs) return @"-";
    if (endMs < startMs) return @"invalid";
    return [NSString stringWithFormat:@"%llu", (unsigned long long)(endMs - startMs)];
}

static NSString *sn_audit_volume_text(NSDictionary *snapshot)
{
    NSString *result = sn_audit_snapshot_string(snapshot, @"volumeResult", @"pending");
    if ([result isEqualToString:@"notOwned"] || [result isEqualToString:@"noCapture"]) return result;
    if ([result isEqualToString:@"handedOff"]) {
        return [NSString stringWithFormat:@"handedOff(toTxn=%llu,originTxn=%llu)",
                (unsigned long long)sn_audit_snapshot_u64(snapshot, @"volumeHandoffTxn"),
                (unsigned long long)sn_audit_snapshot_u64(snapshot, @"volumeOriginTxn")];
    }
    NSNumber *preValue = [snapshot[@"volumePre"] isKindOfClass:NSNumber.class] ? snapshot[@"volumePre"] : nil;
    NSNumber *targetValue = [snapshot[@"volumeTarget"] isKindOfClass:NSNumber.class] ? snapshot[@"volumeTarget"] : nil;
    NSNumber *finalValue = [snapshot[@"volumeFinal"] isKindOfClass:NSNumber.class] ? snapshot[@"volumeFinal"] : nil;
    NSString *pre = preValue ? [NSString stringWithFormat:@"%.2f", preValue.doubleValue] : @"-";
    NSString *target = targetValue ? [NSString stringWithFormat:@"%.2f", targetValue.doubleValue] : @"-";
    NSString *final = finalValue ? [NSString stringWithFormat:@"%.2f", finalValue.doubleValue] : @"-";
    return [NSString stringWithFormat:@"pre:%@ target:%@ final:%@ result=%@", pre, target, final, result];
}

static NSString *sn_audit_playback_text(NSDictionary *snapshot, BOOL neverStarted)
{
    if (neverStarted) return @"playback=notOwned pausedByUs=NO resume=notNeeded";
    NSString *app = sn_audit_snapshot_string(snapshot, @"playbackApp", @"-");
    NSString *resume = sn_audit_snapshot_string(snapshot, @"resumeResult", @"pending");
    if ([resume isEqualToString:@"handedOff"]) {
        resume = [NSString stringWithFormat:@"handedOff(toTxn=%llu)",
                  (unsigned long long)sn_audit_snapshot_u64(snapshot, @"resumeHandoffTxn")];
    }
    return [NSString stringWithFormat:@"playback=%@ pausedByUs=%@ resume=%@",
            app, [snapshot[@"pausedByUs"] boolValue] ? @"YES" : @"NO", resume];
}

static NSString *sn_audit_format_result_snapshot(NSDictionary *snapshot, uint64_t resultEmissionMs)
{
    if (!snapshot) return nil;
    BOOL started = [snapshot[@"started"] boolValue];
    BOOL neverStartedQueueTerminal = [snapshot[@"queueTerminalReceived"] boolValue] && !started;
    NSString *outcome = neverStartedQueueTerminal
        ? sn_audit_snapshot_string(snapshot, @"queueTerminalOutcome", @"dropped")
        : sn_audit_snapshot_string(snapshot, @"engineOutcome", @"unknown");
    NSString *reason = neverStartedQueueTerminal
        ? sn_audit_snapshot_string(snapshot, @"queueTerminalReason", @"unknown")
        : sn_audit_snapshot_string(snapshot, @"engineReason", @"unknown");
    uint64_t terminalBasisMs = neverStartedQueueTerminal
        ? sn_audit_snapshot_u64(snapshot, @"queueTerminalMs")
        : sn_audit_snapshot_u64(snapshot, @"engineTerminalMs");
    uint64_t speechStartMs = sn_audit_snapshot_u64(snapshot, @"speechStartMs");
    uint64_t queueStartMs = neverStartedQueueTerminal
        ? sn_audit_snapshot_u64(snapshot, @"enqueueMs")
        : ([sn_audit_snapshot_string(snapshot, @"originalQueueDecision", @"") isEqualToString:@"enqueued"]
           ? sn_audit_snapshot_u64(snapshot, @"enqueueMs")
           : sn_audit_snapshot_u64(snapshot, @"decisionMs"));
    if (!queueStartMs && !started && !neverStartedQueueTerminal) {
        queueStartMs = sn_audit_snapshot_u64(snapshot, @"decisionMs");
    }
    uint64_t queueEndMs = started ? speechStartMs : terminalBasisMs;
    NSString *queueWait = sn_audit_elapsed_text(queueEndMs, queueStartMs);
    NSString *speechMs = started ? sn_audit_elapsed_text(terminalBasisMs, speechStartMs) : @"0";
    NSString *cleanupMs = sn_audit_elapsed_text(resultEmissionMs, terminalBasisMs);
    NSString *totalMs = sn_audit_elapsed_text(resultEmissionMs, sn_audit_snapshot_u64(snapshot, @"receivedMs"));

    NSString *routeStart = started ? sn_audit_snapshot_string(snapshot, @"routeAtSpeechStart", @"-") : @"notStarted";
    NSString *routeFinal = neverStartedQueueTerminal ? @"notStarted"
        : sn_audit_snapshot_string(snapshot, @"routeAtFinalResult",
                                   sn_audit_snapshot_string(snapshot, @"routeAtEngineTerminal", routeStart));
    BOOL switched = started && routeStart.length && routeFinal.length && ![routeStart isEqualToString:routeFinal];
    NSString *voice = nil;
    NSString *voiceName = sn_audit_snapshot_string(snapshot, @"voiceName", started ? @"-" : @"pendingUntilStart");
    if (!started && [voiceName isEqualToString:@"pendingUntilStart"]) {
        voice = @"pendingUntilStart";
    } else {
        voice = [NSString stringWithFormat:@"\"%@\"<%@/%@/%@,id=%@>", voiceName,
                 sn_audit_snapshot_string(snapshot, @"lang", @"-"),
                 sn_audit_snapshot_string(snapshot, @"voiceQuality", @"-"),
                 sn_audit_snapshot_string(snapshot, @"voiceSource", @"-"),
                 sn_audit_snapshot_string(snapshot, @"voiceIdentifier", @"-")];
    }
    NSString *policy = sn_audit_snapshot_string(snapshot, @"policy", started ? @"-" : @"pendingUntilStart");
    NSString *queue = sn_audit_snapshot_string(snapshot, @"originalQueueDecision", @"-");
    NSString *cancel = @"-";
    if ([snapshot[@"cancelAccepted"] boolValue]) {
        NSString *source = sn_audit_snapshot_string(snapshot, @"cancelSource", @"-");
        NSString *detail = sn_audit_snapshot_string(snapshot, @"cancelDetail", @"-");
        if (![source isEqualToString:@"-"] && ![detail isEqualToString:@"-"]) {
            cancel = [NSString stringWithFormat:@"%@/%@", source, detail];
        }
    }

    NSString *route = started ? [NSString stringWithFormat:@"%@->%@", routeStart, routeFinal] : @"notStarted";
    return [NSString stringWithFormat:@"[RESULT] %02llu | txn=%llu outcome=%@ reason=%@ started=%@ | queueWaitMs=%@ speechMs=%@ cleanupMs=%@ totalMs=%@ | lang=%@ | voice=%@ | route=%@ switched=%@ | policy=%@ inheritedPlaybackChain=%@ | queue=%@ | volume=%@ | %@ | cancel=%@ | error=%@",
            (unsigned long long)sn_audit_snapshot_u64(snapshot, @"seq"),
            (unsigned long long)sn_audit_snapshot_u64(snapshot, @"txn"), outcome, reason,
            started ? @"YES" : @"NO", queueWait, speechMs, cleanupMs, totalMs,
            sn_audit_snapshot_string(snapshot, @"lang", @"-"), voice, route,
            switched ? @"YES" : @"NO", policy,
            [snapshot[@"inheritedPlaybackChain"] boolValue] ? @"YES" : @"NO", queue,
            sn_audit_volume_text(snapshot), sn_audit_playback_text(snapshot, neverStartedQueueTerminal),
            cancel, sn_audit_snapshot_string(snapshot, @"error", @"-")];
}

/* Claims and emits the audit result only after all terminal state is present. */
static void sn_audit_try_finalize_result(uint64_t txn)
{
    if (!txn) return;
    NSDictionary *preflight = sn_audit_result_snapshot_for_txn(txn);
    NSDictionary *readiness = sn_audit_result_readiness(preflight);
    if (![readiness[@"ready"] boolValue]) return;

    BOOL claimed = NO;
    BOOL started = NO;
    os_unfair_lock_lock(&gSNAuditLock);
    NSString *intakeKey = gSNAuditTxnToIntakeKeys[sn_audit_key(txn)];
    NSMutableDictionary *record = gSNAuditIntakeRecords[intakeKey];
    if (record && ![record[@"resultLogged"] boolValue] && ![record[@"resultFinalizing"] boolValue]) {
        record[@"resultFinalizing"] = @YES;
        started = [record[@"started"] boolValue];
        claimed = YES;
    }
    os_unfair_lock_unlock(&gSNAuditLock);
    if (!claimed) return;

    NSString *finalRoute = nil;
    if (started) {
        finalRoute = [[SNMediaControl lastOutputPortType] copy];
        if (finalRoute.length) {
            os_unfair_lock_lock(&gSNAuditLock);
            NSMutableDictionary *routeRecord = gSNAuditIntakeRecords[gSNAuditTxnToIntakeKeys[sn_audit_key(txn)]];
            if (routeRecord && [routeRecord[@"resultFinalizing"] boolValue] && ![routeRecord[@"resultLogged"] boolValue]) {
                routeRecord[@"routeAtFinalResult"] = finalRoute;
            }
            os_unfair_lock_unlock(&gSNAuditLock);
        }
    }

    NSDictionary *finalSnapshot = sn_audit_result_snapshot_for_txn(txn);
    uint64_t resultEmissionMs = SN_AuditNowMS();
    NSString *line = sn_audit_format_result_snapshot(finalSnapshot, resultEmissionMs);
    BOOL wroteOutput = (DBG_ENGINE_ON && line.length > 0);
    if (wroteOutput) {
        SNLOGFMT(@"%@", line);
        logRawTextIntoFile(kSNAuditSeparator);
    }

    os_unfair_lock_lock(&gSNAuditLock);
    NSMutableDictionary *finalRecord = gSNAuditIntakeRecords[gSNAuditTxnToIntakeKeys[sn_audit_key(txn)]];
    if (finalRecord && [finalRecord[@"resultFinalizing"] boolValue]) {
        finalRecord[@"resultLogged"] = @YES;
        finalRecord[@"separatorLogged"] = @(wroteOutput);
        finalRecord[@"terminal"] = @YES;
        finalRecord[@"resultFinalizing"] = @NO;
        sn_audit_prune_locked();
    }
    os_unfair_lock_unlock(&gSNAuditLock);
    [finalRoute release];
}

static NSDictionary *sn_audit_snapshot_sequence(uint64_t sequence)
{
    if (!sequence) return nil;
    NSDictionary *copy = nil;
    os_unfair_lock_lock(&gSNAuditLock);
    NSMutableDictionary *record = gSNAuditIntakeRecords[sn_audit_intake_key(sequence)];
    if (record && ![record[@"notifLogged"] boolValue]) {
        record[@"notifLogged"] = @YES;
        copy = [record copy];
    }
    os_unfair_lock_unlock(&gSNAuditLock);
    return [copy autorelease];
}

static BOOL sn_audit_mark_separator_logged(uint64_t sequence)
{
    if (!sequence) return NO;
    BOOL shouldWrite = NO;
    os_unfair_lock_lock(&gSNAuditLock);
    NSMutableDictionary *record = gSNAuditIntakeRecords[sn_audit_intake_key(sequence)];
    if (record && [record[@"terminalWithoutTxn"] boolValue] &&
        [record[@"notifLogged"] boolValue] && ![record[@"separatorLogged"] boolValue]) {
        record[@"separatorLogged"] = @YES;
        shouldWrite = YES;
    }
    sn_audit_prune_locked();
    os_unfair_lock_unlock(&gSNAuditLock);
    return shouldWrite;
}

static BOOL sn_audit_write_notif(NSDictionary *s, NSString *txnText)
{
    if (!DBG_NOTIF_ON || !s) return NO;
    BOOL withoutTxn = [txnText isEqualToString:@"-"];
    NSString *voiceName = s[@"voiceName"] ?: (withoutTxn ? @"notEvaluated" : @"-");
    NSString *languageText = withoutTxn
        ? [NSString stringWithFormat:@"reason=%@ candidates=notEvaluated", s[@"terminalReason"] ?: @"notEvaluated"]
        : (s[@"langDiagnostic"] ?: @"chars=0 words=0 candidates=- system=- chosen=- reason=notEvaluated");
    NSString *voiceText = [voiceName isEqualToString:@"notEvaluated"]
        ? @"notEvaluated"
        : [NSString stringWithFormat:@"%@<%@> source=%@ quality=%@",
           voiceName,
           s[@"voiceIdentifier"] ?: @"-",
           s[@"voiceSource"] ?: @"-",
           s[@"voiceQuality"] ?: @"-"];
    SNLOGFMT(@"[NOTIF] %02llu | txn=%@ sectionID=%@ title_len=%@ subtitle_len=%@ body_len=%@ | wifi=%@ bt=%@ wired=%@ broadWired=%@ trust=%@ trustedBy=%@ callGate=%@ | route=%@ otherAudio=%@ volume=%@%% muted=%@ locked=%@ fg=%@ screen=%@ battery=%@ | sound=%@ fmt=%@ | lang=%@ %@ | policy=%@ queue=%@ action=%@ result=%@ voice=%@",
             [s[@"seq"] unsignedLongLongValue], txnText ?: @"-",
             s[@"sectionID"] ?: @"-", s[@"titleLen"] ?: @0, s[@"subtitleLen"] ?: @0, s[@"bodyLen"] ?: @0,
             s[@"wifi"] ?: @"-", s[@"bluetooth"] ?: @"-", s[@"wired"] ?: @"-", s[@"broadWired"] ?: @"-",
             s[@"trust"] ?: @"-", s[@"trustedBy"] ?: @"-", s[@"callGate"] ?: @"-",
             s[@"route"] ?: @"-", s[@"otherAudio"] ?: @"-", s[@"volume"] ?: @"-", s[@"muted"] ?: @"-", s[@"locked"] ?: @"-",
             s[@"foreground"] ?: @"-", s[@"screen"] ?: @"-", s[@"battery"] ?: @"-", s[@"sound"] ?: @"-",
             s[@"format"] ?: @"-", s[@"lang"] ?: @"-", languageText, s[@"policy"] ?: @"-", s[@"queue"] ?: @"-",
             s[@"action"] ?: @"-", s[@"result"] ?: @"-",
             voiceText);
    return YES;
}

static BOOL sn_audit_emit_notif(uint64_t txn)
{
    if (!DBG_NOTIF_ON) return NO;
    NSDictionary *s = sn_audit_snapshot(txn, YES);
    return sn_audit_write_notif(s, [NSString stringWithFormat:@"%llu", (unsigned long long)txn]);
}

static void sn_audit_emit_denied(NSDictionary *s, NSString *reason)
{
    if (!s) return;
    uint64_t seq = [s[@"seq"] unsignedLongLongValue];
    BOOL isDrop = [reason isEqualToString:@"burstDuplicate"];
    NSString *terminalReason = [reason isEqualToString:@"untrusted"] ? @"noTrustedConnection" : (reason ?: @"denied");
    NSString *soundReason = [terminalReason isEqualToString:@"noTrustedConnection"] ? @"trustDenied" : terminalReason;
    os_unfair_lock_lock(&gSNAuditLock);
    NSMutableDictionary *record = gSNAuditIntakeRecords[sn_audit_intake_key(seq)];
    if (record) {
        [record addEntriesFromDictionary:s];
        record[@"state"] = isDrop ? @"dropped" : @"denied";
        record[@"terminal"] = @YES;
        record[@"terminalWithoutTxn"] = @YES;
        record[@"terminalKind"] = isDrop ? @"drop" : @"deny";
        record[@"terminalReason"] = terminalReason;
        record[@"decisionMs"] = @(SN_AuditNowMS());
        record[@"queue"] = @"none";
        record[@"action"] = isDrop ? @"drop" : @"deny";
        record[@"result"] = isDrop ? @"drop" : @"deny";
        record[@"sound"] = [NSString stringWithFormat:@"notAttempted(reason=%@)", soundReason];
        record[@"format"] = @"notEvaluated";
        record[@"lang"] = @"notEvaluated";
        record[@"langReason"] = @"notEvaluated";
        record[@"langDiagnostic"] = @"notEvaluated";
        record[@"policy"] = @"notEvaluated";
        record[@"voiceName"] = @"notEvaluated";
    }
    os_unfair_lock_unlock(&gSNAuditLock);
    NSDictionary *snapshot = sn_audit_snapshot_sequence(seq);
    if (sn_audit_write_notif(snapshot, @"-") && sn_audit_mark_separator_logged(seq)) {
        logRawTextIntoFile(kSNAuditSeparator);
    }
}

static std::atomic_uint64_t gFinishOnceTxn{0};
static std::atomic_bool     gFinishOnceDone{false};

static inline void sn_finish_once_reset(uint64_t txn) {
    gFinishOnceTxn.store(txn, std::memory_order_release);
    gFinishOnceDone.store(false, std::memory_order_release);
    gGraceScheduledTxn.store(0, std::memory_order_release);
}

static inline BOOL sn_finish_once_try(uint64_t txn) {
    if (gFinishOnceTxn.load(std::memory_order_acquire) != txn) return NO;
    bool expected = false;
    return gFinishOnceDone.compare_exchange_strong(expected, true, std::memory_order_acq_rel) ? YES : NO;
}

static inline uint64_t sn_terminal_event_txn(NSNotification *notification)
{
    NSNumber *value = notification.userInfo[kSNEngineAVUserInfoTransaction];
    return [value respondsToSelector:@selector(unsignedLongLongValue)] ? value.unsignedLongLongValue : 0;
}

static BOOL sn_terminal_txn_is_current(uint64_t eventTxn, const char *reason)
{
    uint64_t activeTxn = gCurrentTxn.load(std::memory_order_acquire);
    uint64_t closedTxn = gClosedTxn.load(std::memory_order_acquire);
    if (eventTxn != 0 && (eventTxn == activeTxn || (activeTxn == 0 && eventTxn == closedTxn))) {
        if (DBG_QUEUE_VERBOSE_ON) {
            SNLOGFMT(@"[QUEUE] terminal accepted | eventTxn=%llu activeTxn=%llu closedTxn=%llu reason=%s",
                     (unsigned long long)eventTxn,
                     (unsigned long long)activeTxn,
                     (unsigned long long)closedTxn,
                     (reason ?: "terminal"));
        }
        return YES;
    }

    if (DBG_QUEUE_ON) {
        SNLOGFMT(@"[QUEUE] stale terminal ignored | eventTxn=%llu activeTxn=%llu closedTxn=%llu reason=%s",
                 (unsigned long long)eventTxn,
                 (unsigned long long)activeTxn,
                 (unsigned long long)closedTxn,
                 (reason ?: "terminal"));
    }
    return NO;
}

static std::atomic_uint64_t gGraceTxn{0};
static std::atomic_bool     gGraceArmed{false};

static inline void sn_reset_grace_armed(void) {
    gGraceTxn.store(0, std::memory_order_release);
    gGraceArmed.store(false, std::memory_order_release);
}

#pragma mark - Siri / Navigation Gate

static std::atomic_bool gSiriGateBusy{false};
static std::atomic_uint64_t gSiriGateLastUpdateMS{0};

static inline void sn_siriGate_set(BOOL busy) {
    gSiriGateBusy.store(busy ? true : false, std::memory_order_release);
    gSiriGateLastUpdateMS.store(SN_NowMS(), std::memory_order_relaxed);
}

#pragma mark - Preferences

static BOOL gPrefPauseToggle = NO;
static BOOL gPrefResetVolumeAfterSpeak = NO;

#pragma mark - Selector Cache

static SEL selSetSystemOutputVolume   = NULL;
static SEL selPauseIfPlayingPhone     = NULL;
static SEL selResumeIfPausedPhone     = NULL;

typedef NS_ENUM(uint8_t, SNCancelCandidateKind) {
    SNCancelCandidateVolume,
    SNCancelCandidatePower,
    SNCancelCandidateRinger
};

#pragma mark - Forward Declarations
static void finishWork(void);
static inline NSString *SN_CurrentSSID(void);
static inline BOOL sn_isPhoneMediaNowPlaying(void);
static inline NSString *SN_AppDisplayNameForSection(NSString *sectionID, id bulletin);
static inline BOOL SN_PrefBoolFast(NSString *key, BOOL def);
static inline NSString *sn_normalized_app_counter_key(NSString *bundleID);
static void SN_CancelAll(const char *source);
static inline BOOL sn_cancel_buttons_armed_now(void);
static inline BOOL sn_cancel_target_active_now(void);
static inline BOOL sn_cancel_mode_accepts_volume(SNCancelButtonMode mode);
static void sn_handle_cancel_candidate(const char *source, NSString *detail, SNCancelCandidateKind kind);
static void sn_cancel_ringer_switch(NSString *detail);
static void sn_start_duck_chain_and_tts(NSString *title,
                                        NSString *msg,
                                        NSString *bcp47,
                                        NSString *appCtx,
                                        uint64_t txn);

static void sn_queue_enqueue(NSString *title, NSString *msg, NSString *bcp47, NSString *appCtx,
                             uint64_t txn, const char *reason, uint64_t behindTxn);
static NSUInteger sn_queue_count(void);
static void sn_queue_clear(const char *reason);
static BOOL sn_try_speak_next_from_queue(const char *reason);
static BOOL sn_queue_finish_terminal(const char *reason, uint64_t txn);

#pragma mark - Utilities

static std::atomic<uint64_t> gIdleCooldownUntilMS{0};
static dispatch_source_t sIdleCleanupTimer = nil;
static std::atomic<bool> gIdleCleanupArmed(false);
static uint64_t gIdleLastArmAtMS = 0;
static dispatch_queue_t sIdleQueue = nil;

static inline float sn_clampf(float v, float lo, float hi) {
    if (v < lo) return lo; if (v > hi) return hi; return v;
}

static inline void SN_TTS_InitOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sTTSQueue = dispatch_queue_create("com.selandros.speaknotification16.tts", DISPATCH_QUEUE_SERIAL);
    });
}

static inline NSInteger sn_pref_debounce_ms(void) {
    BOOL disableSound = SN_PrefBoolFast(@"disableNotificationSound", NO);
    return disableSound ? (NSInteger)kSNPreSpeakDebounceFastMs : (NSInteger)kSNPostSpeakSoftDebounceMs;
}

static inline BOOL SN_IsCarPlayRoute(void) {
    @try {
        AVAudioSessionRouteDescription *route = [AVAudioSession sharedInstance].currentRoute;
        if (!route || route.outputs.count == 0) return NO;
        for (AVAudioSessionPortDescription *out in route.outputs) {
            NSString *t = out.portType ?: @"";
            if ([t isEqualToString:AVAudioSessionPortCarAudio] ||
                [t rangeOfString:@"Car" options:NSCaseInsensitiveSearch].location != NSNotFound)
                return YES;
        }
    } @catch (...) {}
    return NO;
}

static inline BOOL sn_route_has_HFP(AVAudioSessionRouteDescription *rt)
{
    BOOL hfp = NO;
    for (AVAudioSessionPortDescription *p in rt.outputs) { if ([p.portType isEqualToString:AVAudioSessionPortBluetoothHFP]) { hfp = YES; break; } }
    if (!hfp) for (AVAudioSessionPortDescription *p in rt.inputs)  { if ([p.portType isEqualToString:AVAudioSessionPortBluetoothHFP]) { hfp = YES; break; } }
    return hfp;
}

#pragma mark - Call Gate

static BOOL sn_speech_channel_busy_now(void) {
    if ([SNCancellation isSpeaking]) return YES;
    if (SN_CallMonitorActive()) return YES;

    uint64_t last = gSiriGateLastUpdateMS.load(std::memory_order_relaxed);
    if (last) {
        uint64_t now = SN_NowMS();
        if (now > last && (now - last) < kSNSiriBusyWindowMs) return YES;
    }
    return NO;
}

static inline BOOL SN_ShouldSpeakNow(void) {
    BOOL ok = [[SNCallMonitor shared] shouldAllowSpeechNow];
    if (ok && DBG_CALLGATE_VERBOSE_ON) SNLOGFMT(@"[CALLGATE] shouldSpeakNow=1");
    return ok;
}

static BOOL sn_callgate_should_block(void)
{
    BOOL callActive = SN_CallMonitorActive();

    BOOL inCallUI = NO;
    @autoreleasepool {
        NSString *fgCur = SNAppStateTryForegroundBID() ?: @"";
        inCallUI = (fgCur.length && [fgCur isEqualToString:@"com.apple.InCallService"]);
    }

    BOOL hfpOn = NO;
    @try {
        AVAudioSessionRouteDescription *rt = [[AVAudioSession sharedInstance] currentRoute];
        hfpOn = sn_route_has_HFP(rt);
    } @catch (...) {}

    uint64_t nowMS = SN_NowMS();
    uint64_t cooldownMS = gCallCooldownUntilMS.load(std::memory_order_relaxed);
    BOOL inCooldown = (cooldownMS && nowMS < cooldownMS);

    return (callActive || inCallUI || hfpOn || inCooldown);
}

static inline void sn_post_finish_hold_ms(int ms, dispatch_block_t block)
{
    if (ms <= 0 || block == nil) {
        if (block) block();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        block();
    });
}

static inline NSString *SN_HHMM_Now(void) {
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.timeZone = [NSTimeZone localTimeZone];
        fmt.dateFormat = @"HH:mm";
    });
    return [fmt stringFromDate:[NSDate date]];
}

static inline NSString *sn_language_prefix(NSString *language)
{
    if (![language isKindOfClass:NSString.class] || language.length == 0) return nil;
    NSString *normalized = [[language stringByReplacingOccurrencesOfString:@"_" withString:@"-"] lowercaseString];
    NSString *prefix = [[normalized componentsSeparatedByString:@"-"] firstObject];
    return (prefix.length >= 2) ? prefix : nil;
}

static inline double sn_language_hypothesis_score(NSDictionary *hypotheses, NSString *language)
{
    return language.length ? [[hypotheses objectForKey:language] doubleValue] : 0.0;
}

static NSString *sn_normalized_voice_language(NSString *raw)
{
    if (![raw isKindOfClass:NSString.class]) return nil;
    NSString *trimmed = [[raw stringByReplacingOccurrencesOfString:@"_" withString:@"-"]
                         stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0 || [trimmed caseInsensitiveCompare:@"auto"] == NSOrderedSame) return nil;
    return [SNStringUtils clampAllowedBCP47:trimmed];
}

static NSString *sn_explicit_voice_language(void)
{
    NSUserDefaults *defaults = [[[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite] autorelease];
    return sn_normalized_voice_language([defaults objectForKey:@"voiceLang"]);
}

static void sn_language_text_metrics(NSString *sample, NSUInteger *letterCount, NSUInteger *wordCount)
{
    NSUInteger letters = 0;
    NSUInteger words = 0;
    if ([sample isKindOfClass:NSString.class] && sample.length > 0) {
        for (NSUInteger i = 0; i < sample.length; i++) {
            if ([[NSCharacterSet letterCharacterSet] characterIsMember:[sample characterAtIndex:i]]) letters++;
        }
        NSArray *parts = [sample componentsSeparatedByCharactersInSet:[[NSCharacterSet letterCharacterSet] invertedSet]];
        for (NSString *part in parts) if (part.length > 0) words++;
    }
    if (letterCount) *letterCount = letters;
    if (wordCount) *wordCount = words;
}

static NSString *sn_detect_language_nl(NSString *sample,
                                        NSString **detectedLanguage,
                                        NSString **reason,
                                        NSString **diagnostic)
{
    NSString *systemLanguage = [SNStringUtils systemPrimaryBCP47] ?: @"en-US";
    NSUInteger letterCount = 0;
    NSUInteger wordCount = 0;
    sn_language_text_metrics(sample, &letterCount, &wordCount);
    if (detectedLanguage) *detectedLanguage = nil;
    if (reason) *reason = @"empty-source";
    if (diagnostic) *diagnostic = nil;

    NSString *explicitLanguage = sn_explicit_voice_language();
    if (explicitLanguage.length > 0) {
        if (detectedLanguage) *detectedLanguage = [explicitLanguage copy];
        if (reason) *reason = @"explicit-user";
        if (diagnostic) *diagnostic = [[NSString stringWithFormat:@"chars=%lu words=%lu candidates=- system=%@ chosen=%@ reason=explicitVoiceLanguage",
                                       (unsigned long)letterCount, (unsigned long)wordCount,
                                       systemLanguage, explicitLanguage] copy];
        return explicitLanguage;
    }
    if (![sample isKindOfClass:NSString.class] || sample.length == 0) {
        if (diagnostic) *diagnostic = [[NSString stringWithFormat:@"chars=0 words=0 candidates=- system=%@ chosen=%@ reason=noCandidate",
                                       systemLanguage, systemLanguage] copy];
        return systemLanguage;
    }

    NLLanguageRecognizer *recognizer = [[NLLanguageRecognizer alloc] init];
    NSString *dominant = nil;
    NSDictionary *hypotheses = nil;
    @try {
        [recognizer processString:sample];
        dominant = [[recognizer dominantLanguage] copy];
        hypotheses = [[recognizer languageHypothesesWithMaximum:3] retain];
    } @catch (...) {
        [recognizer release];
        if (reason) *reason = @"recognizer-failure";
        if (diagnostic) *diagnostic = [[NSString stringWithFormat:@"chars=%lu words=%lu candidates=- system=%@ chosen=%@ reason=recognizerFailure",
                                       (unsigned long)letterCount, (unsigned long)wordCount,
                                       systemLanguage, systemLanguage] copy];
        return systemLanguage;
    }

    NSArray *languages = [[hypotheses allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        double leftScore = sn_language_hypothesis_score(hypotheses, left);
        double rightScore = sn_language_hypothesis_score(hypotheses, right);
        if (leftScore > rightScore) return NSOrderedAscending;
        if (leftScore < rightScore) return NSOrderedDescending;
        return [left compare:right];
    }];
    NSString *top = languages.count > 0 ? [languages objectAtIndex:0] : nil;
    NSString *topPrefix = sn_language_prefix(top);
    if (topPrefix.length == 0) topPrefix = sn_language_prefix(dominant);
    NSString *detected = dominant.length ? [SNStringUtils clampAllowedBCP47:dominant] :
                         (topPrefix.length ? [SNStringUtils mapPrefixToBCP47:topPrefix] : nil);
    double topScore = sn_language_hypothesis_score(hypotheses, top);
    NSString *second = languages.count > 1 ? [languages objectAtIndex:1] : nil;
    NSString *third = languages.count > 2 ? [languages objectAtIndex:2] : nil;
    double secondScore = sn_language_hypothesis_score(hypotheses, second);
    double thirdScore = sn_language_hypothesis_score(hypotheses, third);
    NSString *finalLanguage = systemLanguage;
    BOOL shortText = (letterCount < 20 || wordCount < 3);
    double minimumScore = shortText ? 0.90 : 0.75;
    double minimumMargin = shortText ? 0.20 : 0.15;

    if (topPrefix.length == 0) {
        if (reason) *reason = @"no-result";
    } else if (topScore >= minimumScore && (topScore - secondScore) >= minimumMargin) {
        finalLanguage = [SNStringUtils clampAllowedBCP47:topPrefix];
        if (reason) *reason = shortText ? @"short-confident" : @"confident";
    } else if (reason) {
        *reason = shortText ? @"short-fallback" : @"uncertain-fallback";
    }

    NSMutableArray *candidateParts = [NSMutableArray array];
    if (top.length) [candidateParts addObject:[NSString stringWithFormat:@"%@:%0.2f", sn_language_prefix(top) ?: top, topScore]];
    if (second.length) [candidateParts addObject:[NSString stringWithFormat:@"%@:%0.2f", sn_language_prefix(second) ?: second, secondScore]];
    if (third.length) [candidateParts addObject:[NSString stringWithFormat:@"%@:%0.2f", sn_language_prefix(third) ?: third, thirdScore]];
    if (diagnostic) *diagnostic = [[NSString stringWithFormat:@"chars=%lu words=%lu candidates=%@ system=%@ chosen=%@ reason=%@",
                                   (unsigned long)letterCount, (unsigned long)wordCount,
                                   candidateParts.count ? [candidateParts componentsJoinedByString:@","] : @"-",
                                   systemLanguage, finalLanguage, (reason && *reason) ? *reason : @"unknown"] copy];

    if (detectedLanguage && detected.length > 0) *detectedLanguage = [detected copy];
    [recognizer release];
    [dominant release];
    [hypotheses release];
    return finalLanguage;
}

static NSString *sn_voice_quality_label(NSInteger quality)
{
    if (quality == AVSpeechSynthesisVoiceQualityPremium) return @"premium";
    if (quality == AVSpeechSynthesisVoiceQualityEnhanced) return @"enhanced";
    return @"compact";
}


#pragma mark - Trust / Policy Gates

static inline NSString *SN_CurrentSSID(void) {
    NSString *s = nil;
    @try { s = SN_WiFiCurrentSSID(); } @catch (...) {}
    return (s.length ? s : nil);
}

static inline BOOL SN_ListContainsString(NSArray *list, NSString *needle) {
    if (!list || list.count == 0 || needle.length == 0) return NO;
    NSString *n = [needle stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (n.length == 0) return NO;
    for (NSString *s in list) {
        if (![s isKindOfClass:NSString.class]) continue;
        if ([s caseInsensitiveCompare:n] == NSOrderedSame) return YES;
    }
    return NO;
}

static NSString *SN_TrustLogString(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return @"-";
    NSString *clean = [[value componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet]
                       componentsJoinedByString:@" "];
    clean = [clean stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return clean.length ? clean : @"-";
}

static NSString *SN_TrustAlias(NSDictionary *aliases, NSString *key) {
    NSString *alias = [aliases[key] isKindOfClass:NSString.class] ? aliases[key] : @"";
    return SN_TrustLogString(alias);
}

static NSString *SN_WiredAliasKey(NSString *portType, NSString *canonicalUID) {
    return (portType.length && canonicalUID.length)
        ? [NSString stringWithFormat:@"wired:%@|%@", portType, canonicalUID] : @"";
}

static NSString *SN_WiredDefaultLogName(NSString *routeName, NSString *portType, NSString *canonicalUID) {
    NSString *name = SN_TrustLogString(routeName);
    if ([name isEqualToString:@"-"] || canonicalUID.length == 0) return name;
    NSString *suffix = nil;
    if ([portType isEqualToString:AVAudioSessionPortCarAudio]) {
        NSString *mac = [[canonicalUID componentsSeparatedByString:@"-Audio-AudioMain"] firstObject];
        NSArray *parts = [mac componentsSeparatedByString:@":"];
        if (parts.count >= 2) suffix = [NSString stringWithFormat:@"%@:%@", parts[parts.count - 2], parts.lastObject];
    }
    if (suffix.length == 0) {
        NSMutableString *compact = [NSMutableString string];
        NSCharacterSet *alphanumeric = NSCharacterSet.alphanumericCharacterSet;
        for (NSUInteger i = 0; i < canonicalUID.length; i++) {
            unichar c = [canonicalUID characterAtIndex:i];
            if ([alphanumeric characterIsMember:c]) [compact appendFormat:@"%C", c];
        }
        suffix = compact.length > 4 ? [compact substringFromIndex:compact.length - 4] : compact;
    }
    return suffix.length ? [NSString stringWithFormat:@"%@ · %@", name, suffix] : name;
}

static NSArray<AVAudioSessionPortDescription *> *SN_CurrentBluetoothOutputs(void) {
    @try {
        NSMutableArray *outputs = [NSMutableArray array];
        for (AVAudioSessionPortDescription *output in AVAudioSession.sharedInstance.currentRoute.outputs) {
            NSString *type = output.portType ?: @"";
            if ([type isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
                [type isEqualToString:AVAudioSessionPortBluetoothHFP] ||
                [type isEqualToString:AVAudioSessionPortBluetoothLE]) {
                [outputs addObject:output];
            }
        }
        return outputs;
    } @catch (...) {
        return @[];
    }
}

static NSDictionary *SN_EvaluateTrustedConnections(BOOL trustedCheckEnabled) {
    NSUserDefaults *defs = [[[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite] autorelease];
    NSArray *ssids = [[defs objectForKey:kSSIDsKey] isKindOfClass:NSArray.class] ? [defs objectForKey:kSSIDsKey] : @[];
    NSArray *bts = [[defs objectForKey:kBTKey] isKindOfClass:NSArray.class] ? [defs objectForKey:kBTKey] : @[];
    NSArray *wired = [[defs objectForKey:kWiredAudioDevicesV2Key] isKindOfClass:NSArray.class] ? [defs objectForKey:kWiredAudioDevicesV2Key] : @[];
    NSDictionary *aliases = [[defs objectForKey:kTrustedConnectionAliasesV1Key] isKindOfClass:NSDictionary.class] ? [defs objectForKey:kTrustedConnectionAliasesV1Key] : @{};
    BOOL broadWiredEnabled = [defs boolForKey:kAllowAnyWiredAudioDeviceKey];
    NSMutableArray *sources = [NSMutableArray array];

    NSString *ssid = SN_CurrentSSID();
    BOOL wifiMatched = ssid.length && SN_ListContainsString(ssids, ssid);
    NSString *wifiStatus = ssid.length ? (wifiMatched ? @"matched" : @"not trusted") : nil;
    NSString *wifiAlias = ssid.length ? SN_TrustAlias(aliases, [NSString stringWithFormat:@"wifi:%@", ssid]) : @"-";
    NSString *wifiField = !ssid.length ? @"-" : ([wifiAlias isEqualToString:@"-"]
        ? [NSString stringWithFormat:@"%@(%@)", SN_TrustLogString(ssid), wifiStatus]
        : [NSString stringWithFormat:@"%@<ssid=\"%@\">(%@)", wifiAlias, SN_TrustLogString(ssid), wifiStatus]);
    if (wifiMatched) [sources addObject:@"wifi"];

    NSMutableArray *bluetoothFields = [NSMutableArray array];
    BOOL bluetoothMatched = NO;
    for (AVAudioSessionPortDescription *output in SN_CurrentBluetoothOutputs()) {
        NSString *name = SN_TrustLogString(output.portName);
        BOOL matched = ![name isEqualToString:@"-"] && SN_ListContainsString(bts, name);
        NSString *alias = SN_TrustAlias(aliases, [NSString stringWithFormat:@"bluetooth:%@", name]);
        NSString *field = [alias isEqualToString:@"-"]
            ? [NSString stringWithFormat:@"%@(%@)", name, matched ? @"matched" : @"not trusted"]
            : [NSString stringWithFormat:@"%@<system=\"%@\">(%@)", alias, name, matched ? @"matched" : @"not trusted"];
        [bluetoothFields addObject:field];
        bluetoothMatched |= matched;
    }
    if (bluetoothMatched) [sources addObject:@"bluetooth"];
    NSString *bluetoothField = bluetoothFields.count ? (bluetoothFields.count == 1 ? bluetoothFields.firstObject : [NSString stringWithFormat:@"[%@]", [bluetoothFields componentsJoinedByString:@","]]) : @"-";

    NSMutableArray *wiredFields = [NSMutableArray array];
    BOOL wiredMatched = NO;
    BOOL hasSupportedWiredOutput = NO;
    @try {
        for (AVAudioSessionPortDescription *output in AVAudioSession.sharedInstance.currentRoute.outputs) {
            if (!SNIsTrustedWiredAudioPortType(output.portType)) continue;
            hasSupportedWiredOutput = YES;
            NSString *name = SN_TrustLogString(output.portName);
            NSString *typeLabel = SNTrustedWiredAudioPortTypeLabel(output.portType) ?: @"-";
            NSString *canonicalUID = SNCanonicalWiredAudioUID(output.portType, output.UID);
            NSDictionary *matchedEntry = nil;
            NSDictionary *relevantEntry = nil;
            for (NSDictionary *entry in wired) {
                if (![entry isKindOfClass:NSDictionary.class]) continue;
                NSString *entryType = entry[@"portType"];
                NSString *entryUID = entry[@"uid"];
                if (![entryType isKindOfClass:NSString.class] || ![entryUID isKindOfClass:NSString.class] ||
                    ![SNTrustedWiredAudioPortTypeLabel(entryType) isEqualToString:typeLabel]) continue;
                NSString *entryCanonicalUID = SNCanonicalWiredAudioUID(entryType, entryUID);
                if ([entryCanonicalUID isEqualToString:canonicalUID]) { matchedEntry = entry; break; }
                if (!relevantEntry && [SN_TrustLogString(entry[@"name"]) caseInsensitiveCompare:name] == NSOrderedSame) relevantEntry = entry;
            }
            NSDictionary *displayEntry = matchedEntry ?: relevantEntry;
            NSString *alias = displayEntry ? SN_TrustAlias(aliases, SN_WiredAliasKey(displayEntry[@"portType"], SNCanonicalWiredAudioUID(displayEntry[@"portType"], displayEntry[@"uid"]))) : @"-";
            NSString *displayName = ![alias isEqualToString:@"-"] ? alias : SN_WiredDefaultLogName(name, output.portType, canonicalUID);
            NSString *status = matchedEntry ? @"matched" : (relevantEntry ? @"unmatched" : @"not trusted");
            [wiredFields addObject:[NSString stringWithFormat:@"%@<%@/%@>(%@)", displayName, name, typeLabel, status]];
            if (matchedEntry) wiredMatched = YES;
        }
    } @catch (...) {}
    if (wiredMatched) [sources addObject:@"wired"];
    BOOL broadWiredMatched = !wiredMatched && broadWiredEnabled && hasSupportedWiredOutput;
    if (broadWiredMatched) [sources addObject:@"broadWired"];
    NSString *wiredField = wiredFields.count ? [wiredFields componentsJoinedByString:@","] : @"-";

    BOOL allowed = !trustedCheckEnabled || sources.count > 0;
    NSString *trustedBy = !trustedCheckEnabled ? @"trustedCheckDisabled" : (sources.count ? [sources componentsJoinedByString:@","] : @"none");
    return @{
        @"wifi": wifiField,
        @"bluetooth": bluetoothField,
        @"wired": wiredField,
        @"broadWired": broadWiredEnabled ? @"enabled" : @"disabled",
        @"trustedBy": trustedBy,
        @"result": allowed ? @"allow" : @"deny",
        @"allowed": @(allowed)
    };
}

static inline BOOL sn_isPhoneMediaNowPlaying(void) {
    NSString *bid=nil,*name=nil,*route=nil; BOOL playing=NO;
    SNAudioNowPlayingProbe(&bid,&name,&playing,&route);
    return playing;
}

static inline BOOL sn_isRingerMuteActive(void) {
    BOOL known = NO;
    BOOL muted = [SNMediaControl ringerMutedKnown:&known];
    return (known && muted);
}

static inline BOOL SN_BlockOnMutePref(void);

#pragma mark - Preferences, Debug, and Caches

static NSSet<NSString *> *gSN_StripEmojiSet = nil;

static inline void sn_add_normalized_keys_for(NSMutableSet *dst, NSString *key) {
    if (!(key && key.length)) return;
    [dst addObject:key];

    NSString *noNotif = [SNStringUtils stripNotificationsSuffix:key];
    if (noNotif.length) [dst addObject:noNotif];

    NSString *noIdx = [SNStringUtils stripTrailingIndex:key];
    if (noIdx.length) [dst addObject:noIdx];

    NSString *noNotifNoIdx = [SNStringUtils stripTrailingIndex:noNotif];
    if (noNotifNoIdx.length) [dst addObject:noNotifNoIdx];
}

static void SN_LoadEmojiStripCache(void)
{
    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite] autorelease];
    id raw = [d objectForKey:kSNPerAppEmojiStripKey];
    NSDictionary *per = [raw isKindOfClass:NSDictionary.class] ? (NSDictionary *)raw : @{};

    NSMutableSet *acc = [NSMutableSet set];
    [per enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        if (![k isKindOfClass:NSString.class]) return;
        if ([v isKindOfClass:NSNumber.class] && [((NSNumber *)v) boolValue]) {
            sn_add_normalized_keys_for(acc, (NSString *)k);
        }
    }];

    NSSet *old = gSN_StripEmojiSet;
    gSN_StripEmojiSet = [acc copy];
    [old release];
}

static inline NSString *sn_normalized_app_counter_key(NSString *bundleID)
{
    if (![bundleID isKindOfClass:NSString.class] || bundleID.length == 0) return nil;
    NSString *key = [bundleID stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    key = [SNStringUtils stripNotificationsSuffix:key];
    key = [SNStringUtils stripTrailingIndex:key];
    return key.length ? key : nil;
}

static BOOL sn_disable_sound_for_app(NSString *sectionID,
                                     NSString *publisherID,
                                     NSString **globalRawOut,
                                     NSString **perAppRawOut,
                                     NSString **sourceOut)
{
    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite] autorelease];
    id globalObject = [d objectForKey:@"disableNotificationSound"];
    BOOL globalEnabled = [globalObject isKindOfClass:NSNumber.class] ? [globalObject boolValue] : NO;

    NSDictionary *perApp = [d dictionaryForKey:kSNPerAppDisableSoundKey];
    NSNumber *perAppValue = nil;
    NSString *sectionKey = sn_normalized_app_counter_key(sectionID);
    NSString *publisherKey = sn_normalized_app_counter_key(publisherID);
    if ([perApp isKindOfClass:NSDictionary.class]) {
        id sectionValue = sectionKey.length ? [perApp objectForKey:sectionKey] : nil;
        id publisherValue = publisherKey.length ? [perApp objectForKey:publisherKey] : nil;
        if ([sectionValue isKindOfClass:NSNumber.class]) {
            perAppValue = sectionValue;
        } else if ([publisherValue isKindOfClass:NSNumber.class]) {
            perAppValue = publisherValue;
        }
    }

    BOOL effective = perAppValue ? perAppValue.boolValue : globalEnabled;
    if (globalRawOut) {
        *globalRawOut = [globalObject isKindOfClass:NSNumber.class]
            ? ([globalObject boolValue] ? @"1" : @"0")
            : @"missing";
    }
    if (perAppRawOut) {
        *perAppRawOut = perAppValue ? (perAppValue.boolValue ? @"1" : @"0") : @"inherit";
    }
    if (sourceOut) {
        *sourceOut = perAppValue ? @"perApp" : @"global";
    }
    return effective;
}

static void sn_migrate_legacy_per_app_sound_suppress_overrides(void)
{
    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite] autorelease];
    if ([d boolForKey:kSNSoundSuppressMigrationKey]) return;

    id existing = [d objectForKey:kSNPerAppDisableSoundKey];
    NSUInteger count = [existing isKindOfClass:NSDictionary.class] ? [(NSDictionary *)existing count] : 0;

    [d removeObjectForKey:kSNPerAppDisableSoundKey];
    [d setBool:YES forKey:kSNSoundSuppressMigrationKey];
    [d synchronize];

    if (DBG_SOUND_ON) {
        SNLOGFMT(@"[SOUND] migration cleared old per-app suppress overrides count=%lu",
                 (unsigned long)count);
    }
}


static NSString *sn_try_suppress_notification_sound(id bulletin,
                                                     NSString *sectionID,
                                                     NSString *publisherID,
                                                     NSString *bulletinID)
{
    NSString *globalRaw = nil;
    NSString *perAppRaw = nil;
    NSString *source = nil;
    BOOL enabled = sn_disable_sound_for_app(sectionID, publisherID, &globalRaw, &perAppRaw, &source);
    NSString *app = sn_normalized_app_counter_key(sectionID) ?: (sectionID.length ? sectionID : @"-");
    NSString *bulletinKey = bulletinID.length ? bulletinID : @"-";

    if (!enabled) return @"enabled";

    if (DBG_SOUND_VERBOSE_ON) {
        SNLOGFMT(@"[SOUND] prefs global raw=%@ effective=%d", globalRaw ?: @"missing", (int)([globalRaw isEqualToString:@"1"]));
        SNLOGFMT(@"[SOUND] prefs perApp app=%@ raw=%@ source=%@ effective=%d",
                 app, perAppRaw ?: @"inherit", source ?: @"-", (int)enabled);
    }

    if (!bulletin) {
        return @"suppressionSkipped";
    }

    if (DBG_SOUND_VERBOSE_ON) {
        SNLOGFMT(@"[SOUND] suppress attempt | app=%@ bulletin=%@ enabled=1", app, bulletinKey);
    }

    BOOL succeeded = NO;
    NSString *missReason = @"apiUnavailable";
    @try {
        if ([bulletin respondsToSelector:@selector(setSound:)]) {
            [bulletin performSelector:@selector(setSound:) withObject:nil];
            succeeded = YES;
        } else {
            [bulletin setValue:nil forKey:@"sound"];
            succeeded = YES;
        }
    } @catch (__unused NSException *exception) {
        succeeded = NO;
        missReason = @"exception";
    }

    if (DBG_SOUND_ON) {
        SNLOGFMT(@"[SOUND] suppress | app=%@ source=%@ result=%@ bulletin=%@",
                 app, source ?: @"-", succeeded ? @"ok" : @"fail", bulletinKey);
    }
    if (!succeeded && DBG_SOUND_VERBOSE_ON) {
        SNLOGFMT(@"[SOUND] suppress detail | app=%@ bulletin=%@ reason=%@", app, bulletinKey, missReason);
    }
    return succeeded ? @"suppressed" : @"suppressionFailed";
}

static inline void sn_increment_spoken_count_for_app(NSString *bundleID)
{
    NSString *key = sn_normalized_app_counter_key(bundleID);
    if (key.length == 0) return;

    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite] autorelease];
    NSMutableDictionary *counts = [[d dictionaryForKey:kSNPerAppSpokenCountsKey] mutableCopy];
    if (!counts) counts = [[NSMutableDictionary alloc] init];

    NSNumber *old = [counts objectForKey:key];
    unsigned long long next = ([old respondsToSelector:@selector(unsignedLongLongValue)] ? [old unsignedLongLongValue] : 0ULL) + 1ULL;
    [counts setObject:@(next) forKey:key];
    [d setObject:counts forKey:kSNPerAppSpokenCountsKey];
    [d setObject:key forKey:kSNLastSpokenAppIDKey];
    [d synchronize];
    [counts release];
}

static inline BOOL sn_should_strip_emoji_for(NSString *sectionID, NSString *publisherID)
{
    NSSet *set = gSN_StripEmojiSet;
    if (!set || set.count == 0) return NO;

    NSString *c1 = sectionID ?: @"";
    if (c1.length) {
        if ([set containsObject:c1]) return YES;
        if ([set containsObject:[SNStringUtils stripNotificationsSuffix:c1]]) return YES;
        if ([set containsObject:[SNStringUtils stripTrailingIndex:c1]]) return YES;
        if ([set containsObject:[SNStringUtils stripTrailingIndex:[SNStringUtils stripNotificationsSuffix:c1]]]) return YES;
    }

    NSString *c2 = publisherID ?: @"";
    if (c2.length) {
        if ([set containsObject:c2]) return YES;
        if ([set containsObject:[SNStringUtils stripNotificationsSuffix:c2]]) return YES;
        if ([set containsObject:[SNStringUtils stripTrailingIndex:c2]]) return YES;
        if ([set containsObject:[SNStringUtils stripTrailingIndex:[SNStringUtils stripNotificationsSuffix:c2]]]) return YES;
    }
    return NO;
}

static inline NSDictionary *SN_PerAppFormatsRetained(void) {
    os_unfair_lock_lock(&gSNFormatLock);
    NSDictionary *d = gSN_PerAppFormats ?: @{};
    d = [d retain];
    os_unfair_lock_unlock(&gSNFormatLock);
    return [d autorelease];
}

static inline NSString *SN_GlobalFormatRetained(void) {
    os_unfair_lock_lock(&gSNFormatLock);
    NSString *s = gSN_GlobalFormat ?: gSN_FallbackFormat;
    s = [s retain];
    os_unfair_lock_unlock(&gSNFormatLock);
    return [s autorelease];
}

static inline NSString *sn_trim(NSString *s) {
    if (![s isKindOfClass:NSString.class]) return nil;
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return (t.length ? t : nil);
}

static void SN_LoadFormatsCache(void)
{
    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite] autorelease];

    NSDictionary *per = [d dictionaryForKey:kSNPerAppDictKey];
    NSDictionary *newPer = nil;

    if ([per isKindOfClass:NSDictionary.class] && per.count) {
        NSMutableDictionary *flt = [NSMutableDictionary dictionaryWithCapacity:per.count];

        [per enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            NSString *key = [k isKindOfClass:NSString.class] ? (NSString *)k : nil;
            NSString *val = [SNStringUtils trimOrNil:v];
            if (!(key && val)) return;

            if (!flt[key]) flt[key] = val;

            NSString *kNoIdx = [SNStringUtils stripTrailingIndex:key];
            if (kNoIdx.length && ![kNoIdx isEqualToString:key] && !flt[kNoIdx]) flt[kNoIdx] = val;

            if ([key hasSuffix:@".notifications"]) {
                NSString *kNoNotif = [SNStringUtils stripNotificationsSuffix:key];
                if (!flt[kNoNotif]) flt[kNoNotif] = val;
            }
        }];

        newPer = [flt copy];
    } else {
        newPer = [@{} copy];
    }

    NSString *newGlob = sn_trim([d stringForKey:kSNGlobalFormatKey]);
    if (!newGlob) newGlob = sn_trim([d stringForKey:@"messageFormat"]);
    NSString *newGlobOwned = newGlob ? [newGlob copy] : nil;

    os_unfair_lock_lock(&gSNFormatLock);
    NSDictionary *oldPer = gSN_PerAppFormats;
    gSN_PerAppFormats = newPer;

    NSString *oldGlob = gSN_GlobalFormat;
    gSN_GlobalFormat = newGlobOwned;
    os_unfair_lock_unlock(&gSNFormatLock);

    if (oldPer) [oldPer release];
    if (oldGlob) [oldGlob release];

    if (DBG_APP_ON) {
        /*SNLOGFMT(@"[APP] dbg per.keys=%@", [gSN_PerAppFormats allKeys]);*/
    }
}

static inline NSString *SN_ResolveFormat(NSString *sectionID, NSString *publisherID, NSString **outSourceTag)
{
    NSString *c1 = [SNStringUtils safeStr:sectionID];
    NSString *c2 = [SNStringUtils safeStr:publisherID];
    NSString *c1a = [SNStringUtils stripNotificationsSuffix:c1];
    NSString *c3name = SN_AppDisplayNameForSection(c1, nil) ?: @"";

    NSDictionary *formats = SN_PerAppFormatsRetained();
    NSString *global = SN_GlobalFormatRetained();

    NSString *result = nil;
    if (formats && [formats isKindOfClass:NSDictionary.class] && formats.count) {
        NSString *candidates[SN_FMT_CANDIDATE_COUNT + 1] = { c1a, c1, c2, c3name, nil };
        for (int i = 0; i < SN_FMT_CANDIDATE_COUNT; i++) {
            NSString *key = candidates[i];
            if (!(key && key.length)) continue;
            id val = [formats objectForKey:key];
            if ([val isKindOfClass:NSString.class] && [(NSString *)val length]) {
                if (outSourceTag) *outSourceTag = @"perApp";
                result = (NSString *)val;
                break;
            }
        }
    }

    if (!result || !result.length) {
        if (global.length) {
            if (outSourceTag) *outSourceTag = @"global";
            result = global;
        } else {
            if (outSourceTag) *outSourceTag = @"fallback";
            result = gSN_FallbackFormat;
        }
    }

    return result;
}

static inline void SN_EnsurePerAppDictExists(void)
{
    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite] autorelease];
    id cur = [d objectForKey:kSNPerAppDictKey];
    if (![cur isKindOfClass:NSDictionary.class]) {
        [d setObject:@{} forKey:kSNPerAppDictKey];
        [d synchronize];
    }
}

static inline void sn_invalidate_filter_cache(void) { gFilterCacheValid = NO; }

static inline void sn_rebuild_filter_cache_if_needed(void) {
    if (gFilterCacheValid) return;

    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite] autorelease];
    NSArray *blockArr = [d arrayForKey:@"blockAppIDs"];
    if (![blockArr isKindOfClass:NSArray.class]) blockArr = @[];

    NSSet *newSet = [[NSSet alloc] initWithArray:blockArr];

    NSSet *old = gBlockWhenOpenSet;
    gBlockWhenOpenSet = newSet;

    [old release];

    gFilterCacheValid = YES;
    /*if (DBG_APP_ON) SNLOGFMT(@"[APP] blockWhenOpenSet=%@", gBlockWhenOpenSet);*/
}

static inline void sn_lazy_filter_cache(void)
{
    if (!gFilterDirty && gAppFilterMode && gAllowSet && gBlockSet) return;

    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite] autorelease];

    NSString *mode = [d objectForKey:@"appFilterMode"];
    if (![mode isKindOfClass:NSString.class] || mode.length == 0) mode = @"whitelist";

    NSArray *allowArr = [d objectForKey:@"allowedAppIDs"];
    if (![allowArr isKindOfClass:NSArray.class]) allowArr = @[];

    NSArray *blockArr = [d objectForKey:@"blockAppIDs"];
    if (![blockArr isKindOfClass:NSArray.class]) blockArr = @[];
    BOOL seeded = [d objectForKey:@"allowedSeededOnce"] ? [d boolForKey:@"allowedSeededOnce"] : NO;

    NSSet *allow = [NSSet setWithArray:allowArr];
    NSSet *block = [NSSet setWithArray:blockArr];

    NSString *newMode = [mode copy];
    NSSet *newAllow = [allow copy];
    NSSet *newBlock = [block copy];

    NSString *oldMode = gAppFilterMode;
    NSSet *oldAllow = gAllowSet;
    NSSet *oldBlock = gBlockSet;

    gAppFilterMode = newMode;
    gAllowSet = newAllow;
    gBlockSet = newBlock;
    gAllowSeededOnce = seeded;

    [oldMode release];
    [oldAllow release];
    [oldBlock release];

    gFilterDirty = NO;
}

static inline BOOL sn_isAppAllowed(NSString *bundleID)
{
    if (bundleID.length == 0) return NO;

    sn_lazy_filter_cache();

    NSString *mode = gAppFilterMode ?: @"whitelist";
    NSSet *allow = gAllowSet;
    NSSet *block = gBlockSet;

    if ([mode isEqualToString:@"whitelist"] && (allow == nil || allow.count == 0)) {
        return !gAllowSeededOnce;
    }

    if ([mode isEqualToString:@"whitelist"]) {
        return [allow containsObject:bundleID];
    } else {
        return ![block containsObject:bundleID];
    }
}

static inline void sn_seed_allowed_if_needed(void)
{
    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite] autorelease];

    BOOL seeded = [d objectForKey:@"allowedSeededOnce"] ? [d boolForKey:@"allowedSeededOnce"] : NO;
    if (seeded) return;

    id existing = [d objectForKey:@"allowedAppIDs"];
    [d setObject:([existing isKindOfClass:NSArray.class] ? existing : @[]) forKey:@"allowedAppIDs"];
    [d setBool:YES forKey:@"allowedSeededOnce"];
    [d synchronize];
}

static inline BOOL SN_PrefBoolFast(NSString *key, BOOL def) {
    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite] autorelease];
    id v = [d objectForKey:key];
    return [v isKindOfClass:NSNumber.class] ? [v boolValue] : def;
}

static inline void SN_LoadCachedPrefs(void) {
    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite] autorelease];
    gPrefPauseToggle          = [d objectForKey:kSNPauseKey] ? [d boolForKey:kSNPauseKey] : NO;
    gPrefEnabledCached        = [d objectForKey:@"enabled"] ? [d boolForKey:@"enabled"] : YES;
    gPrefSpeakUnlockedCached  = [d objectForKey:@"speakWhenUnlocked"] ? [d boolForKey:@"speakWhenUnlocked"] : NO;
    gPrefMuteSpamCached       = [d objectForKey:@"muteSpam"] ? [d boolForKey:@"muteSpam"] : NO;
    gPrefSpamWindowCached     = [d objectForKey:@"spamCooldownSeconds"] ? [d doubleForKey:@"spamCooldownSeconds"] : kSNDefaultSpamWindowSec;
    gPrefResetVolumeAfterSpeak = [d objectForKey:kSNResetVolumeAfterSpeakKey] ? [d boolForKey:kSNResetVolumeAfterSpeakKey] : NO;
    if (gPrefSpamWindowCached < 0.0) gPrefSpamWindowCached = kSNDefaultSpamWindowSec;
}


static std::atomic_bool sFullAuditHeaderWritten{false};

static inline void SN_ReloadDebugFlag(void) {
    // Master debug enables all non-private audit categories in the local test build.
    gDebugLogs = SN_PrefBoolFast(kSNDebugKey, NO);
    if (gDebugLogs) {
        bool expected = false;
        if (sFullAuditHeaderWritten.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
            SNLOGFMT(@"[DEBUG] mode=full-audit privateText=0 categories=notif,tts,policy,volume,queue,audio,engine,sound,lang,voice,callgate,release");
        }
    } else {
        sFullAuditHeaderWritten.store(false, std::memory_order_release);
    }
}

static void SN_ApplyCancelModeFromPrefs(void);

static void SN_PrefsChanged(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
    SN_ReloadDebugFlag();
    sn_migrate_legacy_per_app_sound_suppress_overrides();
    SN_LoadCachedPrefs();
    SN_ApplyCancelModeFromPrefs();
    sn_invalidate_filter_cache();
    sn_seed_allowed_if_needed();
    SN_LoadFormatsCache();
    SN_LoadEmojiStripCache();

    gFilterDirty = YES;
    SNReleaseAlertsPreferencesChanged();
}

#pragma mark - Idle / Cleanup Helpers

static void sn_schedule_idle_session_cleanup_ms(uint32_t delayMs);
static BOOL sn_can_notify_others_now(void);
static bool sn_resume_blocked_now(uint64_t *optDelayMsOut);
static void sn_notify_others_after_gate(void);

static inline BOOL sn_queue_transition_pending_now(void)
{
    BOOL queued = (sn_queue_count() > 0 && SN_PrefBoolFast(@"queueNotifications", NO));
    return (queued ||
            gQueueDrainInFlight.load(std::memory_order_acquire) ||
            gStartInFlightTxn.load(std::memory_order_acquire) != 0);
}

static inline BOOL sn_audio_chain_busy_now(void)
{
    return (sn_queue_transition_pending_now() ||
            [SNCancellation isSpeaking] ||
            gCurrentTxn.load(std::memory_order_acquire) != 0 ||
            gDuckChainAlive);
}

static inline int sn_compute_post_hold_ms(BOOL isCar, BOOL unlocked, int extraFromCaller) {
    int ms = (sn_queue_count() == 0 ? (int)kSNPostFinishHoldEmptyMs : (int)kSNPostFinishHoldQueuedMs);
    if (isCar && unlocked) ms += (int)kSNCarPlayExtraHoldMs;
    ms += extraFromCaller;
    return ms < 0 ? 0 : ms;
}

static inline BOOL SN_IsCarPlayUnlocked(void) {
    @try {
        NSString *port = [SNMediaControl lastOutputPortType] ?: @"";
        BOOL unlocked  = ![SNDeviceState isDeviceLocked];
        BOOL isCar     = ([port isEqualToString:AVAudioSessionPortCarAudio] ||
                          [port rangeOfString:@"Car" options:NSCaseInsensitiveSearch].location != NSNotFound);
        return (isCar && unlocked);
    } @catch (...) {}
    return NO;
}

static inline uint32_t sn_idle_ms_for_current_route(void) {
    if (!gPreWasPlaying && !sn_isPhoneMediaNowPlaying()) return 0;

    NSString *port = [SNMediaControl lastOutputPortType] ?: @"";
    if ([port rangeOfString:@"Car" options:NSCaseInsensitiveSearch].location != NSNotFound) return kSNIdleMsCarPlay;
    return kSNIdleMsDefault;
}

static inline NSUInteger sn_safe_len_for_guard(NSString *s) {
    if (![s isKindOfClass:NSString.class]) return kSNSafeMinChars;
    NSUInteger n = [SNStringUtils stripEmoji:s].length;
    return (n < kSNSafeMinChars) ? kSNSafeMinChars : n;
}

static void sn_cancel_idle_cleanup_timer(void) {
    if (sIdleCleanupTimer) {
        dispatch_source_t timer = sIdleCleanupTimer;
        sIdleCleanupTimer = nil;
        dispatch_source_cancel(timer);
#if !__has_feature(objc_arc)
        dispatch_release(timer);
#endif
    }
    gIdleCleanupArmed.store(false, std::memory_order_release);
}

static inline void sn_idle_maybe_release_to_ringer_with_reason(const char *reason)
{
    if (sn_audio_chain_busy_now()) return;
    if (gPausedBySN) return;

    if (sn_isPhoneMediaNowPlaying()) return;

    @try {
        NSString *route = @"-";
        @try {
            route = [AVAudioSession sharedInstance].currentRoute.outputs.firstObject.portType ?: @"-";
        } @catch (...) {}

        if (DBG_AUDIO_VERBOSE_ON && !gLastPreflightBlocked.load(std::memory_order_acquire)) {
            SNLOGFMT(@"[AUDIO] idle release gate (engine tail owns AVSession) | route=%@ reason=%s | Tweak.xm:%d",
                     route,
                     (reason ? reason : "null"),
                     __LINE__);
        }
    } @catch (...) {}
}

static inline void sn_preflight_finalize_block(BOOL allowTTS, const char *reason, id bulletin)
{
    uint64_t nowMS = SN_NowMS();
    gIdleCooldownUntilMS.store(nowMS + (SN_IsCarPlayRoute() ? kSNIdleMsCarPlay : kSNIdleMsDefault), std::memory_order_release);
    gDidReleaseToRinger.store(false, std::memory_order_release);

    bool blockedNow = !allowTTS;
    gLastPreflightBlocked.store(blockedNow, std::memory_order_release);

    if (![SNCancellation isSpeaking]) {
        @try { finishWork(); } @catch (...) {}
    }

    if (sn_queue_count() == 0 && ![SNCancellation isSpeaking] && !sn_isPhoneMediaNowPlaying()) {

        @try {
            if (allowTTS && DBG_AUDIO_VERBOSE_ON) {
                NSString *route = @"-";
                @try {
                    route = [AVAudioSession sharedInstance].currentRoute.outputs.firstObject.portType ?: @"-";
                } @catch (...) {}

                SNLOGFMT(@"[AUDIO] preflight finalize idle (no AV deactivate) | route=%@ reason=%s | Tweak.xm:%d",
                         route,
                         (reason ? reason : "null"),
                         __LINE__);
            }
        } @catch (...) {}

        gDuckChainAlive = NO;
        gDidReleaseToRinger.store(false, std::memory_order_release);
        return;
    }

    sn_schedule_idle_session_cleanup_ms(sn_idle_ms_for_current_route());
}

static inline uint32_t sn_clamp_siri_guard_ms(uint32_t waitedMs, uint32_t capMs)
{
    return (waitedMs > capMs ? capMs : waitedMs);
}

static void sn_schedule_notify_others_nudge(double delaySec)
{
    if (!sn_can_notify_others_now()) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!sn_can_notify_others_now()) return;
        sn_notify_others_after_gate();
    });
}

static inline void sn_idle_cleanup_fire_now_gen(uint64_t gen, const char *tag)
{
    if (gen != gIdleArmedGen) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gen != gIdleArmedGen || !gIdleCleanupArmed.load(std::memory_order_acquire)) return;
        if (sn_audio_chain_busy_now()) {
            gIdleCleanupArmed.store(false, std::memory_order_release);
            if (DBG_AUDIO_VERBOSE_ON) {
                SNLOGFMT(@"[IDLE] blocked | reason=active-queue-chain pending=%lu draining=%d startTxn=%llu",
                         (unsigned long)sn_queue_count(),
                         (gQueueDrainInFlight.load(std::memory_order_acquire) ? 1 : 0),
                         (unsigned long long)gStartInFlightTxn.load(std::memory_order_acquire));
            }
            return;
        }

        uint64_t firedAt = SN_NowMS();
        gIdleCleanupArmed.store(false, std::memory_order_release);
        gIdleCooldownUntilMS.store(firedAt + kSNIdleCooldownAfterFireMs, std::memory_order_release);
        gCooldownSkipLogged.store(false, std::memory_order_release);
        if (DBG_AUDIO_VERBOSE_ON) SNLOGFMT(@"[IDLE] fire%s%s | idleFor=%llums otherAudio=%d",
                                 (tag && *tag ? " " : ""), (tag && *tag ? tag : ""),
                                 (unsigned long long)(firedAt - gIdleLastArmAtMS),
                                 (int)sn_isPhoneMediaNowPlaying());
        gDeferReleaseForLast.store(false, std::memory_order_release);
        sn_idle_maybe_release_to_ringer_with_reason("IdleTimer");
        finishWork();
    });
}

static void sn_schedule_idle_session_cleanup_ms(uint32_t delayMs) {
    if (sn_audio_chain_busy_now()) {
        sn_cancel_idle_cleanup_timer();
        return;
    }

    uint64_t now = SN_NowMS();
    uint64_t until = gIdleCooldownUntilMS.load(std::memory_order_acquire);
    if (now && until && now < until) {
        sn_idle_maybe_release_to_ringer_with_reason("CooldownSkip");
        if (DBG_AUDIO_VERBOSE_ON && gSpeakAllowedCtx.load(std::memory_order_acquire) && !gCooldownSkipLogged.load(std::memory_order_acquire)) {
            SNLOGFMT(@"[IDLE] skip (cooldown)");
            gCooldownSkipLogged.store(true, std::memory_order_release);
        }
        return;
    }
    if (gIdleCleanupArmed.load(std::memory_order_acquire)) {
        uint64_t sinceArm = (now && gIdleLastArmAtMS ? now - gIdleLastArmAtMS : UINT64_C(0));
        if (sinceArm && sinceArm < kSNIdleCoalesceMs) {
            SNLOG_IF_SPEAKCTX(DBG_AUDIO_VERBOSE_ON, @"[IDLE] coalesce (already armed)");
            return;
        }
    }
    if (!sIdleQueue) {
        sIdleQueue = dispatch_queue_create("sn.idle.cleanup", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(sIdleQueue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    }

    if (sIdleCleanupTimer) {
        dispatch_source_t timer = sIdleCleanupTimer;
        sIdleCleanupTimer = nil;
        dispatch_source_cancel(timer);
#if !__has_feature(objc_arc)
        dispatch_release(timer);
#endif
    }

    gIdleGen++;
    gIdleArmedGen = gIdleGen;
    gIdleCleanupArmed.store(true, std::memory_order_release);
    gIdleLastArmAtMS = now;
    /*SNLOG_IF_SPEAKCTX(DBG_AUDIO_VERBOSE_ON, @"[IDLE] schedule %ums", (unsigned)delayMs);*/

    if (gPausedBySN) {
        double nudgeDelay = kSNNotifyOthersNudgeSec;
        if (SN_IsCarPlayUnlocked()) nudgeDelay += kSNCarPlayNudgeExtraSec;
        sn_schedule_notify_others_nudge(nudgeDelay);
    }

    sIdleCleanupTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sIdleQueue);
    uint64_t d = (uint64_t)delayMs * NSEC_PER_MSEC;
    uint64_t myGen = gIdleArmedGen;
    dispatch_source_set_timer(sIdleCleanupTimer, dispatch_time(DISPATCH_TIME_NOW, d), DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(sIdleCleanupTimer, ^{
        sn_idle_cleanup_fire_now_gen(myGen, NULL);
    });
    dispatch_resume(sIdleCleanupTimer);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, d + (kSNTimerFallbackSlackMs * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (gIdleCleanupArmed.load(std::memory_order_acquire) && myGen == gIdleArmedGen) {
            sn_idle_cleanup_fire_now_gen(myGen, "fallback");
        }
    });
}

static inline NSString *SN_Log_HHMMSSFromInterval(NSTimeInterval s) {
    if (s < 0) s = 0;
    long total = (long)llround(s);
    long hh = total / 3600, mm = (total % 3600) / 60, ss = total % 60;
    return [NSString stringWithFormat:@"%02ld:%02ld:%02ld", hh, mm, ss];
}

static inline void sn_log_speak(NSString *title, NSString *msg, NSString *lang)
{
    if (!DBG_SPEAK_ON) return;
    if (DBG_PRIVATE_TEXT_ON) {
        SNLOGFMT(@"[SPEAK] lang=%@ | %@", (lang ?: @"-"), (msg ?: @"-"));
    } else {
        NSUInteger chars = ((title ?: @"").length + (msg ?: @"").length);
        SNLOGFMT(@"[SPEAK] lang=%@ chars=%lu privateText=0", (lang ?: @"-"), (unsigned long)chars);
    }
}


#pragma mark - Volume Utilities & Observer

static void sn_set_system_volume(float v) {
    v = sn_clampf(v, 0.f, 1.f);
    @try {
        if (selSetSystemOutputVolume && [SNMediaControl respondsToSelector:selSetSystemOutputVolume]) {
            ((void(*)(id,SEL,float))objc_msgSend)(SNMediaControl.class, selSetSystemOutputVolume, v);
            return;
        }
    } @catch (...) {}
    @try {
        Class AVC = NSClassFromString(@"AVSystemController");
        SEL sharedSel = NSSelectorFromString(@"sharedAVSystemController");
        id ctrl = (AVC && [AVC respondsToSelector:sharedSel]) ? ((id(*)(id,SEL))objc_msgSend)(AVC, sharedSel) : nil;
        SEL volSel = NSSelectorFromString(@"setVolumeTo:forCategory:");
        if (ctrl && [ctrl respondsToSelector:volSel]) {
            ((BOOL(*)(id,SEL,float,id))objc_msgSend)(ctrl, volSel, v, @"Audio/Video");
        }
    } @catch (...) {}
}

typedef struct {
    uint64_t activeTxn;
    uint64_t originTxn;
    float previousVolume;
    float targetVolume;
    BOOL armed;
    BOOL awaitingInternalSet;
    BOOL awaitingQueueHandoff;
    BOOL userChanged;
} SNVolumeRestoreState;

static os_unfair_lock gVolumeRestoreLock = OS_UNFAIR_LOCK_INIT;
static SNVolumeRestoreState gVolumeRestoreState = {};

typedef NS_ENUM(int, SNVolumeDirection) {
    SNVolumeDirectionNone = 0,
    SNVolumeDirectionUp,
    SNVolumeDirectionDown
};

static inline NSString *sn_volume_direction_name(int direction)
{
    switch ((SNVolumeDirection)direction) {
        case SNVolumeDirectionUp:   return @"up";
        case SNVolumeDirectionDown: return @"down";
        default:                    return @"none";
    }
}

static inline SNVolumeDirection sn_volume_direction(float from, float to)
{
    if (to > from + kSNVolDeltaEps) return SNVolumeDirectionUp;
    if (to < from - kSNVolDeltaEps) return SNVolumeDirectionDown;
    return SNVolumeDirectionNone;
}

static void sn_clear_internal_volume_state(uint64_t expectedTxn, const char *reason)
{
    uint64_t txn = gInternalVolumeSetTxn.load(std::memory_order_acquire);
    if (!txn || (expectedTxn && txn != expectedTxn)) return;

    int direction = gInternalVolumeDirection.load(std::memory_order_acquire);
    gInternalVolumeSetUntilMS.store(0, std::memory_order_release);
    gInternalVolumeTargetMilli.store(-1, std::memory_order_release);
    gInternalVolumeDirection.store(SNVolumeDirectionNone, std::memory_order_release);
    gInternalVolumeSetTxn.store(0, std::memory_order_release);

    if (DBG_VOL_VERBOSE_ON) {
        SNLOGFMT(@"[VOLUME] ensure state clear | txn=%llu internalVolumeDirection=%@ reason=%s",
                 (unsigned long long)txn,
                 sn_volume_direction_name(direction),
                 (reason ?: "unknown"));
    }
}

static inline void sn_clear_stale_internal_volume_state_for_txn(uint64_t txn)
{
    uint64_t ensureTxn = gInternalVolumeSetTxn.load(std::memory_order_acquire);
    if (ensureTxn && ensureTxn != txn) {
        sn_clear_internal_volume_state(ensureTxn, "new-txn");
    }
    uint64_t lastInternalTxn = gLastInternalVolumeTxn.load(std::memory_order_acquire);
    if (lastInternalTxn && lastInternalTxn != txn) {
        gLastInternalVolumeTxn.store(0, std::memory_order_release);
        gLastInternalVolumeDirection.store(SNVolumeDirectionNone, std::memory_order_release);
    }
}

static inline void sn_mark_internal_volume_set(uint64_t txn,
                                               float previous,
                                               float target,
                                               BOOL changeWithButtons)
{
    SNVolumeDirection direction = sn_volume_direction(previous, target);
    gInternalVolumeSetTxn.store(txn, std::memory_order_release);
    gInternalVolumeTargetMilli.store((int)lroundf(sn_clampf(target, 0.0f, 1.0f) * 1000.0f),
                                     std::memory_order_release);
    gInternalVolumeDirection.store(direction, std::memory_order_release);
    gLastInternalVolumeTxn.store(txn, std::memory_order_release);
    gLastInternalVolumeDirection.store(direction, std::memory_order_release);
    gInternalVolumeSetUntilMS.store(SN_NowMS() + kSNInternalVolumeSetWindowMs,
                                    std::memory_order_release);
    gLastVolumePolicyChangeWithButtons.store(changeWithButtons ? true : false,
                                             std::memory_order_release);
}

static inline BOOL sn_internal_volume_event_matches(float current, uint64_t *txnOut)
{
    uint64_t txn = gInternalVolumeSetTxn.load(std::memory_order_acquire);
    uint64_t until = gInternalVolumeSetUntilMS.load(std::memory_order_acquire);
    int targetMilli = gInternalVolumeTargetMilli.load(std::memory_order_acquire);
    uint64_t now = SN_NowMS();
    if (!txn || !until || targetMilli < 0) {
        if (txnOut) *txnOut = 0;
        return NO;
    }
    if (now > until) {
        sn_clear_internal_volume_state(txn, "expired");
        if (txnOut) *txnOut = 0;
        return NO;
    }
    if (txnOut) *txnOut = txn;

    float target = ((float)targetMilli) / 1000.0f;
    return fabsf(sn_clampf(current, 0.0f, 1.0f) - target) <= kSNVolumeRestoreGuardEps;
}

static inline BOOL sn_internal_volume_set_pending(uint64_t *txnOut)
{
    uint64_t txn = gInternalVolumeSetTxn.load(std::memory_order_acquire);
    uint64_t until = gInternalVolumeSetUntilMS.load(std::memory_order_acquire);
    if (!txn || !until) {
        if (txnOut) *txnOut = 0;
        return NO;
    }
    if (SN_NowMS() > until) {
        sn_clear_internal_volume_state(txn, "expired");
        if (txnOut) *txnOut = 0;
        return NO;
    }
    if (txnOut) *txnOut = txn;
    return YES;
}

static BOOL sn_volume_restore_observe(float current);

static void sn_handle_system_volume_change(NSString *path, float oldVolume, float newVolume)
{
    (void)path;
    float newV = sn_clampf(newVolume, 0.0f, 1.0f);
    BOOL internal = sn_internal_volume_event_matches(newV, NULL);
    if (!internal) {
        internal = sn_volume_restore_observe(newV);
    }
    sSN_LastVol = newV;
    sSN_VolInit = YES;
}

static NSInteger sn_tts_volume_slider_percent_from_prefs(void)
{
    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite] autorelease];
    NSInteger sliderInt = [d objectForKey:kSNVolSliderKey]
        ? [d integerForKey:kSNVolSliderKey]
        : ([d objectForKey:@"speechVolume"]
            ? [d integerForKey:@"speechVolume"]
            : 30);
    if (sliderInt < 0) sliderInt = 0;
    if (sliderInt > 100) sliderInt = 100;
    return sliderInt;
}

static float sn_expected_tts_target_for_txn(uint64_t txn)
{
    float target = ((float)sn_tts_volume_slider_percent_from_prefs()) / 100.0f;
    os_unfair_lock_lock(&gVolumeRestoreLock);
    if (txn && gVolumeRestoreState.armed && gVolumeRestoreState.activeTxn == txn) {
        target = gVolumeRestoreState.targetVolume;
    }
    os_unfair_lock_unlock(&gVolumeRestoreLock);
    return sn_clampf(target, 0.0f, 1.0f);
}

static void sn_schedule_post_volume_set_check(uint64_t txn, float preVolume, float targetVolume, BOOL restoring)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        float current = sn_clampf([SNMediaControl currentMediaVolume], 0.0f, 1.0f);
        if (DBG_VOL_VERBOSE_ON) {
            NSString *route = [SNMediaControl lastOutputPortType] ?: @"-";
            SNLOGFMT(@"[VOLUME] post-set check | txn=%llu pre=%.2f target=%.2f current=%.2f route=%@",
                     (unsigned long long)txn, preVolume, targetVolume, current, route);
        }
        if (DBG_VOL_VERBOSE_ON) {
            SNLOGFMT(@"[VOLUME] internal control released | txn=%llu current=%.2f target=%.2f",
                     (unsigned long long)txn,
                     current,
                     targetVolume);
        }
        if (restoring) {
            NSString *result = fabsf(current - targetVolume) <= kSNVolumeRestoreGuardEps
                ? @"restored" : @"restoreFailed";
            sn_audit_volume_terminal(txn, result, current);
        } else {
            sn_audit_volume_set_confirmed(txn, current, targetVolume);
        }
        sn_clear_internal_volume_state(txn, "post-set-check");
    });
}

static void sn_schedule_post_start_volume_check(uint64_t txn, float expectedMin)
{
    if (!DBG_VOL_VERBOSE_ON) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(160 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (!DBG_VOL_VERBOSE_ON) return;
        float current = sn_clampf([SNMediaControl currentMediaVolume], 0.0f, 1.0f);
        SNLOGFMT(@"[VOLUME] post-start check | txn=%llu current=%.2f expectedMin=%.2f",
                 (unsigned long long)txn, current, expectedMin);
    });
}

static void sn_volume_restore_capture_for_set(uint64_t txn, float previous, float target)
{
    if (!gPrefResetVolumeAfterSpeak || !txn) return;

    BOOL didCapture = NO;
    os_unfair_lock_lock(&gVolumeRestoreLock);
    if (!gVolumeRestoreState.armed || gVolumeRestoreState.activeTxn != txn) {
        gVolumeRestoreState = {};
        gVolumeRestoreState.activeTxn = txn;
        gVolumeRestoreState.originTxn = txn;
        gVolumeRestoreState.previousVolume = previous;
        gVolumeRestoreState.userChanged = NO;
        gVolumeRestoreState.armed = YES;
        didCapture = YES;
    }
    gVolumeRestoreState.targetVolume = target;
    gVolumeRestoreState.awaitingInternalSet = YES;
    gVolumeRestoreState.awaitingQueueHandoff = NO;
    os_unfair_lock_unlock(&gVolumeRestoreLock);

    if (didCapture && DBG_VOL_ON) {
        SNLOGFMT(@"[VOLUME] capture txn=%llu pre=%.2f target=%.2f resetAfter=1",
                 (unsigned long long)txn, previous, target);
    }
    if (didCapture) sn_audit_volume_capture(txn, previous, target);
}

static BOOL sn_volume_restore_observe(float current)
{
    BOOL internalEvent = NO;
    os_unfair_lock_lock(&gVolumeRestoreLock);
    if (!gVolumeRestoreState.armed) {
        os_unfair_lock_unlock(&gVolumeRestoreLock);
        return NO;
    }

    if (gVolumeRestoreState.awaitingInternalSet) {
        if (fabsf(current - gVolumeRestoreState.targetVolume) <= kSNVolumeRestoreGuardEps) {
            gVolumeRestoreState.awaitingInternalSet = NO;
            internalEvent = YES;
            os_unfair_lock_unlock(&gVolumeRestoreLock);
            return YES;
        }
        gVolumeRestoreState.awaitingInternalSet = NO;
    }

    if (fabsf(current - gVolumeRestoreState.targetVolume) > kSNVolumeRestoreGuardEps) {
        gVolumeRestoreState.userChanged = YES;
    }
    os_unfair_lock_unlock(&gVolumeRestoreLock);
    return internalEvent;
}

static BOOL sn_volume_restore_defer_for_queue(uint64_t txn, NSUInteger pending)
{
    if (!txn || pending == 0) return NO;

    uint64_t originTxn = 0;
    BOOL deferred = NO;
    os_unfair_lock_lock(&gVolumeRestoreLock);
    if (gVolumeRestoreState.armed && gVolumeRestoreState.activeTxn == txn) {
        gVolumeRestoreState.awaitingQueueHandoff = YES;
        originTxn = gVolumeRestoreState.originTxn;
        deferred = YES;
    }
    os_unfair_lock_unlock(&gVolumeRestoreLock);

    if (deferred && DBG_VOL_ON) {
        SNLOGFMT(@"[VOLUME] defer restore txn=%llu originTxn=%llu pending=%lu",
                 (unsigned long long)txn,
                 (unsigned long long)originTxn,
                 (unsigned long)pending);
    }
    return deferred;
}

static void sn_volume_restore_handoff_to_queued_txn(uint64_t txn)
{
    if (!txn) return;

    uint64_t fromTxn = 0;
    uint64_t originTxn = 0;
    float previous = 0.0f;
    float target = 0.0f;
    BOOL handedOff = NO;
    os_unfair_lock_lock(&gVolumeRestoreLock);
    if (gVolumeRestoreState.armed && gVolumeRestoreState.awaitingQueueHandoff) {
        fromTxn = gVolumeRestoreState.activeTxn;
        originTxn = gVolumeRestoreState.originTxn;
        previous = gVolumeRestoreState.previousVolume;
        target = gVolumeRestoreState.targetVolume;
        gVolumeRestoreState.activeTxn = txn;
        gVolumeRestoreState.awaitingQueueHandoff = NO;
        handedOff = YES;
    }
    os_unfair_lock_unlock(&gVolumeRestoreLock);

    if (handedOff && DBG_VOL_ON) {
        SNLOGFMT(@"[VOLUME] queue handoff fromTxn=%llu toTxn=%llu originTxn=%llu",
                 (unsigned long long)fromTxn,
                 (unsigned long long)txn,
                 (unsigned long long)originTxn);
    }
    if (handedOff) sn_audit_volume_handoff(fromTxn, txn, originTxn, previous, target);
}

static BOOL sn_volume_restore_keeps_target_for_queued_txn(uint64_t txn)
{
    if (!txn) return NO;

    uint64_t originTxn = 0;
    BOOL keepTarget = NO;
    os_unfair_lock_lock(&gVolumeRestoreLock);
    if (gVolumeRestoreState.armed &&
        gVolumeRestoreState.activeTxn == txn &&
        gVolumeRestoreState.originTxn != 0 &&
        gVolumeRestoreState.originTxn != txn) {
        originTxn = gVolumeRestoreState.originTxn;
        keepTarget = YES;
    }
    os_unfair_lock_unlock(&gVolumeRestoreLock);

    if (keepTarget && DBG_VOL_ON) {
        SNLOGFMT(@"[VOLUME] keep target for queued txn=%llu originTxn=%llu",
                 (unsigned long long)txn,
                 (unsigned long long)originTxn);
    }
    return keepTarget;
}

static void sn_volume_restore_if_terminal(uint64_t txn, BOOL force)
{
    if (!force && [SNCancellation isSpeaking]) return;

    float previous = 0.0f;
    float target = 0.0f;
    uint64_t activeTxn = 0;
    uint64_t originTxn = 0;
    BOOL userChanged = NO;

    os_unfair_lock_lock(&gVolumeRestoreLock);
    if (!gVolumeRestoreState.armed) {
        os_unfair_lock_unlock(&gVolumeRestoreLock);
        sn_audit_volume_no_capture(txn, sn_clampf([SNMediaControl currentMediaVolume], 0.0f, 1.0f));
        if (DBG_VOL_VERBOSE_ON) {
            SNLOGFMT(@"[VOLUME] restore skip txn=%llu reason=noCapture",
                     (unsigned long long)txn);
        }
        return;
    }
    if (!txn || gVolumeRestoreState.activeTxn != txn) {
        uint64_t ownerTxn = gVolumeRestoreState.activeTxn;
        os_unfair_lock_unlock(&gVolumeRestoreLock);
        if (DBG_VOL_ON) {
            SNLOGFMT(@"[VOLUME] restore skip txn=%llu reason=txnMismatch ownerTxn=%llu",
                     (unsigned long long)txn,
                     (unsigned long long)ownerTxn);
        }
        return;
    }

    activeTxn = gVolumeRestoreState.activeTxn;
    originTxn = gVolumeRestoreState.originTxn;
    previous = gVolumeRestoreState.previousVolume;
    target = gVolumeRestoreState.targetVolume;
    userChanged = gVolumeRestoreState.userChanged;
    gVolumeRestoreState = {};
    os_unfair_lock_unlock(&gVolumeRestoreLock);

    float current = sn_clampf([SNMediaControl currentMediaVolume], 0.0f, 1.0f);
    if (userChanged || fabsf(current - target) > kSNVolumeRestoreGuardEps) {
        sn_audit_volume_terminal(activeTxn ? activeTxn : txn, @"userChanged", current);
        if (DBG_VOL_ON) {
            SNLOGFMT(@"[VOLUME] restore skip txn=%llu reason=userChanged current=%.2f",
                     (unsigned long long)(activeTxn ? activeTxn : txn), current);
        }
        return;
    }

    if (DBG_VOL_ON) {
        SNLOGFMT(@"[VOLUME] restore txn=%llu originTxn=%llu pre=%.2f current=%.2f",
                 (unsigned long long)(activeTxn ? activeTxn : txn),
                 (unsigned long long)originTxn,
                 previous, current);
    }
    uint64_t restoreTxn = activeTxn ? activeTxn : txn;
    sn_mark_internal_volume_set(restoreTxn,
                                current,
                                previous,
                                gLastVolumePolicyChangeWithButtons.load(std::memory_order_acquire));
    sn_set_system_volume(previous);
    sn_audit_volume_set_requested(restoreTxn, previous, YES);
    sn_schedule_post_volume_set_check(restoreTxn, current, previous, YES);
}

static void SN_OnVolumeChanged(const char *keyPath, float value) {
    float v = sn_clampf(value, 0.f, 1.f);
    BOOL internalSetEvent = sn_internal_volume_event_matches(v, NULL);
    BOOL snInternalRestoreEvent = sn_volume_restore_observe(v);
    if (internalSetEvent || snInternalRestoreEvent) {
        sSN_LastVol = v;
        sSN_VolInit = YES;
        return;
    }
    int level = (int)lroundf(v * 100.0f);

    NSString *fgBID = SNAppStateTryForegroundBID();
    NSString *npBID = nil, *npName = nil, *npRoute = nil; BOOL npPlaying = NO;
    SNAudioNowPlayingProbe(&npBID, &npName, &npPlaying, &npRoute);
    NSString *routePort = [SNMediaControl lastOutputPortType] ?: @"";

    // Silence unused variable warnings (no debug active)
    (void)level;
    (void)fgBID;
    (void)npBID;
    (void)npName;
    (void)npRoute;
    (void)npPlaying;
    (void)routePort;
/*
    if (DBG_VOL_ON) SNLOGFMT(@"VOL | volType=%s level=%d%% hyg=%ld source=%s route=%@ fgApp=%@ nowPlayingApp=%@",
             "tts", level, (long)tsk, (keyPath ? keyPath : "unknown"),
             (routePort.length ? routePort : @"-"),
             (fgBID.length ? fgBID : @"-"),
             (npBID.length ? npBID : @"-"));
*/
    BOOL known = NO;
    BOOL muted = [SNMediaControl ringerMutedKnown:&known];

    if (SN_BlockOnMutePref() && known && muted && sn_cancel_target_active_now()) {
        if (DBG_VOL_ON) SNLOGFMT(@"[MUTE] detected during speech (pref=on) -> cancel");
        sn_cancel_ringer_switch(@"silent");
        return;
    }
    // KVO records volume state and restore ownership only; it is not physical input.
    sSN_LastVol = v;
    sSN_VolInit = YES;
}

static BOOL gSNOutVolStarted = NO;

@interface SNOutVolObserver : NSObject
+ (instancetype)shared;
- (void)start;
- (void)stop;
@end

@implementation SNOutVolObserver
+ (instancetype)shared { static SNOutVolObserver *o; static dispatch_once_t once; dispatch_once(&once, ^{ o = [self new]; }); return o; }

- (void)start {
    if (gSNOutVolStarted) return;
    gSNOutVolStarted = YES;
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        [s addObserver:self forKeyPath:@"outputVolume" options:NSKeyValueObservingOptionNew context:NULL];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sn_onReset:)
                                                     name:AVAudioSessionMediaServicesWereResetNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sn_onInt:)
                                                     name:AVAudioSessionInterruptionNotification object:nil];
    } @catch (...) {}
}
- (void)stop {
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        @try { [s removeObserver:self forKeyPath:@"outputVolume"]; } @catch (...) {}
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVAudioSessionMediaServicesWereResetNotification object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVAudioSessionInterruptionNotification object:nil];
    } @catch (...) {}
    gSNOutVolStarted = NO;
}
- (void)sn_onReset:(NSNotification *)n {}
- (void)sn_onInt:(NSNotification *)n {}
- (void)sn_onRoute:(NSNotification *)n {}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (![keyPath isEqualToString:@"outputVolume"]) return;
    NSNumber *nv = change[NSKeyValueChangeNewKey];
    if (![nv isKindOfClass:NSNumber.class]) return;
    SN_OnVolumeChanged("KVO_outputVolume", (float)nv.doubleValue);
}
@end

#pragma mark - Speak Queue

static void sn_start_duck_chain_and_tts(NSString *title, NSString *msg, NSString *bcp47, NSString *appCtx, uint64_t txn);

static NSMutableArray *sSNQueue = nil;
static dispatch_queue_t sSNQueueQ = NULL;

static inline void sn_queue_init_once(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sSNQueue  = [[NSMutableArray alloc] init];
        sSNQueueQ = dispatch_queue_create("sn.speak.queue", DISPATCH_QUEUE_SERIAL);
    });
}

static inline BOOL sn_queue_drain_in_flight(void) {
    return gQueueDrainInFlight.load(std::memory_order_acquire);
}

static inline BOOL sn_queue_tail_active(void) {
    @try {
        return (gDuckMgr ? gDuckMgr.inPostRoll : NO);
    } @catch (...) {}
    return NO;
}

static inline void sn_queue_log_state(const char *event, const char *reason, uint64_t txn)
{
    if (!DBG_QUEUE_VERBOSE_ON) return;
    NSUInteger pending = sn_queue_count();
    SNLOGFMT(@"[QUEUE] %s | reason=%s pending=%lu speaking=%d chainAlive=%d tail=%d draining=%d txn=%llu",
             (event ? event : "?"),
             (reason ? reason : "?"),
             (unsigned long)pending,
             ([SNCancellation isSpeaking] ? 1 : 0),
             (gDuckChainAlive ? 1 : 0),
             (sn_queue_tail_active() ? 1 : 0),
             (sn_queue_drain_in_flight() ? 1 : 0),
             (unsigned long long)txn);
}

static BOOL sn_try_speak_next_from_queue(const char *reason) {
    sn_queue_init_once();

    NSUInteger pending = sn_queue_count();
    if (DBG_QUEUE_VERBOSE_ON) {
        sn_queue_log_state("drain attempt", reason, 0);
    }

    if (pending == 0) {
        if (DBG_QUEUE_VERBOSE_ON) {
            sn_queue_log_state("queue empty", reason, 0);
        }
        return NO;
    }

    if (!SN_PrefBoolFast(@"queueNotifications", NO)) {
        if (DBG_QUEUE_VERBOSE_ON) {
            sn_queue_log_state("drain blocked", "queue-off", 0);
        }
        sn_queue_clear("queueDisabled");
        return NO;
    }

    if (gStartInFlightTxn.load(std::memory_order_acquire) != 0) {
        if (DBG_QUEUE_VERBOSE_ON) {
            sn_queue_log_state("drain blocked", "start-in-flight", 0);
        }
        return NO;
    }

    if ([SNCancellation isSpeaking]) {
        if (DBG_QUEUE_VERBOSE_ON) {
            sn_queue_log_state("drain blocked", "speaking", 0);
        }
        return NO;
    }

    bool expected = false;
    if (!gQueueDrainInFlight.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
        if (DBG_QUEUE_VERBOSE_ON) {
            sn_queue_log_state("drain blocked", "draining", 0);
        }
        return NO;
    }

    __block NSDictionary *item = nil;
    dispatch_sync(sSNQueueQ, ^{
        if (sSNQueue.count) {
            item = [[sSNQueue objectAtIndex:0] retain];
            [sSNQueue removeObjectAtIndex:0];
        }
    });

    if (!item) {
        gQueueDrainInFlight.store(false, std::memory_order_release);
        if (DBG_QUEUE_VERBOSE_ON) {
            sn_queue_log_state("queue empty", reason, 0);
        }
        return NO;
    }

    NSString *t = [[item objectForKey:@"t"] retain];
    NSString *m = [[item objectForKey:@"m"] retain];
    NSString *b = [[item objectForKey:@"b"] retain];
    NSString *a = [[item objectForKey:@"a"] retain];
    uint64_t txn = (uint64_t)[[item objectForKey:@"x"] unsignedLongLongValue];
    uint64_t sequence = (uint64_t)[[item objectForKey:@"n"] unsignedLongLongValue];
    [item release];

    (void)sn_audit_queue_item_matches(txn, sequence);

    sn_volume_restore_handoff_to_queued_txn(txn);

    if (DBG_QUEUE_VERBOSE_ON) {
        sn_queue_log_state("dequeue start", reason, txn);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (DBG_QUEUE_VERBOSE_ON) {
            SNLOGFMT(@"[QUEUE] start next | reason=%s pending=%lu draining=%d txn=%llu",
                     (reason ? reason : "?"),
                     (unsigned long)sn_queue_count(),
                     (sn_queue_drain_in_flight() ? 1 : 0),
                     (unsigned long long)txn);
        }
        sn_start_duck_chain_and_tts(t, m, b, a, txn);
        [t release]; [m release]; [b release]; [a release];
    });
    return YES;
}

static void sn_queue_enqueue(NSString *title, NSString *msg, NSString *bcp47, NSString *appCtx,
                             uint64_t txn, const char *reason, uint64_t behindTxn) {
    sn_queue_init_once();
    NSString *t = [ (title  ?: @"") copy ];
    NSString *m = [ (msg    ?: @"") copy ];
    NSString *b = [ (bcp47  ?: @"") copy ];
    NSString *a = [ (appCtx ?: @"") copy ];
    NSNumber *x = [[NSNumber alloc] initWithUnsignedLongLong:txn];
    uint64_t sequence = sn_audit_sequence_for_txn(txn);
    NSNumber *n = [[NSNumber alloc] initWithUnsignedLongLong:sequence];
    NSDictionary *item = [[NSDictionary alloc] initWithObjectsAndKeys:
                          t, @"t", m, @"m", b, @"b", a, @"a", x, @"x", n, @"n", nil];
    [t release]; [m release]; [b release]; [a release]; [x release]; [n release];
    
    // CRITICAL FIX: Check if queue was empty before enqueue
    dispatch_async(sSNQueueQ, ^{
        BOOL wasEmpty = (sSNQueue.count == 0);
        [sSNQueue addObject:item];
        BOOL auditRecorded = sn_audit_record_enqueue(txn,
                                                     sequence,
                                                     sSNQueue.count,
                                                     behindTxn,
                                                     reason);
        if (auditRecorded) sn_audit_emit_notif(txn);
        if (sSNQueue.count > kSNQueueCap) {
            NSDictionary *evicted = [sSNQueue objectAtIndex:0];
            uint64_t evictedTxn = (uint64_t)[evicted[@"x"] unsignedLongLongValue];
            uint64_t evictedSequence = (uint64_t)[evicted[@"n"] unsignedLongLongValue];
            sn_audit_record_queue_terminal(evictedTxn,
                                           evictedSequence,
                                           @"dropped",
                                           @"queueCapacity");
            [sSNQueue removeObjectAtIndex:0];
        }
        if (DBG_QUEUE_ON) {
            const char *reason = ([SNCancellation isSpeaking] ? "speaking" : (wasEmpty ? "idle-empty" : "queued"));
            SNLOGFMT(@"[QUEUE] enqueue | reason=%s pending=%lu speaking=%d chainAlive=%d tail=%d draining=%d txn=%llu",
                     reason,
                     (unsigned long)sSNQueue.count,
                     ([SNCancellation isSpeaking] ? 1 : 0),
                     (gDuckChainAlive ? 1 : 0),
                     (sn_queue_tail_active() ? 1 : 0),
                     (sn_queue_drain_in_flight() ? 1 : 0),
                     (unsigned long long)txn);
        }
        [item release];
        
        // If queue was empty and nothing is actively speaking, wake it now.
        if (wasEmpty &&
            ![SNCancellation isSpeaking] &&
            !sn_queue_drain_in_flight() &&
            gStartInFlightTxn.load(std::memory_order_acquire) == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (DBG_QUEUE_ON) {
                    sn_queue_log_state("direct start", "idle-empty", txn);
                }
                (void)sn_try_speak_next_from_queue("enqueue");
            });
        }
    });
}

static void sn_queue_clear(const char *reason) {
    sn_queue_init_once();
    NSString *auditReason = [[NSString alloc] initWithUTF8String:(reason ?: "unknown")];
    dispatch_async(sSNQueueQ, ^{
        NSString *outcome = [auditReason isEqualToString:@"cancelAll"]
            ? @"cancelledBeforeStart" : @"dropped";
        for (NSDictionary *item in sSNQueue) {
            uint64_t txn = (uint64_t)[item[@"x"] unsignedLongLongValue];
            uint64_t sequence = (uint64_t)[item[@"n"] unsignedLongLongValue];
            sn_audit_record_queue_terminal(txn, sequence, outcome, auditReason);
        }
        [sSNQueue removeAllObjects];
        [auditReason release];
    });
    gQueueDrainInFlight.store(false, std::memory_order_release);
}

static inline void sn_queue_progress_nudge_after_ms(int ms)
{
    static std::atomic<uint64_t> sLastNudgeAtMS(0);
    if (sn_queue_count() == 0) return;

    uint64_t now  = SN_NowMS();
    uint64_t prev = sLastNudgeAtMS.load(std::memory_order_acquire);
    if (prev && (now - prev) < kSNQueueProgressBackoffMs) {
        return;
    }
    sLastNudgeAtMS.store(now, std::memory_order_release);

    // First nudge
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if ([SNCancellation isSpeaking]) return;
        if (sn_queue_count() == 0) return;
        (void)sn_try_speak_next_from_queue("nudge");
    });

    // Second nudge (backup)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((ms + kSNQueueProgressSecondNudgeDeltaMs) * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if ([SNCancellation isSpeaking]) return;
        if (sn_queue_count() == 0) return;
        (void)sn_try_speak_next_from_queue("nudge-backup");
    });
}

static inline void sn_hold_audio_for_queue_handoff(uint64_t txn)
{
    sn_cancel_idle_cleanup_timer();
    g_snPromptDidStart = NO;
    gDeferReleaseForLast.store(false, std::memory_order_release);
    uint64_t expectedCurrentTxn = txn;
    (void)gCurrentTxn.compare_exchange_strong(expectedCurrentTxn, 0, std::memory_order_acq_rel);
    gSpeakAllowedCtx.store(false, std::memory_order_release);
}

static BOOL sn_queue_finish_terminal(const char *reason, uint64_t txn)
{
    uint64_t expectedStartTxn = txn;
    (void)gStartInFlightTxn.compare_exchange_strong(expectedStartTxn, 0, std::memory_order_acq_rel);
    gQueueDrainInFlight.store(false, std::memory_order_release);

    NSUInteger pending = sn_queue_count();
    BOOL queueCanContinue = (pending > 0 && SN_PrefBoolFast(@"queueNotifications", NO));
    if (queueCanContinue) {
        (void)sn_volume_restore_defer_for_queue(txn, pending);
    }

    if (DBG_QUEUE_VERBOSE_ON) {
        const char *event = "finish terminal";
        if (reason && (!strcmp(reason, "timeout") || !strcmp(reason, "watchdog"))) {
            event = "watchdog terminal";
        } else if (reason && !strcmp(reason, "cancel")) {
            event = "cancel terminal";
        }
        sn_queue_log_state(event, reason, txn);
    }

    BOOL startedNext = NO;
    if (queueCanContinue) {
        sn_hold_audio_for_queue_handoff(txn);
        if (DBG_QUEUE_VERBOSE_ON) {
            SNLOGFMT(@"[QUEUE] audio hold | txn=%llu pending=%lu",
                     (unsigned long long)txn,
                     (unsigned long)pending);
        }
        startedNext = sn_try_speak_next_from_queue(reason ?: "terminal");
        if (startedNext) return YES;
    }

    sn_volume_restore_if_terminal(txn, NO);
    finishWork();

    if ([SNCancellation isSpeaking]) return NO;

    if (sn_queue_count() > 0) {
        startedNext = sn_try_speak_next_from_queue(reason ?: "terminal");
    } else if (DBG_QUEUE_VERBOSE_ON) {
        sn_queue_log_state("queue empty", reason, txn);
    }

    return startedNext;
}

static NSUInteger sn_queue_count(void) {
    sn_queue_init_once();
    __block NSUInteger n = 0;
    dispatch_sync(sSNQueueQ, ^{
        n = sSNQueue.count;
    });
    return n;
}

#pragma mark - TTS Duration Guard

static volatile uint64_t gSpeakStartAtMS = 0;
static volatile NSUInteger gSpeakCharCount = 0;
static volatile BOOL gSpeakFinishArmed = NO;

static inline uint32_t sn_expected_ms_for_chars(NSUInteger n) {
    uint32_t ms = (uint32_t)(kSNMinSpeakBaseMs + (kSNMsPerChar * (n > 0 ? n : 0)));
    if (ms < kSNMinSpeakFloorMs) ms = (uint32_t)kSNMinSpeakFloorMs;
    if (ms > kSNMinSpeakCeilMs)  ms = (uint32_t)kSNMinSpeakCeilMs;
    return ms;
}

static inline uint32_t sn_expected_ms_lang_adjust(uint32_t baseMs) {
    NSString *lang = gLastSpeakBCP47 ?: @"";
    if ([lang hasPrefix:@"sv"]) {
        uint64_t adj = (uint64_t)((double)baseMs * kSNSwedishSpeedFactor);
        if (adj > kSNMinSpeakCeilMs) adj = kSNMinSpeakCeilMs;
        return (uint32_t)adj;
    }
    return baseMs;
}

static inline void sn_arm_speak_guard(NSUInteger totalChars) {
    gSpeakCharCount = totalChars;
    gSpeakStartAtMS = SN_NowMS();
    gSpeakFinishArmed = YES;
    gLastVolCancelAtMS.store(0, std::memory_order_release);
    gLastPhysicalVolumeDirection.store(SNVolumeDirectionNone, std::memory_order_release);
    sSN_LastVol = sn_clampf([SNMediaControl currentMediaVolume], 0.0f, 1.0f);
    sSN_VolInit = YES;
    uint32_t dueBase = sn_expected_ms_for_chars(totalChars);
    uint32_t due     = sn_expected_ms_lang_adjust(dueBase);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(due * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        gSpeakFinishArmed = NO;
    });
}

static inline BOOL sn_finish_is_too_early(void) {
    if (!gSpeakFinishArmed) return NO;
    uint64_t t0 = gSpeakStartAtMS;
    if (!t0) return NO;
    uint64_t now = SN_NowMS();
    if (now <= t0) return NO;
    uint64_t elapsed = (now - t0);
    uint32_t need    = sn_expected_ms_for_chars(gSpeakCharCount);
    return (elapsed + kSNEarlyFinishGuardMs) < need;
}

static volatile uint64_t gLastTTSEndAtMS = 0;
static inline void sn_mark_tts_end_now(void) { gLastTTSEndAtMS = SN_NowMS(); }

static inline BOOL sn_cancel_buttons_armed_now(void) {
    uint64_t started = gSpeakStartAtMS;
    if (!started) return NO;
    uint64_t now = SN_NowMS();
    return (now > started && (now - started) >= kSNCancelButtonArmDelayMs);
}

static inline BOOL sn_cancel_target_active_now(void)
{
    if ([SNCancellation isSpeaking]) return YES;

    uint64_t txn = gCurrentTxn.load(std::memory_order_acquire);
    return (txn != 0 &&
            gA2DPSessionWarmupPendingTxn.load(std::memory_order_acquire) == txn &&
            gStartInFlightTxn.load(std::memory_order_acquire) == txn);
}

static inline BOOL sn_cancel_mode_accepts_volume(SNCancelButtonMode mode)
{
    return (mode == SNCancelButtonModeVolumeUp ||
            mode == SNCancelButtonModeVolumeDown ||
            mode == SNCancelButtonModeVolumeUpDown ||
            mode == SNCancelButtonModeAny);
}

static void sn_handle_cancel_candidate(const char *source, NSString *detail, SNCancelCandidateKind kind)
{
    if (!sn_cancel_target_active_now()) return;

    uint64_t txn = gCurrentTxn.load(std::memory_order_acquire);
    if (!txn || gCancelAllTxn.load(std::memory_order_acquire) == txn) return;

    SNCancelButtonMode mode = [SNCancellation cancelMode];
    BOOL modeAccepted = (mode == SNCancelButtonModeAny);
    if (kind == SNCancelCandidateVolume) {
        modeAccepted = sn_cancel_mode_accepts_volume(mode);
    } else if (kind == SNCancelCandidatePower) {
        modeAccepted = modeAccepted || mode == SNCancelButtonModePower;
    }

    BOOL isDirectVolumeButton = (kind == SNCancelCandidateVolume &&
                                 source &&
                                 strcmp(source, "VolumeButton") == 0);
    BOOL accepted = NO;
    if (modeAccepted) {
        if (isDirectVolumeButton) {
            // Real hardware volume-button hooks should cancel immediately.
            accepted = YES;
        } else {
            // Non-button volume candidates keep the startup arm guard.
            accepted = sn_cancel_buttons_armed_now();
        }
    }
    if (!accepted) return;

    NSString *auditSource = source ? [NSString stringWithUTF8String:source] : @"-";
    sn_audit_record_cancel_accepted(txn, auditSource, detail, @"cancel");

    if (kind == SNCancelCandidateVolume && DBG_CANCEL_ON) {
        SNLOGFMT(@"[CANCEL] accepted | txn=%llu source=VolumeButton detail=%@ action=cancel",
                 (unsigned long long)txn,
                 (detail ?: @"-"));
    }
    SN_CancelAll(source);
}

static void sn_cancel_ringer_switch(NSString *detail)
{
    if (!sn_cancel_target_active_now()) return;
    uint64_t txn = gCurrentTxn.load(std::memory_order_acquire);
    if (!txn || gCancelAllTxn.load(std::memory_order_acquire) == txn) return;
    sn_audit_record_cancel_accepted(txn, @"RingerSwitch", detail, @"cancel");
    SN_CancelAll("RingerSwitch");
}

#pragma mark - Safe KVC / App Names

static inline NSString *SN_GetStringKVC(id obj, NSString *key) {
    if (!obj || key.length == 0) return @"";
    id v = nil;
    @try { v = [obj valueForKey:key]; } @catch (...) { return @""; }
    if ([v isKindOfClass:NSString.class]) return (NSString *)v;
    if ([v respondsToSelector:@selector(stringValue)]) return [(id)v stringValue] ?: @"";
    if (v && CFGetTypeID((__bridge CFTypeRef)v) == CFStringGetTypeID()) return (__bridge NSString *)v;
    return @"";
}

static inline NSString *SN_GetStringPropOrKVC(id obj, NSString *selectorName, NSString *kvcKey) {
    if (obj && selectorName.length) {
        SEL sel = NSSelectorFromString(selectorName);
        if ([obj respondsToSelector:sel]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
            if ([v isKindOfClass:NSString.class] && [(NSString *)v length]) return (NSString *)v;
            if (v && CFGetTypeID((__bridge CFTypeRef)v) == CFStringGetTypeID()) return (__bridge NSString *)v;
        }
    }
    return SN_GetStringKVC(obj, kvcKey);
}

// Returns localized display name for app/sectionID, bridged from SpringBoardServices
#ifdef __cplusplus
extern "C" CFStringRef SBSCopyLocalizedApplicationNameForDisplayIdentifier(CFStringRef identifier);
#else
extern CFStringRef SBSCopyLocalizedApplicationNameForDisplayIdentifier(CFStringRef identifier);
#endif

static inline NSString *SN_AppDisplayNameForSection(NSString *sectionID, id bulletin)
{
    NSString *secName = SN_GetStringPropOrKVC(bulletin, @"sectionDisplayName", @"sectionDisplayName");
    if (secName.length) return secName;

    if (sectionID.length) {
        NSString *name = nil;
        CFStringRef cs = SBSCopyLocalizedApplicationNameForDisplayIdentifier((__bridge CFStringRef)sectionID);
        if (cs) {
            name = [NSString stringWithString:(__bridge NSString *)cs];
            CFRelease(cs);
        }
        if (name.length) return name;
    }
    return (sectionID.length ? sectionID : @"");
}

static inline NSString *SN_AppLabelForLog(NSString *sectionID, id bulletin)
{
    NSString *name = SN_AppDisplayNameForSection(sectionID, bulletin);
    if (name.length == 0) return @"-";
    if (sectionID.length && ![name isEqualToString:sectionID]) {
        return [NSString stringWithFormat:@"%@ (%@)", name, sectionID];
    }
    return name;
}


#pragma mark - Burst / Anti-spam

static dispatch_queue_t gBurstMapQ;
static NSMutableDictionary<NSString *, NSNumber *> *gBurstLastSpokeMS;
static inline uint64_t sn_now_ms_inline(void) { return SN_NowMS(); }
static uint8_t kBurstMapQKey;


static inline void sn_burst_init_mapq_once(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gBurstMapQ = dispatch_queue_create("sn.burst.map", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(gBurstMapQ, &kBurstMapQKey, (void *)1, NULL);
        gBurstLastSpokeMS = [NSMutableDictionary new];
    });
}

static inline void sn_mark_burst_spoken_nowForKey_sync(NSString *key)
{
    if (key.length == 0) return;
    sn_burst_init_mapq_once();
    uint64_t now = sn_now_ms_inline();
    if (dispatch_get_specific(&kBurstMapQKey)) {
        gBurstLastSpokeMS[key] = @(now);
    } else {
        dispatch_sync(gBurstMapQ, ^{
            gBurstLastSpokeMS[key] = @(now);
        });
    }
}

static void SN_BurstInitOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gBurstTracker = [SNBurstTracker new]; });
}



static inline NSNumber *sn_burst_last_ms_for_key(NSString *key) {
    if (key.length == 0) return nil;
    sn_burst_init_mapq_once();

    __block NSNumber *out = nil;
    if (dispatch_get_specific(&kBurstMapQKey)) {
        out = gBurstLastSpokeMS[key];
    } else {
        dispatch_sync(gBurstMapQ, ^{
            out = gBurstLastSpokeMS[key];
        });
    }
    return out;
}

static inline BOOL sn_burst_spoken_recently(NSString *key, double windowSec)
{
    if (key.length == 0 || windowSec <= 0.0) return NO;

    NSNumber *msNum = sn_burst_last_ms_for_key(key);
    if (!msNum) return NO;

    uint64_t now  = sn_now_ms_inline();
    uint64_t last = (uint64_t)msNum.unsignedLongLongValue;
    return (now > last) && ((now - last) < (uint64_t)(windowSec * 1000.0));
}

static inline NSString *sn_make_burst_key(NSString *appCtxOrSection,
                                          NSString *normalizedTitle,
                                          NSString *bodyOrMsg)
{
    NSString *(^component)(NSString *) = ^NSString *(NSString *value) {
        NSData *data = [(value ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
        return data ? [data base64EncodedStringWithOptions:0] : @"";
    };

    return [NSString stringWithFormat:@"%@|%@|%@",
            component(appCtxOrSection ?: @"-"),
            component(normalizedTitle ?: @""),
            component(bodyOrMsg ?: @"")];
}

#pragma mark - Ringer Switch

static inline BOOL sn_silent_from_token(uint64_t tokenState) {
    return gRingerSilentIsOne ? ( (tokenState >= 1) ) : (tokenState == 0);
}

static void sn_handle_ringerstate_token(int token) {
    uint64_t t = 0;
    notify_get_state(token, &t);

    if (!gRingerPolarityLocked) {
        BOOL known = NO;
        BOOL muted = [SNMediaControl ringerMutedKnown:&known];
        if (known) {
            gRingerSilentIsOne    = ( (t >= 1) == muted );
            gRingerPolarityLocked = YES;
        }
    }

    BOOL nowSilent = sn_silent_from_token(t);

    if (!gRingerInit) {
        gPrevRingerSilent = nowSilent;
        gRingerInit = YES;
    } else if (sn_cancel_target_active_now() && (nowSilent != gPrevRingerSilent)) {
        sn_handle_cancel_candidate("RingerSwitch", (nowSilent ? @"silent" : @"ring"), SNCancelCandidateRinger);
    }
    gPrevRingerSilent = nowSilent;

    if (SN_BlockOnMutePref() && nowSilent && sn_cancel_target_active_now()) {
        sn_cancel_ringer_switch(@"silent");
    }
}

#pragma mark - Volume Policy

static void sn_apply_tts_volume_policy(uint64_t txn)
{
    sn_clear_stale_internal_volume_state_for_txn(txn);
    if (sn_volume_restore_keeps_target_for_queued_txn(txn)) return;

    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite] autorelease];

    NSInteger sliderInt = sn_tts_volume_slider_percent_from_prefs();

    BOOL changeWithButtons = [d objectForKey:kSNChangeWithButtonsKey]
        ? [d boolForKey:kSNChangeWithButtonsKey]
        : ([d objectForKey:@"useSystemVolume"]
            ? [d boolForKey:@"useSystemVolume"]
            : NO);
    gLastVolumePolicyChangeWithButtons.store(changeWithButtons ? true : false,
                                             std::memory_order_release);

    float curF = sn_clampf([SNMediaControl currentMediaVolume], 0.f, 1.f);
    int curInt = (int)lroundf(curF * 100.0f);
    float target = ((float)sliderInt) / 100.0f;
    BOOL willSet = changeWithButtons
        ? (curInt < (sliderInt - (int)tsk))
        : (fabsf(curF - target) > (tsk/100.0f));

    sn_audit_volume_prepare(txn, curF, target, willSet, gPrefResetVolumeAfterSpeak);

    if (willSet ? DBG_VOL_ON : DBG_VOL_VERBOSE_ON) {
        NSString *route = [SNMediaControl lastOutputPortType] ?: @"-";
        BOOL locked = [SNDeviceState isDeviceLocked];
        BOOL playing = NO;
        @try { playing = sn_isPhoneMediaNowPlaying(); } @catch (...) { playing = NO; }
        SNLOGFMT(@"[VOLUME] pre-speak | txn=%llu pre=%.2f target=%.2f route=%@ locked=%d playing=%d action=%@",
                 (unsigned long long)txn, curF, target, route, (int)locked, (int)playing,
                 willSet ? @"set" : @"skip");
    }

    if (changeWithButtons) {
        if (willSet) {
            sn_volume_restore_capture_for_set(txn, curF, target);
            sn_mark_internal_volume_set(txn, curF, target, YES);
            sn_set_system_volume(target);
            sn_audit_volume_set_requested(txn, target, NO);
            if (DBG_VOL_ON) SNLOGFMT(@"[VOL] ensure-min SET cwButtons=1 cur=%d%% slider=%ld%% (hyst=%d)",
                                     curInt, (long)sliderInt, (int)tsk);
            sn_schedule_post_volume_set_check(txn, curF, target, NO);
        } else {
            /*if (DBG_VOL_ON) SNLOGFMT(@"[VOL] ensure-min SKIP cwButtons=1 cur=%d%% slider=%ld%% (hyst=%d)",
                                     curInt, (long)sliderInt, (int)tsk);*/
        }
    } else {
        if (willSet) {
            sn_volume_restore_capture_for_set(txn, curF, target);
            sn_mark_internal_volume_set(txn, curF, target, NO);
            sn_set_system_volume(target);
            sn_audit_volume_set_requested(txn, target, NO);
            if (DBG_VOL_ON) SNLOGFMT(@"[VOL] exact-set SET cwButtons=0 cur=%d%% slider=%ld%% (hyst=%d)",
                                     curInt, (long)sliderInt, (int)tsk);
            sn_schedule_post_volume_set_check(txn, curF, target, NO);
        } else {
            if (DBG_VOL_ON) SNLOGFMT(@"[VOL] exact-set SKIP cwButtons=0 cur=%d%% slider=%ld%% (hyst=%d)",
                                     curInt, (long)sliderInt, (int)tsk);
        }
    }
}

#pragma mark - Cancel Helpers
static BOOL sn_resume_core_guarded(uint64_t txn);

static inline BOOL SN_BlockOnMutePref(void) {
    return SN_PrefBoolFast(@"blockSpeakOnMute", NO);
}

static BOOL sn_wait_for_clear_channel(NSTimeInterval maxWaitSec) {
    NSTimeInterval step = kSNBusyWaitStepSec;
    NSTimeInterval waited = 0.0;
    while (waited < maxWaitSec) {
        if (!sn_speech_channel_busy_now()) return YES;
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:step]];
        waited += step;
    }
    return !sn_speech_channel_busy_now();
}

static void SN_ApplyCancelModeFromPrefs(void) {
    SNCancelButtonMode mode = [[SNPreferences sharedInstance] cancelButtonMode];
    [SNCancellation setCancelMode:mode];

    if (mode == SNCancelButtonModeVolumeUpDown || mode == SNCancelButtonModeAny) {
        [[SNOutVolObserver shared] start];
    } else {
        [[SNOutVolObserver shared] stop];
    }
}

static inline void sn_prime_system_volume_notifications(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            Class controllerClass = NSClassFromString(@"AVSystemController");
            SEL sharedSelector = NSSelectorFromString(@"sharedAVSystemController");
            if (controllerClass && [controllerClass respondsToSelector:sharedSelector]) {
                (void)((id(*)(id,SEL))objc_msgSend)(controllerClass, sharedSelector);
            }
        } @catch (...) {}
    });
}

static inline void sn_clear_duck_manager_after_abort(void)
{
    SNDuckManager *mgr = gDuckMgr;
    gDuckMgr = nil;
    if (!mgr) return;
    [mgr abortNow];
#if !__has_feature(objc_arc)
    [mgr release];
#endif
}

static inline void sn_abort_active_chain(const char *reason) {
    if (DBG_POLICY_ON && !gLastPreflightBlocked.load(std::memory_order_acquire)) {
        SNLOGFMT(@"[POLICY] abort chain | reason=%s activeDuck=%d post=%d",
                 (reason ?: "unknown"),
                 (gDuckMgr ? gDuckMgr.activeDuck : 0),
                 (gDuckMgr ? gDuckMgr.inPostRoll : 0));
    }
    sn_clear_duck_manager_after_abort();

    gDuckChainAlive = NO;
}

static void sn_cancel_cleanup_maybe_start_resume(uint64_t txn)
{
    if (!txn || gCancelCleanupTxn.load(std::memory_order_acquire) != txn) return;
    if (!gCancelDuckCleanupDone.load(std::memory_order_acquire) ||
        !gCancelEngineCleanupDone.load(std::memory_order_acquire)) {
        return;
    }

    bool expected = false;
    if (!gCancelResumeScheduled.compare_exchange_strong(expected, true,
                                                        std::memory_order_acq_rel,
                                                        std::memory_order_relaxed)) {
        return;
    }

    if (DBG_AUDIO_ON) {
        SNLOGFMT(@"[RESUME] cleanup complete | txn=%llu activeDuck=%d pausedBySN=%d preWasPlaying=%d mode=%s route=%@",
                 (unsigned long long)txn,
                 (int)(gDuckMgr ? gDuckMgr.activeDuck : NO),
                 (int)gPausedBySN,
                 (int)gPreWasPlaying,
                 (gLastDuckMode == SNDuckModePause ? "pause" : "none"),
                 ([SNMediaControl lastOutputPortType] ?: @"-"));
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kSNResumeCleanupSettleMs * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        gCancelResumeScheduled.store(false, std::memory_order_release);
        if (gCancelCleanupTxn.load(std::memory_order_acquire) != txn) return;
        if (!sn_resume_owner_matches(txn, gPreNowPlayingBID)) {
            sn_log_resume_skip(txn, @"thisTxnDidNotPause", gPreNowPlayingBID);
            return;
        }
        uint64_t activeTxn = gCurrentTxn.load(std::memory_order_acquire);
        if (activeTxn && activeTxn != txn) {
            sn_log_resume_skip(txn, @"staleTxn", gPreNowPlayingBID);
            return;
        }
        if ([SNCancellation isSpeaking] || SN_CallMonitorActive() || sn_queue_count() > 0) {
            sn_log_resume_skip(txn, @"cleanupNotFinished", gPreNowPlayingBID);
            return;
        }
        (void)sn_resume_core_guarded(txn);
    });
}

static inline void sn_cancel_cleanup_mark_duck_done(uint64_t txn)
{
    if (!txn || gCancelCleanupTxn.load(std::memory_order_acquire) != txn) return;
    gCancelDuckCleanupDone.store(true, std::memory_order_release);
    if (DBG_AUDIO_ON) {
        SNLOGFMT(@"[RESUME] cleanup state | txn=%llu phase=duck-released activeDuck=%d engineCleanup=%d",
                 (unsigned long long)txn,
                 (int)(gDuckMgr ? gDuckMgr.activeDuck : NO),
                 (int)gCancelEngineCleanupDone.load(std::memory_order_acquire));
    }
    sn_cancel_cleanup_maybe_start_resume(txn);
}

static inline void sn_cancel_cleanup_mark_engine_done(uint64_t txn)
{
    if (!txn || gCancelCleanupTxn.load(std::memory_order_acquire) != txn) return;
    gCancelEngineCleanupDone.store(true, std::memory_order_release);
    if (DBG_AUDIO_ON) {
        SNLOGFMT(@"[RESUME] cleanup state | txn=%llu phase=engine-session-released duckCleanup=%d",
                 (unsigned long long)txn,
                 (int)gCancelDuckCleanupDone.load(std::memory_order_acquire));
    }
    sn_cancel_cleanup_maybe_start_resume(txn);
}

static void sn_finish_duck_manager_for_cancel(uint64_t txn)
{
    SNDuckManager *mgr = gDuckMgr;
    gDuckMgr = nil;
    gDuckChainAlive = NO;
    if (!mgr) {
        sn_cancel_cleanup_mark_duck_done(txn);
        return;
    }

    BOOL activeDuck = mgr.activeDuck;
    if (!activeDuck) {
        [mgr abortNow];
#if !__has_feature(objc_arc)
        [mgr release];
#endif
        sn_cancel_cleanup_mark_duck_done(txn);
        return;
    }

    @try {
        [mgr noteTTSEndedCancelled:YES onComplete:^{
            dispatch_async(dispatch_get_main_queue(), ^{
#if !__has_feature(objc_arc)
                [mgr release];
#endif
                sn_cancel_cleanup_mark_duck_done(txn);
            });
        }];
    } @catch (...) {
        [mgr abortNow];
#if !__has_feature(objc_arc)
        [mgr release];
#endif
        sn_cancel_cleanup_mark_duck_done(txn);
    }
}

static inline void sn_post_cancel_terminal(uint64_t txn)
{
    uint64_t prev = gCancelPostedTxn.load(std::memory_order_acquire);
    if (!txn || prev == txn) return;

    gCancelPostedTxn.store(txn, std::memory_order_release);
    [[NSNotificationCenter defaultCenter] postNotificationName:kSNEngineAVDidCancel
                                                        object:nil
                                                      userInfo:@{
                                                          kSNEngineAVUserInfoTerminalReason: @"cancel",
                                                          kSNEngineAVUserInfoTransaction: @(txn),
                                                          kSNAuditSyntheticCancelTerminalKey: @YES
                                                      }];
}

void SN_CancelAll(const char *source) {
    BOOL volumeButtonCancel = (source && strcmp(source, "VolumeButton") == 0);
    if (DBG_CANCEL_ON && !volumeButtonCancel) {
        SNLOGFMT(@"[CANCEL] source=%s speaking=%d", source, [SNCancellation isSpeaking] ? 1 : 0);
    }
    uint64_t cancelTxn = gCurrentTxn.load(std::memory_order_acquire);
    NSString *auditSource = source ? [NSString stringWithUTF8String:source] : @"-";
    sn_audit_record_cancel_accepted(cancelTxn, auditSource, nil, @"cancel");
    BOOL wasPausedByUs = gPausedBySN;
    BOOL wasPlaying = gPreWasPlaying;
    uint64_t pauseOwnerTxn = gMediaPauseOwnerTxn.load(std::memory_order_acquire);
    BOOL queueTransition = (source && !strncmp(source, "QueueOff", 8));
    BOOL resumeEligible = (!queueTransition &&
                           cancelTxn != 0 &&
                           pauseOwnerTxn == cancelTxn &&
                           wasPausedByUs &&
                           wasPlaying);

    gCancelAllTxn.store(cancelTxn, std::memory_order_release);
    if (cancelTxn != 0 &&
        gA2DPSessionWarmupPendingTxn.load(std::memory_order_acquire) == cancelTxn) {
        gA2DPWarmupAbortedTxn.store(cancelTxn, std::memory_order_release);
    }
    uint64_t expectedStartTxn = cancelTxn;
    (void)gStartInFlightTxn.compare_exchange_strong(expectedStartTxn, 0, std::memory_order_acq_rel);
    sn_queue_clear("cancelAll");
    [SNCancellation cancelAllForTransaction:cancelTxn];

    if (resumeEligible) {
        gCancelCleanupTxn.store(cancelTxn, std::memory_order_release);
        gCancelDuckCleanupDone.store(false, std::memory_order_release);
        gCancelEngineCleanupDone.store(false, std::memory_order_release);
        gCancelResumeScheduled.store(false, std::memory_order_release);
        if (DBG_AUDIO_ON) {
            SNLOGFMT(@"[RESUME] cleanup state | txn=%llu phase=cancel-begin ownerTxn=%llu activeDuck=%d pausedBySN=%d preWasPlaying=%d mode=%s route=%@",
                     (unsigned long long)cancelTxn,
                     (unsigned long long)pauseOwnerTxn,
                     (int)(gDuckMgr ? gDuckMgr.activeDuck : NO),
                     (int)wasPausedByUs,
                     (int)wasPlaying,
                     (gLastDuckMode == SNDuckModePause ? "pause" : "none"),
                     ([SNMediaControl lastOutputPortType] ?: @"-"));
        }
        sn_finish_duck_manager_for_cancel(cancelTxn);
    } else {
        if (wasPausedByUs || wasPlaying || pauseOwnerTxn) {
            sn_log_resume_skip(cancelTxn,
                               (pauseOwnerTxn != cancelTxn ? @"txnMismatch" : @"thisTxnDidNotPause"),
                               gPreNowPlayingBID);
        }
        sn_abort_active_chain(source);
    }
    sn_post_cancel_terminal(cancelTxn);

    if (!(wasPausedByUs && wasPlaying)) {
        gPausedBySN    = NO;
        gPreWasPlaying = NO;
        gResumeDone.store(true, std::memory_order_release);
    } else {
        gResumeDone.store(false, std::memory_order_release);
    }

    gPokeScheduled.store(false, std::memory_order_release);

    if (sIdleCleanupTimer) {
        dispatch_source_t timer = sIdleCleanupTimer;
        sIdleCleanupTimer = nil;
        dispatch_source_cancel(timer);
#if !__has_feature(objc_arc)
        dispatch_release(timer);
#endif
    }

    uint64_t now = SN_NowMS();
    gIdleCooldownUntilMS.store(now + kSNPostCallCooldownMs, std::memory_order_release);
    gCooldownSkipLogged.store(false, std::memory_order_release);

    if ([NSThread isMainThread]) {
        sn_idle_maybe_release_to_ringer_with_reason("CancelAll");
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            sn_idle_maybe_release_to_ringer_with_reason("CancelAll");
        });
    }

}

#pragma mark - Resume Helper

static std::atomic_uint64_t gResumeBlockUntilMs{0};
static std::atomic_bool gNotifyOthersInFlight(false);
static std::atomic_uint64_t gNotifyOthersCooldownUntilMS{0};

static inline BOOL sn_can_notify_others_now(void)
{
    if (!gPausedBySN || !gPreWasPlaying) return NO;
    if (sn_audio_chain_busy_now()) return NO;

    if (!gSpeakAllowedCtx.load(std::memory_order_acquire)) return NO;

    return YES;
}

static void sn_notify_others_after_gate(void)
{
    if (!sn_can_notify_others_now()) return;

    uint64_t now = SN_NowMS();
    uint64_t cd  = gNotifyOthersCooldownUntilMS.load(std::memory_order_acquire);
    if (cd && now < cd) return;

    uint64_t delay = 0;
    if (sn_resume_blocked_now(&delay)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            if (!sn_resume_blocked_now(NULL)) sn_notify_others_after_gate();
        });
        return;
    }

    bool expected = false;
    if (!gNotifyOthersInFlight.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) return;

    @try {
        if (DBG_POKE_ON) {
            NSString *route = @"-";
            @try {
                route = [AVAudioSession sharedInstance].currentRoute.outputs.firstObject.portType ?: @"-";
            } @catch (...) {}
            SNLOGFMT(@"[POKE] notify-others gate (no AV deactivate, engine tail) | route=%@", route);
        }
    } @catch (...) {}

    gNotifyOthersInFlight.store(false, std::memory_order_release);
    gNotifyOthersCooldownUntilMS.store(now + 10000, std::memory_order_release);
}

static inline uint64_t sn_now_ms(void)
{
    struct timeval tv; gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000ull + (uint64_t)tv.tv_usec / 1000ull;
}

static inline void sn_arm_tail_keepalive_ms(uint32_t ms)
{
    uint64_t now = sn_now_ms();
    uint64_t newUntil = now + (uint64_t)ms;

    for (;;) {
        uint64_t cur = gResumeBlockUntilMs.load(std::memory_order_acquire);
        if (cur >= newUntil) break;
        if (gResumeBlockUntilMs.compare_exchange_weak(cur, newUntil,
                                                      std::memory_order_acq_rel,
                                                      std::memory_order_acquire)) {
            break;
        }
    }
}

static inline bool sn_resume_blocked_now(uint64_t *optDelayMsOut)
{
    uint64_t until = gResumeBlockUntilMs.load(std::memory_order_acquire);
    if (!until) return false;

    uint64_t now = sn_now_ms();
    if ((int64_t)(until - now) <= 0) {
        gResumeBlockUntilMs.store(0, std::memory_order_release);
        return false;
    }
    if (optDelayMsOut) *optDelayMsOut = until - now;
    return true;
}

static BOOL sn_resume_core_guarded(uint64_t txn)
{
    if (!txn) txn = sn_resume_cycle_txn();
    NSString *targetBID = sn_resume_target_bundle_id();
    if (!sn_resume_owner_matches(txn, targetBID)) {
        sn_log_resume_skip(txn,
                           (gMediaPauseOwnerTxn.load(std::memory_order_acquire) == txn
                               ? @"thisTxnDidNotPause"
                               : @"txnMismatch"),
                           targetBID);
        return NO;
    }

    uint64_t activeTxn = gCurrentTxn.load(std::memory_order_acquire);
    if (activeTxn && activeTxn != txn) {
        sn_log_resume_skip(txn, @"staleTxn", targetBID);
        return NO;
    }

    if (gCancelCleanupTxn.load(std::memory_order_acquire) == txn &&
        (!gCancelDuckCleanupDone.load(std::memory_order_acquire) ||
         !gCancelEngineCleanupDone.load(std::memory_order_acquire))) {
        sn_log_resume_skip(txn, @"cleanupNotFinished", targetBID);
        return NO;
    }

    if (gResumeAttempted.load(std::memory_order_acquire)) {
        return NO;
    }

    if (sn_audio_chain_busy_now()) {
        if (DBG_AUDIO_ON) SNLOGFMT(@"[RESUME] blocked by active queue chain");
        return NO;
    }

    uint64_t delay = 0;
    if (sn_resume_blocked_now(&delay)) {
        if (DBG_AUDIO_ON) SNLOGFMT(@"[RESUME] blocked by keepalive | delay=%llums",
                                  (unsigned long long)delay);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            if (!sn_resume_blocked_now(NULL)) {
                (void)sn_resume_core_guarded(txn);
            }
        });
        return NO;
    }

    bool expected = false;
    if (!gResumeAttempted.compare_exchange_strong(expected, true, std::memory_order_acq_rel, std::memory_order_relaxed)) {
        return NO;
    }
    gResumeCycleTxn.store(txn, std::memory_order_release);
    gResumeDone.store(false, std::memory_order_release);

    (void)sn_resume_issue_request(targetBID, SNResumeMethodSameController, txn);
    sn_resume_verify_stage(txn, targetBID, SNResumeMethodSameController, 1);
    return YES;
}

static void sn_try_resume_or_schedule_poke_10s(uint64_t terminalTxn)
{
    uint64_t ownerTxn = gMediaPauseOwnerTxn.load(std::memory_order_acquire);
    if (!terminalTxn || ownerTxn != terminalTxn) {
        sn_log_resume_skip(terminalTxn,
                           (ownerTxn ? @"txnMismatch" : @"thisTxnDidNotPause"),
                           gPreNowPlayingBID);
        return;
    }
    if (sn_audio_chain_busy_now()) return;
    if (gResumeAttempted.load(std::memory_order_acquire)) return;

    uint64_t gateDelay = 0;
    if (sn_resume_blocked_now(&gateDelay)) {
        if (DBG_AUDIO_ON) SNLOGFMT(@"[RESUME] gate active, defer direct/retries | delay=%llums",
                                  (unsigned long long)gateDelay);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gateDelay * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            if (!sn_resume_blocked_now(NULL) && !gResumeAttempted.load(std::memory_order_acquire))
                sn_try_resume_or_schedule_poke_10s(terminalTxn);
        });
        return;
    }
    gResumeDone.store(false, std::memory_order_release);
    if (!gPausedBySN) { if (DBG_AUDIO_ON) SNLOGFMT(@"[RESUME] skip (not paused)"); return; }
    if (!gPreWasPlaying) { if (DBG_AUDIO_ON) SNLOGFMT(@"[RESUME] skip (nothing was playing)"); return; }
    if (SN_CallMonitorActive()) { if (DBG_AUDIO_ON) SNLOGFMT(@"[RESUME] skip (call active)"); return; }

    if (DBG_AUDIO_ON) SNLOGFMT(@"[RESUME] try direct resume | pausedByUs=%d preWasPlaying=%d callActive=%d",
                              (int)gPausedBySN, (int)gPreWasPlaying, (int)SN_CallMonitorActive());

    double directDelay = kSNResumeDirectDelaySec;
    if (SN_IsCarPlayUnlocked()) directDelay += kSNCarPlayResumeExtraSec;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(directDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gResumeDone.load(std::memory_order_acquire)) return;
        if (gResumeAttempted.load(std::memory_order_acquire)) return;
        if (sn_audio_chain_busy_now()) return;
        if (sn_isPhoneMediaNowPlaying()) {
            sn_audit_resume_terminal(terminalTxn, @"verified", nil, nil);
            return;
        }
        (void)sn_resume_core_guarded(terminalTxn);
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSNResumeRetryFirstSec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gResumeDone.load(std::memory_order_acquire)) return;
        if (gResumeAttempted.load(std::memory_order_acquire)) return;
        if (sn_audio_chain_busy_now()) return;
        if (sn_isPhoneMediaNowPlaying()) {
            sn_audit_resume_terminal(terminalTxn, @"verified", nil, nil);
            return;
        }
        (void)sn_resume_core_guarded(terminalTxn);
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSNResumeRetrySecondSec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gResumeDone.load(std::memory_order_acquire)) return;
        if (gResumeAttempted.load(std::memory_order_acquire)) return;
        if (sn_audio_chain_busy_now()) return;
        if (sn_isPhoneMediaNowPlaying()) {
            sn_audit_resume_terminal(terminalTxn, @"verified", nil, nil);
            return;
        }

        if (!sn_resume_owner_matches(terminalTxn, gPreNowPlayingBID)) {
            sn_log_resume_skip(terminalTxn, @"staleTxn", gPreNowPlayingBID);
            return;
        }
        (void)sn_resume_core_guarded(terminalTxn);
    });

    if (gResumeDone.load(std::memory_order_acquire) || gResumeAttempted.load(std::memory_order_acquire)) return;
    if (sn_queue_count() > 0) return;

    if (!sn_can_notify_others_now()) {
        if (DBG_POKE_ON) SNLOGFMT(@"[POKE] skip schedule (policy disallows notify-others)");
        return;
    }

    bool expectedPoke = false;
    if (!gPokeScheduled.compare_exchange_strong(expectedPoke, true, std::memory_order_acq_rel, std::memory_order_relaxed)) return;
    if (DBG_POKE_ON) SNLOGFMT(@"[POKE] scheduled in 10s (first resume failed)");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSNFallbackPokeDelaySec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gPokeScheduled.store(false, std::memory_order_release);
        if (gResumeDone.load(std::memory_order_acquire) || gResumeAttempted.load(std::memory_order_acquire)) return;
        if ([SNCancellation isSpeaking]) return;
        if (sn_isPhoneMediaNowPlaying()) {
            sn_audit_resume_terminal(terminalTxn, @"verified", nil, nil);
            return;
        }
        if (sn_queue_count() > 0) return;

        if (sn_can_notify_others_now()) {
            sn_notify_others_after_gate();
        }
    });
}

#pragma mark - Duck/Pause Callbacks

static BOOL sn_cb_requestApply(SNDuckMode mode, NSInteger targetDb, void *ctx) {
    (void)targetDb;
    if (mode == SNDuckModePause) {
        /*if (DBG_POLICY_ON) SNLOGFMT(@"[POLICY] requestApply -> pauseIfPlayingPhoneMedia");*/
        BOOL pauseRequestIssued = NO;
        BOOL pauseReturned = NO;
        if (gPreWasPlaying || sn_isPhoneMediaNowPlaying()) {
            pauseRequestIssued = YES;
            @try {
                pauseReturned = [SNMediaControl pauseIfPlayingPhoneMedia];
            } @catch (...) {
                pauseReturned = NO;
            }
        }
        gPausedBySN = (pauseRequestIssued && gPreWasPlaying);
        if (gPausedBySN) {
            uint64_t txn = gCurrentTxn.load(std::memory_order_acquire);
            gMediaPauseOwnerTxn.store(txn, std::memory_order_release);
            sn_audit_resume_owner(txn, nil, gPreNowPlayingBID);
            if (DBG_AUDIO_VERBOSE_ON) {
                SNLOGFMT(@"[RESUME] owner set | txn=%llu target=%@ method=pauseIfPlayingPhoneMedia pauseReturned=%d",
                         (unsigned long long)txn,
                         (gPreNowPlayingBID.length ? gPreNowPlayingBID : @"-"),
                         (int)pauseReturned);
            }
        } else if (DBG_AUDIO_ON) {
            SNLOGFMT(@"[RESUME] owner not set | txn=%llu preWasPlaying=%d requestIssued=%d pauseReturned=%d",
                     (unsigned long long)gCurrentTxn.load(std::memory_order_acquire),
                     (int)gPreWasPlaying,
                     (int)pauseRequestIssued,
                     (int)pauseReturned);
        }
        if (!gPausedBySN) sn_audit_resume_not_needed(gCurrentTxn.load(std::memory_order_acquire));
        return YES;
    }
    gPausedBySN = NO;
    /*if (DBG_POLICY_ON) SNLOGFMT(@"[POLICY] requestApply -> none");*/
    return YES;
}

static BOOL sn_cb_confirmApplied(SNDuckMode mode, void *ctx) {
    return YES;
}

static void sn_cb_releaseState(SNDuckMode mode, BOOL pausedByUs, BOOL resumeOnCancel, void *ctx)
{
    if (gCurrentTxn.load(std::memory_order_acquire) == 0 &&
        gStartInFlightTxn.load(std::memory_order_acquire) == 0 &&
        ![SNCancellation isSpeaking]) {
        gDuckChainAlive = NO;
    }

    if (![SNCancellation isSpeaking] && sn_queue_count() == 0) {
        sn_idle_maybe_release_to_ringer_with_reason("DuckRelease");
    }
}

#pragma mark - Speak Start (hardened with full logging)

static inline void sn_snapshot_last_speak(NSString *title,
                                          NSString *msg,
                                          NSString *bcp47,
                                          NSString *appCtx)
{
    NSString *t = [title  copy];
    NSString *m = [msg    copy];
    NSString *b = [bcp47  copy];
    NSString *a = [appCtx copy];

    os_unfair_lock_lock(&gLastSpeakLock);
    NSString *oldT = gLastSpeakTitle;
    NSString *oldM = gLastSpeakMsg;
    NSString *oldB = gLastSpeakBCP47;
    NSString *oldA = gLastSpeakAppCtx;

    gLastSpeakTitle  = t;
    gLastSpeakMsg    = m;
    gLastSpeakBCP47  = b;
    gLastSpeakAppCtx = a;
    os_unfair_lock_unlock(&gLastSpeakLock);

    if (oldT) [oldT release];
    if (oldM) [oldM release];
    if (oldB) [oldB release];
    if (oldA) [oldA release];
}

static BOOL sn_handle_start_in_flight(NSString *title, NSString *msg, NSString *bcp47,
                                      NSString *appCtx, uint64_t txn)
{
    uint64_t ownerTxn = gStartInFlightTxn.load(std::memory_order_acquire);
    if (!ownerTxn || ownerTxn == txn) return NO;

    if (SN_PrefBoolFast(@"queueNotifications", NO)) {
        sn_queue_enqueue(title ?: @"", msg ?: @"", bcp47 ?: @"", appCtx ?: @"",
                         txn, "start-in-flight", ownerTxn);
        if (DBG_QUEUE_VERBOSE_ON) {
            SNLOGFMT(@"[QUEUE] enqueue | reason=start-in-flight ownerTxn=%llu txn=%llu",
                     (unsigned long long)ownerTxn,
                     (unsigned long long)txn);
        }
        sn_queue_progress_nudge_after_ms(kSNQueueProgressNudgeLongMs);
        return YES;
    }

    if (DBG_QUEUE_ON) {
        SNLOGFMT(@"[QUEUE] replace start | reason=queue-off ownerTxn=%llu txn=%llu",
                 (unsigned long long)ownerTxn,
                 (unsigned long long)txn);
    }
    SN_CancelAll("QueueOffStart");
    return NO;
}

static inline void sn_reserve_start_txn(uint64_t txn)
{
    gCurrentTxn.store(txn, std::memory_order_release);
    gStartInFlightTxn.store(txn, std::memory_order_release);
    gVolumeReleaseWaitTxn.store(0, std::memory_order_release);
}

static inline BOOL sn_start_txn_is_owned(uint64_t txn)
{
    return (txn != 0 &&
            gCurrentTxn.load(std::memory_order_acquire) == txn &&
            gStartInFlightTxn.load(std::memory_order_acquire) == txn);
}

static NSString *sn_a2dp_session_warmup_skip_reason(NSString **outPort,
                                                     BOOL *outPlaying,
                                                     BOOL *outOtherAudio,
                                                     BOOL *outHFP,
                                                     BOOL respectWarmWindow)
{
    if (outPort) *outPort = @"-";
    if (outPlaying) *outPlaying = NO;
    if (outOtherAudio) *outOtherAudio = NO;
    if (outHFP) *outHFP = NO;

    if ([SNCancellation isSpeaking]) return @"alreadySpeaking";

    AVAudioSessionRouteDescription *route = nil;
    NSString *port = @"-";
    BOOL hfp = NO;
    BOOL otherAudio = NO;
    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        route = session.currentRoute;
        AVAudioSessionPortDescription *output = route.outputs.firstObject;
        if (output.portType.length) port = output.portType;
        hfp = sn_route_has_HFP(route);
        otherAudio = session.isOtherAudioPlaying;
    } @catch (...) {
        return @"notA2DP";
    }

    BOOL playing = NO;
    @try { playing = sn_isPhoneMediaNowPlaying(); } @catch (...) {}

    if (outPort) *outPort = port;
    if (outPlaying) *outPlaying = playing;
    if (outOtherAudio) *outOtherAudio = otherAudio;
    if (outHFP) *outHFP = hfp;

    if (hfp) return @"hfp";
    if (SN_IsCarPlayRoute()) return @"car";
    if (route.outputs.count != 1 || ![port isEqualToString:AVAudioSessionPortBluetoothA2DP]) return @"notA2DP";
    if (SN_CallMonitorActive() || sn_callgate_should_block()) return @"call";
    if (!SN_ShouldSpeakNow()) return @"interruption";
    if (playing) return @"playing";
    if (otherAudio) return @"otherAudio";
    uint64_t warmUntilMS = gA2DPWarmUntilMS.load(std::memory_order_acquire);
    if (respectWarmWindow && warmUntilMS > SN_NowMS()) return @"warm";
    return nil;
}

static void sn_mark_a2dp_warm(uint64_t txn, const char *source)
{
    AVAudioSessionRouteDescription *route = nil;
    NSString *port = nil;
    @try {
        route = [AVAudioSession sharedInstance].currentRoute;
        port = route.outputs.firstObject.portType;
    } @catch (...) {}
    if (route.outputs.count != 1 ||
        ![port isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
        sn_route_has_HFP(route)) {
        return;
    }

    uint64_t warmUntilMS = SN_NowMS() + kSNA2DPWarmWindowMs;
    gA2DPWarmUntilMS.store(warmUntilMS, std::memory_order_release);
    if (DBG_ENGINE_VERBOSE_ON) {
        SNLOGFMT(@"[A2DP] warm state | txn=%llu warmUntil=%llu source=%s",
                 (unsigned long long)txn,
                 (unsigned long long)warmUntilMS,
                 (source ?: "unknown"));
    }
}

static void sn_abort_a2dp_warmup(uint64_t txn, const char *source, NSString *reason)
{
    if (!txn) return;
    gA2DPWarmupAbortedTxn.store(txn, std::memory_order_release);
    if (DBG_ENGINE_ON) {
        SNLOGFMT(@"[A2DP] abort | txn=%llu reason=%@",
                 (unsigned long long)txn,
                 (reason ?: @"cancel"));
    }
    SN_CancelAll(source ?: "A2DPWarmupAbort");
}

static BOOL sn_a2dp_warmup_route_is_still_valid(void)
{
    @try {
        AVAudioSessionRouteDescription *route = [AVAudioSession sharedInstance].currentRoute;
        NSString *port = route.outputs.firstObject.portType;
        return (route.outputs.count == 1 &&
                [port isEqualToString:AVAudioSessionPortBluetoothA2DP] &&
                !sn_route_has_HFP(route));
    } @catch (...) {
        return NO;
    }
}

static void sn_start_engine_speak_reserved(NSString *title, NSString *body, NSString *lang, uint64_t txn)
{
    // Re-arm timing and physical-button baseline at the actual engine start.
    sn_arm_speak_guard(sn_safe_len_for_guard(body ?: @""));
    BOOL accepted = [SNEngineAV speakTitle:title body:body lang:lang transaction:txn];
    if (DBG_ENGINE_ON) {
        NSUInteger chars = (title.length + body.length);
        SNLOGFMT(@"[ENGINE] start request | txn=%llu utterance=chars:%lu accepted=%d",
                 (unsigned long long)txn, (unsigned long)chars, (int)accepted);
    }
    if (accepted) {
        if (DBG_CANCEL_VERBOSE_ON) {
            SNLOGFMT(@"[CANCEL] volume physical armed | txn=%llu baseline=%.3f ensureTxn=0",
                     (unsigned long long)txn,
                     sSN_LastVol);
        }
        sn_schedule_post_start_volume_check(txn, sn_expected_tts_target_for_txn(txn));
    } else {
        sn_audit_record_engine_rejection(txn, [SNMediaControl lastOutputPortType]);
        sn_audit_emit_notif(txn);
        sn_audit_try_finalize_result(txn);
    }
}

static void sn_speak_reserved(NSString *title, NSString *body, NSString *lang, uint64_t txn)
{
    if (!sn_start_txn_is_owned(txn)) {
        if (DBG_QUEUE_ON) {
            SNLOGFMT(@"[QUEUE] stale start ignored | txn=%llu activeTxn=%llu startTxn=%llu",
                     (unsigned long long)txn,
                     (unsigned long long)gCurrentTxn.load(std::memory_order_acquire),
                     (unsigned long long)gStartInFlightTxn.load(std::memory_order_acquire));
        }
        return;
    }

    uint64_t ensureTxn = 0;
    if (sn_internal_volume_set_pending(&ensureTxn) && ensureTxn == txn) {
        uint64_t expectedWaitTxn = 0;
        if (gVolumeReleaseWaitTxn.compare_exchange_strong(expectedWaitTxn, txn,
                                                          std::memory_order_acq_rel,
                                                          std::memory_order_relaxed)) {
            if (DBG_VOL_VERBOSE_ON) {
                SNLOGFMT(@"[VOLUME] waiting for internal control release | txn=%llu ensureTxn=%llu",
                         (unsigned long long)txn,
                         (unsigned long long)ensureTxn);
            }
            NSString *deferredTitle = [title copy];
            NSString *deferredBody = [body copy];
            NSString *deferredLang = [lang copy];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(240 * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                uint64_t expectedTxn = txn;
                (void)gVolumeReleaseWaitTxn.compare_exchange_strong(expectedTxn, 0,
                                                                     std::memory_order_acq_rel,
                                                                     std::memory_order_relaxed);
                if (sn_start_txn_is_owned(txn)) {
                    sn_clear_internal_volume_state(txn, "pre-speech-release");
                    sn_speak_reserved(deferredTitle, deferredBody, deferredLang, txn);
                }
#if !__has_feature(objc_arc)
                [deferredTitle release];
                [deferredBody release];
                [deferredLang release];
#endif
            });
        }
        return;
    }

    NSString *port = nil;
    BOOL playing = NO;
    BOOL otherAudio = NO;
    BOOL hfp = NO;
    NSString *skipReason = sn_a2dp_session_warmup_skip_reason(&port, &playing, &otherAudio, &hfp, YES);
    BOOL callActive = SN_CallMonitorActive();
    BOOL callBlocked = sn_callgate_should_block();
    BOOL carRoute = SN_IsCarPlayRoute();
    BOOL speaking = [SNCancellation isSpeaking];
    uint64_t activeTxn = gCurrentTxn.load(std::memory_order_acquire);
    BOOL newerTxn = (activeTxn != 0 && activeTxn != txn);
    uint64_t nowMS = SN_NowMS();
    uint64_t warmUntilMS = gA2DPWarmUntilMS.load(std::memory_order_acquire);
    uint64_t warmRemainingMS = (warmUntilMS > nowMS) ? (warmUntilMS - nowMS) : 0;
    if (DBG_ENGINE_VERBOSE_ON) {
        SNLOGFMT(@"[A2DP] gate | txn=%llu route=%@ playing=%d otherAudio=%d hfp=%d car=%d call=%d speaking=%d owner=%d newerTxn=%d warmRemainingMs=%llu",
                 (unsigned long long)txn,
                 (port.length ? port : @"-"),
                 (int)playing,
                 (int)otherAudio,
                 (int)hfp,
                 (int)carRoute,
                 (int)(callActive || callBlocked),
                 (int)speaking,
                 (int)sn_start_txn_is_owned(txn),
                 (int)newerTxn,
                 (unsigned long long)warmRemainingMS);
    }
    if (skipReason.length) {
        if (DBG_ENGINE_VERBOSE_ON) {
            SNLOGFMT(@"[A2DP] skip | txn=%llu reason=%@", (unsigned long long)txn, skipReason);
        }
        sn_start_engine_speak_reserved(title, body, lang, txn);
        return;
    }

    if (gA2DPSessionWarmupPendingTxn.load(std::memory_order_acquire) == txn) {
        return;
    }
    if (gA2DPSessionWarmupAttemptedTxn.load(std::memory_order_acquire) == txn) {
        sn_start_engine_speak_reserved(title, body, lang, txn);
        return;
    }
    gA2DPSessionWarmupAttemptedTxn.store(txn, std::memory_order_release);

    if (DBG_ENGINE_VERBOSE_ON) {
        SNLOGFMT(@"[A2DP] warmup plan | txn=%llu route=%@ duration=400ms kind=zeros",
                 (unsigned long long)txn, port);
    }

    BOOL prepared = [SNEngineAV prepareVoicePromptForRoute:SNMixRouteBluetooth duckOthers:NO];
    if (!prepared) {
        SNLOGFMT(@"[A2DP] failure | txn=%llu stage=prepare error=session", (unsigned long long)txn);
        sn_start_engine_speak_reserved(title, body, lang, txn);
        return;
    }

    BOOL active = [SNEngineAV activateForTTS];
    if (DBG_ENGINE_VERBOSE_ON) {
        SNLOGFMT(@"[A2DP] session | txn=%llu prepared=%d active=%d", (unsigned long long)txn, (int)prepared, (int)active);
    }
    if (!active) {
        SNLOGFMT(@"[A2DP] failure | txn=%llu stage=activate error=session", (unsigned long long)txn);
        sn_start_engine_speak_reserved(title, body, lang, txn);
        return;
    }

    gA2DPSessionWarmupPendingTxn.store(txn, std::memory_order_release);
    NSString *deferredTitle = [title copy];
    NSString *deferredBody = [body copy];
    NSString *deferredLang = [lang copy];
    NSUInteger bufferBytes = 0;
    double sampleRate = 0;
    BOOL playerInitialized = NO;
    BOOL preparedToPlay = NO;
    BOOL playerPlaying = NO;
    NSString *failureStage = nil;
    NSString *failureError = nil;
    BOOL playerStarted = [SNEngineAV beginA2DPWarmupForTransaction:txn
                                                           duration:((NSTimeInterval)kSNA2DPAudioPreRollMs / 1000.0)
                                                        bufferBytes:&bufferBytes
                                                         sampleRate:&sampleRate
                                                         playerInitialized:&playerInitialized
                                                            preparedToPlay:&preparedToPlay
                                                               playerPlaying:&playerPlaying
                                                               startGuard:^BOOL(uint64_t guardedTxn) {
                                                                   NSString *guardPort = nil;
                                                                   BOOL guardPlaying = NO;
                                                                   BOOL guardOtherAudio = NO;
                                                                   BOOL guardHFP = NO;
                                                                   return (sn_start_txn_is_owned(guardedTxn) &&
                                                                           !sn_a2dp_session_warmup_skip_reason(&guardPort,
                                                                                                               &guardPlaying,
                                                                                                               &guardOtherAudio,
                                                                                                               &guardHFP,
                                                                                                               NO).length);
                                                               }
                                                          startCompletion:^(uint64_t startedTxn,
                                                                            BOOL initialized,
                                                                            BOOL preparedForPlay,
                                                                            BOOL playResult,
                                                                            BOOL isPlaying,
                                                                            NSUInteger startedBytes,
                                                                            double startedSampleRate,
                                                                            NSString *startFailureStage,
                                                                            NSString *startFailureError) {
                                                              if (startedTxn != txn) return;
                                                              if (DBG_ENGINE_VERBOSE_ON) {
                                                                  SNLOGFMT(@"[A2DP] player init | txn=%llu ok=%d prepared=%d bytes=%lu error=%@",
                                                                           (unsigned long long)txn,
                                                                           (int)initialized,
                                                                           (int)preparedForPlay,
                                                                           (unsigned long)startedBytes,
                                                                           (startFailureError ?: @"-"));
                                                                  SNLOGFMT(@"[A2DP] player play | txn=%llu result=%d isPlaying=%d",
                                                                           (unsigned long long)txn,
                                                                           (int)playResult,
                                                                           (int)isPlaying);
                                                              }
                                                              if (playResult && isPlaying) {
                                                                  if (DBG_ENGINE_VERBOSE_ON) {
                                                                      SNLOGFMT(@"[A2DP] warmup session | txn=%llu prepared=%d active=1",
                                                                               (unsigned long long)txn,
                                                                               (int)preparedForPlay);
                                                                      SNLOGFMT(@"[A2DP] warmup audio start | txn=%llu playerStarted=1 bytes=%lu sampleRate=%.0f",
                                                                               (unsigned long long)txn,
                                                                               (unsigned long)startedBytes,
                                                                               startedSampleRate);
                                                                  }
                                                                  SNLOGFMT(@"[A2DP] pre-roll | txn=%llu duration=400ms",
                                                                           (unsigned long long)txn);
                                                              } else {
                                                                  SNLOGFMT(@"[A2DP] failure | txn=%llu stage=%@ error=%@",
                                                                           (unsigned long long)txn,
                                                                           (startFailureStage ?: @"player"),
                                                                           (startFailureError ?: @"unknown"));
                                                              }
                                                          }
                                                       failureStage:&failureStage
                                                       failureError:&failureError
                                                         completion:^(uint64_t completedTxn,
                                                                      BOOL completed,
                                                                      NSString *reason,
                                                                      uint64_t elapsedMS) {
        if (completedTxn != txn) return;
        uint64_t expectedPendingTxn = txn;
        (void)gA2DPSessionWarmupPendingTxn.compare_exchange_strong(expectedPendingTxn, 0,
                                                                     std::memory_order_acq_rel,
                                                                     std::memory_order_relaxed);

        if (!sn_start_txn_is_owned(txn)) {
            NSString *reason = (gCurrentTxn.load(std::memory_order_acquire) != txn) ? @"newTxn" : @"cancel";
            if (DBG_ENGINE_ON) {
                SNLOGFMT(@"[A2DP] abort | txn=%llu reason=%@", (unsigned long long)txn, reason);
            }
        } else {
            NSString *currentPort = nil;
            BOOL currentPlaying = NO;
            BOOL currentOtherAudio = NO;
            BOOL currentHFP = NO;
            NSString *currentSkip = sn_a2dp_session_warmup_skip_reason(&currentPort,
                                                                         &currentPlaying,
                                                                         &currentOtherAudio,
                                                                         &currentHFP,
                                                                         NO);
            if (currentSkip.length) {
                if (DBG_ENGINE_VERBOSE_ON) {
                    SNLOGFMT(@"[A2DP] abort detail | txn=%llu reason=%@ route=%@ playing=%d otherAudio=%d hfp=%d",
                             (unsigned long long)txn,
                             currentSkip,
                             currentPort,
                             (int)currentPlaying,
                             (int)currentOtherAudio,
                             (int)currentHFP);
                }
                if (![currentSkip isEqualToString:@"alreadySpeaking"]) {
                    sn_abort_a2dp_warmup(txn, "A2DPWarmupAbort", currentSkip);
                }
            } else if (!completed) {
                if (DBG_ENGINE_ON) {
                    SNLOGFMT(@"[A2DP] failure | txn=%llu stage=player error=%@",
                             (unsigned long long)txn,
                             (reason ?: @"unknown"));
                }
                sn_start_engine_speak_reserved(deferredTitle, deferredBody, deferredLang, txn);
            } else {
                sn_mark_a2dp_warm(txn, "preroll");
                if (DBG_ENGINE_VERBOSE_ON) {
                    SNLOGFMT(@"[A2DP] warmup audio finish | txn=%llu elapsedMs=%llu",
                             (unsigned long long)txn,
                             (unsigned long long)elapsedMS);
                    SNLOGFMT(@"[A2DP] warmup complete | txn=%llu elapsedMs=%llu routeStillA2DP=1",
                             (unsigned long long)txn,
                             (unsigned long long)elapsedMS);
                }
                sn_start_engine_speak_reserved(deferredTitle, deferredBody, deferredLang, txn);
            }
        }
#if !__has_feature(objc_arc)
        [deferredTitle release];
        [deferredBody release];
        [deferredLang release];
#endif
    }];

    if (!playerStarted) {
        uint64_t expectedPendingTxn = txn;
        (void)gA2DPSessionWarmupPendingTxn.compare_exchange_strong(expectedPendingTxn, 0,
                                                                     std::memory_order_acq_rel,
                                                                     std::memory_order_relaxed);
#if !__has_feature(objc_arc)
        [deferredTitle release];
        [deferredBody release];
        [deferredLang release];
#endif
        sn_start_engine_speak_reserved(title, body, lang, txn);
        return;
    }

}

static void sn_start_duck_chain_and_tts(NSString *title, NSString *msg, NSString *bcp47,
                                        NSString *appCtx, uint64_t txn)
{
    sn_cancel_idle_cleanup_timer();
    if (!txn) txn = sn_new_txn();

    NSString *useBCP47 = nil;
    NSString *explicitVoice = sn_explicit_voice_language();
    if (explicitVoice.length) {
        useBCP47 = explicitVoice;
    } else if (bcp47.length) {
        useBCP47 = [SNStringUtils clampAllowedBCP47:bcp47];
    } else {
        useBCP47 = [SNStringUtils systemPrimaryBCP47];
    }

    if (sn_handle_start_in_flight(title, msg, useBCP47, appCtx, txn)) return;

    sn_snapshot_last_speak(title, msg, useBCP47, appCtx);

    gPokeScheduled.store(false, std::memory_order_release);

    NSString *port = [SNMediaControl lastOutputPortType] ?: @"";
    BOOL npPlaying = NO;
    { NSString *bid=nil,*name=nil,*r=nil; SNAudioNowPlayingProbe(&bid,&name,&npPlaying,&r); }

    BOOL continuingQueuedChain = (gQueueDrainInFlight.load(std::memory_order_acquire) &&
                                  gDuckMgr && gDuckChainAlive);
    BOOL inheritedPlaybackChain = NO;
    if (continuingQueuedChain) {
        inheritedPlaybackChain = sn_resume_state_handoff_to_queued_txn(txn);
    } else {
        sn_resume_state_clear_for_new_txn(txn);
        NSString *pbid=nil,*pname=nil,*proute=nil; BOOL pplaying=NO;
        SNAudioNowPlayingProbe(&pbid,&pname,&pplaying,&proute);
        if (gPreNowPlayingBID) { [gPreNowPlayingBID release]; gPreNowPlayingBID = nil; }
        gPreWasPlaying = pplaying;
        gPreNowPlayingBID = (pbid.length ? [pbid copy] : nil);
        sn_audit_playback_snapshot(txn, pname, pbid, pplaying);
    }

    BOOL phonePlayback = sn_isPhoneMediaNowPlaying();
    BOOL pausePref = gPrefPauseToggle ? YES : NO;
    BOOL effPause = (pausePref && phonePlayback);
    if (!effPause && !inheritedPlaybackChain) sn_audit_resume_not_needed(txn);
    const char *modeStr = effPause ? "pause" : "none";

    if (effPause ? DBG_POLICY_ON : DBG_POLICY_VERBOSE_ON) {
        SNLOGFMT(@"[POLICY] decide pausePref=%d phonePlayback=%d route=%@ -> mode=%s",
                 (int)pausePref, (int)phonePlayback, (port.length ? port : @"-"), modeStr);
    }

    gLastDuckMode = effPause ? SNDuckModePause : SNDuckModeDuck;
    sn_audit_update(txn, @{
        @"policy": (effPause ? @"pause" : @"none"),
        @"queue": (continuingQueuedChain ? @"dequeued" : @"direct"),
        @"route": (port.length ? port : @"-")
    });

    SNDuckConfig cfg;
    cfg.preRollMs      = kSNPreRollMs;
    cfg.confirmMs      = kSNFailSafeConfirmMs;
    cfg.postRollMs     = kSNPostRollMs;
    cfg.mode           = gLastDuckMode;
    cfg.targetDb       = 0;
    cfg.resumeOnCancel = YES;

    SNDuckCallbacks cb;
    cb.requestApply    = &sn_cb_requestApply;
    cb.confirmApplied  = &sn_cb_confirmApplied;
    cb.releaseState    = &sn_cb_releaseState;

    NSString *speakTitle = @"";
    NSString *speakBody  = msg ?: @"";

    // FAST REUSE PATH
    if (gDuckMgr && gDuckChainAlive) {
        if ([SNCancellation isSpeaking]) {
                BOOL qOn = SN_PrefBoolFast(@"queueNotifications", NO);
                if (qOn) {
                    sn_queue_enqueue(title ?: @"", msg ?: @"", useBCP47 ?: @"", appCtx ?: @"",
                                     txn, "chain-speaking", gCurrentTxn.load(std::memory_order_acquire));
                    if (DBG_POLICY_ON) SNLOGFMT(@"[POLICY] enqueue (speaking) | app=%@", SN_AppLabelForLog(appCtx, nil));
                    sn_queue_progress_nudge_after_ms(kSNQueueProgressNudgeLongMs);
                    return;
                } else {
                    SN_CancelAll("QueueOff");
                    if (DBG_POLICY_ON) SNLOGFMT(@"[POLICY] queue OFF -> interrupt current and speak now");
                    sn_start_duck_chain_and_tts(title, msg, useBCP47, appCtx, txn);
                    return;
                }
        }
        if (sn_audit_record_direct(txn)) sn_audit_emit_notif(txn);
        if (gLastDuckMode == SNDuckModePause) {
            (void)[SNEngineAV activateForTTSWithDuck:NO];
        }
        sn_reserve_start_txn(txn);
        sn_apply_tts_volume_policy(txn);

        gCancelPostedTxn.store(0, std::memory_order_release);
        gSpeakAllowedCtx.store(true, std::memory_order_release);
        sn_finish_once_reset(txn);
        sn_reset_grace_armed();

        NSString *keyTitle = title ?: @"";
        NSString *keyBody  = [SNStringUtils sanitizeForTTS:(msg ?: @"")];
	        sn_mark_burst_spoken_nowForKey_sync(sn_make_burst_key(appCtx, keyTitle, keyBody));
	
	        sn_log_speak(speakTitle, speakBody, useBCP47);
	        sn_increment_spoken_count_for_app(appCtx);
        gDidReleaseToRinger.store(false, std::memory_order_release);
        gBurstDropSinceLastSpeak.store(false, std::memory_order_release);

        if ([SNCancellation isSpeaking]) {
            g_sn_postSpeakHold = YES;
        }
        if (g_sn_postSpeakHold) {
            if (DBG_POLICY_ON) SNLOGFMT(@"[POLICY] post-speak hold -> soft debounce");
            int dms = (int)sn_pref_debounce_ms();
            g_sn_postSpeakHold = NO;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dms * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                BOOL needSettle = NO;
                @try {
                    if (sn_isPhoneMediaNowPlaying()) {
                        [SNMediaControl pauseIfPlayingPhoneMedia];
                        needSettle = YES;
                    }
                } @catch (...) {}
                if (needSettle) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSNPauseSettleMs * NSEC_PER_MSEC)),
                                   dispatch_get_main_queue(), ^{
                        sn_speak_reserved(speakTitle, speakBody, useBCP47, txn);
                    });
                } else {
                    sn_speak_reserved(speakTitle, speakBody, useBCP47, txn);
                }
            });
        } else {
            BOOL needSettle = NO;
            @try {
                if (sn_isPhoneMediaNowPlaying()) {
                    [SNMediaControl pauseIfPlayingPhoneMedia];
                    needSettle = YES;
                }
            } @catch (...) {}
            if (needSettle) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSNPauseSettleMs * NSEC_PER_MSEC)),
                               dispatch_get_main_queue(), ^{
                    sn_speak_reserved(speakTitle, speakBody, useBCP47, txn);
                });
            } else {
                sn_speak_reserved(speakTitle, speakBody, useBCP47, txn);
            }
        }
        if (sn_queue_count() > 0 && ![SNCancellation isSpeaking]) {
            if (DBG_POLICY_VERBOSE_ON) SNLOGFMT(@"[POLICY] reuse fast-chain (active=%d post=%d)", gDuckMgr.activeDuck, gDuckMgr.inPostRoll);
            return;
        }

        return;
    }

    // START NEW CHAIN
    if (sn_audit_record_direct(txn)) sn_audit_emit_notif(txn);
    sn_clear_duck_manager_after_abort();
    sn_reserve_start_txn(txn);
    gCancelPostedTxn.store(0, std::memory_order_release);
    gSpeakAllowedCtx.store(true, std::memory_order_release);
    gDuckMgr = [[SNDuckManager alloc] initWithConfig:cfg callbacks:cb ctxPtr:NULL];
    gDuckChainAlive = YES;

    [gDuckMgr startWithReady:^{
        if (!sn_start_txn_is_owned(txn)) {
            if (DBG_QUEUE_ON) {
                SNLOGFMT(@"[QUEUE] stale start ignored | txn=%llu activeTxn=%llu startTxn=%llu",
                         (unsigned long long)txn,
                         (unsigned long long)gCurrentTxn.load(std::memory_order_acquire),
                         (unsigned long long)gStartInFlightTxn.load(std::memory_order_acquire));
            }
            return;
        }
        if (DBG_POLICY_ON) {
            SNLOGFMT(@"[POLICY] start ok | txn=%llu mode=%s route=%@ app=%@ playing=%@",
                     (unsigned long long)txn, modeStr,
                     (port.length ? port : @"-"),
                     SN_AppLabelForLog(appCtx, nil),
                     (npPlaying ? @"YES" : @"NO"));
        }
        if (gLastRouteAtStart) { [gLastRouteAtStart release]; gLastRouteAtStart = nil; }
        gLastRouteAtStart = (port.length ? [port copy] : nil);
        gResumeAttempted.store(false, std::memory_order_release);
        gDidReleaseToRinger.store(false, std::memory_order_release);
        if (effPause) {
            (void)[SNEngineAV activateForTTSWithDuck:NO];
        }
        sn_apply_tts_volume_policy(txn);
        gResumeLogged.store(false, std::memory_order_release);
        sn_finish_once_reset(txn);
        sn_reset_grace_armed();

	        sn_log_speak(speakTitle, speakBody, useBCP47);
	        sn_increment_spoken_count_for_app(appCtx);
	        NSString *keyTitle2 = title ?: @"";
        NSString *keyBody2  = [SNStringUtils sanitizeForTTS:(msg ?: @"")];
        NSString *burstKey2 = sn_make_burst_key(appCtx, keyTitle2, keyBody2);
        sn_mark_burst_spoken_nowForKey_sync(burstKey2);

        gDidReleaseToRinger.store(false, std::memory_order_release);
        gBurstDropSinceLastSpeak.store(false, std::memory_order_release);

        if ([SNCancellation isSpeaking]) {
            g_sn_postSpeakHold = YES;
        }
        sn_speak_reserved(speakTitle, speakBody, useBCP47, txn);
    } abort:^{
        if (!sn_start_txn_is_owned(txn)) return;
        uint64_t expectedStartTxn = txn;
        (void)gStartInFlightTxn.compare_exchange_strong(expectedStartTxn, 0, std::memory_order_acq_rel);
        if (DBG_POLICY_ON) {
            SNLOGFMT(@"[POLICY] abort | txn=%llu", (unsigned long long)txn);
            SNLOGFMT(@"[POLICY] failed start mode=%s route=%@ app=%@ playing=%@",
                     modeStr,
                     (port.length ? port : @"-"),
                     SN_AppLabelForLog(appCtx, nil),
                     (npPlaying ? @"YES" : @"NO"));
        }
        gQueueDrainInFlight.store(false, std::memory_order_release);
        gDuckChainAlive = NO;
        NSUInteger pending = sn_queue_count();
        BOOL queueCanContinue = (pending > 0 && SN_PrefBoolFast(@"queueNotifications", NO));
        BOOL deferredRestore = (queueCanContinue && sn_volume_restore_defer_for_queue(txn, pending));
        if (!deferredRestore) {
            sn_volume_restore_if_terminal(txn, YES);
        }
        uint64_t expectedCurrentTxn = txn;
        (void)gCurrentTxn.compare_exchange_strong(expectedCurrentTxn, 0, std::memory_order_acq_rel);
        gSpeakAllowedCtx.store(false, std::memory_order_release);
        if (![SNCancellation isSpeaking]) {
            BOOL startedNext = NO;
            if (sn_queue_count() > 0) {
                startedNext = sn_try_speak_next_from_queue("start-abort");
            } else {
                sn_schedule_idle_session_cleanup_ms(sn_idle_ms_for_current_route());
            }
            if (deferredRestore && !startedNext) {
                sn_volume_restore_if_terminal(txn, YES);
            }
        }
    }];
}


#pragma mark - Teardown / Finish

static void finishWork(void)
{
    if (sn_queue_transition_pending_now()) return;

    @try {
        /* EngineAV handles teardown via keepalive */
    } @catch (...) {}

    sn_mark_tts_end_now();
    g_snPromptDidStart = NO;

    if (gDuckMgr) {
        @try { [gDuckMgr noteTTSEndedCancelled:NO]; } @catch (...) {}
    }
    gDuckChainAlive = NO;
    bool last = (sn_queue_count() == 0);
    gDeferReleaseForLast.store(last, std::memory_order_release);
    gCurrentTxn.store(0, std::memory_order_release);
    gSpeakAllowedCtx.store(false, std::memory_order_release);
    g_snPromptDidStart = NO;

    uint32_t idleMs = sn_idle_ms_for_current_route();
    if (idleMs == 0 && ![SNCancellation isSpeaking] && sn_queue_count() == 0) {
        sn_idle_maybe_release_to_ringer_with_reason("FinishImmediate");
        return;
    }
    sn_schedule_idle_session_cleanup_ms(idleMs);
}

#pragma mark - Release Alerts Constants

static NSString * const kReleaseEnabledKey = @"releaseAlertsEnabled";
static NSString * const kReleaseTokenKey = @"releaseGitHubToken";
static NSString * const kReleaseLastCheckKey = @"releaseLastCheckAt";
static NSString * const kReleaseNextCheckKey = @"releaseNextCheckAt";
static NSString * const kReleaseLastSeenTagKey = @"releaseLastSeenTag";
static NSString * const kReleaseLastSeenBuildIDKey = @"releaseLastSeenBuildID";
static NSString * const kReleaseLastNotifiedTagKey = @"releaseLastNotifiedTag";
static NSString * const kReleaseLastNotifiedBuildIDKey = @"releaseLastNotifiedBuildID";
static NSString * const kReleaseAvailableBuildIDKey = @"releaseAvailableBuildID";
static NSString * const kReleaseLastPublishAttemptBuildIDKey = @"releaseLastPublishAttemptBuildID";
static NSString * const kReleaseQueuedBuildIDKey = @"releaseQueuedBuildID";
static NSString * const kReleaseQueuedTagKey = @"releaseQueuedTag";
static NSString * const kReleaseQueuedURLKey = @"releaseQueuedURL";
static NSString * const kReleaseETagKey = @"releaseETag";
static NSString * const kReleaseLastURLKey = @"releaseLastReleaseURL";
static NSString * const kReleaseLastErrorKey = @"releaseLastError";
static NSString * const kReleaseLastStatusCodeKey = @"releaseLastStatusCode";
static NSString * const kReleaseTokenAlertShownKey = @"releaseTokenAlertShown";
static NSString * const kReleaseTokenAlertPendingKey = @"releaseTokenAlertPending";
static NSString * const kReleaseTokenAlertKindKey = @"releaseTokenAlertKind";
static NSString * const kReleaseCurrentInstallIDKey = @"releaseCurrentInstallID";
static NSString * const kReleaseLastProcessedInstallIDKey = @"releaseLastProcessedInstallID";
static NSString * const kReleaseManualRequestIDKey = @"releaseManualCheckRequestID";
static NSString * const kReleaseManualResultStatusKey = @"releaseManualCheckResultStatus";
static NSString * const kReleaseManualResultTagKey = @"releaseManualCheckResultTag";
static NSString * const kReleaseManualResultURLKey = @"releaseManualCheckResultURL";
static NSString * const kReleaseManualResultMessageKey = @"releaseManualCheckResultMessage";
static NSString * const kReleaseManualResultRequestIDKey = @"releaseManualCheckResultRequestID";
static NSString * const kReleaseManualResultTimestampKey = @"releaseManualCheckResultTimestamp";
static NSString * const kReleaseTokenValidationRequestIDKey = @"releaseTokenValidationRequestID";
static NSString * const kReleaseTokenValidationStatusKey = @"releaseTokenValidationStatus";
static NSString * const kReleaseTokenValidationResultStatusKey = @"releaseTokenValidationResultStatus";
static NSString * const kReleaseTokenValidationResultRequestIDKey = @"releaseTokenValidationResultRequestID";

static NSString * const kReleaseRepo = @"Selandros/SpeakNotification16";
static NSString * const kReleaseSectionID = @"com.apple.Preferences";
static NSString * const kReleaseInstalledVersion = @"2.1.4";
static NSString * const kReleaseAssetPrefix = @"com.selandros.speaknotification16_";
static NSString * const kReleaseAssetSuffix = @"_iphoneos-arm64.deb";
static NSString * const kReleaseAPIURLString = @"https://api.github.com/repos/Selandros/SpeakNotification16/releases/latest";
static NSString * const kReleaseBulletinPrefix = @"SpeakNotification16ReleaseAlert.";
static NSString * const kReleaseBulletinCategory = @"SpeakNotification16ReleaseAlert";
static NSString * const kReleaseTokenBulletinPrefix = @"SpeakNotification16TokenAlert.";
static NSString * const kReleaseTokenBulletinCategory = @"SpeakNotification16TokenAlert";

static const NSTimeInterval kReleaseInitialDelay = 45.0;
static const NSTimeInterval kReleaseNormalInterval = 12.0 * 60.0 * 60.0;
static const NSTimeInterval kReleaseNetworkRetry = 2.0 * 60.0 * 60.0;
// This mirrors the verified iOS 16.1 interrupt-path destination selected by BulletinBoard.
static const unsigned long long kSNReleaseFallbackDestinations = 0xE;

typedef NS_ENUM(NSUInteger, SNReleaseCheckMode) {
    SNReleaseCheckModeNormal = 0,
    SNReleaseCheckModeInstallBaseline = 1,
    SNReleaseCheckModeTokenValidation = 2,
};

#pragma mark - Release Alerts State

static dispatch_queue_t gReleaseQueue = NULL;
static dispatch_source_t gReleaseTimer = NULL;
static dispatch_source_t gReleaseFlushRetryTimer = NULL;
static unsigned int gReleaseFlushRetryAttempt = 0;
static std::atomic_bool gReleaseDebug{false};
static std::atomic_bool gReleaseCheckInFlight{false};
static std::atomic_bool gReleaseHasPending{false};
static std::atomic_bool gReleaseFlushScheduled{false};
static std::atomic_bool gReleasePublishActive{false};
static os_unfair_lock gReleasePendingLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock gReleaseServerLock = OS_UNFAIR_LOCK_INIT;
static BBBulletinRequest *gPendingUpdate = nil;
static BBBulletinRequest *gPendingToken = nil;
static BBBulletinRequest *gPublishingBulletin = nil;
static id gReleaseBBServer = nil;
static id gReleaseBBProvider = nil;
static BOOL gReleaseBBProviderSupportsAddDestinations = NO;
static std::atomic_uint gReleaseBBProviderRetryStage{0};
static NSString *gReleaseLastToken = nil;
static BOOL gReleaseLastEnabled = YES;
static BOOL gReleasePrefsSnapshotValid = NO;
static std::atomic<unsigned long long> gReleaseDestinations{0};
static char gReleaseBBQueueSpecificKey;

#define RELEASE_LOG(fmt, ...) do { \
    if (gReleaseDebug.load(std::memory_order_acquire)) { \
        SNLOGFMT((fmt), ##__VA_ARGS__); \
    } \
} while (0)

#define RELEASE_LOG_VERBOSE(fmt, ...) do { \
    if (gReleaseDebug.load(std::memory_order_acquire) && (gDebugLogs || DEBUG_RELEASE_VERBOSE)) { \
        SNLOGFMT((fmt), ##__VA_ARGS__); \
    } \
} while (0)

static void sn_release_schedule_locked(NSTimeInterval delay, NSString *reason);
static void sn_release_schedule_install_baseline_locked(NSTimeInterval delay);
static void sn_release_perform_check_locked(BOOL force,
                                            NSString *manualRequestID,
                                            SNReleaseCheckMode mode);
static BOOL sn_release_request_cached_flush(NSString *source);
static void sn_release_schedule_flush_retry_locked(void);
static void sn_release_cancel_flush_retry_locked(NSString *reason);

#pragma mark - Release Alerts Preferences and URL Validation

static BOOL sn_release_is_springboard(void)
{
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSString *processName = NSProcessInfo.processInfo.processName ?: @"";
    return [bundleID isEqualToString:@"com.apple.springboard"] ||
           [processName isEqualToString:@"SpringBoard"];
}

static NSUserDefaults *sn_release_defaults(void)
{
    return [[[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite] autorelease];
}

static BOOL sn_release_enabled(NSUserDefaults *defs)
{
    id value = [defs objectForKey:kReleaseEnabledKey];
    return [value isKindOfClass:NSNumber.class] ? [value boolValue] : YES;
}

static NSString *sn_release_token(NSUserDefaults *defs)
{
    NSString *value = [defs stringForKey:kReleaseTokenKey];
    if (![value isKindOfClass:NSString.class]) return @"";
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static void sn_release_reload_debug(void)
{
    NSUserDefaults *defs = sn_release_defaults();
    gReleaseDebug.store([defs boolForKey:@"debugLoggingEnabled"], std::memory_order_release);
}

static BOOL sn_release_allowed_api_url(NSURL *url)
{
    if (![url isKindOfClass:NSURL.class]) return NO;
    if (![url.scheme.lowercaseString isEqualToString:@"https"]) return NO;
    if (![url.host.lowercaseString isEqualToString:@"api.github.com"]) return NO;
    if (url.port || url.user.length > 0 || url.password.length > 0) return NO;
    return [url.path isEqualToString:@"/repos/Selandros/SpeakNotification16/releases/latest"];
}

static BOOL sn_release_allowed_release_url(NSURL *url)
{
    if (![url isKindOfClass:NSURL.class]) return NO;
    if (![url.scheme.lowercaseString isEqualToString:@"https"]) return NO;
    if (![url.host.lowercaseString isEqualToString:@"github.com"]) return NO;
    if (url.port || url.user.length > 0 || url.password.length > 0) return NO;
    return [url.path hasPrefix:@"/Selandros/SpeakNotification16/releases/"];
}

@interface SNReleaseSessionDelegate : NSObject <NSURLSessionTaskDelegate>
@end

@implementation SNReleaseSessionDelegate

- (void)URLSession:(__unused NSURLSession *)session
              task:(__unused NSURLSessionTask *)task
willPerformHTTPRedirection:(__unused NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler
{
    BOOL allowed = sn_release_allowed_api_url(request.URL);
    if (!allowed) {
        RELEASE_LOG(@"[RELEASE] redirect blocked | host=%@", request.URL.host ?: @"-");
    }
    completionHandler(allowed ? request : nil);
}

@end

static NSString *sn_release_response_etag(NSHTTPURLResponse *response)
{
    for (id key in response.allHeaderFields) {
        if ([key isKindOfClass:NSString.class] &&
            [(NSString *)key caseInsensitiveCompare:@"ETag"] == NSOrderedSame) {
            id value = response.allHeaderFields[key];
            return [value isKindOfClass:NSString.class] ? value : nil;
        }
    }
    return nil;
}

static NSString *sn_release_asset_timestamp(NSDictionary *asset)
{
    NSString *updatedAt = [asset[@"updated_at"] isKindOfClass:NSString.class]
        ? asset[@"updated_at"] : nil;
    if (updatedAt.length > 0) return updatedAt;
    NSString *createdAt = [asset[@"created_at"] isKindOfClass:NSString.class]
        ? asset[@"created_at"] : nil;
    return createdAt.length > 0 ? createdAt : nil;
}

static NSString *sn_release_version_from_tag(NSString *tag)
{
    if (![tag isKindOfClass:NSString.class]) return nil;
    NSString *value = [tag stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([value hasPrefix:@"v"] || [value hasPrefix:@"V"]) value = [value substringFromIndex:1];
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@"."];
    if (parts.count != 3) return nil;
    for (NSString *part in parts) {
        if (part.length == 0 || (part.length > 1 && [part hasPrefix:@"0"])) return nil;
        if ([[part stringByTrimmingCharactersInSet:NSCharacterSet.decimalDigitCharacterSet] length] != 0) return nil;
    }
    return value;
}

static BOOL sn_release_compare_versions(NSString *left,
                                        NSString *right,
                                        NSComparisonResult *result)
{
    NSArray<NSString *> *leftParts = [left componentsSeparatedByString:@"."];
    NSArray<NSString *> *rightParts = [right componentsSeparatedByString:@"."];
    if (leftParts.count != 3 || rightParts.count != 3) return NO;
    for (NSUInteger index = 0; index < 3; index++) {
        long long leftValue = [leftParts[index] longLongValue];
        long long rightValue = [rightParts[index] longLongValue];
        if (leftValue < rightValue) {
            if (result) *result = NSOrderedAscending;
            return YES;
        }
        if (leftValue > rightValue) {
            if (result) *result = NSOrderedDescending;
            return YES;
        }
    }
    if (result) *result = NSOrderedSame;
    return YES;
}

static NSString *sn_release_expected_asset_name(NSString *releaseVersion)
{
    if (releaseVersion.length == 0) return nil;
    return [NSString stringWithFormat:@"%@%@%@",
            kReleaseAssetPrefix, releaseVersion, kReleaseAssetSuffix];
}

static NSDictionary *sn_release_matching_asset(NSArray *assets, NSString *releaseVersion)
{
    if (![assets isKindOfClass:NSArray.class]) return nil;
    NSString *expectedName = sn_release_expected_asset_name(releaseVersion);
    if (expectedName.length == 0) return nil;
    NSDictionary *match = nil;
    for (id item in assets) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *asset = (NSDictionary *)item;
        NSString *name = [asset[@"name"] isKindOfClass:NSString.class] ? asset[@"name"] : nil;
        if (![name hasPrefix:kReleaseAssetPrefix] || ![name hasSuffix:kReleaseAssetSuffix]) continue;
        if (![name isEqualToString:expectedName]) continue;
        if (match) return nil;
        match = asset;
    }
    return match;
}

static uint64_t sn_release_build_hash(NSString *buildID)
{
    const unsigned char *bytes = (const unsigned char *)buildID.UTF8String;
    uint64_t hash = UINT64_C(1469598103934665603);
    if (!bytes) return hash;
    while (*bytes) {
        hash ^= (uint64_t)(*bytes++);
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

#pragma mark - Release Alerts Bulletin Publishing State

static NSString *sn_release_bulletin_type(BBBulletinRequest *bulletin)
{
    id value = [bulletin.context isKindOfClass:NSDictionary.class]
        ? bulletin.context[@"type"] : nil;
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSString *sn_release_bulletin_build_id(BBBulletinRequest *bulletin)
{
    id value = [bulletin.context isKindOfClass:NSDictionary.class]
        ? bulletin.context[@"buildID"] : nil;
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static void sn_release_update_pending_flag_locked(void)
{
    gReleaseHasPending.store(gPendingUpdate != nil || gPendingToken != nil,
                             std::memory_order_release);
}

static BOOL sn_release_enqueue_pending(BBBulletinRequest *bulletin)
{
    if (![bulletin isKindOfClass:BBBulletinRequest.class]) return NO;
    NSString *type = sn_release_bulletin_type(bulletin);
    BOOL queued = NO;
    os_unfair_lock_lock(&gReleasePendingLock);
    if ([type isEqualToString:@"update"]) {
        NSString *newBuildID = sn_release_bulletin_build_id(bulletin);
        NSString *oldBuildID = sn_release_bulletin_build_id(gPendingUpdate);
        if (newBuildID.length > 0 && ![newBuildID isEqualToString:oldBuildID]) {
            [gPendingUpdate release];
            gPendingUpdate = [bulletin retain];
            queued = YES;
        }
    } else if ([type isEqualToString:@"token"] && !gPendingToken) {
        gPendingToken = [bulletin retain];
        queued = YES;
    }
    sn_release_update_pending_flag_locked();
    os_unfair_lock_unlock(&gReleasePendingLock);
    return queued;
}

static void sn_release_requeue_pending(BBBulletinRequest *bulletin)
{
    if (![bulletin isKindOfClass:BBBulletinRequest.class]) return;
    NSString *type = sn_release_bulletin_type(bulletin);
    os_unfair_lock_lock(&gReleasePendingLock);
    if ([type isEqualToString:@"update"] && !gPendingUpdate) {
        gPendingUpdate = [bulletin retain];
    } else if ([type isEqualToString:@"token"] && !gPendingToken) {
        gPendingToken = [bulletin retain];
    }
    sn_release_update_pending_flag_locked();
    os_unfair_lock_unlock(&gReleasePendingLock);
}

static BBBulletinRequest *sn_release_take_next_pending(void)
{
    BBBulletinRequest *bulletin = nil;
    os_unfair_lock_lock(&gReleasePendingLock);
    if (gPendingUpdate) {
        bulletin = gPendingUpdate;
        gPendingUpdate = nil;
    } else if (gPendingToken) {
        bulletin = gPendingToken;
        gPendingToken = nil;
    }
    sn_release_update_pending_flag_locked();
    os_unfair_lock_unlock(&gReleasePendingLock);
    return bulletin;
}

static void sn_release_clear_pending_update_matching(NSString *buildID)
{
    os_unfair_lock_lock(&gReleasePendingLock);
    if (buildID.length > 0 && [sn_release_bulletin_build_id(gPendingUpdate) isEqualToString:buildID]) {
        [gPendingUpdate release];
        gPendingUpdate = nil;
    }
    sn_release_update_pending_flag_locked();
    os_unfair_lock_unlock(&gReleasePendingLock);
}

static void sn_release_clear_pending_token(void)
{
    os_unfair_lock_lock(&gReleasePendingLock);
    [gPendingToken release];
    gPendingToken = nil;
    sn_release_update_pending_flag_locked();
    os_unfair_lock_unlock(&gReleasePendingLock);
}

static BOOL sn_release_pending_update_matches(NSString *buildID)
{
    if (buildID.length == 0) return NO;
    os_unfair_lock_lock(&gReleasePendingLock);
    BOOL matches = [sn_release_bulletin_build_id(gPendingUpdate) isEqualToString:buildID];
    os_unfair_lock_unlock(&gReleasePendingLock);
    return matches;
}

static BOOL sn_release_build_is_published(NSUserDefaults *defs, NSString *buildID)
{
    return buildID.length > 0 &&
           [[defs stringForKey:kReleaseLastNotifiedBuildIDKey] isEqualToString:buildID];
}

static BOOL sn_release_build_is_queued(NSUserDefaults *defs, NSString *buildID)
{
    if (buildID.length == 0 || sn_release_build_is_published(defs, buildID)) return NO;
    return [[defs stringForKey:kReleaseQueuedBuildIDKey] isEqualToString:buildID] ||
           [[defs stringForKey:kReleaseLastPublishAttemptBuildIDKey] isEqualToString:buildID] ||
           sn_release_pending_update_matches(buildID);
}

static void sn_release_clear_persistent_queue(NSUserDefaults *defs, NSString *buildID)
{
    NSString *queued = [defs stringForKey:kReleaseQueuedBuildIDKey];
    if (buildID.length == 0 || [queued isEqualToString:buildID]) {
        [defs removeObjectForKey:kReleaseQueuedBuildIDKey];
        [defs removeObjectForKey:kReleaseQueuedTagKey];
        [defs removeObjectForKey:kReleaseQueuedURLKey];
    }
    NSString *attempted = [defs stringForKey:kReleaseLastPublishAttemptBuildIDKey];
    if (buildID.length == 0 || [attempted isEqualToString:buildID]) {
        [defs removeObjectForKey:kReleaseLastPublishAttemptBuildIDKey];
    }
}

static void sn_release_set_bool_if_supported(id object, NSString *selectorName, BOOL value)
{
    SEL selector = NSSelectorFromString(selectorName);
    if ([object respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
    }
}

static void sn_release_set_integer_if_supported(id object, NSString *selectorName, NSInteger value)
{
    SEL selector = NSSelectorFromString(selectorName);
    if ([object respondsToSelector:selector]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(object, selector, value);
    }
}

static void sn_release_set_object_if_supported(id object, NSString *selectorName, id value)
{
    SEL selector = NSSelectorFromString(selectorName);
    if ([object respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
    }
}

static BOOL sn_release_prepare_bulletin(BBBulletinRequest *bulletin,
                                        unsigned long long destinations)
{
    if (![bulletin isKindOfClass:BBBulletinRequest.class] || destinations == 0) return NO;
    bulletin.sectionID = kReleaseSectionID;
    if (![bulletin.sectionID isEqualToString:@"com.apple.Preferences"]) return NO;
    NSDate *now = [NSDate date];
    bulletin.date = now;
    bulletin.lastInterruptDate = now;
    bulletin.turnsOnDisplay = YES;
    sn_release_set_object_if_supported(bulletin, @"setPublicationDate:", now);
    sn_release_set_object_if_supported(bulletin, @"setRecencyDate:", now);
    sn_release_set_bool_if_supported(bulletin, @"setClearable:", YES);
    sn_release_set_bool_if_supported(bulletin, @"setShowsMessagePreview:", YES);
    sn_release_set_integer_if_supported(bulletin, @"setInterruptionLevel:", 1);
    sn_release_set_integer_if_supported(bulletin, @"setLockScreenPriority:", 1);
    NSString *type = sn_release_bulletin_type(bulletin) ?: @"unknown";
    RELEASE_LOG(@"[RELEASE] notify prepare | type=%@ section=%@ destinations=0x%llx hasAction=%d",
                type, kReleaseSectionID, destinations, bulletin.defaultAction != nil);
    return destinations != 0;
}

static BBBulletinRequest *sn_release_make_update_bulletin(NSString *tag,
                                                           NSString *buildID,
                                                           NSString *releaseURLString)
{
    NSURL *url = [NSURL URLWithString:releaseURLString ?: @""];
    if (tag.length == 0 || buildID.length == 0 || !sn_release_allowed_release_url(url)) return nil;
    NSString *identifier = [NSString stringWithFormat:@"%@%016llx",
        kReleaseBulletinPrefix, (unsigned long long)sn_release_build_hash(buildID)];
    BBBulletinRequest *bulletin = [[[BBBulletinRequest alloc] init] autorelease];
    bulletin.bulletinID = identifier;
    bulletin.publisherBulletinID = identifier;
    bulletin.recordID = identifier;
    bulletin.categoryID = kReleaseBulletinCategory;
    bulletin.sectionID = kReleaseSectionID;
    bulletin.title = @"New version available";
    bulletin.subtitle = nil;
    bulletin.message = @"Update available for SpeakNotification16";
    bulletin.defaultAction = [BBAction actionWithLaunchURL:url callblock:nil];
    bulletin.context = @{@"type": @"update", @"tag": tag, @"buildID": buildID};
    return bulletin;
}

static BBBulletinRequest *sn_release_make_token_bulletin(NSString *kind)
{
    BOOL invalid = [kind isEqualToString:@"invalid"];
    NSString *safeKind = invalid ? @"invalid" : @"missing";
    NSString *identifier = [kReleaseTokenBulletinPrefix stringByAppendingString:safeKind];
    BBBulletinRequest *bulletin = [[[BBBulletinRequest alloc] init] autorelease];
    bulletin.bulletinID = identifier;
    bulletin.publisherBulletinID = identifier;
    bulletin.recordID = identifier;
    bulletin.categoryID = kReleaseTokenBulletinCategory;
    bulletin.sectionID = kReleaseSectionID;
    bulletin.title = invalid ? @"Beta token invalid" : @"Beta token required";
    bulletin.subtitle = nil;
    bulletin.message = invalid
        ? @"Update the token in SpeakNotification16 Settings."
        : @"Add a valid GitHub token in SpeakNotification16 Settings.";
    bulletin.defaultAction = nil;
    bulletin.context = @{@"type": @"token", @"kind": safeKind};
    return bulletin;
}

static BOOL sn_release_queue_update_locked(NSString *tag,
                                           NSString *buildID,
                                           NSString *releaseURLString)
{
    BBBulletinRequest *bulletin = sn_release_make_update_bulletin(tag, buildID, releaseURLString);
    if (!bulletin) return NO;
    if (!sn_release_enqueue_pending(bulletin)) return NO;
    NSUserDefaults *defs = sn_release_defaults();
    [defs setObject:buildID forKey:kReleaseQueuedBuildIDKey];
    [defs setObject:buildID forKey:kReleaseAvailableBuildIDKey];
    [defs setObject:tag forKey:kReleaseQueuedTagKey];
    [defs setObject:releaseURLString forKey:kReleaseQueuedURLKey];
    [defs synchronize];
    RELEASE_LOG(@"[RELEASE] notify queued | type=update tag=%@ buildID=%@ reason=awaitingBBServerContext",
                tag, buildID);
    if (!sn_release_request_cached_flush(@"automaticCheck")) {
        sn_release_schedule_flush_retry_locked();
    }
    return YES;
}

static BOOL sn_release_queue_token_alert_locked(NSString *kind)
{
    NSUserDefaults *defs = sn_release_defaults();
    if ([defs boolForKey:kReleaseTokenAlertShownKey]) {
        RELEASE_LOG_VERBOSE(@"[RELEASE] token alert state | shown=1 reset=0 reason=continuedError");
        return NO;
    }
    BBBulletinRequest *bulletin = sn_release_make_token_bulletin(kind);
    if (!sn_release_enqueue_pending(bulletin)) return NO;
    [defs setBool:YES forKey:kReleaseTokenAlertShownKey];
    [defs setBool:YES forKey:kReleaseTokenAlertPendingKey];
    [defs setObject:([kind isEqualToString:@"invalid"] ? @"invalid" : @"missing")
            forKey:kReleaseTokenAlertKindKey];
    [defs synchronize];
    RELEASE_LOG(@"[RELEASE] notify queued | type=token reason=%@ awaitingBBServerContext=1",
                [kind isEqualToString:@"invalid"] ? @"invalidToken" : @"missingToken");
    RELEASE_LOG_VERBOSE(@"[RELEASE] token alert state | shown=1 reset=0 reason=queued");
    if (!sn_release_request_cached_flush(@"tokenError")) {
        sn_release_schedule_flush_retry_locked();
    }
    return YES;
}

static void sn_release_reset_token_alert_period_locked(void)
{
    NSUserDefaults *defs = sn_release_defaults();
    BOOL wasShown = [defs boolForKey:kReleaseTokenAlertShownKey];
    [defs removeObjectForKey:kReleaseTokenAlertShownKey];
    [defs removeObjectForKey:kReleaseTokenAlertPendingKey];
    [defs removeObjectForKey:kReleaseTokenAlertKindKey];
    [defs synchronize];
    sn_release_clear_pending_token();
    if (!gReleaseHasPending.load(std::memory_order_acquire)) {
        sn_release_cancel_flush_retry_locked(@"noPending");
    }
    RELEASE_LOG_VERBOSE(@"[RELEASE] token alert state | shown=0 reset=%d reason=validResponse", wasShown);
}

static BOOL sn_release_set_token_status_locked(NSUserDefaults *defs,
                                               NSString *status,
                                               BOOL notifySettings)
{
    if (!defs || status.length == 0) return NO;
    NSString *previous = [defs stringForKey:kReleaseTokenValidationStatusKey];
    if ([previous isEqualToString:status]) return NO;
    [defs setObject:status forKey:kReleaseTokenValidationStatusKey];
    [defs synchronize];
    if (notifySettings) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             kSNReleaseCheckResultNotify,
                                             NULL, NULL, true);
    }
    return YES;
}

#pragma mark - Release Alerts Bulletin Publishing

static dispatch_queue_t sn_release_bbserver_queue(id server)
{
    if (!server) return NULL;
    Ivar queueIvar = class_getInstanceVariable([server class], "_queue");
    return queueIvar ? (dispatch_queue_t)object_getIvar(server, queueIvar) : NULL;
}

static id sn_release_cached_server(unsigned long long *destinationsOut)
{
    if (destinationsOut) {
        *destinationsOut = gReleaseDestinations.load(std::memory_order_acquire);
    }
    os_unfair_lock_lock(&gReleaseServerLock);
    id server = [gReleaseBBServer retain];
    os_unfair_lock_unlock(&gReleaseServerLock);
    return server;
}

static BOOL sn_release_lookup_preferences_provider_on_server_queue(id server)
{
    dispatch_queue_t serverQueue = sn_release_bbserver_queue(server);
    if (!serverQueue ||
        dispatch_get_specific(&gReleaseBBQueueSpecificKey) != &gReleaseBBQueueSpecificKey) {
        return NO;
    }

    os_unfair_lock_lock(&gReleaseServerLock);
    BOOL alreadyReady = (gReleaseBBProvider != nil && gReleaseBBProviderSupportsAddDestinations);
    os_unfair_lock_unlock(&gReleaseServerLock);
    if (alreadyReady) return YES;

    SEL lookupSelector = NSSelectorFromString(@"dataProviderForSectionID:");
    if (![server respondsToSelector:lookupSelector]) return NO;

    id provider = nil;
    @try {
        provider = ((id (*)(id, SEL, id))objc_msgSend)(server, lookupSelector, kReleaseSectionID);
    } @catch (__unused NSException *exception) {
        return NO;
    }
    if (!provider) return NO;

    SEL addDestinations = NSSelectorFromString(@"addBulletin:forDestinations:");
    if (![provider respondsToSelector:addDestinations]) return NO;

    os_unfair_lock_lock(&gReleaseServerLock);
    if (gReleaseBBProvider != provider) {
        [gReleaseBBProvider release];
        gReleaseBBProvider = [provider retain];
    }
    gReleaseBBProviderSupportsAddDestinations = YES;
    os_unfair_lock_unlock(&gReleaseServerLock);
    gReleaseBBProviderRetryStage.store(3, std::memory_order_release);

    RELEASE_LOG_VERBOSE(@"[RELEASE] bbprovider ready | class=%@ addDestinations=1",
                NSStringFromClass([provider class]));
    return YES;
}

static void sn_release_schedule_preferences_provider_retries(id server)
{
    unsigned int expected = 0;
    if (!gReleaseBBProviderRetryStage.compare_exchange_strong(expected, 1,
                                                               std::memory_order_acq_rel)) {
        return;
    }

    dispatch_queue_t serverQueue = sn_release_bbserver_queue(server);
    if (!serverQueue) {
        gReleaseBBProviderRetryStage.store(3, std::memory_order_release);
        return;
    }

    id serverValue = [server retain];
    RELEASE_LOG_VERBOSE(@"[RELEASE] bbprovider lookup retry | delay=1s");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), serverQueue, ^{
        if (gReleaseBBProviderRetryStage.load(std::memory_order_acquire) != 1) {
            [serverValue release];
            return;
        }
        if (sn_release_lookup_preferences_provider_on_server_queue(serverValue)) {
            [serverValue release];
            return;
        }

        gReleaseBBProviderRetryStage.store(2, std::memory_order_release);
        RELEASE_LOG_VERBOSE(@"[RELEASE] bbprovider lookup retry | delay=5s");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), serverQueue, ^{
            if (gReleaseBBProviderRetryStage.load(std::memory_order_acquire) == 2) {
                if (!sn_release_lookup_preferences_provider_on_server_queue(serverValue)) {
                    RELEASE_LOG_VERBOSE(@"[RELEASE] bbprovider unavailable | retries=2");
                }
                gReleaseBBProviderRetryStage.store(3, std::memory_order_release);
            }
            [serverValue release];
        });
    });
}

static void SNReleaseAlertsHandleBBServerLifecycle(id server)
{
    if (!sn_release_is_springboard()) return;
    Class expectedClass = NSClassFromString(@"BBServer");
    SEL publishSelector = NSSelectorFromString(@"publishBulletin:destinations:");
    dispatch_queue_t serverQueue = sn_release_bbserver_queue(server);
    if (!server || !expectedClass || ![server isKindOfClass:expectedClass] ||
        ![server respondsToSelector:publishSelector] || !serverQueue) {
        return;
    }

    BOOL saved = NO;
    os_unfair_lock_lock(&gReleaseServerLock);
    if (gReleaseBBServer != server) {
        [gReleaseBBServer release];
        gReleaseBBServer = [server retain];
        saved = YES;
    }
    os_unfair_lock_unlock(&gReleaseServerLock);

    if (saved) {
        RELEASE_LOG_VERBOSE(@"[RELEASE] bbserver context capture | source=lifecycle class=%@ result=saved",
                    NSStringFromClass([server class]));
    }

    dispatch_queue_set_specific(serverQueue, &gReleaseBBQueueSpecificKey,
                                &gReleaseBBQueueSpecificKey, NULL);
    id serverValue = [server retain];
    dispatch_async(serverQueue, ^{
        if (!sn_release_lookup_preferences_provider_on_server_queue(serverValue)) {
            sn_release_schedule_preferences_provider_retries(serverValue);
        }
        [serverValue release];
    });
}

static BOOL sn_release_preferences_provider_is_ready(void)
{
    os_unfair_lock_lock(&gReleaseServerLock);
    BOOL ready = (gReleaseBBProvider != nil && gReleaseBBProviderSupportsAddDestinations);
    os_unfair_lock_unlock(&gReleaseServerLock);
    return ready;
}

static unsigned long long sn_release_destinations_for_pending_bulletin(BBBulletinRequest *bulletin)
{
    unsigned long long observed = gReleaseDestinations.load(std::memory_order_acquire);
    if (observed != 0) {
        RELEASE_LOG_VERBOSE(@"[RELEASE] notify destinations | source=observed value=0x%llx", observed);
        return observed;
    }

    NSString *type = sn_release_bulletin_type(bulletin);
    BOOL ownReleaseEvent = [type isEqualToString:@"token"] || [type isEqualToString:@"update"];
    if (ownReleaseEvent &&
        [kReleaseSectionID isEqualToString:@"com.apple.Preferences"] &&
        sn_release_preferences_provider_is_ready()) {
        RELEASE_LOG_VERBOSE(@"[RELEASE] notify destinations | source=fallback value=0x%llx reason=noObservedDestinations",
                    kSNReleaseFallbackDestinations);
        return kSNReleaseFallbackDestinations;
    }
    return 0;
}

static void sn_release_mark_publish_attempt(BBBulletinRequest *bulletin)
{
    if (![sn_release_bulletin_type(bulletin) isEqualToString:@"update"]) return;
    NSString *buildID = sn_release_bulletin_build_id(bulletin);
    if (buildID.length == 0) return;
    NSUserDefaults *defs = sn_release_defaults();
    [defs setObject:buildID forKey:kReleaseLastPublishAttemptBuildIDKey];
    [defs synchronize];
}

static void sn_release_complete_publication(BBBulletinRequest *bulletin, BOOL published)
{
    NSString *type = sn_release_bulletin_type(bulletin) ?: @"unknown";
    NSDictionary *context = [bulletin.context isKindOfClass:NSDictionary.class]
        ? bulletin.context : nil;
    RELEASE_LOG(@"[RELEASE] notify publish | queue=bbserver result=%@ type=%@ section=%@",
                published ? @"ok" : @"fail", type, kReleaseSectionID);

    NSUserDefaults *defs = sn_release_defaults();
    if ([type isEqualToString:@"update"]) {
        NSString *tag = [context[@"tag"] isKindOfClass:NSString.class] ? context[@"tag"] : nil;
        NSString *buildID = [context[@"buildID"] isKindOfClass:NSString.class] ? context[@"buildID"] : nil;
        if (published && buildID.length > 0) {
            if (tag.length > 0) [defs setObject:tag forKey:kReleaseLastNotifiedTagKey];
            [defs setObject:buildID forKey:kReleaseLastNotifiedBuildIDKey];
            sn_release_clear_persistent_queue(defs, buildID);
            [defs synchronize];
            RELEASE_LOG(@"[RELEASE] notify publish state | buildID=%@ queuedCleared=1 publishedSaved=1",
                        buildID);
        } else {
            [defs removeObjectForKey:kReleaseLastPublishAttemptBuildIDKey];
            [defs setObject:@"notification" forKey:kReleaseLastErrorKey];
            [defs synchronize];
            sn_release_requeue_pending(bulletin);
            RELEASE_LOG(@"[RELEASE] notify publish state | buildID=%@ queuedCleared=0 publishedSaved=0",
                        buildID ?: @"-");
        }
    } else if ([type isEqualToString:@"token"]) {
        if (published) {
            [defs removeObjectForKey:kReleaseTokenAlertPendingKey];
            [defs synchronize];
        } else {
            [defs setBool:YES forKey:kReleaseTokenAlertPendingKey];
            [defs synchronize];
            sn_release_requeue_pending(bulletin);
        }
    }

    if (published && gReleaseQueue) {
        dispatch_async(gReleaseQueue, ^{
            if (!gReleaseHasPending.load(std::memory_order_acquire)) {
                sn_release_cancel_flush_retry_locked(@"published");
            }
        });
    }
}

static void sn_release_request_flush(id server, NSString *source)
{
    if (!server) return;
    dispatch_queue_t serverQueue = sn_release_bbserver_queue(server);
    if (!serverQueue) return;

    bool expected = false;
    if (!gReleaseFlushScheduled.compare_exchange_strong(expected, true,
                                                         std::memory_order_acq_rel)) {
        return;
    }
    RELEASE_LOG_VERBOSE(@"[RELEASE] notify pending flush | source=%@", source ?: @"unknown");

    id serverValue = [server retain];
    dispatch_async(serverQueue, ^{
        @autoreleasepool {
            if (gReleasePublishActive.load(std::memory_order_acquire)) {
                RELEASE_LOG_VERBOSE(@"[RELEASE] notify pending flush skip | reason=publishActive");
                gReleaseFlushScheduled.store(false, std::memory_order_release);
                [serverValue release];
                return;
            }

            BBBulletinRequest *bulletin = sn_release_take_next_pending();
            if (!bulletin) {
                RELEASE_LOG_VERBOSE(@"[RELEASE] notify pending flush skip | reason=none");
                gReleaseFlushScheduled.store(false, std::memory_order_release);
                [serverValue release];
                return;
            }

            unsigned long long destinations = sn_release_destinations_for_pending_bulletin(bulletin);
            if (destinations == 0) {
                RELEASE_LOG_VERBOSE(@"[RELEASE] notify pending flush skip | reason=noDestinations");
                sn_release_requeue_pending(bulletin);
                [bulletin release];
                gReleaseFlushScheduled.store(false, std::memory_order_release);
                [serverValue release];
                return;
            }

            BOOL published = NO;
            if (sn_release_prepare_bulletin(bulletin, destinations)) {
                sn_release_mark_publish_attempt(bulletin);
                gReleasePublishActive.store(true, std::memory_order_release);
                gPublishingBulletin = [bulletin retain];
                @try {
                    SEL selector = NSSelectorFromString(@"publishBulletin:destinations:");
                    ((void (*)(id, SEL, id, unsigned long long))objc_msgSend)(serverValue,
                                                                              selector,
                                                                              bulletin,
                                                                              destinations);
                    published = YES;
                } @catch (NSException *exception) {
                    published = NO;
                    RELEASE_LOG(@"[RELEASE] notify publish exception | name=%@ type=%@ action=keepPending",
                                exception.name ?: @"NSException", sn_release_bulletin_type(bulletin) ?: @"unknown");
                }
                [gPublishingBulletin release];
                gPublishingBulletin = nil;
                gReleasePublishActive.store(false, std::memory_order_release);
            }
            sn_release_complete_publication(bulletin, published);
            [bulletin release];
            gReleaseFlushScheduled.store(false, std::memory_order_release);
        }
        [serverValue release];
    });
}

static BOOL sn_release_request_cached_flush(NSString *source)
{
    unsigned long long destinations = 0;
    id server = sn_release_cached_server(&destinations);
    BOOL available = server && sn_release_bbserver_queue(server) &&
        (destinations != 0 || sn_release_preferences_provider_is_ready());
    if (available) sn_release_request_flush(server, source);
    [server release];
    return available;
}

static void sn_release_capture_server(id server, unsigned long long destinations)
{
    Class expectedClass = NSClassFromString(@"BBServer");
    SEL publishSelector = NSSelectorFromString(@"publishBulletin:destinations:");
    dispatch_queue_t serverQueue = sn_release_bbserver_queue(server);
    if (!server || !expectedClass || ![server isKindOfClass:expectedClass] ||
        ![server respondsToSelector:publishSelector] || !serverQueue || destinations == 0) {
        return;
    }

    dispatch_queue_set_specific(serverQueue, &gReleaseBBQueueSpecificKey,
                                &gReleaseBBQueueSpecificKey, NULL);
    if (dispatch_get_specific(&gReleaseBBQueueSpecificKey) != &gReleaseBBQueueSpecificKey) {
        return;
    }

    os_unfair_lock_lock(&gReleaseServerLock);
    if (gReleaseBBServer != server) {
        [gReleaseBBServer release];
        gReleaseBBServer = [server retain];
    }
    gReleaseDestinations.store(destinations, std::memory_order_release);
    os_unfair_lock_unlock(&gReleaseServerLock);
    if (gReleaseHasPending.load(std::memory_order_acquire)) {
        if (gReleaseQueue) {
            dispatch_async(gReleaseQueue, ^{
                sn_release_cancel_flush_retry_locked(@"observedDestinations");
            });
        }
        sn_release_request_flush(server, @"bbserverCapture");
    }
}

static void SNReleaseAlertsHandleBBServerEntry(id server,
                                        id bulletin,
                                        unsigned long long destinations)
{
    if (!sn_release_is_springboard()) return;
    if (gReleasePublishActive.load(std::memory_order_acquire) &&
        bulletin == gPublishingBulletin) {
        return;
    }
    if (destinations != 0) {
        unsigned long long previous = gReleaseDestinations.exchange(destinations,
                                                                    std::memory_order_acq_rel);
        if (previous != destinations && gReleaseHasPending.load(std::memory_order_acquire)) {
            RELEASE_LOG_VERBOSE(@"[RELEASE] bbserver destinations observe | value=0x%llx", destinations);
        }
    }
    sn_release_capture_server(server, destinations);
    if (!sn_release_preferences_provider_is_ready()) {
        (void)sn_release_lookup_preferences_provider_on_server_queue(server);
    }
}

#pragma mark - Release Alerts Scheduling and Manual Check Results

static void sn_release_cancel_timer_locked(void)
{
    if (!gReleaseTimer) return;
    dispatch_source_t timer = gReleaseTimer;
    gReleaseTimer = NULL;
    dispatch_source_cancel(timer);
#if !__has_feature(objc_arc)
    dispatch_release(timer);
#endif
}

static void sn_release_cancel_flush_retry_locked(NSString *reason)
{
    BOOL hadRetryState = (gReleaseFlushRetryTimer != NULL ||
                          gReleaseFlushRetryAttempt > 0);
    if (gReleaseFlushRetryTimer) {
        dispatch_source_t timer = gReleaseFlushRetryTimer;
        gReleaseFlushRetryTimer = NULL;
        dispatch_source_cancel(timer);
#if !__has_feature(objc_arc)
        dispatch_release(timer);
#endif
    }
    gReleaseFlushRetryAttempt = 0;
    if (hadRetryState) {
        RELEASE_LOG_VERBOSE(@"[RELEASE] notify flush retry cancel | reason=%@",
                    reason ?: @"unknown");
    }
}

static void sn_release_schedule_flush_retry_locked(void)
{
    if (!gReleaseHasPending.load(std::memory_order_acquire)) {
        sn_release_cancel_flush_retry_locked(@"noPending");
        return;
    }
    if (gReleaseFlushRetryTimer || gReleaseFlushRetryAttempt >= 2) return;

    NSTimeInterval delay = (gReleaseFlushRetryAttempt == 0) ? 45.0 : 120.0;
    gReleaseFlushRetryAttempt++;
    gReleaseFlushRetryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                      0,
                                                      0,
                                                      gReleaseQueue);
    if (!gReleaseFlushRetryTimer) {
        gReleaseFlushRetryAttempt--;
        return;
    }

    uint64_t delayNS = (uint64_t)(delay * NSEC_PER_SEC);
    dispatch_source_set_timer(gReleaseFlushRetryTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayNS),
                              DISPATCH_TIME_FOREVER,
                              (uint64_t)(2.0 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(gReleaseFlushRetryTimer, ^{
        dispatch_source_t timer = gReleaseFlushRetryTimer;
        gReleaseFlushRetryTimer = NULL;
        if (timer) {
            dispatch_source_cancel(timer);
#if !__has_feature(objc_arc)
            dispatch_release(timer);
#endif
        }

        BOOL pending = gReleaseHasPending.load(std::memory_order_acquire);
        BOOL context = pending
            ? sn_release_request_cached_flush(@"flushRetry")
            : NO;
        RELEASE_LOG_VERBOSE(@"[RELEASE] notify flush retry fire | pending=%d", pending);
        if (!pending) {
            sn_release_cancel_flush_retry_locked(@"noPending");
        } else if (!context) {
            sn_release_schedule_flush_retry_locked();
        }
    });
    dispatch_resume(gReleaseFlushRetryTimer);
    RELEASE_LOG_VERBOSE(@"[RELEASE] notify flush retry schedule | delay=%.0fs", delay);
}

static void sn_release_schedule_mode_locked(NSTimeInterval delay,
                                            NSString *reason,
                                            SNReleaseCheckMode mode)
{
    NSUserDefaults *defs = sn_release_defaults();
    if (!sn_release_enabled(defs)) {
        sn_release_cancel_timer_locked();
        [defs removeObjectForKey:kReleaseNextCheckKey];
        [defs synchronize];
        return;
    }
    if (delay < 1.0) delay = 1.0;
    sn_release_cancel_timer_locked();
    [defs setDouble:NSDate.date.timeIntervalSince1970 + delay forKey:kReleaseNextCheckKey];
    [defs synchronize];

    gReleaseTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gReleaseQueue);
    if (!gReleaseTimer) return;
    uint64_t delayNS = (uint64_t)(delay * NSEC_PER_SEC);
    uint64_t leewayNS = (uint64_t)(MIN(MAX(delay * 0.05, 1.0), 300.0) * NSEC_PER_SEC);
    dispatch_source_set_timer(gReleaseTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayNS),
                              DISPATCH_TIME_FOREVER,
                              leewayNS);
    SNReleaseCheckMode scheduledMode = mode;
    dispatch_source_set_event_handler(gReleaseTimer, ^{
        dispatch_source_t timer = gReleaseTimer;
        gReleaseTimer = NULL;
        if (timer) {
            dispatch_source_cancel(timer);
#if !__has_feature(objc_arc)
            dispatch_release(timer);
#endif
        }
        sn_release_perform_check_locked(NO, nil, scheduledMode);
    });
    dispatch_resume(gReleaseTimer);
    RELEASE_LOG(@"[RELEASE] check schedule | delay=%.0fs reason=%@",
                delay, reason ?: @"-");
}

static void sn_release_schedule_locked(NSTimeInterval delay, NSString *reason)
{
    sn_release_schedule_mode_locked(delay, reason, SNReleaseCheckModeNormal);
}

static void sn_release_schedule_install_baseline_locked(NSTimeInterval delay)
{
    sn_release_schedule_mode_locked(delay,
                                    @"installBaseline",
                                    SNReleaseCheckModeInstallBaseline);
}

static void sn_release_save_completion_locked(NSInteger statusCode,
                                              NSString *errorName,
                                              NSTimeInterval nextDelay)
{
    NSUserDefaults *defs = sn_release_defaults();
    [defs setDouble:NSDate.date.timeIntervalSince1970 forKey:kReleaseLastCheckKey];
    [defs setInteger:statusCode forKey:kReleaseLastStatusCodeKey];
    if (errorName.length > 0) [defs setObject:errorName forKey:kReleaseLastErrorKey];
    else [defs removeObjectForKey:kReleaseLastErrorKey];
    [defs synchronize];
    gReleaseCheckInFlight.store(false, std::memory_order_release);
    sn_release_schedule_locked(nextDelay,
        errorName.length > 0 ? @"retry" : @"normal");
}

static NSString *sn_release_install_id(NSUserDefaults *defs)
{
    NSString *value = [defs stringForKey:kReleaseCurrentInstallIDKey];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static BOOL sn_release_install_cycle_pending(NSUserDefaults *defs)
{
    NSString *current = sn_release_install_id(defs);
    NSString *processed = [defs stringForKey:kReleaseLastProcessedInstallIDKey];
    return current.length > 0 && ![current isEqualToString:processed ?: @""];
}

static void sn_release_clear_pending_update_for_install_locked(NSUserDefaults *defs)
{
    os_unfair_lock_lock(&gReleasePendingLock);
    [gPendingUpdate release];
    gPendingUpdate = nil;
    sn_release_update_pending_flag_locked();
    os_unfair_lock_unlock(&gReleasePendingLock);
    sn_release_clear_persistent_queue(defs, nil);
    [defs synchronize];
    if (!gReleaseHasPending.load(std::memory_order_acquire)) {
        sn_release_cancel_flush_retry_locked(@"noPending");
    }
}

static void sn_release_complete_install_cycle_locked(NSUserDefaults *defs,
                                                     NSInteger statusCode,
                                                     NSString *errorName)
{
    NSString *installID = sn_release_install_id(defs);
    [defs setDouble:NSDate.date.timeIntervalSince1970 forKey:kReleaseLastCheckKey];
    [defs setInteger:statusCode forKey:kReleaseLastStatusCodeKey];
    if (errorName.length > 0) [defs setObject:errorName forKey:kReleaseLastErrorKey];
    else [defs removeObjectForKey:kReleaseLastErrorKey];
    if (errorName.length > 0) [defs removeObjectForKey:kReleaseAvailableBuildIDKey];
    if (installID.length > 0) {
        [defs setObject:installID forKey:kReleaseLastProcessedInstallIDKey];
    }
    [defs synchronize];
    gReleaseCheckInFlight.store(false, std::memory_order_release);
    RELEASE_LOG_VERBOSE(@"[RELEASE] install cycle complete | installID=%@", installID ?: @"-");
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         kSNReleaseCheckResultNotify,
                                         NULL, NULL, true);
    sn_release_schedule_locked(kReleaseNormalInterval, @"normal");
}

static void sn_release_save_install_baseline_locked(NSUserDefaults *defs,
                                                    NSInteger statusCode,
                                                    NSString *tag,
                                                    NSString *buildID,
                                                    NSString *releaseURLString)
{
    sn_release_clear_pending_update_matching(buildID);
    sn_release_clear_persistent_queue(defs, buildID);
    [defs removeObjectForKey:kReleaseAvailableBuildIDKey];
    if (tag.length > 0) [defs setObject:tag forKey:kReleaseLastNotifiedTagKey];
    [defs setObject:buildID forKey:kReleaseLastNotifiedBuildIDKey];
    if (releaseURLString.length > 0) [defs setObject:releaseURLString forKey:kReleaseLastURLKey];
    [defs synchronize];
    if (!gReleaseHasPending.load(std::memory_order_acquire)) {
        sn_release_cancel_flush_retry_locked(@"noPending");
    }
    RELEASE_LOG_VERBOSE(@"[RELEASE] install baseline | buildID=%@ releaseNotification=suppressed baselineSaved=1",
                buildID);
    sn_release_complete_install_cycle_locked(defs, statusCode, nil);
}

static BOOL sn_release_manual_request_active(NSUserDefaults *defs, NSString *requestID)
{
    return requestID.length > 0 &&
           [[defs stringForKey:kReleaseManualRequestIDKey] isEqualToString:requestID];
}

static BOOL sn_release_token_validation_request_active(NSUserDefaults *defs, NSString *requestID)
{
    return requestID.length > 0 &&
           [[defs stringForKey:kReleaseTokenValidationRequestIDKey] isEqualToString:requestID];
}

static void sn_release_post_manual_result_locked(NSString *requestID,
                                                 NSString *status,
                                                 NSString *tag,
                                                 NSString *releaseURLString,
                                                 NSString *message)
{
    if (requestID.length == 0) return;
    NSUserDefaults *defs = sn_release_defaults();
    [defs synchronize];
    if (sn_release_token_validation_request_active(defs, requestID)) {
        NSString *resultStatus = [status isEqualToString:@"valid"] ? @"valid" :
            ([status isEqualToString:@"invalid"] ? @"invalid" : @"unverified");
        NSString *currentStatus = [defs stringForKey:kReleaseTokenValidationStatusKey];
        if (![resultStatus isEqualToString:@"unverified"] ||
            [currentStatus isEqualToString:@"checking"]) {
            sn_release_set_token_status_locked(defs, resultStatus, NO);
        }
        [defs setObject:resultStatus forKey:kReleaseTokenValidationResultStatusKey];
        [defs setObject:requestID forKey:kReleaseTokenValidationResultRequestIDKey];
        [defs setDouble:NSDate.date.timeIntervalSince1970 forKey:kReleaseManualResultTimestampKey];
        [defs removeObjectForKey:kReleaseTokenValidationRequestIDKey];
        [defs synchronize];
        RELEASE_LOG(@"[RELEASE] token validation result | status=%@", resultStatus);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             kSNReleaseCheckResultNotify,
                                             NULL, NULL, true);
        return;
    }
    if (![[defs stringForKey:kReleaseManualRequestIDKey] isEqualToString:requestID]) {
        RELEASE_LOG(@"[RELEASE] manual check result skip | reason=staleRequest requestID=%@",
                    requestID);
        return;
    }

    NSString *resultStatus = status.length > 0 ? status : @"invalidResponse";
    [defs setObject:resultStatus forKey:kReleaseManualResultStatusKey];
    [defs setObject:requestID forKey:kReleaseManualResultRequestIDKey];
    [defs setDouble:NSDate.date.timeIntervalSince1970 forKey:kReleaseManualResultTimestampKey];
    if (tag.length > 0) [defs setObject:tag forKey:kReleaseManualResultTagKey];
    else [defs removeObjectForKey:kReleaseManualResultTagKey];

    NSURL *url = [NSURL URLWithString:releaseURLString ?: @""];
    if (sn_release_allowed_release_url(url)) {
        [defs setObject:url.absoluteString forKey:kReleaseManualResultURLKey];
    } else {
        [defs removeObjectForKey:kReleaseManualResultURLKey];
    }
    if (message.length > 0) [defs setObject:message forKey:kReleaseManualResultMessageKey];
    else [defs removeObjectForKey:kReleaseManualResultMessageKey];
    [defs removeObjectForKey:kReleaseManualRequestIDKey];
    [defs synchronize];

    RELEASE_LOG(@"[RELEASE] manual check result | requestID=%@ status=%@ tag=%@",
                requestID, resultStatus, tag ?: @"-");
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         kSNReleaseCheckResultNotify,
                                         NULL, NULL, true);
}

static void sn_release_log_classification(BOOL manual, NSString *buildID, NSString *result)
{
    if (buildID.length == 0) return;
    RELEASE_LOG(@"[RELEASE] %@ classify | buildID=%@ result=%@",
                manual ? @"manual check" : @"check",
                buildID, result ?: @"invalidResponse");
}

static void sn_release_mark_manual_build_handled(NSUserDefaults *defs,
                                                 NSString *tag,
                                                 NSString *buildID,
                                                 NSString *releaseURLString)
{
    sn_release_clear_pending_update_matching(buildID);
    sn_release_clear_persistent_queue(defs, buildID);
    [defs setObject:buildID forKey:kReleaseAvailableBuildIDKey];
    if (tag.length > 0) [defs setObject:tag forKey:kReleaseLastNotifiedTagKey];
    [defs setObject:buildID forKey:kReleaseLastNotifiedBuildIDKey];
    if (releaseURLString.length > 0) [defs setObject:releaseURLString forKey:kReleaseLastURLKey];
    [defs synchronize];
    if (!gReleaseHasPending.load(std::memory_order_acquire)) {
        sn_release_cancel_flush_retry_locked(@"noPending");
    }
    RELEASE_LOG(@"[RELEASE] manual check new build | buildID=%@ action=settingsResultOnly", buildID);
    RELEASE_LOG(@"[RELEASE] notify skip | reason=manualCheckHandled buildID=%@", buildID);
    RELEASE_LOG(@"[RELEASE] manual check state | buildID=%@ notifiedSaved=1 queued=0", buildID);
}

#pragma mark - Release Alerts GitHub Check

static void sn_release_rehydrate_pending_locked(void)
{
    NSUserDefaults *defs = sn_release_defaults();
    NSString *attempted = [defs stringForKey:kReleaseLastPublishAttemptBuildIDKey];
    NSString *published = [defs stringForKey:kReleaseLastNotifiedBuildIDKey];
    NSString *queuedBefore = [defs stringForKey:kReleaseQueuedBuildIDKey];
    if (published.length > 0 && [queuedBefore isEqualToString:published]) {
        sn_release_clear_persistent_queue(defs, published);
        attempted = nil;
        queuedBefore = nil;
    } else if (attempted.length > 0 && [attempted isEqualToString:published]) {
        [defs removeObjectForKey:kReleaseLastPublishAttemptBuildIDKey];
    } else if (attempted.length > 0 && queuedBefore.length == 0) {
        NSString *seen = [defs stringForKey:kReleaseLastSeenBuildIDKey];
        NSString *seenTag = [defs stringForKey:kReleaseLastSeenTagKey];
        NSString *seenURL = [defs stringForKey:kReleaseLastURLKey];
        if ([attempted isEqualToString:seen] && seenTag.length > 0 &&
            sn_release_allowed_release_url([NSURL URLWithString:seenURL ?: @""])) {
            [defs setObject:attempted forKey:kReleaseQueuedBuildIDKey];
            [defs setObject:seenTag forKey:kReleaseQueuedTagKey];
            [defs setObject:seenURL forKey:kReleaseQueuedURLKey];
        } else {
            [defs removeObjectForKey:kReleaseLastPublishAttemptBuildIDKey];
        }
    }
    [defs synchronize];

    NSString *buildID = [defs stringForKey:kReleaseQueuedBuildIDKey];
    NSString *tag = [defs stringForKey:kReleaseQueuedTagKey];
    NSString *url = [defs stringForKey:kReleaseQueuedURLKey];
    if (buildID.length > 0 && tag.length > 0 &&
        sn_release_allowed_release_url([NSURL URLWithString:url ?: @""]) &&
        !sn_release_pending_update_matches(buildID)) {
        BBBulletinRequest *bulletin = sn_release_make_update_bulletin(tag, buildID, url);
        if (bulletin) sn_release_enqueue_pending(bulletin);
    }

    if ([defs boolForKey:kReleaseTokenAlertPendingKey]) {
        os_unfair_lock_lock(&gReleasePendingLock);
        BOOL alreadyPending = (gPendingToken != nil);
        os_unfair_lock_unlock(&gReleasePendingLock);
        if (!alreadyPending) {
            NSString *kind = [defs stringForKey:kReleaseTokenAlertKindKey] ?: @"missing";
            BBBulletinRequest *bulletin = sn_release_make_token_bulletin(kind);
            if (bulletin) sn_release_enqueue_pending(bulletin);
        }
    }
}

static void sn_release_clear_in_memory_pending(void)
{
    os_unfair_lock_lock(&gReleasePendingLock);
    [gPendingUpdate release];
    [gPendingToken release];
    gPendingUpdate = nil;
    gPendingToken = nil;
    sn_release_update_pending_flag_locked();
    os_unfair_lock_unlock(&gReleasePendingLock);
}

static void sn_release_handle_304_locked(NSUserDefaults *defs,
                                         NSInteger status,
                                         NSString *manualRequestID,
                                         BOOL manualOrigin,
                                         BOOL manualActive,
                                         SNReleaseCheckMode mode)
{
    NSString *buildID = [defs stringForKey:kReleaseLastSeenBuildIDKey];
    NSString *tag = [defs stringForKey:kReleaseLastSeenTagKey];
    NSString *url = [defs stringForKey:kReleaseLastURLKey];
    BOOL published = sn_release_build_is_published(defs, buildID);
    BOOL queued = sn_release_build_is_queued(defs, buildID);

    if (mode == SNReleaseCheckModeTokenValidation) {
        sn_release_post_manual_result_locked(manualRequestID, @"valid", nil, nil, nil);
        return;
    }

    if (mode == SNReleaseCheckModeInstallBaseline) {
        BOOL cachedReleaseIsValid = (buildID.length > 0 && tag.length > 0 &&
            sn_release_allowed_release_url([NSURL URLWithString:url ?: @""]));
        if (!cachedReleaseIsValid) {
            [defs removeObjectForKey:kReleaseETagKey];
            [defs synchronize];
            sn_release_complete_install_cycle_locked(defs, status, @"invalidResponse");
            return;
        }
        sn_release_save_install_baseline_locked(defs,
                                                status,
                                                tag,
                                                buildID,
                                                url);
        return;
    }

    if (manualOrigin) {
        if (!manualActive) {
            sn_release_save_completion_locked(status, nil, kReleaseNormalInterval);
            return;
        }
        NSString *result = @"upToDate";
        if (buildID.length > 0 && !published && !queued) {
            sn_release_mark_manual_build_handled(defs, tag, buildID, url);
            result = @"updateAvailable";
        } else if (queued) {
            result = @"alreadyQueued";
        }
        sn_release_save_completion_locked(status, nil, kReleaseNormalInterval);
        sn_release_log_classification(YES, buildID, result);
        sn_release_post_manual_result_locked(manualRequestID, result, tag, url, nil);
        return;
    }

    if (queued) {
        sn_release_rehydrate_pending_locked();
        BOOL context = sn_release_request_cached_flush(@"scheduledCheck");
        if (!context) sn_release_schedule_flush_retry_locked();
        RELEASE_LOG_VERBOSE(@"[RELEASE] notify queued retry | source=scheduledCheck");
    } else if (buildID.length > 0 && !published && tag.length > 0 &&
               sn_release_allowed_release_url([NSURL URLWithString:url ?: @""])) {
        sn_release_queue_update_locked(tag, buildID, url);
    }
    sn_release_save_completion_locked(status, nil, kReleaseNormalInterval);
    sn_release_log_classification(NO, buildID,
        published ? @"upToDate" : (queued ? @"alreadyQueued" : @"updateAvailable"));
}

static void sn_release_process_response_locked(NSData *data,
                                               NSURLResponse *response,
                                               NSError *error,
                                               NSString *requestToken,
                                               NSString *manualRequestID,
                                               SNReleaseCheckMode mode)
{
    @autoreleasepool {
        NSUserDefaults *defs = sn_release_defaults();
        [defs synchronize];
        BOOL tokenValidation = (mode == SNReleaseCheckModeTokenValidation);
        BOOL manualOrigin = !tokenValidation && manualRequestID.length > 0;
        BOOL manualActive = tokenValidation
            ? sn_release_token_validation_request_active(defs, manualRequestID)
            : sn_release_manual_request_active(defs, manualRequestID);
        BOOL installBaseline = (mode == SNReleaseCheckModeInstallBaseline);
        if (!sn_release_enabled(defs)) {
            if (!tokenValidation) gReleaseCheckInFlight.store(false, std::memory_order_release);
            sn_release_post_manual_result_locked(manualRequestID, tokenValidation ? @"unverified" : @"releaseDisabled", nil, nil, nil);
            return;
        }

        NSString *currentToken = sn_release_token(defs);
        if (kSNReleaseRepoRequiresToken && ![currentToken isEqualToString:(requestToken ?: @"")]) {
            if (!tokenValidation) gReleaseCheckInFlight.store(false, std::memory_order_release);
            RELEASE_LOG(@"[RELEASE] check skip | reason=tokenChanged");
            sn_release_post_manual_result_locked(manualRequestID, tokenValidation ? @"unverified" : @"invalidResponse", nil, nil, nil);
            if (tokenValidation) return;
            if (installBaseline) {
                sn_release_schedule_install_baseline_locked(1.0);
            } else {
                sn_release_schedule_locked(1.0, @"tokenChanged");
            }
            return;
        }

        if (error || ![response isKindOfClass:NSHTTPURLResponse.class]) {
            RELEASE_LOG(@"[RELEASE] check fail | reason=network code=%ld",
                        (long)error.code);
            if (tokenValidation) {
                sn_release_post_manual_result_locked(manualRequestID, @"unverified", nil, nil, nil);
                return;
            }
            if (installBaseline) {
                sn_release_complete_install_cycle_locked(defs, 0, @"networkError");
            } else {
                sn_release_save_completion_locked(0, @"network", kReleaseNetworkRetry);
            }
            sn_release_post_manual_result_locked(manualRequestID, @"networkError", nil, nil, nil);
            return;
        }

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSInteger status = http.statusCode;
        NSString *etag = sn_release_response_etag(http);
        if (status == 304) {
            RELEASE_LOG_VERBOSE(@"[RELEASE] response | status=%ld", (long)status);
        } else {
            RELEASE_LOG(@"[RELEASE] response | status=%ld", (long)status);
        }

        if (status == 304) {
            if (etag.length > 0) [defs setObject:etag forKey:kReleaseETagKey];
            [defs synchronize];
            BOOL resultWillNotify = tokenValidation ||
                (manualOrigin && manualActive) || installBaseline;
            sn_release_set_token_status_locked(defs, @"valid", !resultWillNotify);
            sn_release_reset_token_alert_period_locked();
            sn_release_handle_304_locked(defs, status, manualRequestID,
                                         manualOrigin, manualActive, mode);
            return;
        }

        if (status == 401 || status == 403 || status == 404) {
            if (status == 401 || status == 403) {
                BOOL resultWillNotify = tokenValidation ||
                    (manualOrigin && manualActive) || installBaseline;
                sn_release_set_token_status_locked(defs, @"invalid", !resultWillNotify);
            }
            if (tokenValidation) {
                sn_release_post_manual_result_locked(manualRequestID, @"invalid", nil, nil, nil);
                return;
            }
            NSString *reason = status == 401 ? @"auth" :
                (status == 403 ? @"forbidden" : @"notFound");
            RELEASE_LOG(@"[RELEASE] check fail | reason=%@ status=%ld", reason, (long)status);
            if (installBaseline) {
                BOOL queued = sn_release_queue_token_alert_locked(@"invalid");
                RELEASE_LOG(@"[RELEASE] install baseline | result=authFailed status=%ld notification=%@",
                            (long)status, queued ? @"queued" : @"alreadyShown");
                sn_release_complete_install_cycle_locked(defs, status, @"authFailed");
            } else {
                if (!manualOrigin) sn_release_queue_token_alert_locked(@"invalid");
                sn_release_save_completion_locked(status, reason, kReleaseNormalInterval);
            }
            sn_release_post_manual_result_locked(manualRequestID, @"authFailed", nil, nil, nil);
            return;
        }

        if (status != 200) {
            if (tokenValidation) {
                sn_release_post_manual_result_locked(manualRequestID, @"unverified", nil, nil, nil);
                return;
            }
            NSTimeInterval retry = status >= 500 ? kReleaseNetworkRetry : kReleaseNormalInterval;
            if (installBaseline) {
                sn_release_complete_install_cycle_locked(defs,
                                                         status,
                                                         status >= 500 ? @"networkError" : @"invalidResponse");
            } else {
                sn_release_save_completion_locked(status, @"http", retry);
            }
            sn_release_post_manual_result_locked(manualRequestID,
                status >= 500 ? @"networkError" : @"invalidResponse", nil, nil, nil);
            return;
        }

        if (tokenValidation) {
            sn_release_set_token_status_locked(defs, @"valid", NO);
            sn_release_reset_token_alert_period_locked();
            sn_release_post_manual_result_locked(manualRequestID, @"valid", nil, nil, nil);
            return;
        }

        BOOL resultWillNotify = (manualOrigin && manualActive) || installBaseline;
        sn_release_set_token_status_locked(defs, @"valid", !resultWillNotify);
        sn_release_reset_token_alert_period_locked();
        if (data.length == 0 || data.length > (1024u * 1024u)) {
            if (tokenValidation) {
                sn_release_post_manual_result_locked(manualRequestID, @"unverified", nil, nil, nil);
                return;
            }
            if (installBaseline) {
                sn_release_complete_install_cycle_locked(defs, status, @"invalidResponse");
            } else {
                sn_release_save_completion_locked(status, @"responseSize", kReleaseNormalInterval);
            }
            sn_release_post_manual_result_locked(manualRequestID, @"invalidResponse", nil, nil, nil);
            return;
        }

        NSError *jsonError = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (![json isKindOfClass:NSDictionary.class] || jsonError) {
            if (tokenValidation) {
                sn_release_post_manual_result_locked(manualRequestID, @"unverified", nil, nil, nil);
                return;
            }
            if (installBaseline) {
                sn_release_complete_install_cycle_locked(defs, status, @"invalidResponse");
            } else {
                sn_release_save_completion_locked(status, @"json", kReleaseNormalInterval);
            }
            sn_release_post_manual_result_locked(manualRequestID, @"invalidResponse", nil, nil, nil);
            return;
        }

        NSDictionary *release = (NSDictionary *)json;
        NSString *tag = [release[@"tag_name"] isKindOfClass:NSString.class]
            ? release[@"tag_name"] : nil;
        NSString *htmlURLString = [release[@"html_url"] isKindOfClass:NSString.class]
            ? release[@"html_url"] : nil;
        NSNumber *draftValue = [release[@"draft"] isKindOfClass:NSNumber.class]
            ? release[@"draft"] : nil;
        NSNumber *prereleaseValue = [release[@"prerelease"] isKindOfClass:NSNumber.class]
            ? release[@"prerelease"] : nil;
        NSArray *assets = [release[@"assets"] isKindOfClass:NSArray.class]
            ? release[@"assets"] : nil;
        NSURL *releaseURL = [NSURL URLWithString:htmlURLString ?: @""];
        if (tag.length == 0 || !draftValue || !prereleaseValue ||
            !sn_release_allowed_release_url(releaseURL)) {
            if (tokenValidation) {
                sn_release_post_manual_result_locked(manualRequestID, @"unverified", nil, nil, nil);
                return;
            }
            if (installBaseline) {
                sn_release_complete_install_cycle_locked(defs, status, @"invalidResponse");
            } else {
                sn_release_save_completion_locked(status, @"invalidRelease", kReleaseNormalInterval);
            }
            sn_release_post_manual_result_locked(manualRequestID, @"invalidResponse", nil, nil, nil);
            return;
        }
        if (draftValue.boolValue || prereleaseValue.boolValue) {
            if (tokenValidation) {
                sn_release_post_manual_result_locked(manualRequestID, @"unverified", nil, nil, nil);
                return;
            }
            RELEASE_LOG(@"[RELEASE] notify skip | reason=%@ tag=%@",
                        draftValue.boolValue ? @"draft" : @"prerelease", tag);
            if (installBaseline) {
                sn_release_complete_install_cycle_locked(defs, status, @"noRelease");
            } else {
                sn_release_save_completion_locked(status, nil, kReleaseNormalInterval);
            }
            sn_release_post_manual_result_locked(manualRequestID, @"noRelease", tag, htmlURLString, nil);
            return;
        }

        NSString *releaseVersion = sn_release_version_from_tag(tag);
        NSDictionary *asset = sn_release_matching_asset(assets, releaseVersion);
        NSString *assetName = [asset[@"name"] isKindOfClass:NSString.class]
            ? asset[@"name"] : nil;
        NSString *updatedAt = sn_release_asset_timestamp(asset);
        if (!asset || assetName.length == 0 || updatedAt.length == 0) {
            if (tokenValidation) {
                sn_release_post_manual_result_locked(manualRequestID, @"unverified", nil, nil, nil);
                return;
            }
            RELEASE_LOG(@"[RELEASE] asset missing | tag=%@", tag);
            if (installBaseline) {
                sn_release_complete_install_cycle_locked(defs, status, @"invalidResponse");
            } else {
                sn_release_save_completion_locked(status, @"assetMissing", kReleaseNormalInterval);
            }
            sn_release_post_manual_result_locked(manualRequestID, @"noRelease", tag, htmlURLString, nil);
            return;
        }

        NSString *buildID = [NSString stringWithFormat:@"%@|%@|%@",
                             tag, assetName, updatedAt];
        if (tokenValidation) {
            sn_release_post_manual_result_locked(manualRequestID, @"valid", nil, nil, nil);
            return;
        }
        if (etag.length > 0) [defs setObject:etag forKey:kReleaseETagKey];
        [defs setObject:tag forKey:kReleaseLastSeenTagKey];
        [defs setObject:buildID forKey:kReleaseLastSeenBuildIDKey];
        [defs setObject:htmlURLString forKey:kReleaseLastURLKey];
        [defs synchronize];
        RELEASE_LOG(@"[RELEASE] latest | tag=%@ asset=%@ updatedAt=%@ buildID=%@ draft=0 prerelease=0",
                    tag, assetName, updatedAt, buildID);

        NSComparisonResult versionOrder = NSOrderedSame;
        if (!sn_release_compare_versions(releaseVersion, kReleaseInstalledVersion, &versionOrder)) {
            if (installBaseline) {
                sn_release_complete_install_cycle_locked(defs, status, @"invalidReleaseVersion");
            } else {
                sn_release_save_completion_locked(status, @"invalidReleaseVersion", kReleaseNormalInterval);
            }
            sn_release_post_manual_result_locked(manualRequestID, @"invalidResponse", tag, htmlURLString, nil);
            return;
        }
        if (versionOrder == NSOrderedAscending) {
            RELEASE_LOG(@"[RELEASE] notify skip | reason=noNewerVersion installed=%@ remote=%@",
                        kReleaseInstalledVersion, releaseVersion);
            if (installBaseline) {
                sn_release_complete_install_cycle_locked(defs, status, nil);
            } else {
                sn_release_save_completion_locked(status, nil, kReleaseNormalInterval);
            }
            sn_release_post_manual_result_locked(manualRequestID, @"upToDate", tag, htmlURLString, nil);
            return;
        }

        if (installBaseline) {
            sn_release_save_install_baseline_locked(defs,
                                                    status,
                                                    tag,
                                                    buildID,
                                                    htmlURLString);
            return;
        }

        BOOL published = sn_release_build_is_published(defs, buildID);
        BOOL queued = sn_release_build_is_queued(defs, buildID);
        if (manualOrigin) {
            if (!manualActive) {
                RELEASE_LOG(@"[RELEASE] manual check result skip | reason=staleRequest requestID=%@",
                            manualRequestID);
                sn_release_save_completion_locked(status, nil, kReleaseNormalInterval);
                return;
            }
            NSString *manualStatus = @"upToDate";
            if (!published && !queued) {
                sn_release_mark_manual_build_handled(defs, tag, buildID, htmlURLString);
                manualStatus = @"updateAvailable";
            } else if (queued) {
                manualStatus = @"alreadyQueued";
            }
            sn_release_save_completion_locked(status, nil, kReleaseNormalInterval);
            sn_release_log_classification(YES, buildID, manualStatus);
            sn_release_post_manual_result_locked(manualRequestID, manualStatus,
                                                 tag, htmlURLString, nil);
            return;
        }

        NSString *result = @"upToDate";
        if (!published && !queued) {
            result = sn_release_queue_update_locked(tag, buildID, htmlURLString)
                ? @"updateAvailable" : @"alreadyQueued";
        } else if (queued) {
            result = @"alreadyQueued";
            sn_release_rehydrate_pending_locked();
            BOOL context = sn_release_request_cached_flush(@"scheduledCheck");
            if (!context) sn_release_schedule_flush_retry_locked();
            RELEASE_LOG_VERBOSE(@"[RELEASE] notify queued retry | source=scheduledCheck");
        } else {
            RELEASE_LOG(@"[RELEASE] notify skip | reason=alreadyPublished buildID=%@", buildID);
        }
        sn_release_save_completion_locked(status, nil, kReleaseNormalInterval);
        sn_release_log_classification(NO, buildID, result);
    }
}

#pragma mark - Release Alerts Initialization and Check Requests

static void sn_release_perform_check_locked(BOOL force,
                                            NSString *manualRequestID,
                                            SNReleaseCheckMode mode)
{
    NSUserDefaults *defs = sn_release_defaults();
    [defs synchronize];
    BOOL tokenValidation = (mode == SNReleaseCheckModeTokenValidation);
    BOOL manualActive = tokenValidation
        ? sn_release_token_validation_request_active(defs, manualRequestID)
        : sn_release_manual_request_active(defs, manualRequestID);
    BOOL manualOrigin = !tokenValidation && manualRequestID.length > 0;
    BOOL installBaseline = (mode == SNReleaseCheckModeInstallBaseline);
    if (!sn_release_enabled(defs)) {
        RELEASE_LOG(@"[RELEASE] check skip | reason=disabled");
        sn_release_post_manual_result_locked(manualRequestID, @"releaseDisabled", nil, nil, nil);
        return;
    }

    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval nextCheck = [defs doubleForKey:kReleaseNextCheckKey];
    if (!force && !installBaseline && nextCheck > now + 1.0) {
        sn_release_schedule_locked(nextCheck - now, @"persisted");
        return;
    }

    RELEASE_LOG(@"[RELEASE] check start | repo=%@ requiresToken=%d force=%d reason=%@",
                kReleaseRepo,
                kSNReleaseRepoRequiresToken,
                force,
                installBaseline ? @"installBaseline" : @"normal");

    NSString *token = sn_release_token(defs);
    if (kSNReleaseRepoRequiresToken && token.length == 0) {
        RELEASE_LOG(@"[RELEASE] auth | requiresToken=1 token=missing");
        BOOL resultWillNotify = tokenValidation || manualActive || installBaseline;
        sn_release_set_token_status_locked(defs, @"missing", !resultWillNotify);
        if (tokenValidation) {
            sn_release_post_manual_result_locked(manualRequestID, @"unverified", nil, nil, nil);
            return;
        }
        if (installBaseline) {
            BOOL queued = sn_release_queue_token_alert_locked(@"missing");
            RELEASE_LOG(@"[RELEASE] install baseline | result=missingToken notification=%@",
                        queued ? @"queued" : @"alreadyShown");
            sn_release_complete_install_cycle_locked(defs, 0, @"missingToken");
        } else {
            if (!manualOrigin) sn_release_queue_token_alert_locked(@"missing");
            sn_release_save_completion_locked(0, @"missingToken", kReleaseNormalInterval);
        }
        if (manualActive) {
            sn_release_post_manual_result_locked(manualRequestID, @"missingToken", nil, nil, nil);
        }
        return;
    }

    if (!tokenValidation) {
        bool expected = false;
        if (!gReleaseCheckInFlight.compare_exchange_strong(expected, true,
                                                            std::memory_order_acq_rel)) {
            RELEASE_LOG(@"[RELEASE] check skip | reason=inFlight");
            if (manualActive) {
                sn_release_post_manual_result_locked(manualRequestID, @"checkInProgress", nil, nil, nil);
            }
            return;
        }
    }

    NSURL *url = [NSURL URLWithString:kReleaseAPIURLString];
    if (!sn_release_allowed_api_url(url)) {
        gReleaseCheckInFlight.store(false, std::memory_order_release);
        sn_release_post_manual_result_locked(manualRequestID, @"invalidResponse", nil, nil, nil);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25.0];
    request.HTTPMethod = @"GET";
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    [request setValue:[NSString stringWithFormat:@"SpeakNotification16/%@", kReleaseInstalledVersion]
        forHTTPHeaderField:@"User-Agent"];
    if (token.length > 0) {
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token]
            forHTTPHeaderField:@"Authorization"];
    }
    NSString *etag = [defs stringForKey:kReleaseETagKey];
    if (etag.length > 0) [request setValue:etag forHTTPHeaderField:@"If-None-Match"];

    RELEASE_LOG(@"[RELEASE] auth | requiresToken=%d token=%@",
                kSNReleaseRepoRequiresToken,
                token.length > 0 ? @"present" : @"missing");

    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.URLCache = nil;
    configuration.HTTPCookieStorage = nil;
    configuration.HTTPShouldSetCookies = NO;
    configuration.HTTPMaximumConnectionsPerHost = 1;
    configuration.timeoutIntervalForRequest = 25.0;
    configuration.timeoutIntervalForResource = 30.0;

    SNReleaseSessionDelegate *delegate = [[[SNReleaseSessionDelegate alloc] init] autorelease];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
                                                           delegate:delegate
                                                      delegateQueue:nil];
    NSString *requestToken = [token copy];
    NSString *requestID = [manualRequestID copy];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            [session finishTasksAndInvalidate];
            dispatch_async(gReleaseQueue, ^{
                sn_release_process_response_locked(data, response, error,
                                                   requestToken, requestID, mode);
            });
        }];
    [task resume];
    [requestToken release];
    [requestID release];
}

static void sn_release_force_check(void)
{
    if (!gReleaseQueue || !sn_release_is_springboard()) return;
    NSUserDefaults *defs = sn_release_defaults();
    [defs synchronize];
    NSString *requestID = [[defs stringForKey:kReleaseManualRequestIDKey] copy];
    dispatch_async(gReleaseQueue, ^{
        sn_release_cancel_timer_locked();
        if (requestID.length > 0) {
            RELEASE_LOG(@"[RELEASE] manual check request | requestID=%@", requestID);
        }
        sn_release_perform_check_locked(YES, requestID, SNReleaseCheckModeNormal);
        [requestID release];
    });
}

static void SNReleaseTokenClearedChanged(__unused CFNotificationCenterRef center,
                                         __unused void *observer,
                                         __unused CFStringRef name,
                                         __unused const void *object,
                                         __unused CFDictionaryRef userInfo)
{
    if (!gReleaseQueue || !sn_release_is_springboard()) return;
    dispatch_async(gReleaseQueue, ^{
        NSUserDefaults *defs = sn_release_defaults();
        [defs removeObjectForKey:kReleaseTokenValidationRequestIDKey];
        [defs removeObjectForKey:kReleaseTokenValidationResultStatusKey];
        [defs removeObjectForKey:kReleaseTokenValidationResultRequestIDKey];
        sn_release_set_token_status_locked(defs, @"missing", NO);
        [defs synchronize];
        RELEASE_LOG(@"[RELEASE] token cleared | source=settings action=noAutomaticCheck");
    });
}

static void SNReleaseTokenValidationChanged(__unused CFNotificationCenterRef center,
                                            __unused void *observer,
                                            __unused CFStringRef name,
                                            __unused const void *object,
                                            __unused CFDictionaryRef userInfo)
{
    if (!gReleaseQueue || !sn_release_is_springboard()) return;
    NSUserDefaults *defs = sn_release_defaults();
    [defs synchronize];
    NSString *requestID = [[defs stringForKey:kReleaseTokenValidationRequestIDKey] copy];
    if (requestID.length == 0) {
        [requestID release];
        return;
    }
    dispatch_async(gReleaseQueue, ^{
        sn_release_perform_check_locked(YES, requestID, SNReleaseCheckModeTokenValidation);
        [requestID release];
    });
}

static void SNReleaseCheckNowChanged(__unused CFNotificationCenterRef center,
                                     __unused void *observer,
                                     __unused CFStringRef name,
                                     __unused const void *object,
                                     __unused CFDictionaryRef userInfo)
{
    sn_release_force_check();
}

static void SNReleaseAlertsPreferencesChanged(void)
{
    if (!gReleaseQueue || !sn_release_is_springboard()) return;
    sn_release_reload_debug();
    dispatch_async(gReleaseQueue, ^{
        NSUserDefaults *defs = sn_release_defaults();
        [defs synchronize];
        NSString *wiredDiagnostic = [defs stringForKey:kWiredAudioDiagnosticKey];
        if (wiredDiagnostic.length) {
            if (gReleaseDebug.load(std::memory_order_acquire)) {
                RELEASE_LOG(@"[WIRED-TEST] %@", wiredDiagnostic);
            }
            [defs removeObjectForKey:kWiredAudioDiagnosticKey];
            [defs synchronize];
        }
        BOOL enabled = sn_release_enabled(defs);
        NSString *token = sn_release_token(defs);
        BOOL relevantChange = !gReleasePrefsSnapshotValid ||
            enabled != gReleaseLastEnabled ||
            ![token isEqualToString:(gReleaseLastToken ?: @"")];
        gReleasePrefsSnapshotValid = YES;
        gReleaseLastEnabled = enabled;
        [gReleaseLastToken release];
        gReleaseLastToken = [token copy];
        if (!relevantChange) return;

        if (!enabled) {
            sn_release_cancel_timer_locked();
            sn_release_cancel_flush_retry_locked(@"noPending");
            [defs removeObjectForKey:kReleaseNextCheckKey];
            [defs synchronize];
            sn_release_clear_in_memory_pending();
            RELEASE_LOG(@"[RELEASE] check skip | reason=disabled");
            return;
        }

        if (sn_release_install_cycle_pending(defs)) {
            if (!gReleaseTimer && !gReleaseCheckInFlight.load(std::memory_order_acquire)) {
                sn_release_schedule_install_baseline_locked(kReleaseInitialDelay);
            }
            return;
        }
        sn_release_rehydrate_pending_locked();
        if (gReleaseHasPending.load(std::memory_order_acquire) &&
            !sn_release_request_cached_flush(@"prefsChanged")) {
            sn_release_schedule_flush_retry_locked();
        }
        sn_release_cancel_timer_locked();
        if (!gReleaseCheckInFlight.load(std::memory_order_acquire)) {
            sn_release_schedule_locked(1.0, @"prefsChanged");
        }
    });
}

static void SNReleaseAlertsStart(void)
{
    if (!sn_release_is_springboard() || gReleaseQueue) return;
    sn_release_reload_debug();
    gReleaseQueue = dispatch_queue_create("com.selandros.speaknotification16.release",
                                          DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(gReleaseQueue,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    SNReleaseCheckNowChanged,
                                    kSNReleaseCheckNowNotify,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    SNReleaseTokenValidationChanged,
                                    kSNReleaseTokenValidationNowNotify,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    SNReleaseTokenClearedChanged,
                                    kSNReleaseTokenClearedNotify,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    dispatch_async(gReleaseQueue, ^{
        NSUserDefaults *defs = sn_release_defaults();
        [defs synchronize];
        BOOL enabled = sn_release_enabled(defs);
        NSString *token = sn_release_token(defs);
        gReleasePrefsSnapshotValid = YES;
        gReleaseLastEnabled = enabled;
        [gReleaseLastToken release];
        gReleaseLastToken = [token copy];
        if (!enabled) {
            RELEASE_LOG(@"[RELEASE] check skip | reason=disabled");
            return;
        }
        sn_release_rehydrate_pending_locked();
        NSString *installID = sn_release_install_id(defs);
        NSString *processedInstallID = [defs stringForKey:kReleaseLastProcessedInstallIDKey];
        if (sn_release_install_cycle_pending(defs)) {
            sn_release_cancel_timer_locked();
            [defs removeObjectForKey:kReleaseTokenAlertShownKey];
            [defs removeObjectForKey:kReleaseTokenAlertPendingKey];
            [defs removeObjectForKey:kReleaseTokenAlertKindKey];
            sn_release_clear_pending_token();
            RELEASE_LOG_VERBOSE(@"[RELEASE] token alert state | shown=0 reset=1 reason=newInstall");
            sn_release_clear_pending_update_for_install_locked(defs);
            [defs removeObjectForKey:kReleaseNextCheckKey];
            [defs synchronize];
            RELEASE_LOG_VERBOSE(@"[RELEASE] install cycle reset | installID=%@ previous=%@",
                        installID,
                        processedInstallID.length > 0 ? processedInstallID : @"-");
            sn_release_schedule_install_baseline_locked(kReleaseInitialDelay);
            return;
        }
        if (gReleaseHasPending.load(std::memory_order_acquire) &&
            !sn_release_request_cached_flush(@"initialRehydrate")) {
            sn_release_schedule_flush_retry_locked();
        }
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        NSTimeInterval persistedNext = [defs doubleForKey:kReleaseNextCheckKey];
        NSTimeInterval delay = kReleaseInitialDelay;
        if (persistedNext > now + delay) delay = persistedNext - now;
        sn_release_schedule_locked(delay, @"initial");
    });
}
#undef RELEASE_LOG_VERBOSE
#undef RELEASE_LOG

#pragma mark - BBServer Hook

static uint64_t SN_Seq = 0;

%hook BBServer
- (id)initWithQueue:(id)queue
{
    id result = %orig;
    SNReleaseAlertsHandleBBServerLifecycle(result);
    return result;
}

- (id)initWithQueue:(id)queue
 dataProviderManager:(id)dataProviderManager
         syncService:(id)syncService
  dismissalSyncCache:(id)dismissalSyncCache
    observerListener:(id)observerListener
     conduitListener:(id)conduitListener
    settingsListener:(id)settingsListener
{
    id result = %orig;
    SNReleaseAlertsHandleBBServerLifecycle(result);
    return result;
}

- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations
{
    SNReleaseAlertsHandleBBServerEntry(self, bulletin, destinations);
    @autoreleasepool {
        BOOL allowTTS = YES;
        BOOL didOrig = NO;

        @try {
            uint64_t seq = __atomic_add_fetch(&SN_Seq, 1, __ATOMIC_RELAXED);

            NSString *title       = SN_GetStringPropOrKVC(bulletin, @"title", @"title");
            NSString *subtitle    = SN_GetStringPropOrKVC(bulletin, @"subtitle", @"subtitle");
            NSString *body        = SN_GetStringPropOrKVC(bulletin, @"message", @"message");
            NSString *sectionID   = SN_GetStringPropOrKVC(bulletin, @"sectionID", @"sectionID");
            NSString *bulletinID  = SN_GetStringPropOrKVC(bulletin, @"bulletinID", @"bulletinID");
            NSString *publisherID = SN_GetStringPropOrKVC(bulletin, @"publisherBulletinID", @"publisherBulletinID");

            if (body.length == 0 && subtitle.length > 0) body = subtitle;
            uint64_t receivedMS = SN_AuditNowMS();
            sn_audit_begin_intake(seq, @{
                @"receivedMs": @(receivedMS),
                @"bulletinID": (bulletinID.length ? bulletinID : @"-"),
                @"publisherID": (publisherID.length ? publisherID : @"-"),
                @"sectionID": (sectionID.length ? sectionID : @"-"),
                @"titleLen": @(title.length),
                @"subtitleLen": @(subtitle.length),
                @"bodyLen": @(body.length)
            });
            
            NSString *bodySan  = [SNStringUtils sanitizeForTTS:(body ?: @"")];
            NSString *normTitleOnce = [SNStringUtils normalizedTitle:(title ?: @"")];
            NSString *titleSan = normTitleOnce ?: @"";

            BOOL locked = [SNDeviceState isDeviceLocked];
            float mediaVol = [SNMediaControl currentMediaVolume];
            int volPct = (int)lrintf(mediaVol * 100.0f);
            BOOL mutedKnown = NO;
            BOOL mutedRaw = [SNMediaControl ringerMutedKnown:&mutedKnown];
            NSString *mutedStr = !mutedKnown ? @"NotWorking" : (mutedRaw ? @"YES" : @"NO");
            BOOL otherAu = NO; @try { otherAu = [[AVAudioSession sharedInstance] isOtherAudioPlaying]; } @catch (...) {}

            NSString *fgBID = SNAppStateTryForegroundBID();
            NSString *fgName = SNAppStateTryForegroundName();
            if (locked && fgBID.length == 0) { fgBID = @"com.apple.springboard"; fgName = @"SpringBoard (locked)"; }

            int brightPct = SN_ScreenBrightnessPercent();
            NSString *orient = SN_OrientationString();
            int battPct = SN_BatteryLevelPercent();
            NSString *battState = SN_BatteryStateString(UIDevice.currentDevice.batteryState);
            BOOL lpm = SN_LowPowerModeEnabled();
            NSDictionary *auditIngress = nil;

            if (allowTTS) {
                NSUserDefaults *defs = [[[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite] autorelease];
                BOOL onlyTrusted = NO;
                id toggleObj = [defs objectForKey:kSNTrustedToggleKey];
                if ([toggleObj isKindOfClass:NSNumber.class]) onlyTrusted = [toggleObj boolValue];
                NSDictionary *trustedResult = SN_EvaluateTrustedConnections(onlyTrusted);
                BOOL blocked = NO;
                NSString *policyBlockReason = nil;

                NSString *npBID = nil, *npName = nil, *npRoute = nil; BOOL npPlaying = NO;
                SNAudioNowPlayingProbe(&npBID, &npName, &npPlaying, &npRoute);

                auditIngress = @{
                    @"seq": @(seq), @"receivedMs": @(receivedMS),
                    @"sectionID": (sectionID.length ? sectionID : @"-"),
                    @"titleLen": @(title.length), @"subtitleLen": @(subtitle.length), @"bodyLen": @(body.length),
                    @"wifi": (trustedResult[@"wifi"] ?: @"-"),
                    @"bluetooth": (trustedResult[@"bluetooth"] ?: @"-"),
                    @"wired": (trustedResult[@"wired"] ?: @"-"),
                    @"broadWired": (trustedResult[@"broadWired"] ?: @"disabled"),
                    @"trust": (trustedResult[@"result"] ?: @"deny"),
                    @"trustedBy": (trustedResult[@"trustedBy"] ?: @"none"),
                    @"route": (npRoute.length ? npRoute : @"-"),
                    @"otherAudio": (otherAu ? @"YES" : @"NO"), @"volume": @(volPct), @"muted": (mutedStr ?: @"-"),
                    @"locked": (locked ? @"YES" : @"NO"),
                    @"foreground": (fgBID.length ? [NSString stringWithFormat:@"%@(%@)", fgBID, (fgName ?: @"-")] : @"-"),
                    @"screen": [NSString stringWithFormat:@"%d%% %@", brightPct, (orient ?: @"-")],
                    @"battery": [NSString stringWithFormat:@"%d%%(%@) lowPower=%@", battPct, (battState ?: @"-"), (lpm ? @"YES" : @"NO")],
                    @"queue": @"none", @"policy": @"notEvaluated",
                    @"callGate": @"notEvaluated", @"sound": @"notAttempted",
                    @"format": @"notEvaluated", @"lang": @"notEvaluated",
                    @"langReason": @"notEvaluated", @"langDiagnostic": @"notEvaluated",
                    @"voiceName": @"notEvaluated", @"action": @"notEvaluated", @"result": @"notEvaluated"
                };

                if (!blocked && onlyTrusted) {
                    if (![trustedResult[@"allowed"] boolValue]) {
                        /*if (DBG_POLICY_ON) SNLOGFMT(@"[POLICY] blocked: untrusted connection (SSID/BT/Wired) | onlyTrusted=1");*/
                        blocked = YES;
                        policyBlockReason = @"untrusted";
                    }
                }

                if (!blocked && SN_BlockOnMutePref() && sn_isRingerMuteActive()) {
                    /*if (DBG_POLICY_ON) SNLOGFMT(@"[POLICY] blocked: mute switch active");*/
                    blocked = YES;
                    policyBlockReason = @"ringerMuted";
                }

                BOOL speakUnlockedOnly = gPrefSpeakUnlockedCached;
                if (!blocked && speakUnlockedOnly && [SNDeviceState isDeviceLocked]) {
                    /*if (DBG_POLICY_ON) SNLOGFMT(@"[POLICY] blocked: device locked + speakWhenUnlocked=1");*/
                    blocked = YES;
                }

                if (!gPrefEnabledCached) {
                    allowTTS = NO;
                    sn_audit_emit_denied(auditIngress, @"disabled");
                    didOrig = YES;
                    %orig(bulletin, destinations);
                    return;
                }

                // Global "block when app is open"
                sn_rebuild_filter_cache_if_needed();
                if (allowTTS) {
                    NSString *fg = fgBID ?: @"";
                    if (fg.length && [gBlockWhenOpenSet containsObject:fg]) {
                        /*if (DBG_APP_ON) SNLOGFMT(@"[APP] blocked: foreground app in global block list | fg=%@", fg);*/
                        allowTTS = NO;
                        sn_audit_emit_denied(auditIngress, @"foregroundBlocked");
                        didOrig = YES;
                        %orig(bulletin, destinations);
                        return;
                    }
                }

                // Self-block: never speak notifications from the foreground app
                if (allowTTS) {
                    NSString *fg  = fgBID ?: @"";
                    NSString *sec = sectionID ?: @"";
                    if (fg.length && sec.length && [fg isEqualToString:sec]) {
                        /*if (DBG_APP_ON) SNLOGFMT(@"[APP] blocked: app is foreground | app=%@", sec);*/
                        allowTTS = NO;
                        sn_audit_emit_denied(auditIngress, @"foregroundSelf");
                        didOrig = YES;
                        %orig(bulletin, destinations);
                        return;
                    }
                }

                // Whitelist/blacklist policy
                if (allowTTS && !sn_isAppAllowed(sectionID ?: @"")) {
                        /*if (DBG_APP_ON) SNLOGFMT(@"[APP] blocked: not whitelisted | app=%@", (sectionID ?: @"-"));*/
                        allowTTS = NO;
                    sn_audit_emit_denied(auditIngress, @"appNotAllowed");
                    didOrig = YES;
                    %orig(bulletin, destinations);
                    return;
                }

                if (blocked) {
                    allowTTS = NO;
                    sn_audit_emit_denied(auditIngress, policyBlockReason ?: @"policyBlocked");
                    didOrig = YES;
                    %orig(bulletin, destinations);
                    return;
                }

                BOOL callGateBlocked = sn_callgate_should_block();
                BOOL callGateAllowed = !callGateBlocked && SN_ShouldSpeakNow();
                if (allowTTS && !callGateAllowed) {
                    allowTTS = NO;
                    sn_audit_emit_denied(auditIngress, callGateBlocked ? @"callActive" : @"interruption");
                    didOrig = YES;
                    %orig(bulletin, destinations);
                    return;
                }
                sn_audit_update_sequence(seq, @{@"callGate": @"allow"});

                if (bulletinID.length > 0 && sn_seen_check_and_add_once(bulletinID)) {
                    sn_audit_emit_denied(auditIngress, @"duplicateBulletin");
                    didOrig = YES;
                    %orig(bulletin, destinations);
                    return;
                }

                // Anti-spam / burst window
                SN_BurstInitOnce();
                if (allowTTS) {
                    BOOL antiSpamOn = gPrefMuteSpamCached;
                    gWindowSec = gPrefSpamWindowCached;
                    double d = [defs objectForKey:@"spamCooldownSeconds"] ? [defs doubleForKey:@"spamCooldownSeconds"] : kSNDefaultSpamWindowSec;
                    gWindowSec = (d >= 0.0 ? d : kSNDefaultSpamWindowSec);
                    /*if (DBG_BURST_ON) SNLOGFMT(@"[BURST] cfg on=%d window=%.0f", (int)antiSpamOn, gWindowSec);*/
                    if (antiSpamOn && gWindowSec > 0.0) {
                        NSString *burstKey = sn_make_burst_key(sectionID, titleSan, bodySan);
                        SNBurstEvent *burstEvent = [gBurstTracker registerEventForKey:burstKey now:[NSDate.date timeIntervalSince1970] window:gWindowSec];
                        BOOL identicalBodySeen = [gBurstTracker isIdenticalBodyAndUpdateForKey:burstKey body:bodySan];
                        BOOL identicalBodyInWindow = (!burstEvent.isFirst && identicalBodySeen);
                        [burstEvent release];

                        BOOL alreadySpokenInWindow = sn_burst_spoken_recently(burstKey, gWindowSec);
                        if (alreadySpokenInWindow || identicalBodyInWindow) {
                            sn_seen_remove(bulletinID);
                            allowTTS = NO;
                            sn_audit_emit_denied(auditIngress, @"burstDuplicate");
                            didOrig = YES;
                            %orig(bulletin, destinations);
                            return;
                        } else {
                            gBurstDropSinceLastSpeak.store(false, std::memory_order_release);
                        }
                        [gBurstTracker pruneIdleEntriesOlderThan:(gWindowSec * 3.0)];
                    }
                }

            }

            NSString *auditSound = @"notAttempted";
            NSDictionary *auditPlan = nil;

            // All synchronous speech eligibility checks have passed.
            if (allowTTS) {
                SN_TTS_InitOnce();
                auditSound = sn_try_suppress_notification_sound(bulletin, sectionID, publisherID, bulletinID);
            }

            // Build message and choose language
            NSString *formatStr = nil, *msg = nil, *bcp47 = nil;
            if (allowTTS) {
                NSString *fmtSrc = nil;
                formatStr = SN_ResolveFormat(sectionID, publisherID, &fmtSrc);
                if (DBG_APP_ON) SNLOGFMT(@"[APP] fmtSource=%@ app=%@", (fmtSrc ?: @"-"), SN_AppLabelForLog(sectionID, bulletin));

                NSString *timeStr = SN_HHMM_Now();

                NSString *appName = SN_AppDisplayNameForSection(sectionID, bulletin);
                NSString *sender  = (subtitle.length ? subtitle : (title ?: @""));
                msg = [SNStringUtils formatTokens:formatStr
                                              app:appName
                                              title:title
                                              sender:sender
                                              body:body
                                              timeHHMM:timeStr];
                if (msg.length == 0) {
                    if      (body.length)   msg = body;
                    else if (title.length)  msg = title;
                    else if (sender.length) msg = sender;
                }

                title = normTitleOnce;
                if (sn_should_strip_emoji_for(sectionID, publisherID)) {
                    title    = [SNStringUtils stripEmoji:title];
                    subtitle = [SNStringUtils stripEmoji:subtitle];
                    msg      = [SNStringUtils stripEmoji:msg];
                }
                msg = [SNStringUtils sanitizeForTTS:msg];
                NSString *languageSource = bodySan.length ? @"body" : (title.length ? @"title" : @"subtitle");
                NSString *languageSourceText = bodySan.length ? bodySan : (title.length ? title : subtitle ?: @"");
                NSString *detectedLanguage = nil;
                NSString *languageReason = nil;
                NSString *languageDiagnostic = nil;
                bcp47 = sn_detect_language_nl(languageSourceText, &detectedLanguage, &languageReason, &languageDiagnostic);
                if (DBG_LANG_ON) {
                    SNLOGFMT(@"[LANG] source=%@ %@ detected=%@ final=%@",
                             languageSource,
                             languageDiagnostic.length ? languageDiagnostic : @"chars=0 words=0 candidates=- system=- chosen=- reason=noCandidate",
                             (detectedLanguage.length ? detectedLanguage : @"-"),
                             (bcp47.length ? bcp47 : @"-"));
                }
                NSMutableDictionary *auditMutable = [auditIngress mutableCopy] ?: [[NSMutableDictionary alloc] init];
                auditMutable[@"sound"] = auditSound ?: @"-";
                auditMutable[@"format"] = fmtSrc ?: @"-";
                auditMutable[@"lang"] = bcp47 ?: @"-";
                auditMutable[@"langReason"] = languageReason ?: @"-";
                auditMutable[@"langDiagnostic"] = languageDiagnostic ?: @"-";
                auditMutable[@"callGate"] = @"allow";
                auditPlan = [auditMutable autorelease];
#if !__has_feature(objc_arc)
                [detectedLanguage release];
                [languageDiagnostic release];
#endif
            }

            if (!allowTTS) {
                if (![SNCancellation isSpeaking] && sn_queue_count() == 0) {
                    sn_idle_maybe_release_to_ringer_with_reason("AllowOrig");
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSNTryNextSpeakDelaySec * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (![SNCancellation isSpeaking] && sn_queue_count() > 0) (void)sn_try_speak_next_from_queue("allowTTS");
                });
                sn_schedule_idle_session_cleanup_ms(sn_idle_ms_for_current_route());
                didOrig = YES;
                %orig(bulletin, destinations);
                return;
            }

                NSString *capSpeakTitle = @"";
                NSString *capTitle      = [titleSan copy];
                NSString *capMsg        = [msg copy];
                NSString *capBCP47      = bcp47 ? [bcp47 copy] : nil;
                NSString *capSection    = sectionID ? [sectionID copy] : nil;
                NSInteger prefDebounceMs = sn_pref_debounce_ms();

                dispatch_async(sTTSQueue, ^{
                    @autoreleasepool {
                        {
                            NSInteger dbMs = prefDebounceMs;
                            if (dbMs > 0) {
                                if (DBG_POLICY_VERBOSE_ON && sn_log_once_txn(gDebounceLoggedTxn, seq)) {
                                    SNLOGFMT(@"[POLICY] debounce %ld ms", (long)dbMs);
                                }
                                usleep((useconds_t)dbMs * 1000);
                            }
                        }
                        dispatch_async(dispatch_get_main_queue(), ^{
                            @autoreleasepool {
                                uint64_t txn = sn_new_txn();
                                sn_audit_begin(txn, seq, auditPlan ?: auditIngress);
                                uint32_t tail = (uint32_t)kSNSiriInterTailMs;
                                uint32_t cap  = (uint32_t)kSNSiriInterTailCapMs;
                                BOOL carplay = SN_IsCarPlayUnlocked();
                                if (carplay) {
                                    tail = (uint32_t)kSNSiriInterTailCarPlayMs;
                                    cap  = (uint32_t)kSNSiriInterTailCarPlayCapMs;
                                }
                                tail = sn_clamp_siri_guard_ms(tail, cap);
                                if (DBG_POLICY_ON && tail > 0) {
                                    if (sn_log_once_txn(gSiriTailLoggedTxn, txn))
                                        SNLOGFMT(@"[POLICY] siri-guard tail %u ms (cap %u)", tail, cap);
                                }

                                /*BOOL didClear = NO;*/
                                /*uint32_t elapsed = SNG_WaitForInterruptionClearThenTailMS_Ex(tail, cap, &didClear);*/
                                /*unsigned long long _siriShown = (unsigned long long)(elapsed > cap ? cap : elapsed);*/

                                dispatch_async(dispatch_get_main_queue(), ^{
                                    if (DBG_POLICY_ON) {
                                        /*if (sn_log_once_txn(gSiriWaitLoggedTxn, txn)) {
                                            SNLOGFMT(@"[POLICY] siri-guard waited %llums (tail=%u cap=%u) reason=%s",
                                                     _siriShown, tail, cap, (didClear ? "cleared" : "timeout"));
                                        }*/
                                    }

                                    NSString *cleanMsg = [SNStringUtils sanitizeForTTS:capMsg];
                                    NSString *burstKey = sn_make_burst_key(capSection, capTitle, cleanMsg);

                                    if (DBG_ENGINE_VERBOSE_ON) SNLOGFMT(@"[TTS] txn=%llu plan",
                                                             (unsigned long long)txn);

                                    if (sn_handle_start_in_flight(capTitle, capMsg, capBCP47, capSection, txn)) {
                                        [capTitle release]; [capMsg release]; [capBCP47 release]; [capSection release];
                                        return;
                                    }

                                    // Normal duck-chain path
                                    if (gDuckMgr && gDuckChainAlive) {
                                        if ([SNCancellation isSpeaking]) {
                                            BOOL qOn = SN_PrefBoolFast(@"queueNotifications", NO);
                                            if (qOn) {
                                                sn_queue_enqueue(capTitle, capMsg, capBCP47, capSection,
                                                                 txn, "chain-speaking", gCurrentTxn.load(std::memory_order_acquire));
                                                if (DBG_POLICY_ON) SNLOGFMT(@"[POLICY] enqueue (chain alive & speaking) | app=%@", SN_AppLabelForLog(capSection, nil));
                                                sn_queue_progress_nudge_after_ms(kSNQueueProgressNudgeLongMs);
                                                [capTitle release]; [capMsg release]; [capBCP47 release]; [capSection release];
                                                return;
                                            } else {
                                                SN_CancelAll("QueueOff");
                                                if (DBG_POLICY_ON) SNLOGFMT(@"[POLICY] queue OFF -> interrupt current and speak now");
                                                gDidReleaseToRinger.store(false, std::memory_order_release);
                                                sn_start_duck_chain_and_tts(capTitle, capMsg, capBCP47, capSection, txn);
                                                [capTitle release]; [capMsg release]; [capBCP47 release]; [capSection release];
                                                return;
                                            }
                                        } else {
                                            if (gLastDuckMode == SNDuckModePause) {
                                                (void)[SNEngineAV activateForTTSWithDuck:NO];
                                            }
                                            sn_reserve_start_txn(txn);
                                            sn_apply_tts_volume_policy(txn);
                                            if (gDuckMgr.inPostRoll) [gDuckMgr extendPostRoll];
                                            gCancelPostedTxn.store(0, std::memory_order_release);
                                            sn_finish_once_reset(txn);
                                            sn_reset_grace_armed();

	                                            sn_mark_burst_spoken_nowForKey_sync(burstKey);
	                                            sn_log_speak(capSpeakTitle, cleanMsg, capBCP47);
	                                            sn_increment_spoken_count_for_app(capSection);
	                                            gDidReleaseToRinger.store(false, std::memory_order_release);
                                            if (g_sn_postSpeakHold) {
                                                if (DBG_POLICY_ON) SNLOGFMT(@"[POLICY] post-speak hold -> soft debounce");
                                                int dms = (int)sn_pref_debounce_ms();
                                                g_sn_postSpeakHold = NO;
                                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dms * NSEC_PER_MSEC)),
                                                               dispatch_get_main_queue(), ^{
                                                    sn_speak_reserved(capSpeakTitle, cleanMsg, capBCP47, txn);
                                                });
                                            } else {
                                                sn_speak_reserved(capSpeakTitle, cleanMsg, capBCP47, txn);
                                            }
                                        }
                                        if (DBG_POLICY_VERBOSE_ON) SNLOGFMT(@"[POLICY] reuse fast-chain (active=%d post=%d)", gDuckMgr.activeDuck, gDuckMgr.inPostRoll);
                                        [capTitle release]; [capMsg release]; [capBCP47 release]; [capSection release];
                                        return;
                                    }

                                    BOOL hardBusy = sn_speech_channel_busy_now();
                                    if (hardBusy) {
                                        (void)sn_wait_for_clear_channel(kSNBusyWaitMaxSec);
                                        if (sn_speech_channel_busy_now()) {
                                            BOOL qOn = SN_PrefBoolFast(@"queueNotifications", NO);
                                            if (qOn) {
                                                sn_queue_enqueue(capTitle, capMsg, capBCP47, capSection,
                                                                 txn, "busy-after-wait", gCurrentTxn.load(std::memory_order_acquire));
                                                if (DBG_POLICY_ON) SNLOGFMT(@"[POLICY] enqueue (busy after wait) | app=%@", SN_AppLabelForLog(capSection, nil));
                                                sn_queue_progress_nudge_after_ms(kSNQueueProgressNudgeLongMs);
                                                [capTitle release]; [capMsg release]; [capBCP47 release]; [capSection release];
                                                return;
                                            } else {
                                                SN_CancelAll("QueueOff");
                                                if (DBG_POLICY_ON) SNLOGFMT(@"[POLICY] queue OFF -> interrupt busy and speak now");
                                                gDidReleaseToRinger.store(false, std::memory_order_release);
                                                sn_start_duck_chain_and_tts(capTitle, capMsg, capBCP47, capSection, txn);
                                                [capTitle release]; [capMsg release]; [capBCP47 release]; [capSection release];
                                                return;
                                            }
                                        }
                                    }
                                    gDidReleaseToRinger.store(false, std::memory_order_release);
                                    sn_start_duck_chain_and_tts(capTitle, capMsg, capBCP47, capSection, txn);
                                    [capTitle release];
                                    [capMsg release];
                                    [capBCP47 release];
                                    [capSection release];
                                });
                            }
                        });
                    }
                });
        } @catch (NSException *ex) {
            if (DBG_NOTIF_ON) SNLOGFMT(@"[NOTIF] exception: %@", ex);
            sn_preflight_finalize_block(NO, "Exception", bulletin);
            %orig(bulletin, destinations);
            return;
        }
        %orig(bulletin, destinations);
        (void)didOrig;
        return;
    }
}
%end

%hook SBVolumeHardwareButton
- (void)volumeIncreasePress:(id)press
{
    (void)press;
    if ([SNCancellation isSpeaking] &&
        sn_cancel_mode_accepts_volume([SNCancellation cancelMode])) {
        gLastPhysicalVolumeDirection.store(SNVolumeDirectionUp, std::memory_order_release);
    }
    sn_handle_cancel_candidate("VolumeButton", @"volumeUp", SNCancelCandidateVolume);
    %orig(press);
}

- (void)volumeDecreasePress:(id)press
{
    (void)press;
    if ([SNCancellation isSpeaking] &&
        sn_cancel_mode_accepts_volume([SNCancellation cancelMode])) {
        gLastPhysicalVolumeDirection.store(SNVolumeDirectionDown, std::memory_order_release);
    }
    sn_handle_cancel_candidate("VolumeButton", @"volumeDown", SNCancelCandidateVolume);
    %orig(press);
}
%end

%hook SBVolumeControl
- (void)increaseVolume
{
    if ([SNCancellation isSpeaking] &&
        sn_cancel_mode_accepts_volume([SNCancellation cancelMode])) {
        gLastPhysicalVolumeDirection.store(SNVolumeDirectionUp, std::memory_order_release);
    }
    sn_handle_cancel_candidate("VolumeButton", @"volumeUp", SNCancelCandidateVolume);
    %orig;
}

- (void)decreaseVolume
{
    if ([SNCancellation isSpeaking] &&
        sn_cancel_mode_accepts_volume([SNCancellation cancelMode])) {
        gLastPhysicalVolumeDirection.store(SNVolumeDirectionDown, std::memory_order_release);
    }
    sn_handle_cancel_candidate("VolumeButton", @"volumeDown", SNCancelCandidateVolume);
    %orig;
}

- (void)setMediaVolume:(float)value
{
    float oldVolume = sSN_VolInit ? sSN_LastVol : [SNMediaControl currentMediaVolume];
    %orig(value);
    sn_handle_system_volume_change(@"SBVolumeControl.setMediaVolume", oldVolume, value);
}

- (void)setVolume:(float)value
{
    float oldVolume = sSN_VolInit ? sSN_LastVol : [SNMediaControl currentMediaVolume];
    %orig(value);
    sn_handle_system_volume_change(@"SBVolumeControl.setVolume", oldVolume, value);
}
%end

%hook AVSystemController
- (BOOL)setVolumeTo:(float)value forCategory:(id)category
{
    float oldVolume = sSN_VolInit ? sSN_LastVol : [SNMediaControl currentMediaVolume];
    BOOL result = %orig(value, category);
    NSString *categoryName = [category isKindOfClass:NSString.class] ? (NSString *)category : @"-";
    if ([categoryName isEqualToString:@"Audio/Video"]) {
        sn_handle_system_volume_change(@"AVSystemController.setVolumeTo", oldVolume, value);
    }
    return result;
}
%end

#pragma mark - Initializer (ctor)

// Guard: never run inside CarPlay host processes.
static inline BOOL sn_is_carplay_host_process(void)
{
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if ([bid isEqualToString:@"com.apple.CarPlayTemplateUIHost"]) return YES;
    if ([bid isEqualToString:@"com.apple.CarPlayUIServer"]) return YES;
    NSString *pname = [NSProcessInfo processInfo].processName ?: @"";
    if ([pname isEqualToString:@"CarPlayTemplateUIHost"]) return YES;
    if ([pname isEqualToString:@"CarPlayUIServer"]) return YES;
    return NO;
}

%ctor
{
    static BOOL inited = NO; if (inited) return; inited = YES;
    if (sn_is_carplay_host_process()) {
        // Do not install any hooks here; CarPlay VC stack is sensitive.
        return;
    }
    @autoreleasepool {
        %init;
        UIDevice.currentDevice.batteryMonitoringEnabled   = YES;
        UIDevice.currentDevice.proximityMonitoringEnabled = YES;
    }

    gBlockWhenOpenSet = [[NSSet alloc] init];
    selSetSystemOutputVolume = NSSelectorFromString(@"setSystemOutputVolume:");
    selPauseIfPlayingPhone   = @selector(pauseIfPlayingPhoneMedia);
    selResumeIfPausedPhone   = @selector(resumeIfPausedPhoneMedia);

    SN_LoadCachedPrefs();
    SN_ReloadDebugFlag();
    sn_migrate_legacy_per_app_sound_suppress_overrides();
    SN_ApplyCancelModeFromPrefs();
    sn_seed_allowed_if_needed();
    SN_LoadEmojiStripCache();
    SN_EnsurePerAppDictExists();
    SN_LoadFormatsCache();

    // Siri/Maps (silence secondary audio hint)
    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionSilenceSecondaryAudioHintNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        NSNumber *type = n.userInfo[AVAudioSessionSilenceSecondaryAudioHintTypeKey];
        if ([type isKindOfClass:NSNumber.class]) {
            if (type.integerValue == AVAudioSessionSilenceSecondaryAudioHintTypeBegin) {
                sn_siriGate_set(YES);
            } else {
                sn_siriGate_set(NO);
            }
        }
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                              usingBlock:^(NSNotification *n){
        uint64_t warmupTxn = gA2DPSessionWarmupPendingTxn.load(std::memory_order_acquire);
        if (warmupTxn && !sn_a2dp_warmup_route_is_still_valid()) {
            sn_abort_a2dp_warmup(warmupTxn, "A2DPWarmupRouteChanged", @"routeChanged");
        }
        if (!sn_a2dp_warmup_route_is_still_valid()) {
            gA2DPWarmUntilMS.store(0, std::memory_order_release);
        }
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        NSNumber *type = n.userInfo[AVAudioSessionInterruptionTypeKey];
        if (type.integerValue != AVAudioSessionInterruptionTypeBegan) return;
        uint64_t warmupTxn = gA2DPSessionWarmupPendingTxn.load(std::memory_order_acquire);
        if (warmupTxn) {
            sn_abort_a2dp_warmup(warmupTxn, "A2DPWarmupInterruption", @"interruption");
        }
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:kSNEngineAVDidSelectVoice
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                              usingBlock:^(NSNotification *n) {
        NSDictionary *ui = n.userInfo ?: @{};
        uint64_t txn = [ui[kSNEngineAVUserInfoTransaction] unsignedLongLongValue];
        NSString *lang = ui[kSNEngineAVUserInfoLang] ?: @"-";
        NSString *name = ui[kSNEngineAVUserInfoVoiceName] ?: @"-";
        NSString *identifier = ui[kSNEngineAVUserInfoVoiceIdentifier] ?: @"-";
        NSString *source = ui[kSNEngineAVUserInfoVoiceSource] ?: @"-";
        NSInteger quality = [ui[kSNEngineAVUserInfoVoiceQuality] integerValue];
        sn_audit_update(txn, @{
            @"lang": lang, @"voiceName": name, @"voiceIdentifier": identifier,
            @"voiceSource": source, @"voiceQuality": sn_voice_quality_label(quality)
        });
        sn_audit_emit_notif(txn);
        if (!DBG_LANG_ON) return;
        BOOL unavailable = [source isEqualToString:@"unavailable"] || [identifier isEqualToString:@"-"];
        if (unavailable) {
            SNLOGFMT(@"[VOICE] unavailable | lang=%@", lang);
        } else if (gDebugLogs || DBG_LANG_VERBOSE_ON) {
            SNLOGFMT(@"[VOICE] lang=%@ name=%@ quality=%@ source=%@ identifier=%@",
                     lang, name, sn_voice_quality_label(quality), source, identifier);
        }
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:kSNEngineAVDidStart
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                              usingBlock:^(NSNotification *n) {
        uint64_t txn = sn_terminal_event_txn(n);
        NSString *route = n.userInfo[kSNEngineAVUserInfoRouteType] ?: @"-";
        sn_audit_record_engine_start(txn, route);
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:kSNEngineAVDidGenerationDrop
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                              usingBlock:^(NSNotification *n) {
        uint64_t txn = sn_terminal_event_txn(n);
        NSString *reason = n.userInfo[kSNEngineAVUserInfoTerminalReason];
        if (![reason isKindOfClass:NSString.class] || reason.length == 0) {
            reason = @"generationInvalidated";
        }
        sn_audit_record_engine_terminal(txn,
                                        @"dropped",
                                        reason,
                                        [SNMediaControl lastOutputPortType]);
    }];

    // Engine finished
    [[NSNotificationCenter defaultCenter] addObserverForName:kSNEngineAVDidFinish
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        uint64_t txn = sn_terminal_event_txn(n);
        if (!sn_terminal_txn_is_current(txn, "finish")) return;

        if (DBG_ENGINE_ON) {
            SNLOGFMT(@"[ENGINE] didFinish | txn=%llu utterance=notification",
                     (unsigned long long)txn);
        }

        if ([SNCancellation isSpeaking]) {
            if (DBG_ENGINE_ON) {
                /* partial finish suppressed: EngineAV posts finish after silence */
            }
            return;
        }

        NSString *auditEndRoute = n.userInfo[kSNEngineAVUserInfoRouteType] ?: @"-";
        sn_audit_record_engine_terminal(txn, @"finished", @"didFinish", auditEndRoute);

        if ((gPausedBySN || gPreWasPlaying) && sn_queue_count() == 0) {
            double nudgeDelay = kSNNotifyOthersNudgeSec;
            if (SN_IsCarPlayUnlocked()) nudgeDelay += kSNCarPlayNudgeExtraSec;
            sn_schedule_notify_others_nudge(nudgeDelay);
        }
        NSNumber *v = n.userInfo[kSNEngineAVUserInfoTailSec];
        NSString *route = n.userInfo[kSNEngineAVUserInfoRouteType];
        int ms = (int)((v ? v.doubleValue : SNEngineAVLastKeepaliveSec()) * 1000.0 + 0.5);
        sn_mark_a2dp_warm(txn, "tts-finish");
        if (ms > 0) {
            sn_arm_tail_keepalive_ms((uint32_t)ms);
        }
        if (DBG_ENGINE_VERBOSE_ON) SNLOGFMT(@"[ENGINE] tail keepalive armed: %d ms | route=%@", ms, route ?: @"?");
        if (DBG_ROUTE_ON && gLastRouteAtStart && route && ![gLastRouteAtStart isEqualToString:route]) {
            SNLOGFMT(@"[ROUTE] switched during TTS: start=%@ -> tail=%@", gLastRouteAtStart, route);
        }

        g_sn_postSpeakHold = NO;

        // GRACE PATH
        if (gDuckMgr && gDuckChainAlive) {
            int graceMs = (int)kSNGraceAfterFinishMs;
            if (SN_IsCarPlayUnlocked()) graceMs += (int)kSNCarPlayGraceExtraMs;

            uint64_t prev = gGraceScheduledTxn.load(std::memory_order_acquire);
            if (prev == txn) return;
            gGraceScheduledTxn.store(txn, std::memory_order_release);

            if (DBG_ENGINE_VERBOSE_ON) SNLOGFMT(@"[ENGINE] didFinish (grace %dms) | txn=%llu",
                                     graceMs, (unsigned long long)txn);

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)graceMs * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                if (!sn_terminal_txn_is_current(txn, "finish")) return;
                if ([SNCancellation isSpeaking]) {
                    if (DBG_ENGINE_VERBOSE_ON) SNLOGFMT(@"[ENGINE] grace saw new speech -> skip teardown");
                    return;
                }
                g_sn_postSpeakHold = NO;
                if (!sn_finish_once_try(txn)) {
                    if (sn_queue_count() > 0 && ![SNCancellation isSpeaking]) {
                        (void)sn_queue_finish_terminal("finish-guard-failed", txn);
                    } else if (sn_queue_count() == 0 && ![SNCancellation isSpeaking]) {
                        sn_schedule_idle_session_cleanup_ms(sn_idle_ms_for_current_route());
                    }
                    return;
                }
                if (sn_queue_count() == 0 && gBurstDropSinceLastSpeak.load(std::memory_order_acquire)) {
                    gBurstDropSinceLastSpeak.store(false, std::memory_order_release);
                    gIdleCooldownUntilMS.store(0, std::memory_order_release);
                    uint64_t expectedStartTxn = txn;
                    (void)gStartInFlightTxn.compare_exchange_strong(expectedStartTxn, 0, std::memory_order_acq_rel);
                    sn_volume_restore_if_terminal(txn, NO);
                    finishWork();
                    sn_idle_maybe_release_to_ringer_with_reason("BurstAfterFinish");
                    sn_schedule_idle_session_cleanup_ms(sn_idle_ms_for_current_route());
                    return;
                }

                // Post-finish hold (grace path)
                NSString *sn_port = [SNMediaControl lastOutputPortType] ?: @"";
                BOOL sn_unlocked = ![SNDeviceState isDeviceLocked];
                BOOL sn_isCar = ([sn_port isEqualToString:AVAudioSessionPortCarAudio] ||
                                 [sn_port rangeOfString:@"Car" options:NSCaseInsensitiveSearch].location != NSNotFound);

                int holdMs = sn_compute_post_hold_ms(sn_isCar, sn_unlocked, 0);
                sn_post_finish_hold_ms(holdMs, ^{
                    if (!sn_terminal_txn_is_current(txn, "finish")) return;
                    if ([SNCancellation isSpeaking]) return;

                    BOOL startedNext = sn_queue_finish_terminal("finish", txn);

                    if (!startedNext && gPausedBySN && gPreWasPlaying && ![SNCancellation isSpeaking] && sn_queue_count() == 0) {
                        sn_try_resume_or_schedule_poke_10s(txn);
                    }

                    if (!startedNext && sn_queue_count() == 0 && ![SNCancellation isSpeaking]) {
                        uint32_t idleMs = sn_idle_ms_for_current_route();
                        if (idleMs == 0) {
                            sn_idle_maybe_release_to_ringer_with_reason("PostHoldEmpty");
                            return;
                        }
                        sn_schedule_idle_session_cleanup_ms(idleMs);
                    }
                });
            });
            return;
        }
    
        // EARLY PATH
        if (sn_finish_is_too_early()) {
            uint64_t t0 = gSpeakStartAtMS;
            uint32_t needBase = sn_expected_ms_for_chars(gSpeakCharCount);
            uint32_t need     = sn_expected_ms_lang_adjust(needBase);
            uint64_t now = SN_NowMS();
            uint32_t elapsed = (now > t0 && t0 > 0) ? (uint32_t)(now - t0) : 0;
            int32_t remain = (int32_t)need - (int32_t)elapsed;
            uint64_t closed = gClosedTxn.load(std::memory_order_acquire);
            if (closed == txn) {
                if (DBG_ENGINE_VERBOSE_ON)
                    SNLOGFMT(@"[ENGINE] didFinish early suppressed (txn %llu closed by cancel)", (unsigned long long)txn);
                return;
            }
            if (remain < 0) remain = 0;
            if (sn_queue_count() == 0) remain += kSNEarlyFinishHeadroomMs;
            if (DBG_ENGINE_VERBOSE_ON) SNLOGFMT(@"[ENGINE] didFinish early -> delay %dms (need=%ums, elapsed=%ums, chars=%lu)",
                                     remain, need, elapsed, (unsigned long)gSpeakCharCount);
            remain += kSNEarlyFinishExtraDelayMs;
            if (SN_IsCarPlayUnlocked()) remain += (int)kSNCarPlayEarlyFinishExtraMs;
    
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)remain * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                if (!sn_terminal_txn_is_current(txn, "finish-early")) return;
                g_sn_postSpeakHold = NO;
                if (!sn_finish_once_try(txn)) {
                    sn_schedule_idle_session_cleanup_ms(sn_idle_ms_for_current_route());
                    return;
                }
                // Early path: finish immediately
                BOOL startedNext = sn_queue_finish_terminal("finish-early", txn);
                if (!startedNext && gPausedBySN && gPreWasPlaying && sn_queue_count() == 0 && ![SNCancellation isSpeaking]) {
                    sn_try_resume_or_schedule_poke_10s(txn);
                }
                if (!startedNext && sn_queue_count() == 0) {
                    sn_schedule_idle_session_cleanup_ms(sn_idle_ms_for_current_route());
                }
            });
            return;
        }
    
        // NORMAL PATH
        if (!sn_finish_once_try(txn)) {
            sn_schedule_idle_session_cleanup_ms(sn_idle_ms_for_current_route());
            return;
        }

        NSString *sn_port = [SNMediaControl lastOutputPortType] ?: @"";
        BOOL sn_unlocked = ![SNDeviceState isDeviceLocked];
        BOOL sn_isCar = ([sn_port isEqualToString:AVAudioSessionPortCarAudio] ||
                         [sn_port rangeOfString:@"Car" options:NSCaseInsensitiveSearch].location != NSNotFound);

        int holdMs = sn_compute_post_hold_ms(sn_isCar, sn_unlocked, 0);
        sn_post_finish_hold_ms(holdMs, ^{
            if (!sn_terminal_txn_is_current(txn, "finish")) return;
            if ([SNCancellation isSpeaking]) return;

            gClosedTxn.store(txn, std::memory_order_release);
            BOOL startedNext = sn_queue_finish_terminal("finish", txn);

            if (!startedNext && gPausedBySN && gPreWasPlaying && ![SNCancellation isSpeaking] && sn_queue_count() == 0) {
                sn_try_resume_or_schedule_poke_10s(txn);
            }

            if (!startedNext && sn_queue_count() == 0 && ![SNCancellation isSpeaking]) {
                uint32_t idleMs = sn_idle_ms_for_current_route();
                if (idleMs == 0) {
                    sn_idle_maybe_release_to_ringer_with_reason("PostHoldEmpty");
                    return;
                }
                sn_schedule_idle_session_cleanup_ms(idleMs);
            }
        });
    }];

    // Engine cancelled
    [[NSNotificationCenter defaultCenter] addObserverForName:kSNEngineAVDidCancel
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        uint64_t txn = sn_terminal_event_txn(n);
        NSString *terminalReason = n.userInfo[kSNEngineAVUserInfoTerminalReason];
        const char *reason = "cancel";
        if ([terminalReason isKindOfClass:NSString.class]) {
            if ([terminalReason isEqualToString:@"timeout"]) {
                reason = "timeout";
                if (DBG_ENGINE_VERBOSE_ON) {
                    SNLOGFMT(@"[ENGINE] timeout stop speech | txn=%llu", (unsigned long long)txn);
                }
            } else if ([terminalReason isEqualToString:@"watchdog"]) {
                reason = "watchdog";
            } else if ([terminalReason isEqualToString:@"empty"] ||
                       [terminalReason isEqualToString:@"noSpeech"]) {
                reason = "empty";
            }
        }

        uint64_t cancelAllTxn = gCancelAllTxn.load(std::memory_order_acquire);
        BOOL isCancelAllEvent = (txn != 0 && cancelAllTxn == txn);
        BOOL syntheticCancelTerminal = [n.userInfo[kSNAuditSyntheticCancelTerminalKey] boolValue];
        if (syntheticCancelTerminal && sn_audit_can_accept_synthetic_cancel_terminal(txn)) {
            NSString *auditEngineReason = [terminalReason isKindOfClass:NSString.class] && terminalReason.length
                ? terminalReason : [NSString stringWithUTF8String:reason];
            sn_audit_record_engine_terminal(txn,
                                            @"cancelled",
                                            auditEngineReason,
                                            [SNMediaControl lastOutputPortType]);
        }

        if (!sn_terminal_txn_is_current(txn, reason)) {
            if (isCancelAllEvent) {
                uint64_t expectedTxn = txn;
                (void)gCancelAllTxn.compare_exchange_strong(expectedTxn, 0, std::memory_order_acq_rel);
            }
            return;
        }

        if (DBG_ENGINE_ON) {
            SNLOGFMT(@"[ENGINE] didCancel | txn=%llu utterance=notification reason=%s",
                     (unsigned long long)txn, reason);
        }
        NSString *auditEngineReason = [terminalReason isKindOfClass:NSString.class] && terminalReason.length
            ? terminalReason : [NSString stringWithUTF8String:reason];
        sn_audit_record_engine_terminal(txn,
                                        @"cancelled",
                                        auditEngineReason,
                                        [SNMediaControl lastOutputPortType]);
        if (!sn_finish_once_try(txn)) return;
        gClosedTxn.store(txn, std::memory_order_release);
        /* EngineAV handles teardown via keepalive on cancel */
        sn_mark_tts_end_now();
        g_snPromptDidStart = NO;

        uint64_t expectedWarmupAbortTxn = txn;
        BOOL preRollWasAborted = gA2DPWarmupAbortedTxn.compare_exchange_strong(expectedWarmupAbortTxn, 0,
                                                                                 std::memory_order_acq_rel,
                                                                                 std::memory_order_relaxed);
        if (!preRollWasAborted) {
            sn_mark_a2dp_warm(txn, "tts-finish");
        }

        if (gDuckMgr) [gDuckMgr noteTTSEndedCancelled:YES];
        if (isCancelAllEvent) {
            uint64_t expectedTxn = txn;
            (void)gCancelAllTxn.compare_exchange_strong(expectedTxn, 0, std::memory_order_acq_rel);
            [SNEngineAV teardownVoicePrompt];
            sn_volume_restore_if_terminal(txn, YES);
            sn_queue_clear("cancelAll");
            gDuckChainAlive = NO;
            uint64_t expectedCurrent = txn;
            (void)gCurrentTxn.compare_exchange_strong(expectedCurrent, 0, std::memory_order_acq_rel);
            gSpeakAllowedCtx.store(false, std::memory_order_release);
            sn_schedule_idle_session_cleanup_ms(sn_idle_ms_for_current_route());
            sn_cancel_cleanup_mark_engine_done(txn);
            return;
        }

        if (DBG_QUEUE_VERBOSE_ON && !strcmp(reason, "empty")) {
            SNLOGFMT(@"[QUEUE] terminal | reason=empty txn=%llu", (unsigned long long)txn);
        }

        g_sn_postSpeakHold = NO;
        NSString *sn_port = [SNMediaControl lastOutputPortType] ?: @"";
        BOOL sn_unlocked = ![SNDeviceState isDeviceLocked];
        BOOL sn_isCar = ([sn_port isEqualToString:AVAudioSessionPortCarAudio] ||
                         [sn_port rangeOfString:@"Car" options:NSCaseInsensitiveSearch].location != NSNotFound);

        int holdMs = sn_compute_post_hold_ms(sn_isCar, sn_unlocked, 0);
        sn_post_finish_hold_ms(holdMs, ^{
            if (!sn_terminal_txn_is_current(txn, reason)) return;
            if ([SNCancellation isSpeaking]) return;

            BOOL startedNext = sn_queue_finish_terminal(reason, txn);

            if (!startedNext && gPausedBySN && gPreWasPlaying && ![SNCancellation isSpeaking] && sn_queue_count() == 0) {
                sn_try_resume_or_schedule_poke_10s(txn);
            }

            if (!startedNext && sn_queue_count() == 0 && ![SNCancellation isSpeaking]) {
                uint32_t idleMs = sn_idle_ms_for_current_route();
                if (idleMs == 0) {
                    sn_idle_maybe_release_to_ringer_with_reason("CancelEmpty");
                    return;
                }
                sn_schedule_idle_session_cleanup_ms(idleMs);
            }
        });
    }];

    // Darwin prefs change
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, SN_PrefsChanged, kSNPrefsNotify, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    SNReleaseAlertsStart();

    // Media volume callback (mute/cancel policy)
    [SNMediaControl setVolumeChangeCallback:&SN_OnVolumeChanged];

    // Screen lock complete -> optional cancel (only on real unlock->lock edge)
    int snTokenLockComplete = 0;
    notify_register_dispatch("com.apple.springboard.lockcomplete", &snTokenLockComplete, dispatch_get_main_queue(), ^(int t) {
        if (!sn_cancel_target_active_now()) return;

        BOOL becameLocked = (!gPrevWasLocked && gSBDeviceLocked);
        gPrevWasLocked = gSBDeviceLocked;

        // Extra guard avoids lock-screen false positives
        if (!becameLocked && !gSBScreenBlanked) return;
        sn_handle_cancel_candidate("Power/Lock", @"lockcomplete", SNCancelCandidatePower);
    });

    // Ringer switch -> cancel mid-speech if needed
    int snTokenRinger = 0;
    notify_register_dispatch("com.apple.springboard.ringerstate", &snTokenRinger, dispatch_get_main_queue(),
                             ^(int t) { sn_handle_ringerstate_token(t); });

    // Device lock state (0/1) -> edge-detect "became locked"
int snTokenLockState = 0;
notify_register_dispatch("com.apple.springboard.lockstate", &snTokenLockState, dispatch_get_main_queue(), ^(int t) {
    uint64_t st = 0; notify_get_state(t, &st);
    gSBDeviceLocked = (st != 0);
});

// Single source of truth: cancel on lock button press (both blank and wake)
static int snTokenLockBtn = 0;
	notify_register_dispatch("com.apple.springboard.lockbutton", &snTokenLockBtn, dispatch_get_main_queue(), ^(int t) {
	    // Only cancel if speaking and prefs mode requires Power/Any button
	    sn_handle_cancel_candidate("Power/Button", @"lockbutton", SNCancelCandidatePower);
});

    // Screen blanked toggle -> treat as "power press" while locked (both wake and sleep)
static int snTokenBlank = 0;
	notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &snTokenBlank, dispatch_get_main_queue(), ^(int t) {
	    // Require active TTS and user pref Power/Any cancel mode
	    sn_handle_cancel_candidate("Power/ScreenToggle", @"blankedScreen", SNCancelCandidatePower);

    // Keep state (optional; if used elsewhere)
    uint64_t st = 0; notify_get_state(t, &st);
    gPrevBlanked = (st != 0);
});


    // System volume change -> optional cancel via volume buttons
    [[NSNotificationCenter defaultCenter] addObserverForName:@"AVSystemController_SystemVolumeDidChangeNotification"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        NSDictionary *ui = n.userInfo ?: @{};
        NSString *reason = [ui objectForKey:@"AVSystemController_AudioVolumeChangeReasonNotificationParameter"];
        NSNumber *num = [ui objectForKey:@"AVSystemController_AudioVolumeNotificationParameter"];
        float newVol = num ? (float)num.doubleValue : -1.0f;
        float observedVol = (newVol >= 0.0f ? newVol : [SNMediaControl currentMediaVolume]);
        float oldVolume = sSN_VolInit ? sSN_LastVol : observedVol;
        BOOL internalSetEvent = sn_internal_volume_event_matches(observedVol, NULL);
        BOOL snInternalRestoreEvent = (newVol >= 0.0f ? sn_volume_restore_observe(newVol) : NO);

        if (![SNCancellation isSpeaking]) {
            sSN_LastVol = observedVol;
            sSN_VolInit = YES;
            return;
        }

        if (internalSetEvent || snInternalRestoreEvent) {
            sSN_LastVol = observedVol;
            sSN_VolInit = YES;
            return;
        }

        if (![reason isKindOfClass:NSString.class] ||
            ![reason isEqualToString:@"ExplicitVolumeChange"]) return;

        sn_handle_system_volume_change(@"AVSystemController.SystemVolumeDidChange",
                                       oldVolume,
                                       observedVol);
    }];
    sn_prime_system_volume_notifications();

    // Output volume KVO helper (debug only)
    if (DBG_VOL_ON) [[SNOutVolObserver shared] start];

    // Call monitor with post-call cooldown
    [[SNCallMonitor shared] startWithHandler:^(BOOL isStart, SNCallInfo *info) {
        NSString *rawName  = info.name ?: @"";
        NSString *rawPhone = info.number ?: @"";
        NSString *nName  = [SNStringUtils normalizePhoneSimple:rawName];
        NSString *nPhone = [SNStringUtils normalizePhoneSimple:rawPhone];
        if (nName.length && nPhone.length && [nName isEqualToString:nPhone]) rawName = @"";
        NSString *name = (rawName.length ? rawName : @"Unknown");

        NSDateFormatter *fmt = [NSDateFormatter new];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.timeZone = [NSTimeZone localTimeZone];
        fmt.dateFormat = @"HH:mm";

        if (isStart) {
            gCallActive.store(true, std::memory_order_release);
            SN_CancelAll("Call:Start");

            // Ensure nothing tries to resume later
            gPokeScheduled.store(false, std::memory_order_release);
            gPausedBySN = NO;
            gPreWasPlaying = NO;

            [fmt release];
            return;
        }

        gCallActive.store(false, std::memory_order_release);

        NSTimeInterval durSec = 0.0;
        if (info.endDate || info.startDate) {
            NSDate *endDate = (info.endDate ?: [NSDate date]);
            NSDate *startDateSafe = (info.startDate ?: endDate);
            durSec = endDate.timeIntervalSince1970 - startDateSafe.timeIntervalSince1970;
            if (durSec < 0) durSec = 0;
        }

        if (DBG_ENGINE_ON && !gLastPreflightBlocked.load(std::memory_order_acquire)) {
            const char *dirStrEnd = (info.direction == SNCallDirectionOutgoing ? "CALL OUT END" :
                                     info.direction == SNCallDirectionIncoming ? "CALL IN END"  : "CALL END");
            SNLOGFMT(@"[TTS-AV] %s | name=\"%@\" | phone=%@ | dur=%@",
                     dirStrEnd, (name ?: @"Unknown"),
                     (info.number.length ? info.number : @"-"),
                     SN_Log_HHMMSSFromInterval(durSec));
        }

        // Post-call cooldown to let HFP/telephony clear
        uint64_t now = SN_NowMS();
        gCallCooldownUntilMS.store(now + kSNPostCallCooldownMs, std::memory_order_relaxed);
        if (DBG_CALLGATE_ON && !gLastPreflightBlocked.load(std::memory_order_acquire))
            SNLOGFMT(@"[CALLGATE] cooldown %ums", (unsigned)kSNPostCallCooldownMs);

        [fmt release];
    }];
}
