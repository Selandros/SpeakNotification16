#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import "SNNotificationFilterController.h"
#import "SNPrefsUtil.h"
#import "SNSharedKeys.h"

static NSString *SNFilterTrim(id value)
{
    if (![value isKindOfClass:NSString.class]) return @"";
    return [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSDictionary *SNValidFilter(id value)
{
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSString *match = SNFilterTrim(value[@"match"]);
    NSString *action = SNFilterTrim(value[@"action"]);
    if (match.length == 0) return nil;
    if (![action isEqualToString:kSNNotificationFilterActionDontSpeak] &&
        ![action isEqualToString:kSNNotificationFilterActionSpeakNotification] &&
        ![action isEqualToString:kSNNotificationFilterActionSpeakMatched] &&
        ![action isEqualToString:kSNNotificationFilterActionSpeakCustom]) return nil;
    NSMutableDictionary *rule = [@{ @"match": match, @"action": action } mutableCopy];
    if ([action isEqualToString:kSNNotificationFilterActionSpeakCustom]) {
        NSString *custom = SNFilterTrim(value[@"customText"]);
        if (custom.length == 0) return nil;
        rule[@"customText"] = custom;
    }
    return rule;
}

static NSArray *SNFiltersForBundle(NSString *bundleID)
{
    NSString *bid = [SNPrefsUtil normalizeBID:bundleID];
    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSDictionary *all = [defs objectForKey:kSNPerAppNotificationFiltersV1Key];
    NSArray *raw = [all isKindOfClass:NSDictionary.class] ? all[bid] : nil;
    if (![raw isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *valid = [NSMutableArray arrayWithCapacity:raw.count];
    for (id value in raw) {
        NSDictionary *rule = SNValidFilter(value);
        if (rule) [valid addObject:rule];
    }
    return valid;
}

static void SNSaveFilters(NSString *bundleID, NSArray *filters)
{
    NSString *bid = [SNPrefsUtil normalizeBID:bundleID];
    if (bid.length == 0) return;
    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSMutableDictionary *all = [[defs objectForKey:kSNPerAppNotificationFiltersV1Key] mutableCopy];
    if (![all isKindOfClass:NSMutableDictionary.class]) all = [NSMutableDictionary dictionary];
    if (filters.count) all[bid] = filters;
    else [all removeObjectForKey:bid];
    if (all.count) [defs setObject:all forKey:kSNPerAppNotificationFiltersV1Key];
    else [defs removeObjectForKey:kSNPerAppNotificationFiltersV1Key];
    [defs synchronize];
    [SNPrefsUtil postPrefsChanged];
}

static BOOL SNOnlySpeakMatchingFilters(NSString *bundleID)
{
    NSString *bid = [SNPrefsUtil normalizeBID:bundleID];
    NSDictionary *all = [[SNPrefsUtil suite] objectForKey:kSNPerAppOnlySpeakMatchingFiltersV1Key];
    return [all isKindOfClass:NSDictionary.class] && [all[bid] boolValue];
}

static void SNSetOnlySpeakMatchingFilters(NSString *bundleID, BOOL enabled)
{
    NSString *bid = [SNPrefsUtil normalizeBID:bundleID];
    if (bid.length == 0) return;
    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSMutableDictionary *all = [[defs objectForKey:kSNPerAppOnlySpeakMatchingFiltersV1Key] mutableCopy];
    if (![all isKindOfClass:NSMutableDictionary.class]) all = [NSMutableDictionary dictionary];
    if (enabled) all[bid] = @YES;
    else [all removeObjectForKey:bid];
    if (all.count) [defs setObject:all forKey:kSNPerAppOnlySpeakMatchingFiltersV1Key];
    else [defs removeObjectForKey:kSNPerAppOnlySpeakMatchingFiltersV1Key];
    [defs synchronize];
    [SNPrefsUtil postPrefsChanged];
}

static NSString *SNFilterActionTitle(NSString *action)
{
    if ([action isEqualToString:kSNNotificationFilterActionDontSpeak]) return @"Don't Speak";
    if ([action isEqualToString:kSNNotificationFilterActionSpeakNotification]) return @"Speak Notification";
    if ([action isEqualToString:kSNNotificationFilterActionSpeakCustom]) return @"Speak Custom Text";
    return @"Speak Matched Phrase";
}

static NSString *SNFilterActionHelp(NSString *action)
{
    if ([action isEqualToString:kSNNotificationFilterActionDontSpeak]) return @"Ignore the notification when this phrase is found.";
    if ([action isEqualToString:kSNNotificationFilterActionSpeakNotification]) return @"Speak the matching notification normally using this app's existing message format.";
    if ([action isEqualToString:kSNNotificationFilterActionSpeakMatched]) return @"Speak only the phrase entered in Contains.";
    if ([action isEqualToString:kSNNotificationFilterActionSpeakCustom]) return @"Speak your own text instead of the notification.";
    return @"";
}

static NSString *SNFilterActionSelectorHelp(NSString *action)
{
    if ([action isEqualToString:kSNNotificationFilterActionDontSpeak]) return @"Blocks notifications containing this phrase.";
    if ([action isEqualToString:kSNNotificationFilterActionSpeakNotification]) return @"Reads the full matching notification using this app's existing message format.";
    if ([action isEqualToString:kSNNotificationFilterActionSpeakMatched]) return @"Reads only the text entered in Contains.";
    if ([action isEqualToString:kSNNotificationFilterActionSpeakCustom]) return @"Reads your own text instead of the notification.";
    return @"";
}

static UITextField *SNFilterTextFieldInView(UIView *view)
{
    if ([view isKindOfClass:UITextField.class]) return (UITextField *)view;
    for (UIView *subview in view.subviews) {
        UITextField *field = SNFilterTextFieldInView(subview);
        if (field) return field;
    }
    return nil;
}

@protocol SNFilterEditorCallbacks <NSObject>
- (void)setActionFromSelector:(NSString *)value;
- (NSString *)actionTitleForSpecifier:(PSSpecifier *)specifier;
- (NSString *)currentActionValue;
@end

@protocol SNFilterActionSelectionCallbacks <NSObject>
- (BOOL)isSelectedActionForSpecifier:(PSSpecifier *)specifier;
@end

@interface SNFilterActionValueCell : PSTableCell
@property (nonatomic, strong) PSSpecifier *filterSpecifier;
@end

@implementation SNFilterActionValueCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier
{
    self = [super initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier
{
    [super refreshCellContentsWithSpecifier:specifier];
    self.filterSpecifier = specifier;
    self.textLabel.text = specifier.name;
    id<SNFilterEditorCallbacks> target = (id<SNFilterEditorCallbacks>)specifier.target;
    self.detailTextLabel.text = [target respondsToSelector:@selector(actionTitleForSpecifier:)]
        ? [target actionTitleForSpecifier:specifier] : @"";
    self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
}

@end

@interface SNFilterActionChoiceCell : PSTableCell
@end

@implementation SNFilterActionChoiceCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier
{
    return [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier specifier:specifier];
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier
{
    [super refreshCellContentsWithSpecifier:specifier];
    self.textLabel.text = specifier.name;
    id<SNFilterActionSelectionCallbacks> target = (id<SNFilterActionSelectionCallbacks>)specifier.target;
    self.accessoryType = [target respondsToSelector:@selector(isSelectedActionForSpecifier:)] &&
        [target isSelectedActionForSpecifier:specifier]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
}

@end

@interface SNNotificationFilterListController ()
@property (nonatomic, copy) NSString *bundleID;
@end

@implementation SNNotificationFilterListController

- (NSArray *)specifiers
{
    if (_specifiers) return _specifiers;
    self.bundleID = [self.specifier propertyForKey:@"bundleID"];
    NSMutableArray *items = [NSMutableArray array];
    NSArray *filters = SNFiltersForBundle(self.bundleID);
    PSSpecifier *onlyMatching = [PSSpecifier preferenceSpecifierNamed:@"Only Speak Matching Filters"
                                                                target:self set:@selector(setOnlyMatching:specifier:)
                                                                get:@selector(getOnlyMatching:)
                                                                detail:nil cell:PSSwitchCell edit:nil];
    [onlyMatching setProperty:self.bundleID forKey:@"bundleID"];
    [onlyMatching setProperty:@"When enabled, notifications from this app are only spoken when they match one of the filters below. Unmatched notifications are ignored." forKey:@"footerText"];
    [items addObject:onlyMatching];
    PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"NOTIFICATION FILTERS" target:self set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
    [group setProperty:@"Rules are checked against the notification title, subtitle, and body." forKey:@"footerText"];
    [items addObject:group];
    for (NSUInteger i = 0; i < filters.count; i++) {
        NSDictionary *rule = filters[i];
        NSString *subtitle = SNFilterActionTitle(rule[@"action"]);
        if ([rule[@"action"] isEqualToString:kSNNotificationFilterActionSpeakCustom]) subtitle = [subtitle stringByAppendingFormat:@" • %@", rule[@"customText"]];
        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:rule[@"match"] target:self set:NULL get:NULL detail:[SNNotificationFilterEditorController class] cell:PSLinkCell edit:nil];
        [row setProperty:self.bundleID forKey:@"bundleID"];
        [row setProperty:@(i) forKey:@"filterIndex"];
        [row setProperty:subtitle forKey:@"subtitle"];
        [items addObject:row];
    }
    PSSpecifier *add = [PSSpecifier preferenceSpecifierNamed:@"Add Filter" target:self set:NULL get:NULL detail:[SNNotificationFilterEditorController class] cell:PSLinkCell edit:nil];
    [add setProperty:self.bundleID forKey:@"bundleID"];
    [add setProperty:@YES forKey:@"newFilter"];
    [items addObject:add];
    _specifiers = [items mutableCopy];
    return _specifiers;
}

- (id)getOnlyMatching:(PSSpecifier *)specifier
{
    return @(SNOnlySpeakMatchingFilters(self.bundleID));
}

- (void)setOnlyMatching:(id)value specifier:(PSSpecifier *)specifier
{
    if ([value boolValue] && SNFiltersForBundle(self.bundleID).count == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Filter Required"
                                                                         message:@"Add at least one valid filter before enabling this mode."
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    SNSetOnlySpeakMatchingFilters(self.bundleID, [value boolValue]);
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (_specifiers) {
        _specifiers = nil;
        [self reloadSpecifiers];
    }
}
@end

@interface SNFilterActionListController : PSListController
@end

@implementation SNFilterActionListController

- (NSArray *)specifiers
{
    if (_specifiers) return _specifiers;
    self.title = @"When matched";
    NSMutableArray *items = [NSMutableArray array];
    NSArray *values = @[kSNNotificationFilterActionDontSpeak,
                        kSNNotificationFilterActionSpeakNotification,
                        kSNNotificationFilterActionSpeakMatched,
                        kSNNotificationFilterActionSpeakCustom];
    for (NSUInteger index = 0; index < values.count; index++) {
        NSString *value = values[index];
        PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:(index == 0 ? @"ACTION" : @"") target:self set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
        [group setProperty:SNFilterActionSelectorHelp(value) forKey:@"footerText"];
        [items addObject:group];
        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:SNFilterActionTitle(value)
                                                               target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
        [row setProperty:[SNFilterActionChoiceCell class] forKey:@"cellClass"];
        [row setProperty:value forKey:@"actionValue"];
        row.buttonAction = @selector(selectAction:);
        [items addObject:row];
    }
    _specifiers = [items mutableCopy];
    return _specifiers;
}

- (BOOL)isSelectedActionForSpecifier:(PSSpecifier *)specifier
{
    NSString *value = [specifier propertyForKey:@"actionValue"];
    NSArray *controllers = self.navigationController.viewControllers;
    id<SNFilterEditorCallbacks> editor = controllers.count > 1
        ? (id<SNFilterEditorCallbacks>)controllers[controllers.count - 2] : nil;
    return [editor respondsToSelector:@selector(currentActionValue)] &&
        [value isEqualToString:[editor currentActionValue]];
}

- (void)selectAction:(PSSpecifier *)specifier
{
    NSString *value = [specifier propertyForKey:@"actionValue"];
    NSArray *controllers = self.navigationController.viewControllers;
    UIViewController *editor = controllers.count > 1 ? controllers[controllers.count - 2] : nil;
    id<SNFilterEditorCallbacks> editorTarget = (id<SNFilterEditorCallbacks>)editor;
    if ([editorTarget respondsToSelector:@selector(setActionFromSelector:)]) {
        [editorTarget setActionFromSelector:value];
    }
    [self.navigationController popViewControllerAnimated:YES];
}

@end

@interface SNNotificationFilterEditorController ()
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *matchDraft;
@property (nonatomic, copy) NSString *customDraft;
@property (nonatomic, copy) NSString *actionDraft;
@property (nonatomic, assign) NSUInteger filterIndex;
@property (nonatomic, assign) BOOL newFilter;
@end

@implementation SNNotificationFilterEditorController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = self.newFilter ? @"Add Filter" : @"Edit Filter";
}

- (NSArray *)specifiers
{
    if (_specifiers) return _specifiers;
    self.bundleID = [self.specifier propertyForKey:@"bundleID"];
    self.newFilter = [[self.specifier propertyForKey:@"newFilter"] boolValue];
    self.filterIndex = [[self.specifier propertyForKey:@"filterIndex"] unsignedIntegerValue];
    NSArray *filters = SNFiltersForBundle(self.bundleID);
    NSDictionary *rule = (!self.newFilter && self.filterIndex < filters.count) ? filters[self.filterIndex] : nil;
    if (!self.matchDraft) self.matchDraft = rule[@"match"] ?: @"";
    if (!self.actionDraft) self.actionDraft = rule[@"action"] ?: kSNNotificationFilterActionDontSpeak;
    if (!self.customDraft) self.customDraft = rule[@"customText"] ?: @"";
    NSMutableArray *items = [NSMutableArray array];
    PSSpecifier *matchGroup = [PSSpecifier preferenceSpecifierNamed:@"MATCH" target:self set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
    [matchGroup setProperty:@"Match a literal phrase in the title, subtitle, or body." forKey:@"footerText"];
    [items addObject:matchGroup];
    PSSpecifier *match = [PSSpecifier preferenceSpecifierNamed:@"Contains" target:self set:@selector(setMatch:specifier:) get:@selector(getMatch:) detail:nil cell:PSEditTextCell edit:nil];
    [match setProperty:@YES forKey:@"isEditable"]; [match setProperty:@YES forKey:@"textFieldIsSingleLine"];
    [match setProperty:@YES forKey:@"noAutoCorrect"]; [match setProperty:@YES forKey:@"noAutoCaps"]; [match setProperty:@"SNFilterMatchCell" forKey:@"id"]; [items addObject:match];
    PSSpecifier *actionGroup = [PSSpecifier preferenceSpecifierNamed:@"ACTION" target:self set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
    [items addObject:actionGroup];
    PSSpecifier *action = [PSSpecifier preferenceSpecifierNamed:@"When matched" target:self set:NULL get:NULL detail:[SNFilterActionListController class] cell:PSLinkCell edit:nil];
    [action setProperty:[SNFilterActionValueCell class] forKey:@"cellClass"];
    [items addObject:action];
    PSSpecifier *actionHelp = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
    [actionHelp setProperty:SNFilterActionHelp(self.actionDraft) forKey:@"footerText"];
    [items addObject:actionHelp];
    if ([self.actionDraft isEqualToString:kSNNotificationFilterActionSpeakCustom]) {
        PSSpecifier *customGroup = [PSSpecifier preferenceSpecifierNamed:@"CUSTOM TEXT" target:self set:NULL get:NULL detail:nil cell:PSGroupCell edit:nil];
        [items addObject:customGroup];
        PSSpecifier *custom = [PSSpecifier preferenceSpecifierNamed:@"Text" target:self set:@selector(setCustom:specifier:) get:@selector(getCustom:) detail:nil cell:PSEditTextCell edit:nil];
        [custom setProperty:@YES forKey:@"isEditable"]; [custom setProperty:@YES forKey:@"textFieldIsSingleLine"];
        [custom setProperty:@YES forKey:@"noAutoCorrect"]; [custom setProperty:@YES forKey:@"noAutoCaps"]; [custom setProperty:@"SNFilterCustomCell" forKey:@"id"]; [items addObject:custom];
    }
    PSSpecifier *save = [PSSpecifier preferenceSpecifierNamed:@"Save" target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil]; save.buttonAction = @selector(saveFilter); [items addObject:save];
    if (!self.newFilter) { PSSpecifier *del = [PSSpecifier preferenceSpecifierNamed:@"Delete Filter" target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil]; del.buttonAction = @selector(deleteFilter); [items addObject:del]; }
    _specifiers = [items mutableCopy];
    return _specifiers;
}

- (NSString *)actionTitleForSpecifier:(PSSpecifier *)specifier { return SNFilterActionTitle(self.actionDraft); }
- (NSString *)currentActionValue { return self.actionDraft; }

- (id)getMatch:(PSSpecifier *)specifier { return self.matchDraft; }
- (void)setMatch:(id)value specifier:(PSSpecifier *)specifier { self.matchDraft = [value isKindOfClass:NSString.class] ? value : @""; }
- (id)getCustom:(PSSpecifier *)specifier { return self.customDraft; }
- (void)setCustom:(id)value specifier:(PSSpecifier *)specifier { self.customDraft = [value isKindOfClass:NSString.class] ? value : @""; }

- (NSString *)currentNativeTextForSpecifierID:(NSString *)specifierID fallback:(NSString *)fallback
{
    PSTableCell *cell = [self cachedCellForSpecifierID:specifierID];
    UITextField *field = SNFilterTextFieldInView(cell);
    return field ? (field.text ?: @"") : (fallback ?: @"");
}

- (void)setActionFromSelector:(NSString *)value
{
    if (![value isEqualToString:kSNNotificationFilterActionDontSpeak] &&
        ![value isEqualToString:kSNNotificationFilterActionSpeakNotification] &&
        ![value isEqualToString:kSNNotificationFilterActionSpeakMatched] &&
        ![value isEqualToString:kSNNotificationFilterActionSpeakCustom]) return;
    self.matchDraft = [self currentNativeTextForSpecifierID:@"SNFilterMatchCell" fallback:self.matchDraft];
    self.customDraft = [self currentNativeTextForSpecifierID:@"SNFilterCustomCell" fallback:self.customDraft];
    self.actionDraft = value;
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)showValidation:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Invalid Filter" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)saveFilter
{
    self.matchDraft = [self currentNativeTextForSpecifierID:@"SNFilterMatchCell" fallback:self.matchDraft];
    if ([self.actionDraft isEqualToString:kSNNotificationFilterActionSpeakCustom]) {
        self.customDraft = [self currentNativeTextForSpecifierID:@"SNFilterCustomCell" fallback:self.customDraft];
    }
    self.matchDraft = SNFilterTrim(self.matchDraft); self.customDraft = SNFilterTrim(self.customDraft);
    if (self.matchDraft.length == 0) { [self showValidation:@"Enter a phrase to match."]; return; }
    if ([self.actionDraft isEqualToString:kSNNotificationFilterActionSpeakCustom] && self.customDraft.length == 0) { [self showValidation:@"Enter custom text for this action."]; return; }
    NSMutableDictionary *rule = [@{ @"match": self.matchDraft, @"action": self.actionDraft } mutableCopy];
    if ([self.actionDraft isEqualToString:kSNNotificationFilterActionSpeakCustom]) rule[@"customText"] = self.customDraft;
    NSMutableArray *filters = [SNFiltersForBundle(self.bundleID) mutableCopy];
    if (self.newFilter) [filters addObject:rule];
    else if (self.filterIndex < filters.count) filters[self.filterIndex] = rule;
    else { [self showValidation:@"This filter is no longer available."]; return; }
    SNSaveFilters(self.bundleID, filters);
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)deleteFilter
{
    NSMutableArray *filters = [SNFiltersForBundle(self.bundleID) mutableCopy];
    if (self.filterIndex < filters.count) [filters removeObjectAtIndex:self.filterIndex];
    SNSaveFilters(self.bundleID, filters);
    [self.navigationController popViewControllerAnimated:YES];
}
@end
