// SNPreferences.m
// Centralized preferences access. Pure motorics; no logging; CPU-cheap.

#import "SNPreferences.h"
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import "SNCancellation.h"

// ---- Darwin notify ----
static void prefsChangedCallback(CFNotificationCenterRef center,
                                 void *observer,
                                 CFStringRef name,
                                 const void *object,
                                 CFDictionaryRef userInfo);

static NSString * const kKeyGlobalFormat         = @"globalFormat";
static NSString * const kKeyMessageFormat        = @"messageFormat";
static NSString * const kKeyQuietHoursEnabled    = @"enableQuietHours";
static NSString * const kKeyQueueEnabled         = @"queueNotifications";
static NSString * const kKeyLockscreenPrivacy    = @"lockscreenPrivacy";
static NSString * const kKeyMuteSpam             = @"muteSpam";
static NSString * const kKeySpamCooldownSeconds  = @"spamCooldownSeconds";

// ---- Core behavior keys ----
static NSString * const kKeyPause                = @"pause";           // BOOL (default NO)
static NSString * const kKeySpeechVolume         = @"speechVolume";    // INT 0–100
static NSString * const kKeyUseSystemVolume      = @"useSystemVolume"; // BOOL
static NSString * const kKeyResetVolumeAfterSpeak = @"SNResetVolumeAfterSpeakEnabled"; // BOOL

// ---- Debug master + domains ----
static NSString * const kKeyDebugMaster          = @"debugLoggingEnabled"; // master toggle
static NSString * const kKeyDbgNotif             = @"debugNotification";
static NSString * const kKeyDbgTTSAV             = @"debugTTSAV";
static NSString * const kKeyDbgBurst             = @"debugBurst";
static NSString * const kKeyDbgVol               = @"debugVol";
static NSString * const kKeyDbgCancel            = @"debugCancel";
static NSString * const kKeyDbgPolicy            = @"debugPolicy";     // replaces duck/pause
static NSString * const kKeyDbgSpeak             = @"debugSpeak";
static NSString * const kKeyDbgPoke              = @"debugPoke";
static NSString * const kKeyDbgRoute             = @"debugRoute";
static NSString * const kKeyDbgEngine            = @"debugEngine";
static NSString * const kKeyDbgPrefs             = @"debugPrefs";

NSString * const kKeyCPRouteLockSeconds   = @"cpRouteLockSeconds";    // INT 0–10 (s)
NSString * const kKeyTTSTailMs            = @"ttsTailMs";             // INT 0–1000 (ms)
NSString * const kKeyPolicyDebounceMs     = @"policyDebounceMs";      // INT 0–500 (ms)
NSString * const kKeyInterruptionTailMs   = @"interruptionTailMs";    // INT 0–2000 (ms)

@implementation SNPreferences {
    // Backing storage for readonly properties
    BOOL _pauseEnabled;
    NSInteger _speechVolume;
    BOOL _useSystemVolume;
    BOOL _resetVolumeAfterSpeakEnabled;

    BOOL _debugEnabled;
    BOOL _debugNotificationEnabled;
    BOOL _debugTTSAVEnabled;
    BOOL _debugBurstEnabled;
    BOOL _debugVolEnabled;
    BOOL _debugCancelEnabled;
    BOOL _debugPolicyEnabled;
    BOOL _debugSpeakEnabled;
    BOOL _debugPokeEnabled;
    BOOL _debugRouteEnabled;
    BOOL _debugEngineEnabled;
    BOOL _debugPrefsEnabled;

    NSArray<NSString *> *_trustedSSIDs;
    NSArray<NSString *> *_trustedBTDevices;
    NSArray<NSString *> *_trustedWiredAudioDevices;
    NSString *_messageFormat;

    BOOL _quietHoursEnabled;
    BOOL _queueEnabled;
    BOOL _lockscreenPrivacyEnabled;

    BOOL _muteSpamEnabled;
    double _spamCooldownSeconds;
}

