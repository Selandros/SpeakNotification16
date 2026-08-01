// SNAudioState.h
// Now-playing probe utilities (pure data source; no policy, no logging).
// CPU-cheap C-ABI surface used by Tweak.xm and friends.

#import <Foundation/Foundation.h>
#import "SNMixPolicy.h"  // for SNMixRouteKind enum

#ifdef __cplusplus
extern "C" {
#endif

// Probes current "now playing" state.
// All out-parameters are optional (pass NULL to skip).
// Returns via out-params:
//   outBundleID    : bundle identifier of the app providing now-playing info (or nil)
//   outDisplayName : human-readable name for the provider (or nil)
//   outIsPlaying   : YES if media is currently playing
//   outRouteName   : short route/port description (e.g., "CarAudio", "BluetoothA2DP")
void SNAudioNowPlayingProbe(NSString * _Nullable * _Nullable outBundleID,
                            NSString * _Nullable * _Nullable outDisplayName,
                            BOOL * _Nullable outIsPlaying,
                            NSString * _Nullable * _Nullable outRouteName);

// Lightweight classifier: returns YES if bundleID is considered a "phone media" app
// (i.e., candidates eligible for pause when pause policy is ON).
BOOL SNIsPhoneMediaApp(NSString * _Nullable bundleID);

// Classifies the current audio route (cheap, defensive).
// Returns CarPlay, Bluetooth, Speaker, AirPlay or Unknown.
SNMixRouteKind SNClassifyCurrentRouteKind(void);

#ifdef __cplusplus
} // extern "C"
#endif
