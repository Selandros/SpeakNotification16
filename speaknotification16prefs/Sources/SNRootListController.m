#import "SNRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <Preferences/PSListController.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>
#import "SNPrefsUtil.h"
#import "SNPreferences.h"

static NSString * const kSNLogPath = @"/var/mobile/Library/Logs/log_speaknotification16.txt";
static NSString * const kReadIncomingKey = @"readIncomingCalls";
static NSString * const kReadMissedKey = @"readMissedCalls";
static NSString * const kSpeakDurationKey = @"speakCallDuration";
static NSString * const kIncomingTextID = @"incomingText";
static NSString * const kMissedTextID = @"missedText";
static NSString * const kDurationTextID = @"durationText";
static NSString * const kSNReleaseTokenKey = @"releaseGitHubToken";
static NSString * const kSNReleaseLastCheckKey = @"releaseLastCheckAt";
static NSString * const kSNReleaseLastSeenTagKey = @"releaseLastSeenTag";
static NSString * const kSNReleaseLastSeenBuildIDKey = @"releaseLastSeenBuildID";
static NSString * const kSNReleaseLastNotifiedBuildIDKey = @"releaseLastNotifiedBuildID";
static NSString * const kSNReleaseAvailableBuildIDKey = @"releaseAvailableBuildID";
static NSString * const kSNReleaseLastURLKey = @"releaseLastReleaseURL";
static NSString * const kSNReleaseCurrentInstallIDKey = @"releaseCurrentInstallID";
static NSString * const kSNReleaseLastProcessedInstallIDKey = @"releaseLastProcessedInstallID";
static NSString * const kSNReleaseTokenFieldID = @"SNReleaseTokenField";
static NSString * const kSNReleaseTokenStatusID = @"SNReleaseTokenStatus";
static NSString * const kSNReleaseCheckNowID = @"SNReleaseCheckNow";
static NSString * const kSNReleaseBetaGroupID = @"SNReleaseBetaGroup";
static NSString * const kSNReleaseBetaSetTokenID = @"SNReleaseBetaSetToken";
static NSString * const kSNReleaseBetaCreateTokenID = @"SNReleaseBetaCreateToken";
static NSString * const kSNReleaseBetaClearTokenID = @"SNReleaseBetaClearToken";
static NSString * const kSNReleaseBetaMarkerKey = @"_SNReleaseBetaAccess";
static NSString * const kSNDebugDeleteLogsID = @"SNDebugDeleteLogs";
static NSString * const kSNDebugLoggingKey = @"debugLoggingEnabled";
static NSString * const kSNReleaseBetaFooter = @"Optional access for private beta releases and authenticated GitHub requests. Public releases do not require a token.";
static NSString * const kSNReleaseManualRequestIDKey = @"releaseManualCheckRequestID";
static NSString * const kSNReleaseManualResultStatusKey = @"releaseManualCheckResultStatus";
static NSString * const kSNReleaseManualResultTagKey = @"releaseManualCheckResultTag";
static NSString * const kSNReleaseManualResultURLKey = @"releaseManualCheckResultURL";
static NSString * const kSNReleaseManualResultMessageKey = @"releaseManualCheckResultMessage";
static NSString * const kSNReleaseManualResultRequestIDKey = @"releaseManualCheckResultRequestID";
static NSString * const kSNReleaseManualResultTimestampKey = @"releaseManualCheckResultTimestamp";
static NSString * const kSNReleaseTokenValidationRequestIDKey = @"releaseTokenValidationRequestID";
static NSString * const kSNReleaseTokenValidationStatusKey = @"releaseTokenValidationStatus";
static NSString * const kSNReleaseTokenValidationResultStatusKey = @"releaseTokenValidationResultStatus";
static NSString * const kSNReleaseTokenValidationResultRequestIDKey = @"releaseTokenValidationResultRequestID";
static NSString * const kSNReleaseTokenURLString = @"https://github.com/settings/personal-access-tokens/new?name=SpeakNotification16%20Beta%20Updates&description=Read-only%20access%20for%20SpeakNotification16%20release%20checks&target_name=Selandros&expires_in=90&contents=read";

static UITextField *SNTextFieldWithPlaceholder(UIView *view, NSString *placeholder) {
    if ([view isKindOfClass:UITextField.class] &&
        [((UITextField *)view).placeholder isEqualToString:placeholder]) {
        return (UITextField *)view;
    }
    for (UIView *subview in view.subviews) {
        UITextField *field = SNTextFieldWithPlaceholder(subview, placeholder);
        if (field) return field;
    }
    return nil;
}

static BOOL SNReleaseResultURLIsAllowed(NSURL *url) {
    if (![url isKindOfClass:NSURL.class]) return NO;
    if (![url.scheme.lowercaseString isEqualToString:@"https"]) return NO;
    if (![url.host.lowercaseString isEqualToString:@"github.com"]) return NO;
    if (url.port || url.user.length > 0 || url.password.length > 0) return NO;
    return [url.path hasPrefix:@"/Selandros/SpeakNotification16/releases/"];
}


@interface SNRootStepperCell : PSTableCell
@property (nonatomic, strong) UIStackView *controlsView;
@property (nonatomic, strong) UIButton *minusButton;
@property (nonatomic, strong) UIButton *plusButton;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) PSSpecifier *stepperSpecifier;
@end

@implementation SNRootStepperCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier
{
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        _minusButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [_minusButton setTitle:@"-" forState:UIControlStateNormal];
        [_minusButton addTarget:self action:@selector(sn_decrement:) forControlEvents:UIControlEventTouchUpInside];
        [self sn_configureStepperButton:_minusButton];

        _plusButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [_plusButton setTitle:@"+" forState:UIControlStateNormal];
        [_plusButton addTarget:self action:@selector(sn_increment:) forControlEvents:UIControlEventTouchUpInside];
        [self sn_configureStepperButton:_plusButton];

        _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _valueLabel.textAlignment = NSTextAlignmentCenter;
        _valueLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _valueLabel.adjustsFontForContentSizeCategory = YES;
        _valueLabel.minimumScaleFactor = 0.8;
        _valueLabel.adjustsFontSizeToFitWidth = YES;

        _controlsView = [[UIStackView alloc] initWithArrangedSubviews:@[_minusButton, _valueLabel, _plusButton]];
        _controlsView.axis = UILayoutConstraintAxisHorizontal;
        _controlsView.alignment = UIStackViewAlignmentCenter;
        _controlsView.spacing = 10.0;
        _controlsView.frame = CGRectMake(0, 0, 146, 34);

        [_minusButton.widthAnchor constraintEqualToConstant:32.0].active = YES;
        [_minusButton.heightAnchor constraintEqualToConstant:32.0].active = YES;
        [_plusButton.widthAnchor constraintEqualToConstant:32.0].active = YES;
        [_plusButton.heightAnchor constraintEqualToConstant:32.0].active = YES;
        [_valueLabel.widthAnchor constraintEqualToConstant:52.0].active = YES;

        self.accessoryView = _controlsView;
        self.accessoryType = UITableViewCellAccessoryNone;
        self.editingAccessoryType = UITableViewCellAccessoryNone;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}

