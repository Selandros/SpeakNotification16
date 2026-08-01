// SNMixPolicy.h
// Decides PAUSE vs DUCK based on settings/state (route currently ignored).
// CPU-cheap, pure function-style API. No logging here.

#import <Foundation/Foundation.h>
#import <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Duck/pause selection used across mix/duck modules
typedef NS_ENUM(NSInteger, SNDuckMode) {
    SNDuckModeDuck = 0,
    SNDuckModePause = 1
};

// Canonical route kinds. Present for forward-compat; current policy ignores route.
typedef NS_ENUM(NSInteger, SNMixRouteKind) {
    SNMixRouteUnknown = 0,
    SNMixRouteCarPlay,
    SNMixRouteBluetooth,   // A2DP/HFP/LE headsets/earbuds
    SNMixRouteSpeaker,     // built-in receiver/speaker
    SNMixRouteAirPlay
};

// Decision bundle used by duck manager and callers
typedef struct {
    SNDuckMode mode;        // duck or pause
    NSInteger  targetDb;    // negative dB if duck; 0 if pause
    BOOL       resumeOnCancel; // resume media after cancel
} SNMixDecision;

// Optional helper to map AVAudioSessionPort* strings to a route kind.
// Implemented in SNMixPolicy.m. Cheap string tests, no allocations on hot path.
SNMixRouteKind SNMixClassifyRoutePort(NSString * _Nullable portType);

// Main policy entry. Returns PAUSE or DUCK; never blocks and alloc-free.
// Inputs:
//     routeKind      : result of SNMixClassifyRoutePort(...) or the caller's mapping (ignored for now)
//     pauseToggle    : user pref "pause" (when ON, allow PAUSE for phone media)
//     isPhonePlaying : YES if current now-playing is phone media
// Output:
//     SNDuckModePause when (pauseToggle && isPhonePlaying), otherwise SNDuckModeDuck.
SNMixDecision SNMixPolicyDecide(SNMixRouteKind routeKind,
                                bool pauseToggle,
                                bool isPhonePlaying);

#ifdef __cplusplus
}
#endif
