#import "SNCancellation.h"
#import "SNEngineRunner.h"
#import "SNEngineAV.h"
#import <stdatomic.h>

@implementation SNCancellation

// Atomic globals (cheap, lock-free, relaxed ordering is enough here)
static _Atomic int gCancelMode = SNCancelButtonModeNone;
static _Atomic bool gSpeaking = false;
static _Atomic bool gMuteCanceled = false;

// Fast idempotent guard so repeated cancels are cheap
static inline bool SN_TrySetSpeakingFalse(void)
{
    bool expected = true;
    return atomic_compare_exchange_strong_explicit(&gSpeaking, &expected, false, memory_order_relaxed, memory_order_relaxed);
}

+ (void)cancelSpeechNow
{
    // Stop the current utterance only (does not purge queue)
    [SNEngineAV stop];
}

+ (void)setCancelMode:(SNCancelButtonMode)mode
{
    atomic_store_explicit(&gCancelMode, (int)mode, memory_order_relaxed);
}

+ (SNCancelButtonMode)cancelMode
{
    return (SNCancelButtonMode)atomic_load_explicit(&gCancelMode, memory_order_relaxed);
}

+ (void)setSpeaking:(BOOL)isSpeaking
{
    atomic_store_explicit(&gSpeaking, isSpeaking, memory_order_relaxed);
}

+ (BOOL)isSpeaking
{
    return atomic_load_explicit(&gSpeaking, memory_order_relaxed);
}

+ (void)noteMutedState:(BOOL)isMuted
{
    // If mute flips ON during active speech: treat as hard cancel and latch.
    if (isMuted && atomic_load_explicit(&gSpeaking, memory_order_relaxed)) {
        [self cancelAll];
        atomic_store_explicit(&gMuteCanceled, true, memory_order_relaxed);
    }
}

+ (BOOL)wasCanceledByMute
{
    return atomic_load_explicit(&gMuteCanceled, memory_order_relaxed);
}

+ (void)resetMuteCancelLatch
{
    atomic_store_explicit(&gMuteCanceled, false, memory_order_relaxed);
}

+ (void)cancelAll
{
    [self cancelAllForTransaction:0];
}

+ (void)cancelAllForTransaction:(uint64_t)txn
{
    // Make cancel idempotent: if not speaking, still purge queue below but avoid duplicate stops.
    if (SN_TrySetSpeakingFalse()) {
        [SNEngineAV stopTransaction:txn];
    } else {
        // Ensure in-flight starters will no-op via generation bump inside stop
        [SNEngineAV stopTransaction:txn];
    }

    if ([SNEngineRunner respondsToSelector:@selector(clearQueue)]) {
        [SNEngineRunner clearQueue];
    }
}

@end