- (void)sn_configureStepperButton:(UIButton *)button
{
    button.titleLabel.font = [UIFont boldSystemFontOfSize:21.0];
    button.layer.cornerRadius = 16.0;
    button.layer.masksToBounds = YES;
    [button setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    [button setTitleColor:[UIColor.labelColor colorWithAlphaComponent:0.35] forState:UIControlStateDisabled];
    [self sn_updateStepperButton:button enabled:YES];
}

- (void)sn_updateStepperButton:(UIButton *)button enabled:(BOOL)enabled
{
    button.enabled = enabled;
    button.alpha = enabled ? 1.0 : 0.45;
    button.backgroundColor = enabled ? UIColor.secondarySystemFillColor : UIColor.tertiarySystemFillColor;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier
{
    [super refreshCellContentsWithSpecifier:specifier];
    self.stepperSpecifier = specifier;
    self.textLabel.text = specifier.name;
    self.accessoryView = self.controlsView;
    self.accessoryType = UITableViewCellAccessoryNone;
    self.editingAccessoryType = UITableViewCellAccessoryNone;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    [self sn_refreshValue];
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated
{
    [super setSelected:NO animated:animated];
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated
{
    [super setHighlighted:NO animated:animated];
}

- (NSInteger)sn_integerProperty:(NSString *)property defaultValue:(NSInteger)fallback
{
    id value = [self.stepperSpecifier propertyForKey:property];
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

- (NSString *)sn_preferenceKey
{
    id key = [self.stepperSpecifier propertyForKey:@"key"];
    return [key isKindOfClass:NSString.class] ? key : nil;
}

- (NSInteger)sn_currentValue
{
    NSString *key = [self sn_preferenceKey];
    NSInteger fallback = [self sn_integerProperty:@"default" defaultValue:0];
    if (key.length == 0) return fallback;

    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
    id stored = [defs objectForKey:key];
    NSInteger value = [stored respondsToSelector:@selector(integerValue)] ? [stored integerValue] : fallback;
    NSInteger minValue = [self sn_integerProperty:@"min" defaultValue:value];
    NSInteger maxValue = [self sn_integerProperty:@"max" defaultValue:value];
    return MIN(MAX(value, minValue), maxValue);
}

- (void)sn_refreshValue
{
    NSInteger value = [self sn_currentValue];
    self.valueLabel.text = [NSString stringWithFormat:@"%ld", (long)value];

    NSInteger minValue = [self sn_integerProperty:@"min" defaultValue:value];
    NSInteger maxValue = [self sn_integerProperty:@"max" defaultValue:value];
    [self sn_updateStepperButton:self.minusButton enabled:(value > minValue)];
    [self sn_updateStepperButton:self.plusButton enabled:(value < maxValue)];
}

- (void)sn_setCurrentValue:(NSInteger)value
{
    NSString *key = [self sn_preferenceKey];
    if (key.length == 0) return;

    NSInteger minValue = [self sn_integerProperty:@"min" defaultValue:value];
    NSInteger maxValue = [self sn_integerProperty:@"max" defaultValue:value];
    NSInteger clamped = MIN(MAX(value, minValue), maxValue);

    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
    [defs setInteger:clamped forKey:key];
    [defs synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), kSNPrefsNotify, NULL, NULL, true);
    [self sn_refreshValue];
}

- (void)sn_decrement:(__unused UIButton *)sender
{
    NSInteger step = [self sn_integerProperty:@"step" defaultValue:1];
    if (step < 1) step = 1;
    [self sn_setCurrentValue:([self sn_currentValue] - step)];
}

- (void)sn_increment:(__unused UIButton *)sender
{
    NSInteger step = [self sn_integerProperty:@"step" defaultValue:1];
    if (step < 1) step = 1;
    [self sn_setCurrentValue:([self sn_currentValue] + step)];
}


@end

static NSString * const kSNDefaultFormat = @"{APP}: {TITLE}: {BODY}";

static NSString *SNTrimmedFormat(NSString *value)
{
    if (![value isKindOfClass:NSString.class]) return @"";
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSUserDefaults *SNFormatDefaults(void)
{
    return [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
}

static NSString *SNGlobalFormatForPreview(NSUserDefaults *defs)
{
    NSString *value = [defs stringForKey:@"globalFormat"];
    if (SNTrimmedFormat(value).length > 0) return value;

    value = [defs stringForKey:@"messageFormat"];
    if (SNTrimmedFormat(value).length > 0) return value;

    return kSNDefaultFormat;
}

static NSString *SNStoredFormatForSpecifier(PSSpecifier *specifier)
{
    NSUserDefaults *defs = SNFormatDefaults();
    id value = [defs objectForKey:@"globalFormat"];
    if ([value isKindOfClass:NSString.class]) return value;

    value = [defs objectForKey:@"messageFormat"];
    return [value isKindOfClass:NSString.class] ? value : kSNDefaultFormat;
}

static NSString *SNEffectiveFormatForSpecifier(PSSpecifier *specifier)
{
    NSUserDefaults *defs = SNFormatDefaults();
    return SNGlobalFormatForPreview(defs);
}

static NSString *SNFormatAppendToken(NSString *format, NSString *token)
{
    NSString *base = [format isKindOfClass:NSString.class] ? format : @"";
    if (base.length == 0) return token;

    NSCharacterSet *spacing = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    unichar last = [base characterAtIndex:(base.length - 1)];
    NSString *separator = [spacing characterIsMember:last] ? @"" : @" ";
    return [base stringByAppendingFormat:@"%@%@", separator, token];
}

static void SNPostFormatChanged(void)
{
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), kSNPrefsNotify, NULL, NULL, true);
}

static void SNSaveFormatForSpecifier(PSSpecifier *specifier, NSString *text)
{
    NSString *value = [text isKindOfClass:NSString.class] ? text : @"";
    NSUserDefaults *defs = SNFormatDefaults();

    [defs setObject:value forKey:@"globalFormat"];

    [defs synchronize];
    SNPostFormatChanged();
}

static UITextField *SNFirstResponderTextFieldInView(UIView *view)
{
    if ([view isKindOfClass:UITextField.class] && view.isFirstResponder) return (UITextField *)view;
    for (UIView *subview in view.subviews) {
        UITextField *field = SNFirstResponderTextFieldInView(subview);
        if (field) return field;
    }
    return nil;
}

static void SNReloadFormatPreview(PSSpecifier *specifier)
{
    id target = specifier.target;
    if ([target respondsToSelector:@selector(reloadSpecifierID:animated:)]) {
        [(PSListController *)target reloadSpecifierID:@"SN_EffectiveFormatCell" animated:NO];
    }
}

static void SNReloadFormatEditor(PSSpecifier *specifier)
{
    id target = specifier.target;
    if ([target respondsToSelector:@selector(reloadSpecifiers)]) {
        [(PSListController *)target reloadSpecifiers];
    }
}

@interface SNFormatValueCell : PSTableCell <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *formatTextField;
@property (nonatomic, strong) PSSpecifier *formatSpecifier;
@end

@implementation SNFormatValueCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier
{
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.accessoryType = UITableViewCellAccessoryNone;
        self.editingAccessoryType = UITableViewCellAccessoryNone;

        _formatTextField = [[UITextField alloc] initWithFrame:CGRectZero];
        _formatTextField.translatesAutoresizingMaskIntoConstraints = NO;
        _formatTextField.borderStyle = UITextBorderStyleRoundedRect;
        _formatTextField.autocorrectionType = UITextAutocorrectionTypeNo;
        _formatTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _formatTextField.clearButtonMode = UITextFieldViewModeWhileEditing;
        _formatTextField.returnKeyType = UIReturnKeyDone;
        _formatTextField.delegate = self;
        [_formatTextField addTarget:self action:@selector(sn_textChanged:) forControlEvents:UIControlEventEditingChanged];
        [_formatTextField addTarget:self action:@selector(sn_textDidEnd:) forControlEvents:UIControlEventEditingDidEnd];
        [self.contentView addSubview:_formatTextField];

        [NSLayoutConstraint activateConstraints:@[
            [_formatTextField.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
            [_formatTextField.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
            [_formatTextField.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_formatTextField.heightAnchor constraintGreaterThanOrEqualToConstant:34.0]
        ]];
    }
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier
{
    [super refreshCellContentsWithSpecifier:specifier];
    self.formatSpecifier = specifier;
    self.textLabel.text = nil;
    self.detailTextLabel.text = nil;
    self.accessoryView = nil;
    self.accessoryType = UITableViewCellAccessoryNone;
    self.editingAccessoryType = UITableViewCellAccessoryNone;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    NSString *placeholder = [specifier propertyForKey:@"placeholder"];
    self.formatTextField.placeholder = [placeholder isKindOfClass:NSString.class] ? placeholder : kSNDefaultFormat;
    self.formatTextField.text = SNStoredFormatForSpecifier(specifier);
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated
{
    [super setSelected:NO animated:animated];
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated
{
    [super setHighlighted:NO animated:animated];
}

- (void)sn_textChanged:(UITextField *)sender
{
    SNSaveFormatForSpecifier(self.formatSpecifier, sender.text ?: @"");
    SNReloadFormatPreview(self.formatSpecifier);
}

- (void)sn_textDidEnd:(UITextField *)sender
{
    SNSaveFormatForSpecifier(self.formatSpecifier, sender.text ?: @"");
    SNReloadFormatPreview(self.formatSpecifier);
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    return YES;
}

@end

@interface SNFormatTokensCell : PSTableCell
@property (nonatomic, strong) UIStackView *containerStack;
@property (nonatomic, strong) UIStackView *tokensStack;
@property (nonatomic, strong) UIStackView *actionsStack;
@property (nonatomic, strong) UIButton *clearButton;
@property (nonatomic, strong) UIButton *defaultButton;
@property (nonatomic, strong) PSSpecifier *formatSpecifier;
@end

@implementation SNFormatTokensCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier
{
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.accessoryType = UITableViewCellAccessoryNone;
        self.editingAccessoryType = UITableViewCellAccessoryNone;

        _tokensStack = [[UIStackView alloc] initWithFrame:CGRectZero];
        _tokensStack.axis = UILayoutConstraintAxisHorizontal;
        _tokensStack.alignment = UIStackViewAlignmentFill;
        _tokensStack.distribution = UIStackViewDistributionFillEqually;
        _tokensStack.spacing = 6.0;

        NSArray<NSArray<NSString *> *> *tokens = @[
            @[@"App", @"{APP}"],
            @[@"Title", @"{TITLE}"],
            @[@"Sender", @"{SENDER}"],
            @[@"Message", @"{BODY}"],
            @[@"Time", @"{TIME}"]
        ];
        for (NSArray<NSString *> *item in tokens) {
            UIButton *button = [self sn_buttonWithTitle:item[0] identifier:item[1] action:@selector(sn_insertToken:)];
            [_tokensStack addArrangedSubview:button];
        }

        _actionsStack = [[UIStackView alloc] initWithFrame:CGRectZero];
        _actionsStack.axis = UILayoutConstraintAxisHorizontal;
        _actionsStack.alignment = UIStackViewAlignmentFill;
        _actionsStack.distribution = UIStackViewDistributionFillEqually;
        _actionsStack.spacing = 8.0;
        _clearButton = [self sn_buttonWithTitle:@"Clear" identifier:@"clear" action:@selector(sn_clearFormat:)];
        _defaultButton = [self sn_buttonWithTitle:@"Default" identifier:@"default" action:@selector(sn_defaultFormat:)];
        [_actionsStack addArrangedSubview:_clearButton];
        [_actionsStack addArrangedSubview:_defaultButton];

        _containerStack = [[UIStackView alloc] initWithArrangedSubviews:@[_tokensStack, _actionsStack]];
        _containerStack.axis = UILayoutConstraintAxisVertical;
        _containerStack.alignment = UIStackViewAlignmentFill;
        _containerStack.distribution = UIStackViewDistributionFillEqually;
        _containerStack.spacing = 8.0;
        _containerStack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_containerStack];

        [NSLayoutConstraint activateConstraints:@[
            [_containerStack.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
            [_containerStack.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
            [_containerStack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8.0],
            [_containerStack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8.0]
        ]];
    }
    return self;
}

- (UIButton *)sn_buttonWithTitle:(NSString *)title identifier:(NSString *)identifier action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setTitle:title forState:UIControlStateNormal];
    button.accessibilityIdentifier = identifier;
    button.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.75;
    button.layer.cornerRadius = 14.0;
    button.layer.masksToBounds = YES;
    button.backgroundColor = UIColor.secondarySystemFillColor;
    [button setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    [button setTitleColor:[UIColor.labelColor colorWithAlphaComponent:0.35] forState:UIControlStateDisabled];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier
{
    [super refreshCellContentsWithSpecifier:specifier];
    self.formatSpecifier = specifier;
    self.textLabel.text = nil;
    self.detailTextLabel.text = nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.accessoryType = UITableViewCellAccessoryNone;
    self.editingAccessoryType = UITableViewCellAccessoryNone;
    [self.clearButton setTitle:@"Clear" forState:UIControlStateNormal];
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated
{
    [super setSelected:NO animated:animated];
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated
{
    [super setHighlighted:NO animated:animated];
}

- (UITextField *)sn_activeTextField
{
    return SNFirstResponderTextFieldInView(self.window ?: self.contentView);
}

- (void)sn_storeText:(NSString *)text reloadEditor:(BOOL)reloadEditor
{
    SNSaveFormatForSpecifier(self.formatSpecifier, text);
    SNReloadFormatPreview(self.formatSpecifier);
    if (reloadEditor) SNReloadFormatEditor(self.formatSpecifier);
}

- (void)sn_insertToken:(UIButton *)sender
{
    NSString *token = sender.accessibilityIdentifier;
    if (token.length == 0) return;

    UITextField *field = [self sn_activeTextField];
    if (field && field.isFirstResponder) {
        UITextRange *range = field.selectedTextRange;
        if (range) {
            [field replaceRange:range withText:token];
        } else {
            field.text = SNFormatAppendToken(field.text, token);
        }
        [field sendActionsForControlEvents:UIControlEventEditingChanged];
        [self sn_storeText:(field.text ?: @"") reloadEditor:NO];
        return;
    }

    NSString *next = SNFormatAppendToken(SNStoredFormatForSpecifier(self.formatSpecifier), token);
    [self sn_storeText:next reloadEditor:YES];
}

- (void)sn_clearFormat:(__unused UIButton *)sender
{
    UITextField *field = [self sn_activeTextField];
    if (field && field.isFirstResponder) {
        field.text = @"";
        [field sendActionsForControlEvents:UIControlEventEditingChanged];
        [self sn_storeText:@"" reloadEditor:NO];
        return;
    }

    [self sn_storeText:@"" reloadEditor:YES];
}

- (void)sn_defaultFormat:(__unused UIButton *)sender
{
    UITextField *field = [self sn_activeTextField];
    if (field && field.isFirstResponder) {
        field.text = kSNDefaultFormat;
        [field sendActionsForControlEvents:UIControlEventEditingChanged];
        [self sn_storeText:kSNDefaultFormat reloadEditor:NO];
        return;
    }

    [self sn_storeText:kSNDefaultFormat reloadEditor:YES];
}

@end

@interface SNFormatPreviewCell : PSTableCell
@property (nonatomic, strong) UILabel *formatLabel;
@property (nonatomic, strong) PSSpecifier *formatSpecifier;
@end

@implementation SNFormatPreviewCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier
{
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.accessoryType = UITableViewCellAccessoryNone;
        self.editingAccessoryType = UITableViewCellAccessoryNone;

        _formatLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _formatLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _formatLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _formatLabel.adjustsFontForContentSizeCategory = YES;
        _formatLabel.numberOfLines = 0;
        _formatLabel.textColor = UIColor.labelColor;
        [self.contentView addSubview:_formatLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_formatLabel.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
            [_formatLabel.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
            [_formatLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:9.0],
            [_formatLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-9.0]
        ]];
    }
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier
{
    [super refreshCellContentsWithSpecifier:specifier];
    self.formatSpecifier = specifier;
    self.textLabel.text = nil;
    self.detailTextLabel.text = nil;
    self.accessoryView = nil;
    self.accessoryType = UITableViewCellAccessoryNone;
    self.editingAccessoryType = UITableViewCellAccessoryNone;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.formatLabel.text = SNEffectiveFormatForSpecifier(specifier);
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated
{
    [super setSelected:NO animated:animated];
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated
{
    [super setHighlighted:NO animated:animated];
}

@end

static NSString *SNLogsDir(void) {
    return @"/var/mobile/Library/Logs";
}

static NSString *SNLogBase(void) {
    return @"log_speaknotification16";
}

static NSString *SNLogExt(void) {
    return @"txt";
}

static NSString *SNActiveLogPath(void) {
    return [SNLogsDir() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.%@", SNLogBase(), SNLogExt()]];
}

static BOOL SNIsSpeakLogFile(NSString *filename) {
    if (![filename hasPrefix:SNLogBase()]) return NO;
    if (![filename hasSuffix:[@"." stringByAppendingString:SNLogExt()]]) return NO;
    return YES;
}

@interface SNRootListController ()
@property (nonatomic, strong) NSMutableArray<NSString *> *wifiItems; // ARC: strong instead of retain
@property (nonatomic, strong) NSMutableArray<NSString *> *btItems;   // ARC: strong instead of retain
@property (nonatomic, copy) NSString *manualReleaseCheckRequestID;
@property (nonatomic, assign) BOOL manualReleaseCheckPending;
@property (nonatomic, assign) NSUInteger manualReleaseCheckGeneration;
@property (nonatomic, assign) BOOL manualReleaseCheckObserverRegistered;
@property (nonatomic, assign) BOOL debugPrefsObserverRegistered;
@property (nonatomic, strong) NSArray<PSSpecifier *> *betaAccessSpecifiers;
@property (nonatomic, copy) NSString *tokenValidationRequestID;
@property (nonatomic, assign) BOOL tokenValidationPending;
@property (nonatomic, assign) NSUInteger tokenValidationGeneration;
- (void)sn_handleManualReleaseCheckResult;
- (void)sn_handleTokenValidationResult;
- (void)sn_rebuildReleaseStatusSpecifier;
- (BOOL)sn_debugLoggingEnabled;
- (void)sn_updateBetaAccessVisibilityAnimated:(BOOL)animated;
@end

static void SNReleaseCheckResultChanged(__unused CFNotificationCenterRef center,
                                        void *observer,
                                        __unused CFStringRef name,
                                        __unused const void *object,
                                        __unused CFDictionaryRef userInfo) {
    SNRootListController *controller = (__bridge SNRootListController *)observer;
    if (!controller) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller sn_updateBetaAccessVisibilityAnimated:NO];
        [controller reloadSpecifierID:kSNReleaseTokenStatusID animated:NO];
        [controller sn_rebuildReleaseStatusSpecifier];
        [controller reloadSpecifiers];
        [controller sn_handleManualReleaseCheckResult];
        [controller sn_handleTokenValidationResult];
    });
}

static void SNReleasePrefsChanged(__unused CFNotificationCenterRef center,
                                  void *observer,
                                  __unused CFStringRef name,
                                  __unused const void *object,
                                  __unused CFDictionaryRef userInfo) {
    SNRootListController *controller = (__bridge SNRootListController *)observer;
    if (!controller) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller sn_updateBetaAccessVisibilityAnimated:YES];
    });
}

@implementation SNRootListController

#pragma mark - Lifecycle / Specifiers

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;

    _specifiers = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];
    [self sn_configureStepperSpecifiers];

    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
    NSArray *ssids = [defs objectForKey:kSSIDsKey];
    NSArray *bts = [defs objectForKey:kBTKey];

    self.wifiItems = [ssids isKindOfClass:NSArray.class]
        ? [ssids mutableCopy]
        : [NSMutableArray array];

    self.btItems = [bts isKindOfClass:NSArray.class]
        ? [bts mutableCopy]
        : [NSMutableArray array];

    id df = [defs objectForKey:@"globalFormat"];
    if (![df isKindOfClass:NSString.class]) {
        NSString *legacy = [defs stringForKey:@"messageFormat"];
        NSString *format = ([legacy isKindOfClass:NSString.class] && legacy.length) ? legacy : @"{APP}: {TITLE}: {BODY}";
        [defs setObject:format forKey:@"globalFormat"];
        [defs setObject:format forKey:@"messageFormat"];
        [defs synchronize];
    }

    [self rebuildInlineLists];
    [self sn_rebuildReleaseStatusSpecifier];
    [self sn_updateBetaAccessVisibilityAnimated:NO];

    self.navigationItem.title = @"SpeakNotification16";
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (!self.manualReleaseCheckObserverRegistered) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)self,
                                        SNReleaseCheckResultChanged,
                                        kSNReleaseCheckResultNotify,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        self.manualReleaseCheckObserverRegistered = YES;
    }
    if (!self.debugPrefsObserverRegistered) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)self,
                                        SNReleasePrefsChanged,
                                        kSNPrefsNotify,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        self.debugPrefsObserverRegistered = YES;
    }
}

- (void)dealloc {
    if (self.manualReleaseCheckObserverRegistered) {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                           (__bridge const void *)self,
                                           kSNReleaseCheckResultNotify,
                                           NULL);
    }
    if (self.debugPrefsObserverRegistered) {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                           (__bridge const void *)self,
                                           kSNPrefsNotify,
                                           NULL);
    }
}

