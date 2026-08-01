// SNMixPolicy.m
// Pure decision logic for PAUSE/DUCK.
// No logging. CPU-cheap. No allocations on hot path.

#import "SNMixPolicy.h"
#import <AVFoundation/AVFoundation.h>
#import <stdbool.h>

// Cheap string equality (nil-safe)
static inline BOOL sn_streq(NSString *a, NSString *b)
{
    if (a == b) return YES;
    if (a.length == 0 || b.length == 0) return NO;
    return [a isEqualToString:b];
}

// Map AVAudioSession portType to our route kind.
// Conservative and cheap; treats wired outputs as Speaker.
SNMixRouteKind SNMixClassifyRoutePort(NSString * _Nullable portType)
{
    if (portType.length == 0) return SNMixRouteUnknown;

    // CarPlay
    if (sn_streq(portType, AVAudioSessionPortCarAudio)) {
        return SNMixRouteCarPlay;
    }

    // Bluetooth family
    if (sn_streq(portType, AVAudioSessionPortBluetoothA2DP) ||
        sn_streq(portType, AVAudioSessionPortBluetoothHFP)  ||
        sn_streq(portType, AVAudioSessionPortBluetoothLE)) {
        return SNMixRouteBluetooth;
    }

    // AirPlay
    if (sn_streq(portType, AVAudioSessionPortAirPlay)) {
        return SNMixRouteAirPlay;
    }

    // Built-in speakers/receiver
    if (sn_streq(portType, AVAudioSessionPortBuiltInSpeaker) ||
        sn_streq(portType, AVAudioSessionPortBuiltInReceiver)) {
        return SNMixRouteSpeaker;
    }

    // Wired outputs -> treat as Speaker for our purposes
    if (sn_streq(portType, AVAudioSessionPortHeadphones) ||
        sn_streq(portType, AVAudioSessionPortLineOut)) {
        return SNMixRouteSpeaker;
    }

    return SNMixRouteUnknown;
}

// Main policy decision (alloc-free, non-blocking).
// Rule: if (pauseToggle && isPhonePlaying) -> PAUSE, else -> DUCK.
// routeKind reserved for future tuning; currently ignored.
SNMixDecision SNMixPolicyDecide(SNMixRouteKind routeKind,
                                bool pauseToggle,
                                bool isPhonePlaying)
{
    (void)routeKind; // reserved for future use

    SNMixDecision d;
    if (pauseToggle && isPhonePlaying) {
        d.mode = SNDuckModePause;        // pause phone media
        d.targetDb = 0;                   // not used for pause
        d.resumeOnCancel = YES;           // safe default
        return d;
    }

    d.mode = SNDuckModeDuck;             // default: duck
    d.targetDb = -12;                     // conservative attenuation
    d.resumeOnCancel = YES;               // safe default
    return d;
}
