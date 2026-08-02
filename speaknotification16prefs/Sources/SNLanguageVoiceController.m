#import "SNLanguageVoiceController.h"
#import <AVFoundation/AVFoundation.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>

#import "SNPrefsUtil.h"
#import "SNPreferences.h"
#import "SNSharedKeys.h"

@class SNLanguageVoiceController;

@interface SNVoiceOptionTarget : NSObject
@property (nonatomic, weak) SNLanguageVoiceController *controller;
@property (nonatomic, copy) NSString *voiceIdentifier;
- (void)choose;
@end

@interface SNVoiceOptionCell : PSTableCell
@end

@implementation SNVoiceOptionCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier
{
    return [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier specifier:specifier];
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier
{
    [super refreshCellContentsWithSpecifier:specifier];
    self.textLabel.text = specifier.name;
    self.detailTextLabel.text = [specifier propertyForKey:@"voiceDetail"] ?: @"";
    self.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    self.accessoryType = [[specifier propertyForKey:@"voiceSelected"] boolValue] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    self.selectionStyle = UITableViewCellSelectionStyleDefault;
}

@end

@interface SNLanguageVoiceController ()
@property (nonatomic, copy) NSString *languageCode;
@property (nonatomic, strong) NSArray<SNVoiceOptionTarget *> *optionTargets;
@property (nonatomic, assign) BOOL preferencesObserverRegistered;
- (NSString *)resolvedLanguageCode;
- (void)selectVoiceIdentifier:(NSString *)identifier;
- (void)reloadVoiceSpecifiers;
@end

@implementation SNVoiceOptionTarget

- (void)choose
{
    [self.controller selectVoiceIdentifier:self.voiceIdentifier ?: @""];
}

@end

static NSString *SNVoiceNormalizedLanguage(NSString *language)
{
    if (![language isKindOfClass:NSString.class] || language.length == 0) return @"";
    return SNNormalizeVoiceLanguage(language);
}

static NSString *SNVoiceLanguagePrefix(NSString *language)
{
    NSString *normalized = SNVoiceNormalizedLanguage(language).lowercaseString;
    NSRange dash = [normalized rangeOfString:@"-"];
    return dash.location == NSNotFound ? normalized : [normalized substringToIndex:dash.location];
}

static NSString *SNVoiceQualityLabel(NSInteger quality)
{
    if (quality == AVSpeechSynthesisVoiceQualityPremium) return @"Premium";
    if (quality == AVSpeechSynthesisVoiceQualityEnhanced) return @"Enhanced";
    return @"Compact";
}

static NSString *SNVoiceIdentifierSuffix(NSString *identifier)
{
    NSArray<NSString *> *parts = [identifier componentsSeparatedByString:@"."];
    return parts.lastObject.length ? parts.lastObject : identifier;
}

static BOOL SNVoiceCanBeAssigned(AVSpeechSynthesisVoice *voice)
{
    if (!voice || voice.identifier.length == 0) return NO;
    @try {
        AVSpeechUtterance *probe = [AVSpeechUtterance speechUtteranceWithString:@" "];
        probe.voice = voice;
        return [probe.voice.identifier isEqualToString:voice.identifier];
    } @catch (__unused id error) {
        return NO;
    }
}

static NSArray<AVSpeechSynthesisVoice *> *SNValidVoicesForLanguage(NSString *language, BOOL *usedLanguageFallback)
{
    NSString *target = SNVoiceNormalizedLanguage(language);
    NSString *prefix = SNVoiceLanguagePrefix(target);
    if (usedLanguageFallback) *usedLanguageFallback = NO;
    if (target.length == 0 || prefix.length == 0) return @[];

    NSMutableArray<AVSpeechSynthesisVoice *> *exact = [NSMutableArray array];
    NSMutableArray<AVSpeechSynthesisVoice *> *sameLanguage = [NSMutableArray array];
    NSMutableSet<NSString *> *seenIdentifiers = [NSMutableSet set];
    for (AVSpeechSynthesisVoice *voice in [AVSpeechSynthesisVoice speechVoices]) {
        NSString *identifier = voice.identifier;
        if (identifier.length == 0 || [seenIdentifiers containsObject:identifier]) continue;
        AVSpeechSynthesisVoice *resolved = [AVSpeechSynthesisVoice voiceWithIdentifier:identifier];
        if (!resolved || !SNVoiceCanBeAssigned(resolved)) continue;
        NSString *declaredLanguage = SNVoiceNormalizedLanguage(voice.language);
        NSString *resolvedLanguage = SNVoiceNormalizedLanguage(resolved.language);
        if (declaredLanguage.length == 0 || ![declaredLanguage isEqualToString:resolvedLanguage]) continue;
        if (![SNVoiceLanguagePrefix(resolvedLanguage) isEqualToString:prefix]) continue;
        [seenIdentifiers addObject:identifier];
        if ([resolvedLanguage isEqualToString:target]) {
            [exact addObject:resolved];
        } else {
            [sameLanguage addObject:resolved];
        }
    }

    NSArray<AVSpeechSynthesisVoice *> *result = exact.count ? exact : sameLanguage;
    if (!exact.count && sameLanguage.count && usedLanguageFallback) *usedLanguageFallback = YES;
    return [result sortedArrayUsingComparator:^NSComparisonResult(AVSpeechSynthesisVoice *left, AVSpeechSynthesisVoice *right) {
        NSComparisonResult name = [left.name localizedCaseInsensitiveCompare:right.name];
        if (name != NSOrderedSame) return name;
        if (left.quality > right.quality) return NSOrderedAscending;
        if (left.quality < right.quality) return NSOrderedDescending;
        return [left.identifier localizedCaseInsensitiveCompare:right.identifier];
    }];
}

static void SNVoicePreferencesChanged(CFNotificationCenterRef center,
                                      void *observer,
                                      CFStringRef name,
                                      const void *object,
                                      CFDictionaryRef userInfo)
{
    SNLanguageVoiceController *controller = (__bridge SNLanguageVoiceController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!controller || !controller.isViewLoaded) return;
        [controller reloadVoiceSpecifiers];
    });
}