- (BOOL)sn_debugLoggingEnabled {
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
    return [defs boolForKey:kSNDebugLoggingKey];
}

- (NSArray *)sn_betaAccessSpecifiers {
    if (self.betaAccessSpecifiers) return self.betaAccessSpecifiers;

    NSMutableArray *specifiers = [NSMutableArray arrayWithCapacity:5];

    PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"Beta Access"
                                                          target:self
                                                             set:NULL
                                                             get:NULL
                                                          detail:nil
                                                            cell:PSGroupCell
                                                            edit:nil];
    [group setProperty:kSNReleaseBetaGroupID forKey:@"id"];
    [group setProperty:kSNReleaseBetaFooter forKey:@"footerText"];
    [specifiers addObject:group];

    PSSpecifier *tokenField = [PSSpecifier preferenceSpecifierNamed:@"Beta Token"
                                                               target:self
                                                                  set:NULL
                                                                  get:NULL
                                                               detail:nil
                                                                 cell:PSSecureEditTextCell
                                                                 edit:nil];
    [tokenField setProperty:kSNReleaseTokenFieldID forKey:@"id"];
    [tokenField setProperty:kSNPrefsSuite forKey:@"defaults"];
    [tokenField setProperty:kSNReleaseTokenKey forKey:@"key"];
    [tokenField setProperty:@"" forKey:@"default"];
    [tokenField setProperty:@"Fine-grained token" forKey:@"placeholder"];
    [specifiers addObject:tokenField];

    PSSpecifier *setToken = [PSSpecifier preferenceSpecifierNamed:@"Set Token"
                                                             target:self
                                                                set:NULL
                                                                get:NULL
                                                             detail:nil
                                                               cell:PSButtonCell
                                                               edit:nil];
    [setToken setProperty:kSNReleaseBetaSetTokenID forKey:@"id"];
    setToken->action = @selector(setReleaseGitHubToken);
    [specifiers addObject:setToken];

    PSSpecifier *status = [PSSpecifier preferenceSpecifierNamed:@"Token Status"
                                                           target:self
                                                              set:NULL
                                                              get:@selector(releaseTokenStatus:)
                                                           detail:nil
                                                             cell:PSTitleValueCell
                                                             edit:nil];
    [status setProperty:kSNReleaseTokenStatusID forKey:@"id"];
    [specifiers addObject:status];

    PSSpecifier *createToken = [PSSpecifier preferenceSpecifierNamed:@"Create Beta Token"
                                                               target:self
                                                                  set:NULL
                                                                  get:NULL
                                                               detail:nil
                                                                 cell:PSButtonCell
                                                                 edit:nil];
    [createToken setProperty:kSNReleaseBetaCreateTokenID forKey:@"id"];
    createToken->action = @selector(createReleaseGitHubToken);
    [specifiers addObject:createToken];

    PSSpecifier *clearToken = [PSSpecifier preferenceSpecifierNamed:@"Clear Beta Token"
                                                              target:self
                                                                 set:NULL
                                                                 get:NULL
                                                              detail:nil
                                                                cell:PSButtonCell
                                                                edit:nil];
    [clearToken setProperty:kSNReleaseBetaClearTokenID forKey:@"id"];
    clearToken->action = @selector(clearReleaseGitHubToken);
    [specifiers addObject:clearToken];

    for (PSSpecifier *specifier in specifiers) {
        [specifier setProperty:@YES forKey:kSNReleaseBetaMarkerKey];
    }
    self.betaAccessSpecifiers = [specifiers copy];
    return self.betaAccessSpecifiers;
}

