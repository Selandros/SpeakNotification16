#import "SNLanguageVoiceListController.h"
#import <AVFoundation/AVFoundation.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>

#import "SNLanguageVoiceController.h"
#import "SNPrefsUtil.h"
#import "SNPreferences.h"
#import "SNSharedKeys.h"

@interface SNLanguageVoiceSummaryCell : PSTableCell
@end

@implementation SNLanguageVoiceSummaryCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier
{
    return [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier specifier:specifier];
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier
{
    [super refreshCellContentsWithSpecifier:specifier];
    self.textLabel.text = specifier.name;
    self.detailTextLabel.text = [specifier propertyForKey:@"voiceSummary"] ?: @"";
    self.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    BOOL selectable = [[specifier propertyForKey:@"voiceSelectable"] boolValue];
    self.accessoryType = selectable ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    self.selectionStyle = selectable ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    self.userInteractionEnabled = selectable;
}

@end

@interface SNLanguageVoiceListController ()
@property (nonatomic, assign) BOOL preferencesObserverRegistered;
@end

static NSString *SNLanguageVoiceNormalizedCode(NSString *language)
{
    if (![language isKindOfClass:NSString.class] || language.length == 0) return @"";
    return SNNormalizeVoiceLanguage(language);
}

static NSString *SNLanguageVoiceQualityLabel(NSInteger quality)
{
    if (quality == AVSpeechSynthesisVoiceQualityPremium) return @"Premium";
    if (quality == AVSpeechSynthesisVoiceQualityEnhanced) return @"Enhanced";
    return @"Compact";
}

static NSString *SNLanguageVoiceDisplayName(NSString *language)
{
    NSString *normalized = SNLanguageVoiceNormalizedCode(language);
    NSString *name = [[NSLocale currentLocale] displayNameForKey:NSLocaleIdentifier value:normalized];
    return name.length ? name : normalized;
}

static NSString *SNLanguageVoicePrefix(NSString *language)
{
    NSString *normalized = SNLanguageVoiceNormalizedCode(language).lowercaseString;
    NSRange dash = [normalized rangeOfString:@"-"];
    return dash.location == NSNotFound ? normalized : [normalized substringToIndex:dash.location];
}

static BOOL SNLanguageVoiceCanBeAssigned(AVSpeechSynthesisVoice *voice)
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

static AVSpeechSynthesisVoice *SNLanguageVoiceAvailableSystemVoice(NSString *language)
{
    NSString *target = SNLanguageVoiceNormalizedCode(language);
    NSString *targetPrefix = SNLanguageVoicePrefix(target);
    if (target.length == 0 || targetPrefix.length == 0) return nil;

    AVSpeechSynthesisVoice *sameLanguageVoice = nil;
    for (AVSpeechSynthesisVoice *voice in [AVSpeechSynthesisVoice speechVoices]) {
        NSString *identifier = voice.identifier;
        if (identifier.length == 0) continue;
        AVSpeechSynthesisVoice *resolved = [AVSpeechSynthesisVoice voiceWithIdentifier:identifier];
        NSString *declaredLanguage = SNLanguageVoiceNormalizedCode(voice.language);
        NSString *resolvedLanguage = SNLanguageVoiceNormalizedCode(resolved.language);
        if (!resolved || declaredLanguage.length == 0 || ![declaredLanguage isEqualToString:resolvedLanguage]) continue;
        if (![SNLanguageVoicePrefix(resolvedLanguage) isEqualToString:targetPrefix]) continue;
        if (!SNLanguageVoiceCanBeAssigned(resolved)) continue;
        if ([resolvedLanguage isEqualToString:target]) return resolved;
        if (!sameLanguageVoice) sameLanguageVoice = resolved;
    }
    return sameLanguageVoice;
}

static void SNLanguageVoicePreferencesChanged(CFNotificationCenterRef center,
                                              void *observer,
                                              CFStringRef name,
                                              const void *object,
                                              CFDictionaryRef userInfo)
{
    SNLanguageVoiceListController *controller = (__bridge SNLanguageVoiceListController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!controller || !controller.isViewLoaded) return;
        [controller reloadLanguageSpecifiers];
    });
}

@implementation SNLanguageVoiceListController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Languages & Voices";
    if (!self.preferencesObserverRegistered) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)(self),
                                        SNLanguageVoicePreferencesChanged,
                                        kSNVoiceStateChangedNotify,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        self.preferencesObserverRegistered = YES;
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadLanguageSpecifiers];
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

