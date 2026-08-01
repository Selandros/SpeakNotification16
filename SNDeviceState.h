// SNDeviceState.h — lock state only, polled on-demand
#import <Foundation/Foundation.h>

@interface SNDeviceState : NSObject
+ (BOOL)isDeviceLocked;
@end