+ (instancetype)sharedInstance {
    static SNPreferences *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

+ (instancetype)shared {
    static SNPreferences *S;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        S = [SNPreferences new];
        [S reload];
        [S startObserving];
    });
    return S;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Trusted/misc
        _trustedSSIDs = @[];
        _trustedBTDevices = @[];
        _trustedWiredAudioDevices = @[];
        _messageFormat = @"{APP}: {TITLE}: {BODY}";
        _quietHoursEnabled = NO;
        _queueEnabled = NO;               // Match plist default.
        _lockscreenPrivacyEnabled = NO;

        // Core behavior (match plist)
        _pauseEnabled = NO;
        _speechVolume = 30;               // 30 %
        _useSystemVolume = NO;            // Match plist default.
        _resetVolumeAfterSpeakEnabled = NO;

        // Debug
        _debugEnabled = NO;
        _debugNotificationEnabled = NO;
        _debugTTSAVEnabled = NO;
        _debugBurstEnabled = NO;
        _debugVolEnabled = NO;
        _debugCancelEnabled = NO;
        _debugPolicyEnabled = NO;
        _debugSpeakEnabled = NO;
        _debugPokeEnabled = NO;
        _debugRouteEnabled = NO;
        _debugEngineEnabled = NO;
        _debugPrefsEnabled = NO;

        _muteSpamEnabled = NO;            // Match plist default.
        _spamCooldownSeconds = 12.0;
    }
    return self;
}

- (void)dealloc
{
    [self stopObserving];
#if !__has_feature(objc_arc)
    if (_trustedSSIDs) { [_trustedSSIDs release]; _trustedSSIDs = nil; }     // release owned arrays
    if (_trustedBTDevices) { [_trustedBTDevices release]; _trustedBTDevices = nil; }
    if (_trustedWiredAudioDevices) { [_trustedWiredAudioDevices release]; _trustedWiredAudioDevices = nil; }
    if (_messageFormat) { [_messageFormat release]; _messageFormat = nil; }
    [super dealloc];
#endif
}

#pragma mark - Suite access

- (NSUserDefaults *)_defs {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
#if !__has_feature(objc_arc)
    return [d autorelease];
#else
    return d;
#endif
}

#pragma mark - Public generic getters

- (NSString *)stringForKey:(NSString *)key defaultValue:(NSString *)defValue {
    if (key.length == 0) return defValue;
    id v = [[self _defs] objectForKey:key];
    if ([v isKindOfClass:NSString.class]) return (NSString *)v;
    return defValue;
}

- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)defValue {
    if (key.length == 0) return defValue;
    id v = [[self _defs] objectForKey:key];
    if ([v isKindOfClass:NSNumber.class]) return [(NSNumber *)v boolValue];
    return defValue;
}

#pragma mark - Cancel prefs

- (SNCancelButtonMode)cancelButtonMode {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];
    NSString *s = [d objectForKey:@"cancelButton"];
    if (![s isKindOfClass:NSString.class] || s.length == 0) s = @"power";
    SNCancelButtonMode m = SNCancelButtonModeNone;
    if ([s isEqualToString:@"power"]) m = SNCancelButtonModePower;
    else if ([s isEqualToString:@"volumeup"]) m = SNCancelButtonModeVolumeUp;
    else if ([s isEqualToString:@"volumedown"]) m = SNCancelButtonModeVolumeDown;
    else if ([s isEqualToString:@"volumeupdown"]) m = SNCancelButtonModeVolumeUpDown;
    else if ([s isEqualToString:@"any"]) m = SNCancelButtonModeAny;
    [d release];
    return m;
}

#pragma mark - Observing

- (void)startObserving {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                (__bridge const void *)self,
                                prefsChangedCallback,
                                kSNPrefsNotify,
                                NULL,
                                CFNotificationSuspensionBehaviorDeliverImmediately);
}

- (void)stopObserving {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                   (__bridge const void *)self,
                                   kSNPrefsNotify,
                                   NULL);
}

static void prefsChangedCallback(CFNotificationCenterRef center,
                                 void *observer,
                                 CFStringRef name,
                                 const void *object,
                                 CFDictionaryRef userInfo) {
    (void)center; (void)name; (void)object; (void)userInfo;
    SNPreferences *selfRef = (__bridge SNPreferences *)observer;
    [selfRef reload];
}

#pragma mark - Reload

- (void)reload {
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:kSNPrefsSuite];

    id ssids = [defs objectForKey:kSSIDsKey];
    id bts   = [defs objectForKey:kBTKey];
    id wired = [defs objectForKey:kWiredAudioDevicesKey];

    NSString *fmt = [defs stringForKey:kKeyGlobalFormat];
    if (![fmt isKindOfClass:NSString.class] || fmt.length == 0) {
        fmt = [defs stringForKey:kKeyMessageFormat];
    }
    if (![fmt isKindOfClass:NSString.class] || fmt.length == 0) {
        fmt = @"{APP}: {TITLE}: {BODY}";
    }

    NSNumber *qHours  = [defs objectForKey:kKeyQuietHoursEnabled];
    NSNumber *queue   = [defs objectForKey:kKeyQueueEnabled];
    NSNumber *lsPriv  = [defs objectForKey:kKeyLockscreenPrivacy];

    NSArray<NSString *> *ssidArr = ([ssids isKindOfClass:NSArray.class] ? ssids : @[]);
    NSArray<NSString *> *btArr   = ([bts   isKindOfClass:NSArray.class] ? bts   : @[]);
    NSArray<NSString *> *wiredArr = ([wired isKindOfClass:NSArray.class] ? wired : @[]);

