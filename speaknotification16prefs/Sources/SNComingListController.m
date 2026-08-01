#import <Preferences/PSListController.h>

@interface SNComingListController : PSListController
@end

@implementation SNComingListController
- (NSArray *)specifiers
{
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Coming" target:self];
    }
    return _specifiers;
}
@end
