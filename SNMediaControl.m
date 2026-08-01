// SNMediaControl.m — PRODUCTION (SBVolumeControl KVO for media volume; ringer mute via Darwin notify)
// Pure motorics only. No logging here.

#import "SNMediaControl.h"
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <notify.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import "SNRuntime.h"

#ifndef SNMUTESOURCE_ENUM
#define SNMUTESOURCE_ENUM 1
typedef NS_ENUM(NSUInteger, SNMuteSource) {
    SNMuteSourceUnknown = 0,
    SNMuteSourceNotify
};
#endif

#pragma mark - New MR Helper
// Minimal MR bridge: play command to specific app if possible
static inline int SN_MR_PlayCommand(void)
{
    return 100; // MRMediaRemoteCommandPlay (empirically stable)
}

static BOOL SN_MR_SendCommandToApp_Play(NSString *bundleID)
{
    if (bundleID.length == 0) return NO;

    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!h) return NO;

    typedef Boolean (*MRSendToAppFn)(int, CFStringRef, CFDictionaryRef);
    typedef Boolean (*MRSendFn)(int, CFDictionaryRef);

    MRSendToAppFn sendToApp = (MRSendToAppFn)dlsym(h, "MRMediaRemoteSendCommandToApp");
    if (sendToApp) {
        Boolean ok = sendToApp(SN_MR_PlayCommand(), (CFStringRef)bundleID, NULL);
        dlclose(h);
        return ok ? YES : NO;
    }

    MRSendFn sendGeneric = (MRSendFn)dlsym(h, "MRMediaRemoteSendCommand");
    if (sendGeneric) {
        Boolean ok = sendGeneric(SN_MR_PlayCommand(), NULL);
        dlclose(h);
        return ok ? YES : NO;
    }

    dlclose(h);
    return NO;
}

#pragma mark - Small ObjC helpers

static inline float SN_TryFloatNoArg(id obj, NSString *selName, float fallback) {
    if (!obj) return fallback;
    SEL sel = NSSelectorFromString(selName);
    if ([obj respondsToSelector:sel]) {
        @try { return ((float (*)(id, SEL))objc_msgSend)(obj, sel); }
        @catch (...) {}
    }
    return fallback;
}

#pragma mark - SBMediaController helpers (pause/resume/nowPlaying)

static id SN_SBMC_Shared(void) {
    @try {
        Class C = NSClassFromString(@"SBMediaController");
        if (!C) return nil;
        return SN_PerformNoArg(C, @"sharedInstance");
    } @catch (...) { return nil; }
}

static BOOL SN_SBMC_IsPlaying(id mc, BOOL *outVal) {
    if (!mc) return NO;
    for (NSString *sel in @[@"isPlaying", @"_isPlaying"]) {
        if (SN_PerformBoolNoArg(mc, sel, outVal)) return YES;
    }
    return NO;
}

static BOOL SN_SBMC_Pause(id mc) {
    if (!mc) return NO;
    for (NSString *sel in @[@"pause", @"_pause"]) {
        SEL s = NSSelectorFromString(sel);
        if ([mc respondsToSelector:s]) { ((void (*)(id,SEL))objc_msgSend)(mc,s); return YES; }
    }
    return NO;
}

static BOOL SN_SBMC_Play(id mc) {
    if (!mc) return NO;
    for (NSString *sel in @[@"play", @"_play", @"togglePlayPause"]) {
        SEL s = NSSelectorFromString(sel);
        if ([mc respondsToSelector:s]) { ((void (*)(id,SEL))objc_msgSend)(mc,s); return YES; }
    }
    return NO;
}

#pragma mark - Ringer mute cache (Darwin notify)

static volatile BOOL gMuteKnown = NO;
static volatile BOOL gMuteValue = NO;                 // YES = muted (silent), NO = ring
static volatile SNMuteSource gMuteSource = SNMuteSourceUnknown;
static NSTimeInterval gMuteTS = 0.0;

static dispatch_queue_t SNMuteQ(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("sn.mute.cache", DISPATCH_QUEUE_SERIAL); });
    return q;
}

static inline void SN_MuteSet(BOOL known, BOOL val, SNMuteSource src) {
    gMuteKnown  = known;
    gMuteValue  = val;
    gMuteSource = src;
    gMuteTS     = CACurrentMediaTime();
}