// release old ivars before assigning new copies (MRC only)
#if !__has_feature(objc_arc)
    if (self->_trustedSSIDs) { [self->_trustedSSIDs release]; self->_trustedSSIDs = nil; }
    if (self->_trustedBTDevices) { [self->_trustedBTDevices release]; self->_trustedBTDevices = nil; }
    if (self->_trustedWiredAudioDevices) { [self->_trustedWiredAudioDevices release]; self->_trustedWiredAudioDevices = nil; }
    if (self->_messageFormat) { [self->_messageFormat release]; self->_messageFormat = nil; }
#endif

#if !__has_feature(objc_arc)
    self->_trustedSSIDs = [ssidArr copy];
    self->_trustedBTDevices = [btArr copy];
    self->_trustedWiredAudioDevices = [wiredArr copy];
    self->_messageFormat = [fmt copy];
#else
    _trustedSSIDs = [ssidArr copy];
    _trustedBTDevices = [btArr copy];
    _trustedWiredAudioDevices = [wiredArr copy];
    _messageFormat = [fmt copy];
#endif
    self->_quietHoursEnabled = [qHours isKindOfClass:NSNumber.class] ? qHours.boolValue : NO;
    self->_queueEnabled = [queue isKindOfClass:NSNumber.class] ? queue.boolValue : NO;
    self->_lockscreenPrivacyEnabled = [lsPriv isKindOfClass:NSNumber.class] ? lsPriv.boolValue : NO;

    // Core behavior
    {
        NSNumber *pauseObj = [defs objectForKey:kKeyPause];
        NSNumber *volObj   = [defs objectForKey:kKeySpeechVolume];
        NSNumber *useSys   = [defs objectForKey:kKeyUseSystemVolume];
        NSNumber *resetVol = [defs objectForKey:kKeyResetVolumeAfterSpeak];

        BOOL pause = [pauseObj isKindOfClass:NSNumber.class] ? pauseObj.boolValue : NO;
        NSInteger sv = [volObj isKindOfClass:NSNumber.class] ? volObj.integerValue : 30;
        if (sv < 0) sv = 0; if (sv > 100) sv = 100;
        BOOL useSystem = [useSys isKindOfClass:NSNumber.class] ? useSys.boolValue : NO;
        BOOL resetAfterSpeak = [resetVol isKindOfClass:NSNumber.class] ? resetVol.boolValue : NO;

        self->_pauseEnabled = pause;
        self->_speechVolume = sv;
        self->_useSystemVolume = useSystem;
        self->_resetVolumeAfterSpeakEnabled = resetAfterSpeak;
    }

    // Debug master + domains
    {
        BOOL master = [defs boolForKey:kKeyDebugMaster];

        BOOL dNotif  = [defs boolForKey:kKeyDbgNotif];
        BOOL dTTSAV  = [defs boolForKey:kKeyDbgTTSAV];
        BOOL dBurst  = [defs boolForKey:kKeyDbgBurst];
        BOOL dVol    = [defs boolForKey:kKeyDbgVol];
        BOOL dCancel = [defs boolForKey:kKeyDbgCancel];
        BOOL dPolicy = [defs boolForKey:kKeyDbgPolicy];
        BOOL dSpeak  = [defs boolForKey:kKeyDbgSpeak];
        BOOL dPoke   = [defs boolForKey:kKeyDbgPoke];
        BOOL dRoute  = [defs boolForKey:kKeyDbgRoute];
        BOOL dEngine = [defs boolForKey:kKeyDbgEngine];
        BOOL dPrefs  = [defs boolForKey:kKeyDbgPrefs];

        self->_debugEnabled             = master;
        self->_debugNotificationEnabled = (master || dNotif);
        self->_debugTTSAVEnabled        = (master || dTTSAV);
        self->_debugBurstEnabled        = (master || dBurst);
        self->_debugVolEnabled          = (master || dVol);
        self->_debugCancelEnabled       = (master || dCancel);
        self->_debugPolicyEnabled       = (master || dPolicy);
        self->_debugSpeakEnabled        = (master || dSpeak);
        self->_debugPokeEnabled         = (master || dPoke);
        self->_debugRouteEnabled        = (master || dRoute);
        self->_debugEngineEnabled       = (master || dEngine);
        self->_debugPrefsEnabled        = (master || dPrefs);
    }

    // Spam/burst control
    {
        id muteSpam = CFPreferencesCopyAppValue((__bridge CFStringRef)kKeyMuteSpam,
                                                (__bridge CFStringRef)kSNPrefsSuite);
        id spamCooldown = CFPreferencesCopyAppValue((__bridge CFStringRef)kKeySpamCooldownSeconds,
                                                    (__bridge CFStringRef)kSNPrefsSuite);

        self->_muteSpamEnabled = [muteSpam isKindOfClass:NSNumber.class] ? [muteSpam boolValue] : NO;

        double win = 12.0;
        if ([spamCooldown isKindOfClass:NSNumber.class]) {
            win = [(NSNumber *)spamCooldown doubleValue];
        }
        self->_spamCooldownSeconds = (win >= 0.0 ? win : 12.0);

        if (muteSpam) CFRelease(muteSpam);
        if (spamCooldown) CFRelease(spamCooldown);
    }

