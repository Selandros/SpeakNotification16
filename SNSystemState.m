#import "SNSystemState.h"

int SN_ScreenBrightnessPercent(void) {
    @try {
        CGFloat b = UIScreen.mainScreen.brightness;
        if (b < 0.0) b = 0.0;
        if (b > 1.0) b = 1.0;
        return (int)lrintf((float)(b * 100.0f));
    } @catch (...) {
        return 0;
    }
}

NSString *SN_OrientationString(void) {
    @try {
        UIDeviceOrientation o = UIDevice.currentDevice.orientation;
        switch (o) {
            case UIDeviceOrientationPortrait: return @"portrait";
            case UIDeviceOrientationPortraitUpsideDown: return @"portraitUpsideDown";
            case UIDeviceOrientationLandscapeLeft: return @"landscapeLeft";
            case UIDeviceOrientationLandscapeRight: return @"landscapeRight";
            case UIDeviceOrientationFaceUp: return @"faceUp";
            case UIDeviceOrientationFaceDown: return @"faceDown";
            case UIDeviceOrientationUnknown:
            default: return @"unknown";
        }
    } @catch (...) {
        return @"unknown";
    }
}

int SN_BatteryLevelPercent(void) {
    @try {
        UIDevice *d = UIDevice.currentDevice;
        BOOL prev = d.isBatteryMonitoringEnabled;
        d.batteryMonitoringEnabled = YES;
        float lvl = d.batteryLevel;
        d.batteryMonitoringEnabled = prev;
        if (lvl < 0.0f) return -1;
        if (lvl > 1.0f) lvl = 1.0f;
        return (int)lrintf(lvl * 100.0f);
    } @catch (...) {
        return -1;
    }
}

NSString *SN_BatteryStateString(UIDeviceBatteryState state) {
    switch (state) {
        case UIDeviceBatteryStateCharging: return @"charging";
        case UIDeviceBatteryStateFull: return @"full";
        case UIDeviceBatteryStateUnplugged: return @"unplugged";
        case UIDeviceBatteryStateUnknown:
        default: return @"unknown";
    }
}

BOOL SN_LowPowerModeEnabled(void) {
    @try {
        return NSProcessInfo.processInfo.isLowPowerModeEnabled;
    } @catch (...) {
        return NO;
    }
}