- (void)sn_updateBetaAccessVisibilityAnimated:(BOOL)animated {
    if (!_specifiers) return;

    BOOL shouldShow = [self sn_debugLoggingEnabled];
    BOOL wasShown = NO;
    NSMutableArray *existingBetaSpecifiers = [NSMutableArray array];
    NSMutableArray *base = [NSMutableArray arrayWithCapacity:_specifiers.count];
    for (PSSpecifier *specifier in _specifiers) {
        if ([[specifier propertyForKey:kSNReleaseBetaMarkerKey] boolValue]) {
            wasShown = YES;
            [existingBetaSpecifiers addObject:specifier];
        } else {
            [base addObject:specifier];
        }
    }

    if (shouldShow) {
        NSArray *betaSpecifiers = wasShown ? existingBetaSpecifiers : [self sn_betaAccessSpecifiers];
        NSInteger anchorIndex = [self indexOfSpecifierWithID:kSNDebugDeleteLogsID];
        NSInteger insertAt = NSNotFound;
        if (anchorIndex != NSNotFound) insertAt = anchorIndex + 1;
        if (insertAt == NSNotFound) insertAt = (NSInteger)base.count;
        for (PSSpecifier *specifier in betaSpecifiers) {
            [base insertObject:specifier atIndex:(NSUInteger)insertAt];
            insertAt++;
        }
    }

    BOOL changed = (shouldShow != wasShown);
    _specifiers = base;
    if (changed && animated && self.isViewLoaded && self.view.window) {
        [self reloadSpecifiers];
    }
}

- (void)sn_configureStepperSpecifiers {
    for (PSSpecifier *specifier in _specifiers) {
        NSString *key = [specifier propertyForKey:@"key"];
        if ([key isEqualToString:@"spamCooldownSeconds"] || [key isEqualToString:@"speechVolume"]) {
            [specifier setProperty:[SNRootStepperCell class] forKey:@"cellClass"];
        }

        NSString *sid = specifier.identifier ?: [specifier propertyForKey:@"id"];
        if ([sid isEqualToString:@"global_format_editor"]) {
            [specifier setProperty:[SNFormatValueCell class] forKey:@"cellClass"];
        } else if ([sid isEqualToString:@"global_format_tokens"]) {
            [specifier setProperty:[SNFormatTokensCell class] forKey:@"cellClass"];
        }
    }
}

- (BOOL)sn_enabledForSpecifierID:(NSString *)sid {
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
    BOOL res = YES;
    if ([sid isEqualToString:kIncomingTextID]) {
        res = [[defs objectForKey:kReadIncomingKey] ?: @(YES) boolValue];
    } else if ([sid isEqualToString:kMissedTextID]) {
        res = [[defs objectForKey:kReadMissedKey] ?: @(NO) boolValue];
    } else if ([sid isEqualToString:kDurationTextID]) {
        res = [[defs objectForKey:kSpeakDurationKey] ?: @(YES) boolValue];
    }
    return res;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self sn_updateBetaAccessVisibilityAnimated:NO];
    [self sn_rebuildReleaseStatusSpecifier];
    [self reloadSpecifiers];
    [self sn_updateTextFieldsEnabled];
}

#pragma mark - Debug file