#if !__has_feature(objc_arc)
    [defs release];
#endif

    // Lightweight in-process broadcast (no logs)
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SNPrefsDidReload"
                                                        object:self
                                                      userInfo:@{
        @"pauseEnabled": @(_pauseEnabled),
        @"speechVolume": @(_speechVolume),
        @"useSystemVolume": @(_useSystemVolume),
        @"resetVolumeAfterSpeakEnabled": @(_resetVolumeAfterSpeakEnabled),
        @"debugEnabled": @(_debugEnabled),
        @"muteSpamEnabled": @(_muteSpamEnabled),
        @"spamCooldownSeconds": @(_spamCooldownSeconds)
    }];
}

#pragma mark - Convenience checks

- (BOOL)isSSIDTrusted:(NSString *)ssid {
    if (_trustedSSIDs.count == 0) return YES;
    if (ssid.length == 0) return NO;
    return [_trustedSSIDs containsObject:ssid];
}

- (BOOL)isBTTrusted:(NSString *)btName {
    if (_trustedBTDevices.count == 0) return YES;
    if (btName.length == 0) return NO;
    return [_trustedBTDevices containsObject:btName];
}

- (BOOL)isWiredAudioTrusted:(NSString *)deviceName {
    if (_trustedWiredAudioDevices.count == 0) return YES;
    if (deviceName.length == 0) return NO;
    return [_trustedWiredAudioDevices containsObject:deviceName];
}

#pragma mark - Synthesize readonlys

// Core behavior
- (BOOL)pauseEnabled { return _pauseEnabled; }
- (NSInteger)speechVolume { return _speechVolume; }
- (BOOL)useSystemVolume { return _useSystemVolume; }
- (BOOL)resetVolumeAfterSpeakEnabled { return _resetVolumeAfterSpeakEnabled; }

// Debug flags
- (BOOL)debugEnabled { return _debugEnabled; }
- (BOOL)debugNotificationEnabled { return _debugNotificationEnabled; }
- (BOOL)debugTTSAVEnabled { return _debugTTSAVEnabled; }
- (BOOL)debugBurstEnabled { return _debugBurstEnabled; }
- (BOOL)debugVolEnabled { return _debugVolEnabled; }
- (BOOL)debugCancelEnabled { return _debugCancelEnabled; }
- (BOOL)debugPolicyEnabled { return _debugPolicyEnabled; }
- (BOOL)debugSpeakEnabled { return _debugSpeakEnabled; }
- (BOOL)debugPokeEnabled { return _debugPokeEnabled; }
- (BOOL)debugRouteEnabled { return _debugRouteEnabled; }
- (BOOL)debugEngineEnabled { return _debugEngineEnabled; }
- (BOOL)debugPrefsEnabled { return _debugPrefsEnabled; }

// Trusted/misc
- (NSArray<NSString *> *)trustedSSIDs { return _trustedSSIDs; }
- (NSArray<NSString *> *)trustedBTDevices { return _trustedBTDevices; }
- (NSArray<NSString *> *)trustedWiredAudioDevices { return _trustedWiredAudioDevices; }
- (NSString *)messageFormat { return _messageFormat; }
- (BOOL)quietHoursEnabled { return _quietHoursEnabled; }
- (BOOL)queueEnabled { return _queueEnabled; }
- (BOOL)lockscreenPrivacyEnabled { return _lockscreenPrivacyEnabled; }
- (BOOL)muteSpamEnabled { return _muteSpamEnabled; }
- (double)spamCooldownSeconds { return _spamCooldownSeconds; }

