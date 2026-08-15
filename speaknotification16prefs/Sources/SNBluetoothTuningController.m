#import "SNBluetoothTuningController.h"
#import "SNPrefsUtil.h"
#import "SNSharedKeys.h"
#import <Preferences/PSSpecifier.h>

@interface SNBluetoothTuningController ()
@property (nonatomic, copy) NSString *savedName;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *canonicalUID;
@property (nonatomic, copy) dispatch_block_t changeHandler;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *aliases;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *tuning;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *deviceUIDs;
@end

@implementation SNBluetoothTuningController

- (instancetype)initWithSavedName:(NSString *)savedName
                      displayName:(NSString *)displayName
                      canonicalUID:(NSString *)canonicalUID
                     changeHandler:(dispatch_block_t)changeHandler
{
    self = [super init];
    if (self) {
        _savedName = [savedName copy];
        _displayName = [displayName copy];
        _canonicalUID = [canonicalUID copy];
        _changeHandler = [changeHandler copy];
        self.navigationItem.title = @"Bluetooth Device";
        [self sn_loadState];
    }
    return self;
}

- (void)sn_loadState
{
    NSUserDefaults *defs = [SNPrefsUtil suite];
    NSDictionary *savedAliases = [defs objectForKey:kTrustedConnectionAliasesV1Key];
    NSDictionary *savedTuning = [defs objectForKey:kSNA2DPDeviceTuningV1Key];
    NSDictionary *savedUIDs = [defs objectForKey:kSNBluetoothDeviceUIDsV1Key];
    self.aliases = [savedAliases isKindOfClass:NSDictionary.class] ? [savedAliases mutableCopy] : [NSMutableDictionary dictionary];
    self.tuning = [savedTuning isKindOfClass:NSDictionary.class] ? [savedTuning mutableCopy] : [NSMutableDictionary dictionary];
    self.deviceUIDs = [savedUIDs isKindOfClass:NSDictionary.class] ? [savedUIDs mutableCopy] : [NSMutableDictionary dictionary];
}

- (NSString *)sn_aliasKey
{
    return self.savedName.length ? [NSString stringWithFormat:@"bluetooth:%@", self.savedName] : @"";
}

- (NSDictionary *)sn_deviceTuning
{
    if (self.canonicalUID.length == 0) return @{};
    id entry = self.tuning[self.canonicalUID];
    return [entry isKindOfClass:NSDictionary.class] ? entry : @{};
}

- (NSInteger)sn_valueForKey:(NSString *)key defaultValue:(NSInteger)defaultValue maximum:(NSInteger)maximum step:(NSInteger)step
{
    id value = [self sn_deviceTuning][key];
    if (![value isKindOfClass:NSNumber.class]) return defaultValue;
    NSInteger rounded = [(NSNumber *)value integerValue];
    rounded = MAX(0, MIN(maximum, rounded));
    return (rounded / step) * step;
}

- (void)sn_save
{
    NSUserDefaults *defs = [SNPrefsUtil suite];
    [defs setObject:self.aliases ?: @{} forKey:kTrustedConnectionAliasesV1Key];
    [defs setObject:self.tuning ?: @{} forKey:kSNA2DPDeviceTuningV1Key];
    [defs setObject:self.deviceUIDs ?: @{} forKey:kSNBluetoothDeviceUIDsV1Key];
    [defs synchronize];
    [SNPrefsUtil postPrefsChanged];
    if (self.changeHandler) self.changeHandler();
}

- (NSArray *)specifiers
{
    if (_specifiers) return _specifiers;
    NSMutableArray *specs = [NSMutableArray array];

    PSSpecifier *nameGroup = [PSSpecifier preferenceSpecifierNamed:@"Name" target:self set:NULL get:NULL detail:Nil cell:PSGroupCell edit:Nil];
    [specs addObject:nameGroup];
    PSSpecifier *name = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:@selector(setName:specifier:) get:@selector(getName:) detail:Nil cell:PSEditTextCell edit:Nil];
    [name setProperty:@YES forKey:@"isEditable"];
    [name setProperty:@YES forKey:@"textFieldIsSingleLine"];
    [name setProperty:@YES forKey:@"noAutoCorrect"];
    [name setProperty:@YES forKey:@"noAutoCaps"];
    [name setProperty:@"name" forKey:@"id"];
    [specs addObject:name];

    PSSpecifier *tuningGroup = [PSSpecifier preferenceSpecifierNamed:@"BLUETOOTH SPEECH TIMING" target:self set:NULL get:NULL detail:Nil cell:PSGroupCell edit:Nil];
    [tuningGroup setProperty:(self.canonicalUID.length
                              ? @"Adds a short silent delay before speaking so the Bluetooth device has time to wake up. Increase this if the beginning of notifications is cut off. Set to 0 ms for no delay."
                              : @"Connect this device once using Bluetooth A2DP to enable per-device tuning.")
                     forKey:@"footerText"];
    [specs addObject:tuningGroup];

    if (self.canonicalUID.length) {
        PSSpecifier *warmupValue = [PSSpecifier preferenceSpecifierNamed:@"Hold Before Speech" target:self set:NULL get:@selector(getWarmupValue:) detail:Nil cell:PSTitleValueCell edit:Nil];
        [warmupValue setProperty:@"warmupValue" forKey:@"id"];
        [specs addObject:warmupValue];
        PSSpecifier *warmup = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:@selector(setWarmup:specifier:) get:@selector(getWarmup:) detail:Nil cell:PSSliderCell edit:Nil];
        [warmup setProperty:@0 forKey:@"min"];
        [warmup setProperty:@1000 forKey:@"max"];
        [warmup setProperty:@50 forKey:@"step"];
        [warmup setProperty:@"warmup" forKey:@"id"];
        [specs addObject:warmup];

        PSSpecifier *keepWarmGroup = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:NULL get:NULL detail:Nil cell:PSGroupCell edit:Nil];
        [keepWarmGroup setProperty:@"Keeps the Bluetooth device ready for a short time after speaking. New notifications during this time can start immediately without another startup delay. Set to 0 ms to disable." forKey:@"footerText"];
        [specs addObject:keepWarmGroup];

        PSSpecifier *keepWarmValue = [PSSpecifier preferenceSpecifierNamed:@"Hold After Speech" target:self set:NULL get:@selector(getKeepWarmValue:) detail:Nil cell:PSTitleValueCell edit:Nil];
        [keepWarmValue setProperty:@"keepWarmValue" forKey:@"id"];
        [specs addObject:keepWarmValue];
        PSSpecifier *keepWarm = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:@selector(setKeepWarm:specifier:) get:@selector(getKeepWarm:) detail:Nil cell:PSSliderCell edit:Nil];
        [keepWarm setProperty:@0 forKey:@"min"];
        [keepWarm setProperty:@3000 forKey:@"max"];
        [keepWarm setProperty:@100 forKey:@"step"];
        [keepWarm setProperty:@"keepWarm" forKey:@"id"];
        [specs addObject:keepWarm];

        PSSpecifier *actionsGroup = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:NULL get:NULL detail:Nil cell:PSGroupCell edit:Nil];
        [specs addObject:actionsGroup];

        PSSpecifier *reset = [PSSpecifier preferenceSpecifierNamed:@"Reset to Defaults" target:self set:NULL get:NULL detail:Nil cell:PSButtonCell edit:Nil];
        reset.buttonAction = @selector(resetToDefaults);
        [specs addObject:reset];
    }

    PSSpecifier *delete = [PSSpecifier preferenceSpecifierNamed:@"Delete Trusted Device" target:self set:NULL get:NULL detail:Nil cell:PSButtonCell edit:Nil];
    delete.buttonAction = @selector(deleteTrustedDevice);
    [delete setProperty:@YES forKey:@"destructive"];
    [specs addObject:delete];
    _specifiers = specs;
    return _specifiers;
}