- (NSArray<NSString *> *)sn_listAllSpeakLogs {
    NSArray<NSString *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:SNLogsDir() error:nil];
    if (items.count == 0) return @[];
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:items.count];
    for (NSString *fn in items) {
        if (!SNIsSpeakLogFile(fn)) continue;
        [paths addObject:[SNLogsDir() stringByAppendingPathComponent:fn]];
    }
    [paths sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSString *active = SNActiveLogPath();
        if ([a isEqualToString:active] && ![b isEqualToString:active]) return NSOrderedAscending;
        if (![a isEqualToString:active] && [b isEqualToString:active]) return NSOrderedDescending;
        return [a.lastPathComponent compare:b.lastPathComponent options:NSNumericSearch];
    }];
    return paths;
}

- (void)deleteLogWithPicker {
    NSArray<NSString *> *logs = [self sn_listAllSpeakLogs];
    if (logs.count == 0) {
        [self sn_presentSimpleAlertWithTitle:@"No logs found" message:nil];
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Delete a log"
                                                                   message:@"Select a file to remove"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;
    for (NSString *path in logs) {
        NSString *title = path.lastPathComponent;
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *a) {
            [weakSelf sn_confirmAndDelete:path];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete ALL logs"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *a) {
        [weakSelf sn_confirmAndDeleteAll];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)sn_confirmAndDelete:(NSString *)path {
    NSString *name = path.lastPathComponent;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Confirm delete"
                                                                message:name
                                                         preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Delete"
                                           style:UIAlertActionStyleDestructive
                                         handler:^(__unused UIAlertAction *a) {
        NSError *err = nil;
        [[NSFileManager defaultManager] removeItemAtPath:path error:&err];
        if (err) {
            [weakSelf sn_presentSimpleAlertWithTitle:@"Delete failed" message:err.localizedDescription];
        } else {
            [weakSelf sn_presentSimpleAlertWithTitle:@"Deleted" message:name];
        }
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)sn_confirmAndDeleteAll {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Delete ALL logs"
                                                                message:@"This removes every SpeakNotification16 log file"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Delete all"
                                           style:UIAlertActionStyleDestructive
                                         handler:^(__unused UIAlertAction *a) {
        NSArray<NSString *> *logs = [weakSelf sn_listAllSpeakLogs];
        for (NSString *p in logs) {
            [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
        }
        [weakSelf sn_presentSimpleAlertWithTitle:@"Done" message:@"All logs deleted"];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)deleteDebugLogs {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:kSNLogPath isDirectory:&isDir] && !isDir) {
        NSError *err = nil;
        [fm removeItemAtPath:kSNLogPath error:&err];
        if (err) {
            [self sn_presentSimpleAlertWithTitle:@"Delete failed" message:(err.localizedDescription ?: @"Could not delete the log file.")];
        } else {
            [self sn_presentSimpleAlertWithTitle:@"Log deleted" message:@"The SpeakNotification16 log file has been deleted."];
        }
    } else {
        [self sn_presentSimpleAlertWithTitle:@"No log file" message:@"There is no log file to delete."];
    }
}

- (void)exportDebugLogs {
    NSArray<NSString *> *logs = [self sn_listAllSpeakLogs];
    if (logs.count == 0) {
        [self sn_presentSimpleAlertWithTitle:@"No logs found" message:nil];
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Export a log"
                                                                   message:@"Select a file to share"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;
    for (NSString *path in logs) {
        NSString *title = path.lastPathComponent;
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *a) {
            [weakSelf sn_exportSelectedLog:path];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)sn_exportSelectedLog:(NSString *)path {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self sn_presentSimpleAlertWithTitle:@"File not found" message:path.lastPathComponent];
            });
            return;
        }

        NSString *ts = [self sn_timestampForFilename];
        NSString *tmpName = [NSString stringWithFormat:@"%@_%@.txt", path.lastPathComponent.stringByDeletingPathExtension, ts];
        NSString *tmpPath = [@"/tmp" stringByAppendingPathComponent:tmpName];
        [fm removeItemAtPath:tmpPath error:nil];

        NSError *copyErr = nil;
        if (![fm copyItemAtPath:path toPath:tmpPath error:&copyErr]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self sn_presentSimpleAlertWithTitle:@"Export failed"
                                             message:(copyErr.localizedDescription ?: @"Could not copy log file.")];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSURL *fileURL = [NSURL fileURLWithPath:tmpPath];
            UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL]
                                                                             applicationActivities:nil];
            avc.popoverPresentationController.sourceView = self.view;
            avc.popoverPresentationController.sourceRect = self.view.bounds;
            [[self viewControllerForPresenting] presentViewController:avc animated:YES completion:nil];
        });
    });
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    NSString *key = [specifier propertyForKey:@"key"];
    BOOL debugChanged = [key isEqualToString:kSNDebugLoggingKey];
    if ([key isEqualToString:kSNReleaseTokenKey]) {
        [self reloadSpecifierID:kSNReleaseTokenStatusID animated:NO];
    } else {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), kSNPrefsNotify, NULL, NULL, true);
    }
    if (debugChanged) [self sn_updateBetaAccessVisibilityAnimated:YES];
    [self sn_updateTextFieldsEnabled];
}

- (BOOL)sn_boolForKey:(NSString *)key defaultValue:(BOOL)def {
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
    id v = [defs objectForKey:key];
    BOOL out = [v isKindOfClass:NSNumber.class] ? [v boolValue] : def;
    return out;
}

- (PSSpecifier *)sn_specifierForID:(NSString *)ident {
    NSInteger idx = [self indexOfSpecifierWithID:ident];
    if (idx == NSNotFound) return nil;
    return _specifiers[idx];
}

- (void)sn_updateTextFieldsEnabled {
    PSSpecifier *incomingText = [self sn_specifierForID:kIncomingTextID];
    PSSpecifier *missedText = [self sn_specifierForID:kMissedTextID];
    PSSpecifier *durationText = [self sn_specifierForID:kDurationTextID];

    if (incomingText) {
        [incomingText setProperty:@([self sn_enabledForSpecifierID:kIncomingTextID]) forKey:@"enabled"];
        [self reloadSpecifier:incomingText animated:NO];
    }
    if (missedText) {
        [missedText setProperty:@([self sn_enabledForSpecifierID:kMissedTextID]) forKey:@"enabled"];
        [self reloadSpecifier:missedText animated:NO];
    }
    if (durationText) {
        [durationText setProperty:@([self sn_enabledForSpecifierID:kDurationTextID]) forKey:@"enabled"];
        [self reloadSpecifier:durationText animated:NO];
    }
}

- (UIViewController *)viewControllerForPresenting {
    return self;
}

- (NSString *)sn_timestampForFilename {
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
    NSString *s = [fmt stringFromDate:[NSDate date]];
    return s;
}

- (void)sn_presentSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self viewControllerForPresenting] presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Release Alerts

- (void)sn_setManualReleaseCheckInProgress:(BOOL)inProgress {
    PSSpecifier *specifier = [self sn_specifierForID:kSNReleaseCheckNowID];
    if (!specifier) return;
    [specifier setProperty:(inProgress ? @"Checking…" : @"Check Now") forKey:@"label"];
    [specifier setProperty:@(!inProgress) forKey:@"enabled"];
    [self reloadSpecifierID:kSNReleaseCheckNowID animated:NO];
}

- (BOOL)sn_releaseUpdateIsAvailable {
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
    NSString *availableBuildID = [defs stringForKey:kSNReleaseAvailableBuildIDKey];
    NSURL *url = [NSURL URLWithString:[defs stringForKey:kSNReleaseLastURLKey] ?: @""];
    return availableBuildID.length > 0 && SNReleaseResultURLIsAllowed(url);
}

- (BOOL)sn_releaseInstallBaselinePending {
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
    NSString *currentInstallID = [defs stringForKey:kSNReleaseCurrentInstallIDKey];
    NSString *processedInstallID = [defs stringForKey:kSNReleaseLastProcessedInstallIDKey];
    return currentInstallID.length > 0 && ![currentInstallID isEqualToString:processedInstallID];
}

- (void)sn_rebuildReleaseStatusSpecifier {
    NSInteger oldIndex = [self indexOfSpecifierWithID:@"SNReleaseLatestStatus"];
    if (oldIndex != NSNotFound) [_specifiers removeObjectAtIndex:oldIndex];

    BOOL checking = [self sn_releaseInstallBaselinePending];
    BOOL available = !checking && [self sn_releaseUpdateIsAvailable];
    NSString *label = checking ? @"Checking…" :
        (available ? @"New release available" : @"You already have the latest");
    PSSpecifier *status = [PSSpecifier preferenceSpecifierNamed:
        label
        target:self set:NULL get:NULL detail:Nil
        cell:(available ? PSLinkCell : PSTitleValueCell) edit:Nil];
    [status setProperty:@"SNReleaseLatestStatus" forKey:@"id"];
    [status setProperty:@(available) forKey:@"enabled"];
    [status setProperty:@(available ? UITableViewCellAccessoryDisclosureIndicator
                                     : UITableViewCellAccessoryNone)
                  forKey:@"accessoryType"];
    if (available) status->action = @selector(openLatestRelease:);

    NSInteger insertAt = [self indexOfSpecifierWithID:@"SNReleaseLastChecked"];
    insertAt = (insertAt == NSNotFound) ? (NSInteger)_specifiers.count : insertAt + 1;
    [_specifiers insertObject:status atIndex:insertAt];
}