// Synchronous read from Darwin notify (fallback). On device: state==0 → muted, state==1 → ring.
static inline BOOL SN_ReadNotifyRinger(BOOL *outKnown, BOOL *outVal) {
    if (outKnown) *outKnown = NO;
    if (outVal)   *outVal   = NO;
    int token = 0;
    if (notify_register_check("com.apple.springboard.ringerstate", &token) != NOTIFY_STATUS_OK || token == 0) {
        return NO;
    }
    uint64_t state = 0;
    int g = notify_get_state(token, &state);
    notify_cancel(token);
    if (g != NOTIFY_STATUS_OK) return NO;
    if (outKnown) *outKnown = YES;
    if (outVal)   *outVal   = (state == 0);
    return YES;
}

#pragma mark - Volume via KVO on SBVolumeControl + route snapshot

// Live cache driven by KVO on SBVolumeControl
static volatile BOOL gSBKVOKnown = NO;
static volatile float gSBKVOEff  = -1.0f;
static volatile float gSBKVOVol  = -1.0f;
static volatile NSTimeInterval gSBKVOTS = 0.0;

// Lightweight output-route snapshot (used to detect CarAudio/Bluetooth)
static NSString *gLastOutputPortType = nil;

// Optional volume-change callback (owned by .xm; no logging here)
static SNVolChangedCB gVolCB = NULL;

// Sets system/media volume in 0.0–1.0 range using SpringBoard APIs.
// No logging; returns void, no-ops if not available.
static inline void sn_set_system_volume_0_1(float v)
{
    Class volCls = NSClassFromString(@"SBVolumeControl");
    if (!volCls) return;

    id vol = ((id(*)(id,SEL))objc_msgSend)(volCls, @selector(sharedInstance));
    if (!vol) return;

    if ([vol respondsToSelector:@selector(setMediaVolume:)]) {
        ((void(*)(id,SEL,float))objc_msgSend)(vol, @selector(setMediaVolume:), v);
        return;
    }
    if ([vol respondsToSelector:@selector(setVolume:)]) {
        ((void(*)(id,SEL,float))objc_msgSend)(vol, @selector(setVolume:), v);
        return;
    }
    // Fallback intentionally omitted: public APIs cannot set outputVolume.
}

@interface SNSBVCObserver : NSObject {
@private
    id _sbvc;  // SBVolumeControl instance (no weak in MRC)
}
@end

@implementation SNSBVCObserver

+ (instancetype)shared {
    static SNSBVCObserver *o;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ o = [self new]; });
    return o;
}

- (void)start {
    [self bindToSBVCIfPossible];
    static dispatch_source_t sRebindTimer = NULL;
    if (!sRebindTimer) {
        sRebindTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(sRebindTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 5ull * NSEC_PER_SEC, 100ull * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(sRebindTimer, ^{
            [self bindToSBVCIfPossible];
        });
        dispatch_resume(sRebindTimer);
    }
}

- (void)bindToSBVCIfPossible {
    @try {
        Class SBVC = NSClassFromString(@"SBVolumeControl");
        if (!SBVC) return;
        id inst = ((id (*)(id, SEL))objc_msgSend)(SBVC, NSSelectorFromString(@"sharedInstance"));
        if (!inst) return;
        if (_sbvc == inst) return;
        @try { [_sbvc removeObserver:self forKeyPath:@"volume"]; } @catch (...) {}
        @try { [_sbvc removeObserver:self forKeyPath:@"effectiveVolume"]; } @catch (...) {}
        _sbvc = inst;
        float eff = SN_TryFloatNoArg(_sbvc, @"effectiveVolume", -1.0f);
        float vol = SN_TryFloatNoArg(_sbvc, @"volume", -1.0f);
        if (eff >= 0.0f) { gSBKVOEff = eff; gSBKVOKnown = YES; gSBKVOTS = CACurrentMediaTime(); }
        if (vol >= 0.0f) { gSBKVOVol = vol; gSBKVOKnown = YES; gSBKVOTS = CACurrentMediaTime(); }
        @try { [_sbvc addObserver:self forKeyPath:@"volume" options:NSKeyValueObservingOptionNew context:NULL]; } @catch (...) {}
        @try { [_sbvc addObserver:self forKeyPath:@"effectiveVolume" options:NSKeyValueObservingOptionNew context:NULL]; } @catch (...) {}
    } @catch (...) {}
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context
{
    NSNumber *nv = change[NSKeyValueChangeNewKey];
    if (![nv isKindOfClass:[NSNumber class]]) return;
    float v = nv.floatValue;
    if (v < 0.0f) v = 0.0f;
    if (v > 1.0f) v = 1.0f;
    gSBKVOKnown = YES;
    gSBKVOTS = CACurrentMediaTime();
    if ([keyPath isEqualToString:@"effectiveVolume"]) {
        gSBKVOEff = v;
    } else if ([keyPath isEqualToString:@"volume"]) {
        gSBKVOVol = v;
    }
    SNVolChangedCB cb = gVolCB;
    if (cb) {
        cb([keyPath UTF8String], v);
    }
}

@end

#pragma mark - Implementation

@implementation SNMediaControl

+ (void)load {
    dispatch_async(SNMuteQ(), ^{
        int token = 0;
        int ok = notify_register_dispatch("com.apple.springboard.ringerstate", &token, SNMuteQ(), ^(int t){
            uint64_t state = 0;
            if (notify_get_state(t, &state) == NOTIFY_STATUS_OK) {
                SN_MuteSet(YES, (state == 0), SNMuteSourceNotify);
            }
        });
        if (ok == NOTIFY_STATUS_OK) {
            uint64_t state = 0;
            if (notify_get_state(token, &state) == NOTIFY_STATUS_OK) {
                SN_MuteSet(YES, (state == 0), SNMuteSourceNotify);
            }
        }
    });
    [[SNSBVCObserver shared] start];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_routeChanged:)
                                                 name:AVAudioSessionRouteChangeNotification
                                               object:nil];
    [self _refreshRouteSnapshot];
}