- (NSArray<PSSpecifier *> *)buildLanguageSpecifiers
{
    NSUserDefaults *defaults = [SNPrefsUtil suite];
    NSDictionary *stored = [defaults dictionaryForKey:kSNLastUsedVoiceByLanguageKey];
    NSMutableArray<NSDictionary *> *availableEntries = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *unavailableEntries = [NSMutableArray array];
    if ([stored isKindOfClass:NSDictionary.class]) {
        [stored enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            NSString *language = SNLanguageVoiceNormalizedCode(key);
            if (language.length == 0 || ![obj isKindOfClass:NSDictionary.class]) return;
            NSDictionary *entry = obj;
            NSString *identifier = [entry[@"voiceIdentifier"] isKindOfClass:NSString.class] ? entry[@"voiceIdentifier"] : @"";
            NSString *voiceName = [entry[@"voiceName"] isKindOfClass:NSString.class] ? entry[@"voiceName"] : @"";
            NSString *status = [entry[@"status"] isKindOfClass:NSString.class] ? entry[@"status"] : @"";
            BOOL available = [status isEqualToString:@"available"];
            if (status.length == 0) available = identifier.length > 0 && voiceName.length > 0;
            NSMutableDictionary *item = [@{
                @"language": language,
                @"entry": entry,
                @"lastAttemptAt": @([entry[@"lastAttemptAt"] doubleValue])
            } mutableCopy];
            if ([item[@"lastAttemptAt"] doubleValue] <= 0.0) item[@"lastAttemptAt"] = @([entry[@"lastUsedAt"] doubleValue]);
            if (available) {
                [availableEntries addObject:item];
            } else {
                [unavailableEntries addObject:item];
            }
        }];
    }

    NSComparator sortEntries = ^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        double leftDate = [left[@"lastAttemptAt"] doubleValue];
        double rightDate = [right[@"lastAttemptAt"] doubleValue];
        if (leftDate > rightDate) return NSOrderedAscending;
        if (leftDate < rightDate) return NSOrderedDescending;
        return [left[@"language"] localizedCaseInsensitiveCompare:right[@"language"]];
    };
    [availableEntries sortUsingComparator:sortEntries];
    [unavailableEntries sortUsingComparator:sortEntries];

    PSSpecifier *information = [PSSpecifier preferenceSpecifierNamed:@""
                                                               target:nil
                                                                  set:NULL
                                                                  get:NULL
                                                               detail:nil
                                                                 cell:PSGroupCell
                                                                 edit:nil];
    [information setProperty:@"Siri voices cannot be selected. Enhanced voices are generally the best available voices supported by SpeakNotification16 on rootless iOS 16." forKey:@"footerText"];

    PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"Languages & Voices"
                                                         target:nil
                                                            set:NULL
                                                            get:NULL
                                                         detail:nil
                                                           cell:PSGroupCell
                                                           edit:nil];
    NSMutableArray<PSSpecifier *> *specifiers = [NSMutableArray arrayWithObjects:information, group, nil];

    if (availableEntries.count == 0) {
        PSSpecifier *empty = [PSSpecifier preferenceSpecifierNamed:@"No spoken languages recorded yet."
                                                            target:nil
                                                               set:NULL
                                                               get:NULL
                                                            detail:nil
                                                              cell:PSTitleValueCell
                                                              edit:nil];
        [empty setProperty:@NO forKey:@"voiceSelectable"];
        [empty setProperty:[SNLanguageVoiceSummaryCell class] forKey:@"cellClass"];
        [specifiers addObject:empty];
    }

    for (NSDictionary *item in availableEntries) {
        NSString *language = item[@"language"];
        NSDictionary *entry = item[@"entry"];
        NSString *voiceName = entry[@"voiceName"] ?: @"System Default";
        NSString *quality = SNLanguageVoiceQualityLabel([entry[@"voiceQuality"] integerValue]);
        PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:SNLanguageVoiceDisplayName(language)
                                                                 target:nil
                                                                    set:NULL
                                                                    get:NULL
                                                                 detail:[SNLanguageVoiceController class]
                                                                   cell:PSLinkCell
                                                                   edit:nil];
        [specifier setProperty:language forKey:@"languageCode"];
        [specifier setProperty:[NSString stringWithFormat:@"%@ • %@ — %@", language, voiceName, quality] forKey:@"voiceSummary"];
        [specifier setProperty:@YES forKey:@"voiceSelectable"];
        [specifier setProperty:[SNLanguageVoiceSummaryCell class] forKey:@"cellClass"];
        [specifiers addObject:specifier];
    }

    if (unavailableEntries.count) {
        PSSpecifier *unavailableGroup = [PSSpecifier preferenceSpecifierNamed:@"Voice Unavailable"
                                                                        target:nil
                                                                           set:NULL
                                                                           get:NULL
                                                                        detail:nil
                                                                          cell:PSGroupCell
                                                                          edit:nil];
        [specifiers addObject:unavailableGroup];

        for (NSDictionary *item in unavailableEntries) {
            NSString *language = item[@"language"];
            PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:SNLanguageVoiceDisplayName(language)
                                                                     target:nil
                                                                        set:NULL
                                                                        get:NULL
                                                                     detail:nil
                                                                       cell:PSTitleValueCell
                                                                       edit:nil];
            [specifier setProperty:[NSString stringWithFormat:@"%@ • No compatible voice found", language] forKey:@"voiceSummary"];
            [specifier setProperty:@NO forKey:@"voiceSelectable"];
            [specifier setProperty:[SNLanguageVoiceSummaryCell class] forKey:@"cellClass"];
            [specifiers addObject:specifier];
        }
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

    PSSpecifier *reset = [PSSpecifier preferenceSpecifierNamed:@"Reset Languages & Voices…"
                                                         target:self
                                                            set:NULL
                                                            get:NULL
                                                         detail:nil
                                                           cell:PSButtonCell
                                                           edit:nil];
    reset.buttonAction = @selector(confirmResetLanguagesAndVoices);
    [specifiers addObject:reset];

    PSSpecifier *help = [PSSpecifier preferenceSpecifierNamed:@""
                                                        target:nil
                                                           set:NULL
                                                           get:NULL
                                                        detail:nil
                                                          cell:PSGroupCell
                                                          edit:nil];
    [help setProperty:@"Try downloading a voice in Settings → Accessibility → VoiceOver → Speech, then return here and reload available voices. Some Siri voices are not available to AVSpeechSynthesizer." forKey:@"footerText"];
    [specifiers addObject:help];
    return specifiers;
}

