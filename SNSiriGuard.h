// SNSiriGuard.h
// Lightweight interruption guard for Siri/Phone/Maps-like speech.
// Pure motorics; no logging. C-ABI for easy use from Tweak.xm.

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Waits until voice-assistant / call-like interruptions are likely clear,
// then sleeps an additional tail (milliseconds). Uses cheap polling with usleep.
// Returns YES if "clear" observed before cap, otherwise NO (timeout).
BOOL SNG_WaitForInterruptionClearThenTailMS(NSInteger tailMs, NSInteger hardCapMs);

// Extended: returns elapsed ms and sets *didClear to YES if exit due to clear (not timeout).
uint32_t SNG_WaitForInterruptionClearThenTailMS_Ex(NSInteger tailMs, NSInteger hardCapMs, BOOL *didClear);

#ifdef __cplusplus
} // extern "C"
#endif