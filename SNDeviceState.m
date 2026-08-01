// SNDeviceState.m — lock state only, polled on-demand
#import "SNDeviceState.h"
#import <notify.h>

@implementation SNDeviceState

+ (BOOL)isDeviceLocked {
    int token = 0;
    uint64_t state = 0;

    if (notify_register_check("com.apple.springboard.lockstate", &token) == NOTIFY_STATUS_OK && token != 0) {
        notify_get_state(token, &state);
        notify_cancel(token);
        return (state != 0);
    }
    return NO;
}

@end