- (NSArray *)specifiers
{
    if (!_specifiers) {
        [self setSpecifiers:[[self buildLanguageSpecifiers] mutableCopy]];
    }
    return _specifiers;
}

- (void)reloadLanguageSpecifiers
{
    if (!self.isViewLoaded) return;
    [self setSpecifiers:[[self buildLanguageSpecifiers] mutableCopy]];
    [self.table reloadData];
}

- (void)reloadAvailableVoices
{
    NSUserDefaults *defaults = [SNPrefsUtil suite];
    NSDictionary *stored = [defaults dictionaryForKey:kSNLastUsedVoiceByLanguageKey];
    if (![stored isKindOfClass:NSDictionary.class]) {
        [self reloadLanguageSpecifiers];
        return;
    }

    NSMutableDictionary *updated = [stored mutableCopy];
    __block BOOL changed = NO;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    [stored enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        NSString *language = SNLanguageVoiceNormalizedCode(key);
        if (language.length == 0 || ![obj isKindOfClass:NSDictionary.class]) return;
        NSDictionary *entry = obj;
        NSString *status = [entry[@"status"] isKindOfClass:NSString.class] ? entry[@"status"] : @"";
        if (![status isEqualToString:@"unavailable"]) return;

        AVSpeechSynthesisVoice *voice = SNLanguageVoiceAvailableSystemVoice(language);
        if (!voice) return;
        NSMutableDictionary *available = [entry mutableCopy];
        available[@"status"] = @"available";
        available[@"lastAttemptAt"] = @(now);
        available[@"voiceIdentifier"] = voice.identifier;
        available[@"voiceName"] = voice.name ?: @"System Default";
        available[@"voiceQuality"] = @(voice.quality);
        available[@"voiceSource"] = @"systemDefault";
        updated[language] = available;
        changed = YES;
    }];

    if (changed) {
        [defaults setObject:updated forKey:kSNLastUsedVoiceByLanguageKey];
        [defaults synchronize];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             kSNVoiceStateChangedNotify,
                                             NULL,
                                             NULL,
                                             true);
    }
    [self reloadLanguageSpecifiers];
}

- (void)confirmResetLanguagesAndVoices
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset Languages & Voices?"
                                                                   message:@"This will clear recorded languages and restore all voice selections to System Default."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf resetLanguagesAndVoices];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetLanguagesAndVoices
{
    NSUserDefaults *defaults = [SNPrefsUtil suite];
    [defaults removeObjectForKey:kSNLastUsedVoiceByLanguageKey];
    [defaults removeObjectForKey:kSNSelectedVoiceIdentifierByLanguageKey];
    [defaults synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         kSNVoiceStateChangedNotify,
                                         NULL,
                                         NULL,
                                         true);
    [self reloadLanguageSpecifiers];
}

@end
