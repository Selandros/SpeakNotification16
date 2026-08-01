#import "SNNetworkState.h"
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import "SNRuntime.h"

// ---------- Wi-Fi (MobileWiFi via dlsym) ----------
static NSString *SN_WiFi_SSID_MobileWiFi(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_LAZY);
    if (!h) return @"-";

    typedef void * (*t_WiFiManagerClientCreate)(CFAllocatorRef, int);
    typedef CFArrayRef (*t_WiFiManagerClientCopyDevices)(void *);
    typedef void * (*t_WiFiDeviceClientCopyCurrentNetwork)(void *);
    typedef CFStringRef (*t_WiFiNetworkGetSSID)(void *);

    t_WiFiManagerClientCreate pCreate = (t_WiFiManagerClientCreate)dlsym(h, "WiFiManagerClientCreate");
    t_WiFiManagerClientCopyDevices pCopyDevices = (t_WiFiManagerClientCopyDevices)dlsym(h, "WiFiManagerClientCopyDevices");
    t_WiFiDeviceClientCopyCurrentNetwork pCopyCurrent = (t_WiFiDeviceClientCopyCurrentNetwork)dlsym(h, "WiFiDeviceClientCopyCurrentNetwork");
    t_WiFiNetworkGetSSID pGetSSID = (t_WiFiNetworkGetSSID)dlsym(h, "WiFiNetworkGetSSID");

    if (!pCreate || !pCopyDevices || !pCopyCurrent || !pGetSSID) {
        dlclose(h);
        return @"-";
    }

    NSString *ssid = @"-";
    @try {
        void *mgr = pCreate(kCFAllocatorDefault, 0);
        if (mgr) {
            CFArrayRef devs = pCopyDevices(mgr);
            if (devs && CFArrayGetCount(devs) > 0) {
                void *dev = (void *)CFArrayGetValueAtIndex(devs, 0);
                void *net = pCopyCurrent(dev);
                if (net) {
                    CFStringRef cfssid = pGetSSID(net);
                    if (cfssid) {
                        NSString *s = (__bridge NSString *)cfssid;
                        if (s.length) ssid = [[s copy] autorelease];
                    }
                    CFRelease(net);
                }
            }
            if (devs) CFRelease(devs);
        }
    } @catch (...) {
        ssid = @"-";
    }
    dlclose(h);
    return ssid.length ? ssid : @"-";
}

NSString *SN_WiFiCurrentSSID(void) {
    // Single guarded path; returns "-" on any failure
    return SN_WiFi_SSID_MobileWiFi();
}

static NSString *SN_BT_DeviceName(id dev) {
    if (!dev) return @"";
    for (NSString *selName in @[@"name", @"displayName", @"nameOrAddress", @"address"]) {
        id v = SN_PerformNoArg(dev, selName);
        if ([v isKindOfClass:NSString.class] && [(NSString *)v length]) return [[(NSString *)v copy] autorelease];
    }
    return @"";
}

void SN_BluetoothSnapshot(BOOL *outBTOn, NSString **outDevicesCSV) {
    if (outBTOn) *outBTOn = NO;
    if (outDevicesCSV) *outDevicesCSV = @"-";

    @try {
        Class BTMgr = NSClassFromString(@"BluetoothManager");
        if (!BTMgr) return;

        id mgr = SN_PerformNoArg(BTMgr, @"sharedInstance");
        if (!mgr) return;

        // Power/enabled state
        BOOL powered = NO;
        if (!SN_PerformBoolNoArg(mgr, @"powered", &powered)) {
            SN_PerformBoolNoArg(mgr, @"enabled", &powered);
        }
        if (outBTOn) *outBTOn = powered;

        // Collect connected devices (both audio + general if available)
        NSMutableArray<NSString *> *names = [NSMutableArray array];

        for (NSString *selList in @[@"connectedAudioDevices", @"connectedDevices"]) {
            id list = SN_PerformNoArg(mgr, selList);
            if ([list isKindOfClass:[NSArray class]]) {
                for (id dev in (NSArray *)list) {
                    NSString *n = SN_BT_DeviceName(dev);
                    if (n.length && ![names containsObject:n]) {
                        [names addObject:n];
                    }
                }
            }
        }

        if (outDevicesCSV) {
            if (names.count == 0) {
                *outDevicesCSV = powered ? @"(on, no devices)" : @"-";
            } else {
                *outDevicesCSV = [names componentsJoinedByString:@","];
            }
        }
    } @catch (...) {
        // keep defaults
    }
}
