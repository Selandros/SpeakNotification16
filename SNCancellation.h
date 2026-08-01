#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SNCancelButtonMode) {
    SNCancelButtonModeNone = 0,
    SNCancelButtonModePower,
    SNCancelButtonModeVolumeUp,
    SNCancelButtonModeVolumeDown,
    SNCancelButtonModeVolumeUpDown,
    SNCancelButtonModeAny
};

@interface SNCancellation : NSObject

+ (void)setCancelMode:(SNCancelButtonMode)mode;   // set current cancel button mode
+ (SNCancelButtonMode)cancelMode;                 // read current cancel button mode

+ (void)setSpeaking:(BOOL)isSpeaking;             // mark speaking on/off
+ (BOOL)isSpeaking;                               // read speaking flag

+ (void)noteMutedState:(BOOL)isMuted;             // called when HW mute toggles
+ (BOOL)wasCanceledByMute;                        // latched after mute-cancel
+ (void)resetMuteCancelLatch;                     // clear mute latch before new session

+ (void)cancelAll;                                // stop TTS + clear pending (no logging here)
+ (void)cancelAllForTransaction:(uint64_t)txn;    // transaction-bound stop for terminal ownership

@end