static void SN_UpdateMuteCacheIfNeeded(void) {
    if (gMuteKnown && (CACurrentMediaTime() - gMuteTS) < 10.0) return;
    dispatch_sync(SNMuteQ(), ^{
        if (gMuteKnown && (CACurrentMediaTime() - gMuteTS) < 10.0) return;
        BOOL k = NO, v = NO;
        if (SN_ReadNotifyRinger(&k, &v) && k) {
            SN_MuteSet(YES, v, SNMuteSourceNotify);
            return;
        }
        SN_MuteSet(NO, NO, SNMuteSourceUnknown);
    });
}

#pragma mark - Public API

static BOOL gPausedByUs = NO;

+ (id)_sbmcShared { return SN_SBMC_Shared(); }

+ (BOOL)isNowPlaying {
    @try {
        id mc = SN_SBMC_Shared();
        BOOL playing = NO;
        if (SN_SBMC_IsPlaying(mc, &playing)) return playing;
    } @catch (...) {}
    @try { return [[AVAudioSession sharedInstance] isOtherAudioPlaying]; } @catch (...) { return NO; }
}

+ (BOOL)pauseIfPlayingPhoneMedia {
    @try {
        id mc = SN_SBMC_Shared();
        BOOL playing = NO;
        if (SN_SBMC_IsPlaying(mc, &playing) && playing) {
            if (SN_SBMC_Pause(mc)) { gPausedByUs = YES; return YES; }
        }
        @try {
            if ([[AVAudioSession sharedInstance] isOtherAudioPlaying]) {
                if (SN_SBMC_Pause(mc)) { gPausedByUs = YES; return YES; }
            }
        } @catch (...) {}
    } @catch (...) {}
    return NO;
}

+ (void)resumeIfPausedPhoneMedia {
    if (!gPausedByUs) return;
    BOOL issued = NO;
    @try {
        issued = SN_SBMC_Play(SN_SBMC_Shared());
    } @catch (...) {}
    if (issued) gPausedByUs = NO;
}

+ (void)forcePlay {
    @try { (void)SN_SBMC_Play(SN_SBMC_Shared()); } @catch (...) {}
}

+ (void)remotePlayForBundle:(NSString *)bundleID {
    if (bundleID.length == 0) return;
    @try {
        // Prefer MRMediaRemote-to-app if available, else fall back to SBMC
        if (SN_MR_SendCommandToApp_Play(bundleID)) return;
        (void)SN_SBMC_Play(SN_SBMC_Shared());
    } @catch (...) {}
}