- (void)sn_openVerifiedReleaseURL:(NSURL *)url {
    if (!SNReleaseResultURLIsAllowed(url)) {
        [self sn_presentSimpleAlertWithTitle:@"Could Not Open Link"
                                    message:@"The release link was not valid."];
        return;
    }
    [UIApplication.sharedApplication openURL:url options:@{}
        completionHandler:^(BOOL success) {
            if (!success) {
                [self sn_presentSimpleAlertWithTitle:@"Could Not Open Link"
                                            message:@"GitHub could not be opened."];
            }
        }];
}

- (void)sn_presentManualReleaseResultWithTitle:(NSString *)title
                                       message:(NSString *)message
                                           url:(NSURL *)url {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    if (SNReleaseResultURLIsAllowed(url)) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Open GitHub"
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                [self sn_openVerifiedReleaseURL:url];
            }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
            style:UIAlertActionStyleCancel handler:nil]];
    } else {
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
            style:UIAlertActionStyleDefault handler:nil]];
    }
    [[self viewControllerForPresenting] presentViewController:alert
                                                     animated:YES
                                                   completion:nil];
}

- (void)sn_handleManualReleaseCheckResult {
    if (!self.manualReleaseCheckPending) return;
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
    [defs synchronize];
    NSString *requestID = [defs stringForKey:kSNReleaseManualResultRequestIDKey];
    if (requestID.length == 0 ||
        ![requestID isEqualToString:self.manualReleaseCheckRequestID]) {
        return;
    }

    NSString *status = [defs stringForKey:kSNReleaseManualResultStatusKey] ?: @"invalidResponse";
    NSString *tag = [defs stringForKey:kSNReleaseManualResultTagKey];
    NSURL *url = [NSURL URLWithString:[defs stringForKey:kSNReleaseManualResultURLKey] ?: @""];
    self.manualReleaseCheckPending = NO;
    self.manualReleaseCheckRequestID = nil;
    self.manualReleaseCheckGeneration++;
    [self sn_setManualReleaseCheckInProgress:NO];
    [self reloadSpecifierID:@"SNReleaseLastChecked" animated:NO];
    [self sn_rebuildReleaseStatusSpecifier];
    [self reloadSpecifiers];

    if ([status isEqualToString:@"updateAvailable"]) {
        NSString *message = tag.length > 0
            ? [NSString stringWithFormat:@"%@ is available.", tag]
            : @"A new release is available.";
        [self sn_presentManualReleaseResultWithTitle:@"New Release Available"
                                             message:message url:url];
    } else if ([status isEqualToString:@"alreadyQueued"]) {
        [self sn_presentManualReleaseResultWithTitle:@"Release Already Found"
            message:@"The latest release has already been detected and its notification is pending."
                url:url];
    } else if ([status isEqualToString:@"upToDate"]) {
        [self sn_presentSimpleAlertWithTitle:@"No New Release"
                                    message:@"You already have the latest available release."];
    } else if ([status isEqualToString:@"missingToken"]) {
        [self sn_presentSimpleAlertWithTitle:@"Beta Token Missing"
                                    message:@"Set a beta token before checking for beta releases."];
    } else if ([status isEqualToString:@"authFailed"]) {
        [self sn_presentSimpleAlertWithTitle:@"Beta Token Invalid"
                                    message:@"The saved beta token was rejected."];
    } else if ([status isEqualToString:@"networkError"]) {
        [self sn_presentSimpleAlertWithTitle:@"Release Check Failed"
                                    message:@"Could not contact GitHub. Check your internet connection and try again."];
    } else if ([status isEqualToString:@"noRelease"]) {
        [self sn_presentSimpleAlertWithTitle:@"No Release Available"
                                    message:@"GitHub did not return an available release."];
    } else if ([status isEqualToString:@"releaseDisabled"]) {
        [self sn_presentSimpleAlertWithTitle:@"Release Alerts Disabled"
                                    message:@"Enable Release Alerts before checking for updates."];
    } else if ([status isEqualToString:@"checkInProgress"]) {
        [self sn_presentSimpleAlertWithTitle:@"Release Check In Progress"
                                    message:@"A release check is already running."];
    } else {
        [self sn_presentSimpleAlertWithTitle:@"Release Check Failed"
                                    message:@"GitHub returned an unexpected response. Try again later."];
    }
}

- (void)sn_handleTokenValidationResult {
    if (!self.tokenValidationPending) return;
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
    [defs synchronize];
    NSString *resultRequestID = [defs stringForKey:kSNReleaseTokenValidationResultRequestIDKey];
    if (resultRequestID.length == 0 ||
        ![resultRequestID isEqualToString:self.tokenValidationRequestID]) {
        return;
    }

    NSString *status = [defs stringForKey:kSNReleaseTokenValidationResultStatusKey] ?: @"unverified";
    self.tokenValidationPending = NO;
    self.tokenValidationRequestID = nil;
    self.tokenValidationGeneration++;
    [self reloadSpecifierID:kSNReleaseTokenStatusID animated:NO];

    if ([status isEqualToString:@"valid"]) {
        [self sn_presentSimpleAlertWithTitle:@"Token Valid"
                                    message:@"This token can access beta releases."];
    } else if ([status isEqualToString:@"invalid"]) {
        [self sn_presentSimpleAlertWithTitle:@"Token Not Valid for Beta Releases"
                                    message:@"This token cannot access Beta Releases."];
    } else {
        [self sn_presentSimpleAlertWithTitle:@"Token Could Not Be Verified"
                                    message:@"The token was saved, but the verification response was unexpected. Try again later."];
    }
}

- (NSString *)releaseLastChecked:(__unused PSSpecifier *)specifier {
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
    NSTimeInterval timestamp = [defs doubleForKey:kSNReleaseLastCheckKey];
    if (timestamp <= 0.0) return @"Never";
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterShortStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    NSString *value = [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:timestamp]];
    return value.length > 0 ? value : @"Never";
}

- (NSString *)releaseLastSeenTag:(__unused PSSpecifier *)specifier {
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
    NSString *tag = [defs stringForKey:kSNReleaseLastSeenTagKey];
    return tag.length > 0 ? tag : @"Not checked";
}

- (NSString *)releaseLatestStatus:(PSSpecifier *)specifier {
    if ([self sn_releaseInstallBaselinePending]) return @"Checking…";
    return [self sn_releaseUpdateIsAvailable]
        ? @"New release available" : @"You already have the latest";
}

- (void)openLatestRelease:(__unused PSSpecifier *)specifier {
    if ([self sn_releaseInstallBaselinePending] || ![self sn_releaseUpdateIsAvailable]) return;
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
    NSURL *url = [NSURL URLWithString:[defs stringForKey:kSNReleaseLastURLKey] ?: @""];
    if (SNReleaseResultURLIsAllowed(url)) [self sn_openVerifiedReleaseURL:url];
}

- (NSString *)releaseTokenStatus:(__unused PSSpecifier *)specifier {
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
    NSString *token = [defs stringForKey:kSNReleaseTokenKey];
    NSString *trimmed = [token stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return @"Missing";
    NSString *status = [defs stringForKey:kSNReleaseTokenValidationStatusKey];
    if (self.tokenValidationPending || [status isEqualToString:@"checking"]) return @"Checking…";
    if ([status isEqualToString:@"valid"]) return @"Valid";
    if ([status isEqualToString:@"invalid"]) return @"Invalid";
    return @"Unverified";
}

- (UITextField *)sn_releaseTokenTextField {
    PSSpecifier *specifier = [self sn_specifierForID:kSNReleaseTokenFieldID];
    if (!specifier) return nil;
    id cell = nil;
    SEL cachedSelector = NSSelectorFromString(@"cachedCellForSpecifier:");
    if ([self respondsToSelector:cachedSelector]) {
        cell = ((id (*)(id, SEL, id))objc_msgSend)(self, cachedSelector, specifier);
    }
    if (!cell) {
        SEL cellSelector = NSSelectorFromString(@"cellForSpecifier:");
        if ([self respondsToSelector:cellSelector]) {
            cell = ((id (*)(id, SEL, id))objc_msgSend)(self, cellSelector, specifier);
        }
    }
    SEL textFieldSelector = NSSelectorFromString(@"textField");
    if ([cell respondsToSelector:textFieldSelector]) {
        return ((id (*)(id, SEL))objc_msgSend)(cell, textFieldSelector);
    }
    UITextField *field = [cell isKindOfClass:UIView.class]
        ? SNTextFieldWithPlaceholder((UIView *)cell, @"Fine-grained token") : nil;
    return field ?: SNTextFieldWithPlaceholder(self.view, @"Fine-grained token");
}

- (void)sn_reloadReleaseTokenRowsWithCompletion:(dispatch_block_t)completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadSpecifierID:kSNReleaseTokenFieldID animated:NO];
        [self reloadSpecifierID:kSNReleaseTokenStatusID animated:NO];
        if (completion) completion();
    });
}

