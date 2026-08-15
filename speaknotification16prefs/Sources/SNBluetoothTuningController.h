#import <Preferences/PSListController.h>

@interface SNBluetoothTuningController : PSListController
- (instancetype)initWithSavedName:(NSString *)savedName
                      displayName:(NSString *)displayName
                      canonicalUID:(NSString *)canonicalUID
                     changeHandler:(dispatch_block_t)changeHandler;
@end