@implementation SNLanguageVoiceController

- (void)viewDidLoad
{
    [super viewDidLoad];
    NSString *language = [self resolvedLanguageCode];
    self.title = [[NSLocale currentLocale] displayNameForKey:NSLocaleIdentifier value:language] ?: language;
    if (!self.preferencesObserverRegistered) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)(self),
                                        SNVoicePreferencesChanged,
                                        kSNVoiceStateChangedNotify,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        self.preferencesObserverRegistered = YES;
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadVoiceSpecifiers];
}

- (void)dealloc
{
    if (self.preferencesObserverRegistered) {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                           (__bridge const void *)(self),
                                           kSNVoiceStateChangedNotify,
                                           NULL);
    }
}

- (NSString *)selectedVoiceIdentifier
{
    NSDictionary *byLanguage = [[SNPrefsUtil suite] dictionaryForKey:kSNSelectedVoiceIdentifierByLanguageKey];
    id value = [byLanguage objectForKey:[self resolvedLanguageCode]];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

- (NSString *)resolvedLanguageCode
{
    if (self.languageCode.length == 0) {
        self.languageCode = SNVoiceNormalizedLanguage([self.specifier propertyForKey:@"languageCode"]);
    }
    return self.languageCode ?: @"";
}

- (PSSpecifier *)voiceSpecifierNamed:(NSString *)name
                              detail:(NSString *)detail
                          identifier:(NSString *)identifier
                            selected:(BOOL)selected
                             targets:(NSMutableArray<SNVoiceOptionTarget *> *)targets
{
    SNVoiceOptionTarget *target = [SNVoiceOptionTarget new];
    target.controller = self;
    target.voiceIdentifier = identifier ?: @"";
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
                                                             target:target
                                                                set:NULL
                                                                get:NULL
                                                             detail:nil
                                                               cell:PSButtonCell
                                                               edit:nil];
    specifier.buttonAction = @selector(choose);
    [specifier setProperty:[SNVoiceOptionCell class] forKey:@"cellClass"];
    [specifier setProperty:(detail ?: @"") forKey:@"voiceDetail"];
    [specifier setProperty:@(selected) forKey:@"voiceSelected"];
    [targets addObject:target];
    return specifier;
}