- (id)getName:(PSSpecifier *)specifier { return self.displayName ?: self.savedName ?: @""; }

- (void)setName:(id)value specifier:(PSSpecifier *)specifier
{
    NSString *name = [[value isKindOfClass:NSString.class] ? value : @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *aliasKey = [self sn_aliasKey];
    if (name.length && ![name isEqualToString:self.savedName]) self.aliases[aliasKey] = name;
    else [self.aliases removeObjectForKey:aliasKey];
    self.displayName = name.length ? name : self.savedName;
    [self sn_save];
}

- (id)getWarmup:(PSSpecifier *)specifier { return @([self sn_valueForKey:@"warmupMs" defaultValue:kSNA2DPDefaultWarmupMs maximum:1000 step:50]); }
- (id)getKeepWarm:(PSSpecifier *)specifier { return @([self sn_valueForKey:@"keepWarmMs" defaultValue:kSNA2DPDefaultKeepWarmMs maximum:3000 step:100]); }
- (id)getWarmupValue:(PSSpecifier *)specifier { return [NSString stringWithFormat:@"%ld ms", (long)[[self getWarmup:specifier] integerValue]]; }
- (id)getKeepWarmValue:(PSSpecifier *)specifier { return [NSString stringWithFormat:@"%ld ms", (long)[[self getKeepWarm:specifier] integerValue]]; }

- (void)sn_setValue:(id)value key:(NSString *)key maximum:(NSInteger)maximum step:(NSInteger)step valueSpecifierID:(NSString *)valueSpecifierID sliderSpecifierID:(NSString *)sliderSpecifierID
{
    NSInteger rounded = MAX(0, MIN(maximum, [value integerValue]));
    rounded = (NSInteger)llround((double)rounded / (double)step) * step;
    NSMutableDictionary *entry = [[self sn_deviceTuning] mutableCopy];
    entry[key] = @(rounded);
    self.tuning[self.canonicalUID] = entry;
    [self sn_save];
    [self reloadSpecifierID:valueSpecifierID animated:NO];
    [self reloadSpecifierID:sliderSpecifierID animated:NO];
}

- (void)setWarmup:(id)value specifier:(PSSpecifier *)specifier { [self sn_setValue:value key:@"warmupMs" maximum:1000 step:50 valueSpecifierID:@"warmupValue" sliderSpecifierID:@"warmup"]; }
- (void)setKeepWarm:(id)value specifier:(PSSpecifier *)specifier { [self sn_setValue:value key:@"keepWarmMs" maximum:3000 step:100 valueSpecifierID:@"keepWarmValue" sliderSpecifierID:@"keepWarm"]; }

- (void)resetToDefaults
{
    [self.tuning removeObjectForKey:self.canonicalUID];
    [self sn_save];
    [self reloadSpecifiers];
}

- (void)deleteTrustedDevice
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete Trusted Device" message:self.displayName preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSUserDefaults *defs = [SNPrefsUtil suite];
        NSMutableArray *items = [[defs objectForKey:kBTKey] isKindOfClass:NSArray.class] ? [[defs objectForKey:kBTKey] mutableCopy] : [NSMutableArray array];
        [items removeObject:self.savedName];
        [defs setObject:items forKey:kBTKey];
        [weakSelf.aliases removeObjectForKey:[weakSelf sn_aliasKey]];
        [weakSelf.deviceUIDs removeObjectForKey:weakSelf.savedName];
        if (weakSelf.canonicalUID.length) [weakSelf.tuning removeObjectForKey:weakSelf.canonicalUID];
        [weakSelf sn_save];
        [weakSelf.navigationController popViewControllerAnimated:YES];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
