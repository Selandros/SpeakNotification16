// comments: English only; pure motorics, no logging here
#import "SNSiriGuard.h"
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>
#import <unistd.h>

typedef BOOL (*fn_callMonitorActive_t)(void);

static inline BOOL sng_call_monitor_active_dynamic(void)
{
    void *sym = dlsym(RTLD_DEFAULT, "SN_CallMonitorActive");
    if (!sym) return NO;
    fn_callMonitorActive_t fp = (fn_callMonitorActive_t)sym;
    return fp ? fp() : NO;
}

static inline BOOL sng_interruption_likely_active(void)
{
    @try {
        if (sng_call_monitor_active_dynamic()) return YES;
        AVAudioSession *s = [AVAudioSession sharedInstance];
        if ([s respondsToSelector:@selector(secondaryAudioShouldBeSilencedHint)]) {
            if (s.secondaryAudioShouldBeSilencedHint) return YES;
        }
    } @catch (...) {}
    return NO;
}

// SNSiriGuard.m (additions below your existing helpers)

// Extended variant: returns elapsed ms; sets *didClear to YES on clear, NO on timeout
uint32_t SNG_WaitForInterruptionClearThenTailMS_Ex(NSInteger tailMs, NSInteger hardCapMs, BOOL *didClear)
{
    if (didClear) *didClear = NO;
    if (hardCapMs <= 0) hardCapMs = 2500;
    if (tailMs < 0) tailMs = 0;

    const int stepMs = 50;
    const int stableOnSamples  = 3;   // ~150ms continuous active before treating as active
    const int stableOffSamples = 3;   // ~150ms continuous clear before exit
    int waited = 0;

    int onCount = 0;
    while (sng_interruption_likely_active()) {
        if (++onCount >= stableOnSamples) break;
        if (waited >= hardCapMs) return (uint32_t)waited;
        usleep((useconds_t)stepMs * 1000);
        waited += stepMs;
    }

    if (onCount < stableOnSamples) {
        int tailBudget = hardCapMs - waited;
        if (tailBudget > 0) {
            int useTail = (int)((tailMs < tailBudget) ? tailMs : tailBudget);
            if (useTail > 0) {
                usleep((useconds_t)useTail * 1000);
                waited += useTail;
            }
        }
        if (didClear) *didClear = YES;
        return (uint32_t)waited;
    }

    int offCount = 0;
    while (waited < hardCapMs) {
        if (!sng_interruption_likely_active()) {
            if (++offCount >= stableOffSamples) {
                int tailBudget = hardCapMs - waited;
                if (tailBudget > 0) {
                    int useTail = (int)((tailMs < tailBudget) ? tailMs : tailBudget);
                    if (useTail > 0) {
                        usleep((useconds_t)useTail * 1000);
                        waited += useTail;
                    }
                }
                if (didClear) *didClear = YES;
                return (uint32_t)waited;
            }
        } else {
            offCount = 0;
        }
        usleep((useconds_t)stepMs * 1000);
        waited += stepMs;
    }
    return (uint32_t)waited; // timeout
}

// Back-compat wrapper matching the old signature
BOOL SNG_WaitForInterruptionClearThenTailMS(NSInteger tailMs, NSInteger hardCapMs)
{
    BOOL cleared = NO;
    (void)SNG_WaitForInterruptionClearThenTailMS_Ex(tailMs, hardCapMs, &cleared);
    return cleared;
}