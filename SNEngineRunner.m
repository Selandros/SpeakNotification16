// SNEngineRunner.m
// Passive runner shim — NOT IN USE currently. Pure motorics; no logging.

#import "SNEngineRunner.h"
#import "SNDeviceState.h"
#import "SNMediaControl.h"
#import "SNEngineAV.h"
#import <os/lock.h>
#import <stdatomic.h>
#import <objc/message.h>

// Respect device mute switch
static const BOOL kRespectMuteSwitch = YES;

// Cancel generation. Any job whose captured gen != current is a no-op when it starts.
static _Atomic uint32_t sGen = 1;

/**
 * Reads environment flags in one place. Defensive and fast.
 */
static inline void SN_ReadEnvironment(BOOL *outLocked,
                                      BOOL *outMuted,
                                      BOOL *outMutedKnown,
                                      float *outMediaVol)
{
    // Device locked?
    if (outLocked) {
        Class CState = objc_getClass("SNDeviceState");
        SEL selLocked = sel_registerName("isDeviceLocked");
        if (CState && class_respondsToSelector(CState, selLocked)) {
            BOOL (*fLock)(id, SEL) = (BOOL (*)(id, SEL))[CState methodForSelector:selLocked];
            @try { *outLocked = fLock(CState, selLocked); } @catch (...) { *outLocked = NO; }
        } else {
            *outLocked = NO;
        }
    }

    // Ringer mute?
    if (outMuted && outMutedKnown) {
        Class CMedia = objc_getClass("SNMediaControl");
        SEL selMuted = sel_registerName("ringerMutedKnown:");
        if (CMedia && class_respondsToSelector(CMedia, selMuted)) {
            BOOL known = NO;
            BOOL (*fMuted)(id, SEL, BOOL *) = (BOOL (*)(id, SEL, BOOL *))[CMedia methodForSelector:selMuted];
            @try {
                BOOL muted = fMuted(CMedia, selMuted, &known);
                *outMuted = muted;
                *outMutedKnown = known;
            } @catch (...) {
                *outMuted = NO; *outMutedKnown = NO;
            }
        } else {
            *outMuted = NO; *outMutedKnown = NO;
        }
    }

    // Media volume?
    if (outMediaVol) {
        Class CMedia = objc_getClass("SNMediaControl");
        SEL selVol = sel_registerName("currentMediaVolume");
        if (CMedia && class_respondsToSelector(CMedia, selVol)) {
            float (*fVol)(id, SEL) = (float (*)(id, SEL))[CMedia methodForSelector:selVol];
            @try { *outMediaVol = fVol(CMedia, selVol); } @catch (...) { *outMediaVol = -1.0f; }
        } else {
            *outMediaVol = -1.0f;
        }
    }
}

/**
 * Simple policy gate: decide if we should speak given env flags.
 * Keep CPU usage minimal and return early on hard blocks.
 */
static inline BOOL SN_ShouldSpeak(BOOL locked, BOOL muted, BOOL mutedKnown)
{
    (void)locked; // reserved for future lock-policy decisions
    if (kRespectMuteSwitch && mutedKnown && muted) {
        return NO;
    }
    return YES;
}

static dispatch_queue_t snRunnerQ(void) {
    static dispatch_queue_t q;
    static dispatch_once_t onceToken;
    static const void *kRunnerQKey = &kRunnerQKey;
    dispatch_once(&onceToken, ^{
        q = dispatch_queue_create("sn.engine.runner", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(q, kRunnerQKey, (void *)kRunnerQKey, NULL);
    });
    return q;
}

@implementation SNEngineRunner

+ (void)clearQueue
{
    // Bump generation - all pending jobs captured with old gen become no-ops.
    atomic_fetch_add_explicit(&sGen, 1, memory_order_relaxed);

    // Drain queue safely (avoid deadlock if already on the queue).
    static const void *kRunnerQKey = &kRunnerQKey;
    if (dispatch_get_specific(kRunnerQKey)) {
        return;
    }
    dispatch_sync(snRunnerQ(), ^{ /* barrier to ensure prior tasks have observed new gen */ });
}

+ (void)runWithTitle:(NSString *)title body:(NSString *)body lang:(NSString *)lang
{
    // Capture generation immediately
    uint32_t myGen = atomic_load_explicit(&sGen, memory_order_relaxed);

    // Make immutable copies that survive into the block (safe under MRC too)
    NSString *t = [title copy];
    NSString *b = [body copy];
    NSString *l = [lang  copy];

    dispatch_block_t work = ^{
        @autoreleasepool {
            // Abort if cancel bumped generation
            if (atomic_load_explicit(&sGen, memory_order_relaxed) != myGen) return;

            BOOL locked = NO, muted = NO, mutedKnown = NO;
            float mediaVol = -1.0f;
            SN_ReadEnvironment(&locked, &muted, &mutedKnown, &mediaVol);
            if (!SN_ShouldSpeak(locked, muted, mutedKnown)) return;

            // Invoke AV engine
            Class C = [SNEngineAV class];
            SEL sel = @selector(speakTitle:body:lang:);
            if (![C respondsToSelector:sel]) return;

            (void)((BOOL (*)(id, SEL, NSString *, NSString *, NSString *))objc_msgSend)(C, sel, t, b, l);
        }
    };

    // Execute on our serial queue
    dispatch_async(snRunnerQ(), work);
}

@end