- (void)createReleaseGitHubToken {
    NSURL *url = [NSURL URLWithString:kSNReleaseTokenURLString];
    if (![url.scheme.lowercaseString isEqualToString:@"https"] ||
        ![url.host.lowercaseString isEqualToString:@"github.com"] ||
        ![url.path hasPrefix:@"/settings/personal-access-tokens/"]) {
        [self sn_presentSimpleAlertWithTitle:@"Could Not Open Link"
                                    message:@"Open GitHub token settings manually."];
        return;
    }
    [UIApplication.sharedApplication openURL:url options:@{}
        completionHandler:^(BOOL success) {
            if (!success) {
                [self sn_presentSimpleAlertWithTitle:@"Could Not Open Link"
                    message:@"Open GitHub token settings manually and create a fine-grained token with Contents set to Read-only."];
            }
        }];
}

- (void)setReleaseGitHubToken {
    UITextField *field = [self sn_releaseTokenTextField];
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
    NSString *value = field.text ?: [defs stringForKey:kSNReleaseTokenKey] ?: @"";
    NSString *token = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (token.length == 0) {
        [self sn_presentSimpleAlertWithTitle:@"Token Missing"
                                    message:@"Enter a token before saving."];
        return;
    }

    NSString *requestID = NSUUID.UUID.UUIDString;
    field.text = token;
    [defs setObject:token forKey:kSNReleaseTokenKey];
    [defs setObject:requestID forKey:kSNReleaseTokenValidationRequestIDKey];
    [defs setObject:@"checking" forKey:kSNReleaseTokenValidationStatusKey];
    [defs removeObjectForKey:kSNReleaseTokenValidationResultStatusKey];
    [defs removeObjectForKey:kSNReleaseTokenValidationResultRequestIDKey];
    [defs synchronize];

    self.tokenValidationRequestID = requestID;
    self.tokenValidationPending = YES;
    NSUInteger generation = ++self.tokenValidationGeneration;
    [self sn_reloadReleaseTokenRowsWithCompletion:nil];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         kSNReleaseTokenValidationNowNotify, NULL, NULL, true);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.tokenValidationPending ||
            self.tokenValidationGeneration != generation ||
            ![self.tokenValidationRequestID isEqualToString:requestID]) {
            return;
        }
        self.tokenValidationPending = NO;
        self.tokenValidationRequestID = nil;
        [defs removeObjectForKey:kSNReleaseTokenValidationRequestIDKey];
        [defs setObject:@"unverified" forKey:kSNReleaseTokenValidationStatusKey];
        [defs synchronize];
        [self sn_reloadReleaseTokenRowsWithCompletion:nil];
        [self sn_presentSimpleAlertWithTitle:@"Token Could Not Be Verified"
                                    message:@"The token was saved, but the verification service could not be reached. Try again later."];
    });
}

- (void)clearReleaseGitHubToken {
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
    [defs removeObjectForKey:kSNReleaseTokenKey];
    [defs removeObjectForKey:kSNReleaseTokenValidationRequestIDKey];
    [defs removeObjectForKey:kSNReleaseTokenValidationStatusKey];
    [defs removeObjectForKey:kSNReleaseTokenValidationResultStatusKey];
    [defs removeObjectForKey:kSNReleaseTokenValidationResultRequestIDKey];
    [defs synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         kSNReleaseTokenClearedNotify, NULL, NULL, true);
    [self sn_reloadReleaseTokenRowsWithCompletion:^{
        [self sn_presentSimpleAlertWithTitle:@"Beta Token Cleared" message:nil];
    }];
}

- (void)checkReleaseNow {
    if (self.manualReleaseCheckPending) return;
    NSString *requestID = NSUUID.UUID.UUIDString;
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
    [defs setObject:requestID forKey:kSNReleaseManualRequestIDKey];
    [defs removeObjectForKey:kSNReleaseManualResultStatusKey];
    [defs removeObjectForKey:kSNReleaseManualResultTagKey];
    [defs removeObjectForKey:kSNReleaseManualResultURLKey];
    [defs removeObjectForKey:kSNReleaseManualResultMessageKey];
    [defs removeObjectForKey:kSNReleaseManualResultRequestIDKey];
    [defs removeObjectForKey:kSNReleaseManualResultTimestampKey];
    [defs synchronize];

    self.manualReleaseCheckRequestID = requestID;
    self.manualReleaseCheckPending = YES;
    NSUInteger generation = ++self.manualReleaseCheckGeneration;
    [self sn_setManualReleaseCheckInProgress:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         kSNReleaseCheckNowNotify, NULL, NULL, true);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.manualReleaseCheckPending ||
            self.manualReleaseCheckGeneration != generation ||
            ![self.manualReleaseCheckRequestID isEqualToString:requestID]) {
            return;
        }
        self.manualReleaseCheckPending = NO;
        self.manualReleaseCheckRequestID = nil;
        [self sn_setManualReleaseCheckInProgress:NO];
        [self sn_presentSimpleAlertWithTitle:@"Release Check Timed Out"
                                    message:@"GitHub did not respond in time. Try again later."];
    });
}

#pragma mark - Inline list building

- (void)rebuildInlineLists {
    NSMutableArray *base = [NSMutableArray array];
    for (PSSpecifier *s in _specifiers) {
        if (![s propertyForKey:@"_inlineType"]) {
            [base addObject:s];
        }
    }
    _specifiers = base;

    [self.btItems sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    [self.wifiItems sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    if (self.btItems.count > 0) {
        NSInteger btAddBtn = [self indexOfSpecifierWithID:@"bt_add_btn"];
        NSInteger btAnchor = [self indexOfSpecifierWithID:@"bt_anchor"];
        NSInteger insertAt = (btAddBtn != NSNotFound) ? btAddBtn + 1 : (btAnchor != NSNotFound ? btAnchor + 1 : NSNotFound);
        if (insertAt != NSNotFound) {
            for (NSUInteger i = 0; i < self.btItems.count; i++) {
                NSString *name = [self.btItems objectAtIndex:i];
                PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:name target:self set:NULL get:NULL detail:Nil cell:PSLinkCell edit:Nil];
                [row setProperty:@"bt" forKey:@"_inlineType"];
                [row setProperty:@(i) forKey:@"_inlineIndex"];
                row->action = @selector(inlineRowTapped:);
                [_specifiers insertObject:row atIndex:(insertAt + (NSInteger)i)];
            }
        }
    }

    if (self.wifiItems.count > 0) {
        NSInteger wifiAddBtn = [self indexOfSpecifierWithID:@"wifi_add_btn"];
        NSInteger wifiAnchor = [self indexOfSpecifierWithID:@"wifi_anchor"];
        NSInteger insertAt = (wifiAddBtn != NSNotFound) ? wifiAddBtn + 1 : (wifiAnchor != NSNotFound ? wifiAnchor + 1 : NSNotFound);
        if (insertAt != NSNotFound) {
            for (NSUInteger i = 0; i < self.wifiItems.count; i++) {
                NSString *ssid = [self.wifiItems objectAtIndex:i];
                PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:ssid target:self set:NULL get:NULL detail:Nil cell:PSLinkCell edit:Nil];
                [row setProperty:@"wifi" forKey:@"_inlineType"];
                [row setProperty:@(i) forKey:@"_inlineIndex"];
                row->action = @selector(inlineRowTapped:);
                [_specifiers insertObject:row atIndex:(insertAt + (NSInteger)i)];
            }
        }
    }
}

- (NSInteger)indexOfSpecifierWithID:(NSString *)ident {
    for (NSInteger i = 0; i < (NSInteger)_specifiers.count; i++) {
        PSSpecifier *s = _specifiers[i];
        NSString *sid = [s propertyForKey:@"id"];
        if ([sid isKindOfClass:NSString.class] && [sid isEqualToString:ident]) {
            return i;
        }
    }
    return NSNotFound;
}

#pragma mark - Buttons

- (void)wifiAddCurrent:(PSSpecifier *)spec {
    NSString *ssid = [self fetchCurrentSSID] ?: @"";
    [self promptFor:@"Add SSID" message:@"Enter the Wi-Fi network name (SSID)." placeholder:@"SSID" prefill:ssid onSubmit:^(NSString *text) {
        if (text.length == 0) return;
        if (![self.wifiItems containsObject:text]) {
            [self.wifiItems addObject:text];
            [self saveListsAndReload];
        }
    }];
}

