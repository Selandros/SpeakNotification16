#import <Preferences/PSListController.h>

@interface LanguagesListController : PSListController
@end

@implementation LanguagesListController
- (NSArray *)specifiers
{
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Languages" target:self];
    }
    return _specifiers;
}
@end