- (NSArray<PSSpecifier *> *)buildVoiceSpecifiers
{
    NSString *language = [self resolvedLanguageCode];
    NSString *selectedIdentifier = [self selectedVoiceIdentifier];
    BOOL usedLanguageFallback = NO;
    NSArray<AVSpeechSynthesisVoice *> *voices = SNValidVoicesForLanguage(language, &usedLanguageFallback);
    NSMutableSet<NSString *> *availableIdentifiers = [NSMutableSet set];
    for (AVSpeechSynthesisVoice *voice in voices) [availableIdentifiers addObject:voice.identifier];
    BOOL selectedUnavailable = selectedIdentifier.length && ![availableIdentifiers containsObject:selectedIdentifier];

    NSMutableArray<SNVoiceOptionTarget *> *targets = [NSMutableArray array];
    NSMutableArray<PSSpecifier *> *specifiers = [NSMutableArray array];
    PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"Voice"
                                                         target:nil
                                                            set:NULL
                                                            get:NULL
                                                         detail:nil
                                                           cell:PSGroupCell
                                                           edit:nil];
    NSString *footer = @"System Default uses the voice iOS resolves for this language.";
    if (usedLanguageFallback) {
        footer = [footer stringByAppendingString:@" No exact regional voice is installed, so compatible language voices are shown."];
    }
    if (selectedUnavailable) {
        footer = [footer stringByAppendingString:@" The saved voice is unavailable; speech will fall back to System Default."];
    }
    [group setProperty:footer forKey:@"footerText"];
    [specifiers addObject:group];

    [specifiers addObject:[self voiceSpecifierNamed:@"System Default"
                                              detail:language
                                          identifier:@""
                                            selected:(selectedIdentifier.length == 0)
                                             targets:targets]];

    if (selectedUnavailable) {
        PSSpecifier *missing = [PSSpecifier preferenceSpecifierNamed:@"Selected voice unavailable"
                                                              target:nil
                                                                 set:NULL
                                                                 get:NULL
                                                              detail:nil
                                                                cell:PSTitleValueCell
                                                                edit:nil];
        [missing setProperty:SNVoiceIdentifierSuffix(selectedIdentifier) forKey:@"detailText"];
        [specifiers addObject:missing];
    }

    PSSpecifier *availableGroup = [PSSpecifier preferenceSpecifierNamed:@"Available Voices"
                                                                  target:nil
                                                                     set:NULL
                                                                     get:NULL
                                                                  detail:nil
                                                                    cell:PSGroupCell
                                                                    edit:nil];
    [specifiers addObject:availableGroup];

    for (AVSpeechSynthesisVoice *voice in voices) {
        NSString *detail = [NSString stringWithFormat:@"%@ • %@", SNVoiceQualityLabel(voice.quality), SNVoiceNormalizedLanguage(voice.language)];
        NSArray<AVSpeechSynthesisVoice *> *sameName = [voices filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(AVSpeechSynthesisVoice *candidate, NSDictionary *bindings) {
            return [candidate.name isEqualToString:voice.name] && candidate.quality == voice.quality;
        }]];
        if (sameName.count > 1) {
            detail = [detail stringByAppendingFormat:@" • %@", SNVoiceIdentifierSuffix(voice.identifier)];
        }
        [specifiers addObject:[self voiceSpecifierNamed:voice.name
                                                  detail:detail
                                              identifier:voice.identifier
                                                selected:[selectedIdentifier isEqualToString:voice.identifier]
                                                 targets:targets]];
    }

    PSSpecifier *reload = [PSSpecifier preferenceSpecifierNamed:@"Reload Available Voices"
                                                         target:self
                                                            set:NULL
                                                            get:NULL
                                                         detail:nil
                                                           cell:PSButtonCell
                                                           edit:nil];
    reload.buttonAction = @selector(reloadAvailableVoices);
    [specifiers addObject:reload];
    self.optionTargets = targets;
    return specifiers;
}

- (NSArray *)specifiers
{
    if (!_specifiers) {
        [self setSpecifiers:[[self buildVoiceSpecifiers] mutableCopy]];
    }
    return _specifiers;
}

- (void)reloadVoiceSpecifiers
{
    if (!self.isViewLoaded) return;
    [self setSpecifiers:[[self buildVoiceSpecifiers] mutableCopy]];
    [self.table reloadData];
}

- (void)reloadAvailableVoices
{
    [self reloadVoiceSpecifiers];
}

- (void)selectVoiceIdentifier:(NSString *)identifier
{
    NSString *language = [self resolvedLanguageCode];
    NSUserDefaults *defaults = [SNPrefsUtil suite];
    NSDictionary *stored = [defaults dictionaryForKey:kSNSelectedVoiceIdentifierByLanguageKey];
    NSMutableDictionary *byLanguage = [stored isKindOfClass:NSDictionary.class] ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    if (identifier.length == 0) {
        [byLanguage removeObjectForKey:language];
    } else {
        [byLanguage setObject:identifier forKey:language];
    }
    [defaults setObject:byLanguage forKey:kSNSelectedVoiceIdentifierByLanguageKey];
    [defaults synchronize];
    [SNPrefsUtil postPrefsChanged];
    [self reloadVoiceSpecifiers];
}

@end