- (void)btAddCurrent:(PSSpecifier *)spec {
    NSString *dev = [self fetchCurrentBTName] ?: @"";
    [self promptFor:@"Add Bluetooth device" message:@"Enter the device name." placeholder:@"Device name" prefill:dev onSubmit:^(NSString *text) {
        if (text.length == 0) return;
        if (![self.btItems containsObject:text]) {
            [self.btItems addObject:text];
            [self saveListsAndReload];
        }
    }];
}

- (void)wifiAddManual:(PSSpecifier *)spec { [self wifiAddCurrent:spec]; }
- (void)btAddManual:(PSSpecifier *)spec { [self btAddCurrent:spec]; }

#pragma mark - Fetch helpers

- (NSString *)fetchCurrentSSID {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_LAZY);
    if (!handle) return nil;

    typedef const struct __WiFiManagerClient * WiFiManagerClientRef;
    typedef const struct __WiFiDeviceClient * WiFiDeviceClientRef;
    typedef const struct __WiFiNetwork * WiFiNetworkRef;

    typedef WiFiManagerClientRef (*t_WiFiManagerClientCreate)(CFAllocatorRef, int);
    typedef CFArrayRef (*t_WiFiManagerClientCopyDevices)(WiFiManagerClientRef);
    typedef WiFiNetworkRef (*t_WiFiDeviceClientCopyCurrentNetwork)(WiFiDeviceClientRef);
    typedef CFStringRef (*t_WiFiNetworkGetSSID)(WiFiNetworkRef);

    t_WiFiManagerClientCreate pCreate = (t_WiFiManagerClientCreate)dlsym(handle, "WiFiManagerClientCreate");
    t_WiFiManagerClientCopyDevices pCopyDevices = (t_WiFiManagerClientCopyDevices)dlsym(handle, "WiFiManagerClientCopyDevices");
    t_WiFiDeviceClientCopyCurrentNetwork pCopyCurrent = (t_WiFiDeviceClientCopyCurrentNetwork)dlsym(handle, "WiFiDeviceClientCopyCurrentNetwork");
    t_WiFiNetworkGetSSID pGetSSID = (t_WiFiNetworkGetSSID)dlsym(handle, "WiFiNetworkGetSSID");
    if (!pCreate || !pCopyDevices || !pCopyCurrent || !pGetSSID) { dlclose(handle); return nil; }

    NSString *result = nil;
    WiFiManagerClientRef mgr = pCreate(kCFAllocatorDefault, 0);
    if (mgr) {
        CFArrayRef devices = pCopyDevices(mgr);
        if (devices && CFArrayGetCount(devices) > 0) {
            WiFiDeviceClientRef dev = (WiFiDeviceClientRef)CFArrayGetValueAtIndex(devices, 0);
            if (dev) {
                WiFiNetworkRef net = pCopyCurrent(dev);
                if (net) {
                    CFStringRef ssid = pGetSSID(net);
                    if (ssid) {
                        NSString *owned = [(__bridge NSString *)ssid copy];
                        result = owned;
                    }
                    CFRelease(net);
                }
            }
        }
        if (devices) CFRelease(devices);
    }
    dlclose(handle);
    return result;
}

- (NSString *)fetchCurrentBTName {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    AVAudioSessionRouteDescription *route = [session currentRoute];
    if (!route || route.outputs.count == 0) return nil;
    for (AVAudioSessionPortDescription *out in route.outputs) {
        NSString *t = out.portType ?: @"";
        if ([t isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
            [t isEqualToString:AVAudioSessionPortBluetoothHFP] ||
            [t isEqualToString:AVAudioSessionPortBluetoothLE]) {
            if (out.portName.length > 0) return out.portName;
        }
    }
    return nil;
}

#pragma mark - Save + reload

- (void)saveListsAndReload {
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
    [defs setObject:self.wifiItems forKey:kSSIDsKey];
    [defs setObject:self.btItems forKey:kBTKey];
    [defs synchronize];

    [self rebuildInlineLists];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadSpecifiers];
    });

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), kSNPrefsNotify, NULL, NULL, true);
}

#pragma mark - Tap-to-delete

- (void)inlineRowTapped:(PSSpecifier *)specifier {
    NSString *type = [specifier propertyForKey:@"_inlineType"];
    NSNumber *nidx = [specifier propertyForKey:@"_inlineIndex"];
    if (![type isKindOfClass:NSString.class] || ![nidx isKindOfClass:NSNumber.class]) return;

    NSUInteger idx = [nidx unsignedIntegerValue];
    NSString *item = nil;

    if ([type isEqualToString:@"wifi"]) {
        if (idx >= self.wifiItems.count) return;
        item = [self.wifiItems objectAtIndex:idx];
    } else if ([type isEqualToString:@"bt"]) {
        if (idx >= self.btItems.count) return;
        item = [self.btItems objectAtIndex:idx];
    } else {
        return;
    }

    NSString *title = [type isEqualToString:@"wifi"] ? @"Remove SSID?" : @"Remove device?";
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:item preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        if ([type isEqualToString:@"wifi"]) {
            if (idx < weakSelf.wifiItems.count) [weakSelf.wifiItems removeObjectAtIndex:idx];
            [weakSelf saveListsAndReload];
        } else if ([type isEqualToString:@"bt"]) {
            if (idx < weakSelf.btItems.count) [weakSelf.btItems removeObjectAtIndex:idx];
            [weakSelf saveListsAndReload];
        }
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Reset all settings

static NSString * const kAppsCacheKeyLiteral = @"cachedVisibleApps_v7";

- (void)resetAllSettings {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Confirm Reset"
                                                                   message:@"Reset all settings to their default values?"
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {

        NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
        [defs setPersistentDomain:@{} forName:kSNPrefsSuite];

        NSDictionary *factory = @{
            // Activation
            @"enabled": @YES,

            // Speak Conditions
            @"respectMute": @NO,
            @"blockSpeakOnMute": @NO,
            @"speakWhenUnlocked": @NO,
            @"disableNotificationSound": @NO,
            @"pause": @NO,
            @"cancelButton": @"power",

            // Anti-spam
            @"muteSpam": @NO,
            @"spamCooldownSeconds": @12,

            // Quiet hours
            @"enableQuietHours": @NO,
            @"quietStart": @"",
            @"quietEnd": @"",

            // Lock screen privacy
            @"lockscreenPrivacy": @NO,

            // Queue
            @"queueNotifications": @NO,

            // Trusted
            @"onlyTrustedConnection": @NO,

            // Voice & Volume
            @"voiceLang": @"auto",
            @"speechVolume": @30,
            @"useSystemVolume": @NO,
            @"SNResetVolumeAfterSpeakEnabled": @NO,
            @"bluetoothMonoAudio": @NO,

            // Calls
            @"readIncomingCalls": @NO,
            @"incomingCallText": @"Incoming call from",
            @"readMissedCalls": @NO,
            @"missedCallText": @"Missed call from",
            @"speakCallDuration": @NO,
            @"callDurationText": @"Talk time",

            // Speech rate
            @"speechRate": @1.0,

            // Filter
            @"filterWords": @"",

            // Message format
            @"globalFormat": @"{APP}: {TITLE}: {BODY}",
            @"messageFormat": @"{APP}: {TITLE}: {BODY}",

            // Debug
            @"debugLoggingEnabled": @NO,

            // Release alerts
            @"releaseAlertsEnabled": @YES,
            @"releaseGitHubToken": @"",

            // Per-app
            @"appFilterMode": @"whitelist",
            @"allowedSeededOnce": @YES,
            @"allowedAppIDs": @[],
            @"blockAppIDs": @[],
            @"perAppFormats": @{},
            @"perAppDisableNotificationSound": @{},
            kSNPerAppSpokenCountsKey: @{},
            kSNLastSpokenAppIDKey: @"",

            // Inline lists
            kSSIDsKey: @[],
            kBTKey: @[]
        };

        @try {
            [defs setPersistentDomain:factory forName:kSNPrefsSuite];
        } @catch (__unused NSException *ex) {
            [factory enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
                [defs setObject:v forKey:k];
            }];
        }

        [defs removeObjectForKey:kAppsCacheKeyLiteral];
        [defs synchronize];

        weakSelf.wifiItems = [NSMutableArray array];
        weakSelf.btItems   = [NSMutableArray array];

        [weakSelf rebuildInlineLists];
        [weakSelf reloadSpecifiers];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), kSNPrefsNotify, NULL, NULL, true);

        UIAlertController *done = [UIAlertController alertControllerWithTitle:@"Done"
                                                                      message:@"Settings were reset."
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [weakSelf presentViewController:done animated:YES completion:nil];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Small alert helper

- (void)promptFor:(NSString *)title message:(NSString *)message placeholder:(NSString *)ph prefill:(NSString *)prefill onSubmit:(void(^)(NSString *text))block {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = ph;
        tf.text = prefill;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        if (block) block(ac.textFields.firstObject.text ?: @"");
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
