#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>

@protocol SNMinuteOfDaySelectionDelegate <NSObject>
- (NSInteger)minuteValueForKey:(NSString *)key;
- (NSString *)minuteTitleForKey:(NSString *)key;
- (void)setMinuteValue:(NSInteger)value forKey:(NSString *)key;
@end

@interface SNMinuteOfDayController : PSListController
@end

@interface SNMinuteOfDayValueCell : PSTableCell
@end
