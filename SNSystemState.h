#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

int SN_ScreenBrightnessPercent(void);
NSString *SN_OrientationString(void);
int SN_BatteryLevelPercent(void);
NSString *SN_BatteryStateString(UIDeviceBatteryState state);
BOOL SN_LowPowerModeEnabled(void);

#ifdef __cplusplus
}
#endif