// Compatibility aliases
+ (BOOL)pauseIfPlaying { return [self pauseIfPlayingPhoneMedia]; }
+ (void)resumeIfPausedByUs { [self resumeIfPausedPhoneMedia]; }

+ (void)resetToken { gPausedByUs = NO; }

+ (float)currentMediaVolume {
    if (gSBKVOKnown && (CACurrentMediaTime() - gSBKVOTS) < 3600.0) {
        float cand = (gSBKVOEff >= 0.0f) ? gSBKVOEff : gSBKVOVol;
        if (cand >= 0.0f) return fmaxf(0.0f, fminf(1.0f, cand));
    }
    @try {
        Class SBVC = NSClassFromString(@"SBVolumeControl");
        if (SBVC) {
            id inst = ((id (*)(id, SEL))objc_msgSend)(SBVC, NSSelectorFromString(@"sharedInstance"));
            if (inst) {
                float v = SN_TryFloatNoArg(inst, @"effectiveVolume", -1.0f);
                if (v < 0.0f) v = SN_TryFloatNoArg(inst, @"volume", -1.0f);
                if (v >= 0.0f) return fmaxf(0.0f, fminf(1.0f, v));
            }
        }
    } @catch (...) {}
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        [s setCategory:AVAudioSessionCategoryAmbient error:nil];
        [s setActive:YES error:nil];
        float v = s.outputVolume;
        return fmaxf(0.0f, fminf(1.0f, v));
    } @catch (...) {
        return 0.0f;
    }
}

+ (float)currentRingerVolume {
    return [self currentMediaVolume];
}

+ (BOOL)ringerMutedKnown:(BOOL *)outKnown source:(SNMuteSource *)outSrc {
    SN_UpdateMuteCacheIfNeeded();
    if (outKnown) *outKnown = gMuteKnown;
    if (outSrc)   *outSrc   = gMuteSource;
    return gMuteValue;
}

+ (BOOL)ringerMutedKnown:(BOOL *)outKnown {
    SN_UpdateMuteCacheIfNeeded();
    if (outKnown) *outKnown = gMuteKnown;
    return gMuteValue;
}

+ (BOOL)isRingerMuted {
    BOOL known = NO;
    BOOL muted = [self ringerMutedKnown:&known source:NULL];
    return muted && known;
}

+ (NSString *)muteSourceName:(SNMuteSource)src {
    return (src == SNMuteSourceNotify) ? @"notify" : @"unknown";
}

#pragma mark - Volume callback & cached reads

+ (void)setVolumeChangeCallback:(SNVolChangedCB)cb {
    gVolCB = cb;
}

+ (float)lastEffectiveVolume {
    if (gSBKVOEff >= 0.0f) return gSBKVOEff;
    if (gSBKVOVol >= 0.0f) return gSBKVOVol;
    return [self currentMediaVolume];
}

+ (NSString *)lastOutputPortType {
    return gLastOutputPortType ?: @"";
}

#pragma mark - System volume setter (used via selector from .xm)

+ (void)setSystemOutputVolume:(float)value {
    float v = value;
    if (v < 0.f) v = 0.f;
    if (v > 1.f) v = 1.f;
    @try {
        Class AVC = NSClassFromString(@"AVSystemController");
        SEL sharedSel = NSSelectorFromString(@"sharedAVSystemController");
        id ctrl = (AVC && [AVC respondsToSelector:sharedSel]) ? ((id(*)(id,SEL))objc_msgSend)(AVC, sharedSel) : nil;
        SEL volSel = NSSelectorFromString(@"setVolumeTo:forCategory:");
        if (ctrl && [ctrl respondsToSelector:volSel]) {
            ((BOOL(*)(id,SEL,float,id))objc_msgSend)(ctrl, volSel, v, @"Audio/Video");
            return;
        }
    } @catch (...) {}
    @try {
        sn_set_system_volume_0_1(v);
    } @catch (...) {}
}

#pragma mark - Route snapshot (private)

+ (void)_routeChanged:(NSNotification *)n {
    [self _refreshRouteSnapshot];
}

+ (void)_refreshRouteSnapshot {
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        AVAudioSessionRouteDescription *r = s.currentRoute;
        AVAudioSessionPortDescription *out = r.outputs.firstObject;
        gLastOutputPortType = out.portType ?: @"";
    } @catch (...) {
        gLastOutputPortType = @"";
    }
}

@end
