#import <Preferences/PSListController.h>

@interface SNLanguageVoiceController : PSListController
- (void)reloadVoiceSpecifiers;
- (void)selectVoiceIdentifier:(NSString *)identifier;
@end
