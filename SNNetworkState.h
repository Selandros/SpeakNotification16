#import <Foundation/Foundation.h>
#import <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

NSString *SN_WiFiCurrentSSID(void);
void SN_BluetoothSnapshot(BOOL *outBTOn, NSString **outDevicesCSV);

#ifdef __cplusplus
}
#endif
