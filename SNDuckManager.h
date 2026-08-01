// SNDuckManager.h
// Orchestrates pre-roll, confirm (with fail-safe + 1 retry), post-roll,
// and abort/cleanup for pause/duck. No logging here – pure motorics.

#import <Foundation/Foundation.h>
#import "SNMixPolicy.h" // for SNDuckMode, SNMixDecision

NS_ASSUME_NONNULL_BEGIN

// Immutable configuration passed at init.
typedef struct {
    SNDuckMode mode;                 // pause or duck
    BOOL       pausedByUs;           // we paused the player
    BOOL       resumeOnCancel;       // resume after cancel
} SNDuckState;

typedef struct {
    SNDuckMode  mode;                // selected mode
    NSInteger   targetDb;            // negative dB if duck; 0 if pause
    BOOL        resumeOnCancel;      // resume media after cancel
    NSUInteger  preRollMs;           // pre-roll wait before apply
    NSUInteger  confirmMs;           // fail-safe confirm window
    NSUInteger  postRollMs;          // post-roll wait after apply
} SNDuckConfig;

// Callbacks implemented by the caller (cheap & non-blocking).
// They must not block or allocate heavily; keep hot path lean.
typedef struct {
    // Apply pause/duck. Return YES if request accepted/scheduled.
    BOOL  (*requestApply)(SNDuckMode mode, NSInteger targetDb, void *ctx);

    // Confirm application (called after confirm window). Return YES to proceed.
    BOOL  (*confirmApplied)(SNDuckMode mode, void *ctx);

    // Release state after post-roll or abort/cancel path.
    // pausedByUs: whether media was paused by the manager
    // resumeOnCancel: echo from config for caller convenience
    void  (*releaseState)(SNDuckMode mode, BOOL pausedByUs, BOOL resumeOnCancel, void *ctx);
} SNDuckCallbacks;

@interface SNDuckManager : NSObject

// Designated initializer.
- (instancetype)initWithConfig:(SNDuckConfig)cfg
                     callbacks:(SNDuckCallbacks)cb
                        ctxPtr:(void * _Nullable)cbCtx NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// ===== Phase 1: pre-roll → apply → confirm =====
// onReady: invoked when pause/duck is considered applied and TTS may start
// onAbort: invoked if the chain fails during pre/confirm
- (void)startWithReady:(void (^)(void))onReady
                 abort:(void (^)(void))onAbort;

// ===== Phase 2: TTS end → post-roll → release =====
- (void)noteTTSEndedCancelled:(BOOL)cancelled;
// With completion so caller can clear references exactly when motorics end.
- (void)noteTTSEndedCancelled:(BOOL)cancelled
                  onComplete:(void (^ _Nullable)(void))completion;

// Abort immediately (idempotent). Safe to call multiple times.
- (void)abortNow;

// ===== Queue/burst helpers =====

// Try to chain a new TTS on top of the current session (skips pre/confirm).
// Returns YES if ready() was invoked and caller may start TTS immediately.
- (BOOL)beginFastChainIfPossibleWithReady:(void (^)(void))onReady
                                    abort:(void (^)(void))onAbort;

// Extend current post-roll window (no-op if not in post-roll).
- (void)extendPostRoll;
// Explicit extension in milliseconds (cap/merge with existing deadline).
- (void)extendPostRollBy:(NSUInteger)ms;

// ===== Introspection =====
@property (atomic, readonly) BOOL activeDuck;   // pause/duck is applied
@property (atomic, readonly) BOOL inPostRoll;   // holding after TTS
@property (atomic, readonly) BOOL pausedByUs;   // media paused by us (pause mode)
@property (atomic, readonly) BOOL sessionHeld;  // any phase active (pre/active/post)

@end

NS_ASSUME_NONNULL_END
