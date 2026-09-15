#import "SNMinuteOfDayController.h"

@implementation SNMinuteOfDayValueCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier
{
    self = [super initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier
{
    [super refreshCellContentsWithSpecifier:specifier];
    id<SNMinuteOfDaySelectionDelegate> target = (id<SNMinuteOfDaySelectionDelegate>)specifier.target;
    NSString *key = [specifier propertyForKey:@"minuteKey"];
    self.textLabel.text = specifier.name;
    self.detailTextLabel.text = [target respondsToSelector:@selector(minuteTitleForKey:)]
        ? [target minuteTitleForKey:key] : @"00:00";
    self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
}

@end

@interface SNMinuteOfDayController ()
@property (nonatomic, copy) NSString *minuteKey;
@property (nonatomic, assign) NSInteger selectedMinute;
@property (nonatomic, retain) UIDatePicker *timePicker;
@property (nonatomic, retain) UIView *pickerHeader;
@end

@implementation SNMinuteOfDayController

- (NSArray *)specifiers
{
    if (_specifiers) return _specifiers;
    self.minuteKey = [self.specifier propertyForKey:@"minuteKey"];
    self.title = @"Select Time";
    NSArray *controllers = self.navigationController.viewControllers;
    id<SNMinuteOfDaySelectionDelegate> owner = controllers.count > 1
        ? (id<SNMinuteOfDaySelectionDelegate>)controllers[controllers.count - 2] : nil;
    self.selectedMinute = [owner respondsToSelector:@selector(minuteValueForKey:)]
        ? [owner minuteValueForKey:self.minuteKey] : 0;
    _specifiers = [@[[PSSpecifier preferenceSpecifierNamed:@"TIME"
                                                     target:self
                                                        set:NULL
                                                        get:NULL
                                                      detail:nil
                                                        cell:PSGroupCell
                                                        edit:nil]] mutableCopy];
    return _specifiers;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                             target:self
                                                                                             action:@selector(commitSelectedTime)];

    CGFloat width = CGRectGetWidth(self.table.bounds);
    self.pickerHeader = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 270)];
    self.pickerHeader.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UILabel *heading = [[UILabel alloc] initWithFrame:CGRectZero];
    heading.translatesAutoresizingMaskIntoConstraints = NO;
    heading.text = @"TIME";
    heading.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    heading.textColor = UIColor.secondaryLabelColor;
    [self.pickerHeader addSubview:heading];

    self.timePicker = [[UIDatePicker alloc] initWithFrame:CGRectZero];
    self.timePicker.translatesAutoresizingMaskIntoConstraints = NO;
    self.timePicker.datePickerMode = UIDatePickerModeTime;
    self.timePicker.preferredDatePickerStyle = UIDatePickerStyleWheels;
    self.timePicker.minuteInterval = 1;
    [self.timePicker addTarget:self action:@selector(timePickerChanged:) forControlEvents:UIControlEventValueChanged];
    [self.pickerHeader addSubview:self.timePicker];

    [NSLayoutConstraint activateConstraints:@[
        [heading.leadingAnchor constraintEqualToAnchor:self.pickerHeader.leadingAnchor constant:20],
        [heading.trailingAnchor constraintEqualToAnchor:self.pickerHeader.trailingAnchor constant:-20],
        [heading.topAnchor constraintEqualToAnchor:self.pickerHeader.topAnchor constant:12],
        [self.timePicker.leadingAnchor constraintEqualToAnchor:self.pickerHeader.leadingAnchor],
        [self.timePicker.trailingAnchor constraintEqualToAnchor:self.pickerHeader.trailingAnchor],
        [self.timePicker.topAnchor constraintEqualToAnchor:heading.bottomAnchor constant:4],
        [self.timePicker.bottomAnchor constraintEqualToAnchor:self.pickerHeader.bottomAnchor constant:-4]
    ]];

    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDateComponents *components = [calendar components:(NSCalendarUnitEra | NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay)
                                               fromDate:NSDate.date];
    components.hour = self.selectedMinute / 60;
    components.minute = self.selectedMinute % 60;
    NSDate *selectedDate = [calendar dateFromComponents:components];
    if (selectedDate) [self.timePicker setDate:selectedDate animated:NO];
    self.table.tableHeaderView = self.pickerHeader;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGRect frame = self.pickerHeader.frame;
    CGFloat width = CGRectGetWidth(self.table.bounds);
    if (frame.size.width != width) {
        frame.size.width = width;
        self.pickerHeader.frame = frame;
        self.table.tableHeaderView = self.pickerHeader;
    }
}

- (void)timePickerChanged:(UIDatePicker *)picker
{
    NSDateComponents *components = [NSCalendar.currentCalendar components:(NSCalendarUnitHour | NSCalendarUnitMinute)
                                                                  fromDate:picker.date];
    self.selectedMinute = components.hour * 60 + components.minute;
}

- (void)commitSelectedTime
{
    NSArray *controllers = self.navigationController.viewControllers;
    id<SNMinuteOfDaySelectionDelegate> owner = controllers.count > 1
        ? (id<SNMinuteOfDaySelectionDelegate>)controllers[controllers.count - 2] : nil;
    if ([owner respondsToSelector:@selector(setMinuteValue:forKey:)]) {
        [owner setMinuteValue:self.selectedMinute forKey:self.minuteKey];
    }
    [self.navigationController popViewControllerAnimated:YES];
}

@end