#pragma mark - 

- (NSInteger)cpRouteLockSeconds
{
    id v = [[self _defs] objectForKey:kKeyCPRouteLockSeconds];
    NSInteger n = [v isKindOfClass:NSNumber.class] ? [(NSNumber *)v integerValue] : 5;
    if (n < 0) return 0;
    if (n > 10) return 10;
    return n;
}

- (NSInteger)ttsTailMs
{
    id v = [[self _defs] objectForKey:kKeyTTSTailMs];
    NSInteger n = [v isKindOfClass:NSNumber.class] ? [(NSNumber *)v integerValue] : 300;
    if (n < 0) return 0;
    if (n > 1000) return 1000;
    return n;
}

- (NSInteger)policyDebounceMs
{
    id v = [[self _defs] objectForKey:kKeyPolicyDebounceMs];
    NSInteger n = [v isKindOfClass:NSNumber.class] ? [(NSNumber *)v integerValue] : 150;
    if (n < 0) return 0;
    if (n > 500) return 500;
    return n;
}

- (NSInteger)interruptionTailMs
{
    id v = [[self _defs] objectForKey:kKeyInterruptionTailMs];
    NSInteger n = [v isKindOfClass:NSNumber.class] ? [(NSNumber *)v integerValue] : 1000;
    if (n < 0) return 0;
    if (n > 2000) return 2000;
    return n;
}


#pragma mark - Snapshots

// Synchronous snapshot for immediate use in the same stack frame.
// Returns an autoreleased, immutable NSDictionary. Do not store across async.
- (NSDictionary *)snapshot
{
    // Build a lightweight, immutable view of the current in-memory state.
    // Using literals keeps it CPU-cheap and avoids extra retains.
    NSDictionary *d = @{
        // Core behavior
        @"pauseEnabled": @(_pauseEnabled),
        @"speechVolume": @(_speechVolume),
        @"useSystemVolume": @(_useSystemVolume),
        @"resetVolumeAfterSpeakEnabled": @(_resetVolumeAfterSpeakEnabled),

        // Debug flags
        @"debugEnabled": @(_debugEnabled),
        @"debugNotificationEnabled": @(_debugNotificationEnabled),
        @"debugTTSAVEnabled": @(_debugTTSAVEnabled),
        @"debugBurstEnabled": @(_debugBurstEnabled),
        @"debugVolEnabled": @(_debugVolEnabled),
        @"debugCancelEnabled": @(_debugCancelEnabled),
        @"debugPolicyEnabled": @(_debugPolicyEnabled),
        @"debugSpeakEnabled": @(_debugSpeakEnabled),
        @"debugPokeEnabled": @(_debugPokeEnabled),
        @"debugRouteEnabled": @(_debugRouteEnabled),
        @"debugEngineEnabled": @(_debugEngineEnabled),
        @"debugPrefsEnabled": @(_debugPrefsEnabled),

        // Trusted / misc
        kSSIDsKey: _trustedSSIDs ?: @[],
        kBTKey: _trustedBTDevices ?: @[],
        kWiredAudioDevicesKey: _trustedWiredAudioDevices ?: @[],
        @"messageFormat": _messageFormat ?: @"{APP}: {TITLE}: {BODY}",
        @"quietHoursEnabled": @(_quietHoursEnabled),
        @"queueEnabled": @(_queueEnabled),
        @"lockscreenPrivacyEnabled": @(_lockscreenPrivacyEnabled),

        // Spam/burst control
        @"muteSpamEnabled": @(_muteSpamEnabled),
        @"spamCooldownSeconds": @(_spamCooldownSeconds),

        @"cpRouteLockSeconds": @([self cpRouteLockSeconds]),
        @"ttsTailMs": @([self ttsTailMs]),
        @"policyDebounceMs": @([self policyDebounceMs]),
        @"interruptionTailMs": @([self interruptionTailMs]),
    };

#if !__has_feature(objc_arc)
    return d;
#else
    return d;
#endif
}

// Owned snapshot for async/block/timer usage.
// Caller must release the returned dictionary when done.
- (NSDictionary *)newSnapshot
{
    NSDictionary *snap = [[self snapshot] copy];
    return snap;
}


@end
