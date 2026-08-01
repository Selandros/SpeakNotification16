// SNEngineAV.m
// Audio engine session control for TTS: prepare/activate/teardown.
// Pure motorics only. No logging here. CPU-cheap paths.

#import "SNEngineAV.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import "SNCancellation.h"
#import <stdatomic.h>
#include <stdint.h>
#include <string.h>
#import "SNMixPolicy.h" // for SNMixRouteKind

NSString * const kSNEngineAVDidFinish = @"SNEngineAVDidFinish";
NSString * const kSNEngineAVDidCancel = @"SNEngineAVDidCancel";
NSString * const kSNEngineAVDidSelectVoice = @"SNEngineAVDidSelectVoice";
NSString * const kSNEngineAVUserInfoTailSec = @"tailSec";
NSString * const kSNEngineAVUserInfoRouteType = @"routeType";
NSString * const kSNEngineAVUserInfoLang = @"lang";
NSString * const kSNEngineAVUserInfoVoiceName = @"voiceName";
NSString * const kSNEngineAVUserInfoVoiceIdentifier = @"voiceIdentifier";
NSString * const kSNEngineAVUserInfoVoiceSource = @"voiceSource";
NSString * const kSNEngineAVUserInfoTerminalReason = @"terminalReason";
NSString * const kSNEngineAVUserInfoTransaction = @"transaction";

static _Atomic double sLastKeepaliveSec = 0.0;

double SNEngineAVLastKeepaliveSec(void)
{
    return atomic_load(&sLastKeepaliveSec);
}

@interface SNEngineAV () <AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate>
@property (nonatomic, retain) AVSpeechSynthesizer *synth;
@property (nonatomic, assign) dispatch_queue_t snSerialQ; // serializes start/stop
@property (nonatomic, retain) AVAudioPlayer *a2dpWarmupPlayer;
@property (nonatomic, copy) SNA2DPWarmupCompletion a2dpWarmupCompletion;
@property (nonatomic, assign) uint64_t a2dpWarmupTransaction;
@property (nonatomic, assign) uint64_t a2dpWarmupStartedAtMS;
@property (nonatomic, assign) uint32_t a2dpWarmupGeneration;
- (void)sn_finishA2DPWarmupForTransaction:(uint64_t)transaction
                                 completed:(BOOL)completed
                                    reason:(NSString *)reason;
- (BOOL)sn_beginA2DPWarmupForTransaction:(uint64_t)transaction
                                 duration:(NSTimeInterval)duration
                              bufferBytes:(NSUInteger *)outBufferBytes
                               sampleRate:(double *)outSampleRate
                      playerInitialized:(BOOL *)outPlayerInitialized
                         preparedToPlay:(BOOL *)outPreparedToPlay
                            playerPlaying:(BOOL *)outPlayerPlaying
                             startGuard:(SNA2DPWarmupStartGuard)startGuard
                        startCompletion:(SNA2DPWarmupStartCompletion)startCompletion
                             failureStage:(NSString **)outFailureStage
                             failureError:(NSString **)outFailureError
                               completion:(SNA2DPWarmupCompletion)completion;
@end

// Cancellation generation for this engine layer
static _Atomic uint32_t sGenAV = 1;

// AudioSession prep/active state (class-wide)
static _Atomic BOOL sVoicePromptPrepared = NO;
static _Atomic BOOL sSessionActive = NO;
static _Atomic SNMixRouteKind sPreparedRoute = SNMixRouteUnknown;
static _Atomic BOOL sPreparedDuckOthers = NO;

// Finish keepalive to prevent tail clipping on route transitions
static dispatch_source_t sFinishKeepalive = nil;
static _Atomic BOOL sKeepaliveArmed = NO;

// Route-based keepalive tail
NSTimeInterval sn_finish_keepalive_sec(void)
{
    @try {
        NSString *p = sn_current_port();
        if ([p isEqualToString:AVAudioSessionPortCarAudio] ||
            [p rangeOfString:@"Car" options:NSCaseInsensitiveSearch].location != NSNotFound) return 2.65;
        if ([p rangeOfString:@"Bluetooth" options:NSCaseInsensitiveSearch].location != NSNotFound) return 0.45;
        if ([p rangeOfString:@"Head" options:NSCaseInsensitiveSearch].location != NSNotFound) return 0.40;
        return 0.30;
    } @catch (...) {}
    return 0.30;
}

// Cheap string sanitizer (filters NSNull/NSNumber/etc.)
static inline NSString *SNStringOrEmpty(id v)
{
    return [v isKindOfClass:NSString.class] ? (NSString *)v : @"";
}

// Fast language fallback (keeps predictable behavior)
static inline NSString *SNLangOrDefault(id v)
{
    return [v isKindOfClass:NSString.class] && [(NSString *)v length] ? (NSString *)v : @"sv-SE";
}

// ================== AudioSession helpers (no logging) ==================

static inline AVAudioSessionCategoryOptions sn_baseOptions(void)
{
    AVAudioSessionCategoryOptions opts = 0;
    opts |= AVAudioSessionCategoryOptionAllowBluetooth;
    opts |= AVAudioSessionCategoryOptionAllowBluetoothA2DP;
    return opts;
}

static inline AVAudioSessionCategoryOptions sn_categoryOptions(BOOL duckOthers)
{
    AVAudioSessionCategoryOptions opts = sn_baseOptions();
    // Speak-over: mix only; never force DuckOthers
    if (duckOthers) {
        opts |= AVAudioSessionCategoryOptionMixWithOthers;
    }
    return opts;
}

static inline NSString *sn_mode_for_route(SNMixRouteKind route)
{
    // VoicePrompt for CarPlay/HFP; SpokenAudio otherwise.
    switch (route) {
        case SNMixRouteCarPlay:
        case SNMixRouteBluetooth:
            return AVAudioSessionModeVoicePrompt;
        default:
            return AVAudioSessionModeSpokenAudio;
    }
}

static inline void SNWriteLE16(uint8_t *dst, uint16_t value)
{
    dst[0] = (uint8_t)(value & 0xff);
    dst[1] = (uint8_t)((value >> 8) & 0xff);
}

static inline void SNWriteLE32(uint8_t *dst, uint32_t value)
{
    dst[0] = (uint8_t)(value & 0xff);
    dst[1] = (uint8_t)((value >> 8) & 0xff);
    dst[2] = (uint8_t)((value >> 16) & 0xff);
    dst[3] = (uint8_t)((value >> 24) & 0xff);
}

static NSData *SNMakeA2DPZeroWAV(NSTimeInterval duration,
                                 NSUInteger *outBytes,
                                 double *outSampleRate)
{
    const uint32_t sampleRate = 48000;
    const uint16_t channels = 1;
    const uint16_t bitsPerSample = 16;
    const uint16_t bytesPerFrame = (uint16_t)(channels * (bitsPerSample / 8));
    uint64_t frameCount = (uint64_t)(duration * (NSTimeInterval)sampleRate + 0.5);
    if (frameCount == 0) frameCount = 1;
    uint64_t dataBytes64 = frameCount * bytesPerFrame;
    if (dataBytes64 > UINT32_MAX || dataBytes64 > (1024 * 1024)) return nil;

    uint32_t dataBytes = (uint32_t)dataBytes64;
    NSMutableData *wav = [NSMutableData dataWithLength:(NSUInteger)(44 + dataBytes)];
    if (!wav) return nil;

    uint8_t *header = (uint8_t *)wav.mutableBytes;
    memcpy(header + 0, "RIFF", 4);
    SNWriteLE32(header + 4, 36 + dataBytes);
    memcpy(header + 8, "WAVEfmt ", 8);
    SNWriteLE32(header + 16, 16);
    SNWriteLE16(header + 20, 1);
    SNWriteLE16(header + 22, channels);
    SNWriteLE32(header + 24, sampleRate);
    SNWriteLE32(header + 28, sampleRate * bytesPerFrame);
    SNWriteLE16(header + 32, bytesPerFrame);
    SNWriteLE16(header + 34, bitsPerSample);
    memcpy(header + 36, "data", 4);
    SNWriteLE32(header + 40, dataBytes);

    if (outBytes) *outBytes = wav.length;
    if (outSampleRate) *outSampleRate = sampleRate;
    return wav;
}

// ================== Simple TTS queue (no logging) ==================

@interface _SNTTSItem : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *lang;
@property (nonatomic, assign) uint32_t gen;
@property (nonatomic, assign) NSTimeInterval timeout;
@property (nonatomic, assign) uint64_t transaction;
@end
@implementation _SNTTSItem
- (void)dealloc
{
    self.text = nil;
    self.lang = nil;
    [super dealloc];
}
@end

static NSMutableArray<_SNTTSItem *> *sTTSQueue;        // FIFO queue
static _Atomic BOOL sSpeaking = NO;                    // speaking flag
static _Atomic uint64_t sActiveTransaction = 0;         // active outer transaction
static _Atomic uint64_t sLegacyTransactionSequence = 1; // non-zero IDs for legacy callers
static dispatch_source_t sSpeakTimeout = nil;          // fallback timer
static NSMutableDictionary<NSString *, NSString *> *sVoiceIdentifierCache;
static NSString *sResolvedEnglishPreferredIdentifier = nil;
static NSString *sResolvedEnglishPreferredSource = nil;

static inline BOOL SNLangIsEnglish(NSString *lang)
{
    return [lang isKindOfClass:NSString.class] && [lang hasPrefix:@"en"];
}

static char kSNUtteranceTransactionKey;

static inline uint64_t SNTransactionForUtterance(AVSpeechUtterance *utterance)
{
    NSNumber *value = utterance ? objc_getAssociatedObject(utterance, &kSNUtteranceTransactionKey) : nil;
    return [value respondsToSelector:@selector(unsignedLongLongValue)] ? value.unsignedLongLongValue : 0;
}

static inline void SNPostTerminalWakeup(NSString *reason, uint64_t txn)
{
    [[NSNotificationCenter defaultCenter] postNotificationName:kSNEngineAVDidCancel
                                                        object:nil
                                                      userInfo:@{
                                                          kSNEngineAVUserInfoTerminalReason: (reason ?: @"terminal"),
                                                          kSNEngineAVUserInfoTransaction: @(txn)
                                                      }];
}

static inline NSString *SNResolvedEnglishPreferredIdentifier(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bestIdentifier = nil;
        NSString *bestSource = nil;
        AVSpeechSynthesisVoice *compactFallback = nil;

        @try {
            for (AVSpeechSynthesisVoice *voice in [AVSpeechSynthesisVoice speechVoices]) {
                if (![voice.language isEqualToString:@"en-US"]) continue;
                if ([voice.name rangeOfString:@"Samantha" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;

                if ([voice.identifier isEqualToString:@"com.apple.voice.compact.en-US.Samantha"]) {
                    compactFallback = voice;
                    if (!bestIdentifier) {
                        bestIdentifier = voice.identifier;
                        bestSource = @"fixed-compact-fallback";
                    }
                    continue;
                }

                BOOL isEnhanced = NO;
                @try {
                    isEnhanced = (voice.quality == AVSpeechSynthesisVoiceQualityEnhanced);
                } @catch (__unused id e) {
                    isEnhanced = NO;
                }

                if (isEnhanced) {
                    bestIdentifier = voice.identifier;
                    bestSource = @"fixed-enhanced";
                    break;
                }

                if (!bestIdentifier) {
                    bestIdentifier = voice.identifier;
                    bestSource = @"fixed-compact-fallback";
                }
            }
        } @catch (__unused id e) {
            bestIdentifier = nil;
            bestSource = nil;
        }

        if (!bestIdentifier && compactFallback.identifier.length) {
            bestIdentifier = compactFallback.identifier;
            bestSource = @"fixed-compact-fallback";
        }

        sResolvedEnglishPreferredIdentifier = [bestIdentifier copy];
        sResolvedEnglishPreferredSource = [bestSource copy];
        if (!sResolvedEnglishPreferredIdentifier.length) {
            sResolvedEnglishPreferredIdentifier = @"com.apple.voice.compact.en-US.Samantha";
            sResolvedEnglishPreferredSource = @"fixed-compact-fallback";
        }
    });
    return sResolvedEnglishPreferredIdentifier;
}

static inline NSString *SNResolvedEnglishPreferredSource(void)
{
    (void)SNResolvedEnglishPreferredIdentifier();
    return sResolvedEnglishPreferredSource;
}

@implementation SNEngineAV

+ (void)sn_prepareSessionIfNeeded {}
+ (void)sn_deactivateSessionIfActive {}

+ (instancetype)shared
{
    static SNEngineAV *g;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g = [SNEngineAV new];
    });
    return g;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _synth = [[AVSpeechSynthesizer alloc] init];
        _synth.delegate = self;
        _snSerialQ = dispatch_queue_create("sn.tts.serial", DISPATCH_QUEUE_SERIAL);
        if (!sTTSQueue) {
            sTTSQueue = [NSMutableArray new];
        }
        if (!sVoiceIdentifierCache) {
            sVoiceIdentifierCache = [NSMutableDictionary new];
        }
    }
    return self;
}

// Keep for back-compat; synth manages its own short-lived session paths on older systems.
- (void)sn_prepareSessionIfNeeded {}
- (void)sn_deactivateSessionIfActive {}

// ================== Public class API (AudioSession) ==================

+ (BOOL)prepareVoicePromptForRoute:(SNMixRouteKind)route
                       duckOthers:(BOOL)duckOthers
{
    if (atomic_load(&sVoicePromptPrepared) &&
        atomic_load(&sPreparedRoute) == route &&
        atomic_load(&sPreparedDuckOthers) == duckOthers) {
        return YES;
    }

    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];

        AVAudioSessionCategoryOptions opts = sn_categoryOptions(duckOthers);
        [s setCategory:AVAudioSessionCategoryPlayback
            withOptions:opts
                  error:NULL];

        NSString *mode = sn_mode_for_route(route);
        [s setMode:mode error:NULL];

        atomic_store(&sPreparedRoute, route);
        atomic_store(&sPreparedDuckOthers, duckOthers);
        atomic_store(&sVoicePromptPrepared, YES);
        return YES;
    } @catch (...) {
        return YES;
    }
}

+ (BOOL)activateForTTSWithDuck:(BOOL)duckMode
{
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        AVAudioSessionCategory cat = AVAudioSessionCategoryPlayback;
        AVAudioSessionCategoryOptions opts = 0;
        if (duckMode) {
            opts |= AVAudioSessionCategoryOptionMixWithOthers;
            opts |= AVAudioSessionCategoryOptionAllowBluetooth;
            opts |= AVAudioSessionCategoryOptionAllowBluetoothA2DP;
        } else {
            opts |= AVAudioSessionCategoryOptionAllowBluetooth;
            opts |= AVAudioSessionCategoryOptionAllowBluetoothA2DP;
        }
        [s setCategory:cat withOptions:opts error:nil];
        [s setMode:AVAudioSessionModeDefault error:nil];
        BOOL ok = [s setActive:YES error:nil];
        if (ok) atomic_store(&sSessionActive, YES);
        return ok;
    } @catch (...) {
        return YES;
    }
}

+ (BOOL)activateForTTS
{
    if (!atomic_load(&sVoicePromptPrepared)) {
        (void)[self prepareVoicePromptForRoute:SNMixRouteSpeaker duckOthers:NO];
    }

    if (atomic_load(&sSessionActive)) return YES;

    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        BOOL ok = [s setActive:YES error:NULL];
        if (ok) atomic_store(&sSessionActive, YES);
        return ok;
    } @catch (...) {
        return NO;
    }
}

- (void)sn_finishA2DPWarmupForTransaction:(uint64_t)transaction
                                 completed:(BOOL)completed
                                    reason:(NSString *)reason
{
    if (!transaction || self.a2dpWarmupTransaction != transaction) return;

    AVAudioPlayer *player = [self.a2dpWarmupPlayer retain];
    player.delegate = nil;
    if (player.isPlaying) [player stop];

    SNA2DPWarmupCompletion completion = [self.a2dpWarmupCompletion copy];
    uint64_t startedAtMS = self.a2dpWarmupStartedAtMS;
    uint64_t nowMS = (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000.0);
    uint64_t elapsedMs = (startedAtMS && nowMS >= startedAtMS) ? (nowMS - startedAtMS) : 0;

    self.a2dpWarmupPlayer = nil;
    self.a2dpWarmupCompletion = nil;
    self.a2dpWarmupTransaction = 0;
    self.a2dpWarmupStartedAtMS = 0;
    self.a2dpWarmupGeneration += 1;

    if (completion) completion(transaction, completed, reason ?: @"unknown", elapsedMs);
#if !__has_feature(objc_arc)
    [completion release];
    [player release];
#endif
}

- (BOOL)sn_beginA2DPWarmupForTransaction:(uint64_t)transaction
                                 duration:(NSTimeInterval)duration
                              bufferBytes:(NSUInteger *)outBufferBytes
                               sampleRate:(double *)outSampleRate
                      playerInitialized:(BOOL *)outPlayerInitialized
                         preparedToPlay:(BOOL *)outPreparedToPlay
                            playerPlaying:(BOOL *)outPlayerPlaying
                            startGuard:(SNA2DPWarmupStartGuard)startGuard
                       startCompletion:(SNA2DPWarmupStartCompletion)startCompletion
                             failureStage:(NSString **)outFailureStage
                             failureError:(NSString **)outFailureError
                               completion:(SNA2DPWarmupCompletion)completion
{
    if (outBufferBytes) *outBufferBytes = 0;
    if (outSampleRate) *outSampleRate = 0;
    if (outPlayerInitialized) *outPlayerInitialized = NO;
    if (outPreparedToPlay) *outPreparedToPlay = NO;
    if (outPlayerPlaying) *outPlayerPlaying = NO;
    if (outFailureStage) *outFailureStage = nil;
    if (outFailureError) *outFailureError = nil;
    if (!transaction || duration <= 0 || !completion || self.a2dpWarmupTransaction != 0) {
        if (outFailureStage) *outFailureStage = @"player";
        if (outFailureError) *outFailureError = @"busy";
        return NO;
    }

    if (startGuard && !startGuard(transaction)) {
        if (startCompletion) {
            startCompletion(transaction, NO, NO, NO, NO, 0, 0, @"guard", @"notReady");
        }
        completion(transaction, NO, @"guard", 0);
        return YES;
    }

    NSUInteger bufferBytes = 0;
    double sampleRate = 0;
    NSData *wav = SNMakeA2DPZeroWAV(duration, &bufferBytes, &sampleRate);
    if (outBufferBytes) *outBufferBytes = bufferBytes;
    if (outSampleRate) *outSampleRate = sampleRate;
    if (!wav) {
        if (outFailureStage) *outFailureStage = @"buffer";
        if (outFailureError) *outFailureError = @"build";
        if (startCompletion) {
            startCompletion(transaction, NO, NO, NO, NO, 0,
                            sampleRate,
                            @"buffer", @"build");
        }
        completion(transaction, NO, @"buffer", 0);
        return YES;
    }

    NSError *error = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithData:wav error:&error];
    BOOL playerInitialized = (player != nil);
    if (outPlayerInitialized) *outPlayerInitialized = playerInitialized;
    if (!player || ![player prepareToPlay]) {
        if (outFailureStage) *outFailureStage = @"player";
        if (outFailureError) *outFailureError = error.localizedDescription ?: @"prepare";
#if !__has_feature(objc_arc)
        [player release];
#endif
        if (startCompletion) {
            startCompletion(transaction,
                            playerInitialized,
                            (outPreparedToPlay ? *outPreparedToPlay : NO),
                            NO,
                            NO,
                            bufferBytes,
                            sampleRate,
                            @"player",
                            (error.localizedDescription ?: @"prepare"));
        }
        completion(transaction, NO, @"player", 0);
        return YES;
    }
    BOOL preparedToPlay = YES;
    if (outPreparedToPlay) *outPreparedToPlay = preparedToPlay;

    player.delegate = self;
    self.a2dpWarmupPlayer = player;
    self.a2dpWarmupCompletion = completion;
    self.a2dpWarmupTransaction = transaction;
    self.a2dpWarmupStartedAtMS = (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000.0);
    self.a2dpWarmupGeneration += 1;
    uint32_t generation = self.a2dpWarmupGeneration;

    BOOL started = [player play];
    BOOL playing = player.isPlaying;
    if (outPlayerPlaying) *outPlayerPlaying = playing;
#if !__has_feature(objc_arc)
    [player release];
#endif
    if (!started || !playing) {
        if (outFailureStage) *outFailureStage = @"player";
        if (outFailureError) *outFailureError = (!started ? @"play" : @"notPlaying");
        NSString *errorText = (!started ? @"play" : @"notPlaying");
        if (startCompletion) {
            startCompletion(transaction,
                            playerInitialized,
                            preparedToPlay,
                            started,
                            playing,
                            bufferBytes,
                            sampleRate,
                            @"player",
                            errorText);
        }
        [self sn_finishA2DPWarmupForTransaction:transaction completed:NO reason:errorText];
        return YES;
    }

    if (startCompletion) {
        startCompletion(transaction,
                        playerInitialized,
                        preparedToPlay,
                        started,
                        playing,
                        bufferBytes,
                        sampleRate,
                        nil,
                        nil);
    }

    __unsafe_unretained SNEngineAV *me = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)((duration + 0.25) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!me || me.a2dpWarmupGeneration != generation ||
            me.a2dpWarmupTransaction != transaction) return;
        [me sn_finishA2DPWarmupForTransaction:transaction completed:NO reason:@"timeout"];
    });
    return YES;
}

+ (BOOL)beginA2DPWarmupForTransaction:(uint64_t)transaction
                              duration:(NSTimeInterval)duration
                           bufferBytes:(NSUInteger *)outBufferBytes
                            sampleRate:(double *)outSampleRate
                   playerInitialized:(BOOL *)outPlayerInitialized
                      preparedToPlay:(BOOL *)outPreparedToPlay
                         playerPlaying:(BOOL *)outPlayerPlaying
                          startGuard:(SNA2DPWarmupStartGuard)startGuard
                     startCompletion:(SNA2DPWarmupStartCompletion)startCompletion
                          failureStage:(NSString **)outFailureStage
                          failureError:(NSString **)outFailureError
                            completion:(SNA2DPWarmupCompletion)completion
{
    if (!transaction || duration <= 0 || !completion || !startCompletion) {
        if (outFailureStage) *outFailureStage = @"player";
        if (outFailureError) *outFailureError = @"invalidRequest";
        return NO;
    }

    SNEngineAV *engine = [self shared];
    if ([NSThread isMainThread]) {
        return [engine sn_beginA2DPWarmupForTransaction:transaction
                                               duration:duration
                                            bufferBytes:outBufferBytes
                                             sampleRate:outSampleRate
                                       playerInitialized:outPlayerInitialized
                                          preparedToPlay:outPreparedToPlay
                                             playerPlaying:outPlayerPlaying
                                             startGuard:startGuard
                                        startCompletion:startCompletion
                                           failureStage:outFailureStage
                                           failureError:outFailureError
                                             completion:completion];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [engine sn_beginA2DPWarmupForTransaction:transaction
                                         duration:duration
                                      bufferBytes:NULL
                                       sampleRate:NULL
                                 playerInitialized:NULL
                                    preparedToPlay:NULL
                                       playerPlaying:NULL
                                       startGuard:startGuard
                                  startCompletion:startCompletion
                                     failureStage:NULL
                                     failureError:NULL
                                       completion:completion];
    });
    return YES;
}

+ (void)teardownVoicePrompt
{
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];

        // Always deactivate and notify others; this is the single exit for TTS session.
        [s setActive:NO
          withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                error:NULL];

        // Restore a neutral category/mode so the system can fully return to normal.
        @try { [s setCategory:AVAudioSessionCategoryAmbient error:NULL]; } @catch (...) {}
        @try { [s setMode:AVAudioSessionModeDefault error:NULL]; } @catch (...) {}

    } @catch (...) {}

    atomic_store(&sSessionActive, NO);
    atomic_store(&sVoicePromptPrepared, NO);
    atomic_store(&sPreparedDuckOthers, NO);
    atomic_store(&sPreparedRoute, SNMixRouteUnknown);
}

// ================== Public class API (Speech) ==================

+ (BOOL)speakTitle:(NSString *)title body:(NSString *)body lang:(NSString *)lang
{
    uint64_t sequence = atomic_fetch_add_explicit(&sLegacyTransactionSequence, 1, memory_order_relaxed);
    return [self speakTitle:title body:body lang:lang transaction:((1ull << 63) | sequence)];
}

+ (BOOL)speakTitle:(NSString *)title body:(NSString *)body lang:(NSString *)lang transaction:(uint64_t)txn
{
    NSString *t = SNStringOrEmpty(title);
    NSString *b = SNStringOrEmpty(body);
    NSString *l = SNLangOrDefault(lang);

    NSString *text = b.length ? b : (t.length ? t : @"");
    if (text.length == 0) {
        SNPostTerminalWakeup(@"empty", txn);
        return NO;
    }

    uint32_t myGen = atomic_load_explicit(&sGenAV, memory_order_relaxed);
    return [[self shared] enqueueText:text lang:l generation:myGen transaction:txn];
}

+ (void)stop
{
    [self stopTransaction:0];
}

+ (void)stopTransaction:(uint64_t)txn
{
    [[self shared] stopNowForTransaction:txn];
}

+ (void)cancelAll
{
    (void)atomic_fetch_add_explicit(&sGenAV, 1, memory_order_relaxed);

    SNEngineAV *me = [self shared];
    dispatch_async(me.snSerialQ, ^{
        @autoreleasepool {
            [sTTSQueue removeAllObjects];
            [me sn_cancelTimeoutLocked];
            atomic_store(&sSpeaking, NO);
        }
    });
}

// ================== Queue implementation ==================

- (BOOL)enqueueText:(NSString *)text lang:(NSString *)lang generation:(uint32_t)gen transaction:(uint64_t)txn
{
    if (text.length == 0) {
        SNPostTerminalWakeup(@"empty", txn);
        return NO;
    }

    __unsafe_unretained SNEngineAV *me = self;
    dispatch_async(self.snSerialQ, ^{
        @autoreleasepool {
            if (atomic_load_explicit(&sGenAV, memory_order_relaxed) != gen) return;

            _SNTTSItem *it = [_SNTTSItem new];
            it.text = text;
            it.lang = lang;
            it.gen = gen;
            it.timeout = 25.0;
            it.transaction = txn;

            [sTTSQueue addObject:it];
            [it release];
            if (!atomic_load(&sSpeaking)) {
                [me sn_startNextLocked];
            }
        }
    });
    return YES;
}

- (void)sn_startNextLocked
{
    if (sTTSQueue.count == 0) {
        atomic_store(&sSpeaking, NO);
        [self sn_cancelTimeoutLocked];
        return;
    }

    // New speech is about to start: cancel any pending keepalive
    [self sn_cancelFinishKeepaliveLocked];

    _SNTTSItem *it = [sTTSQueue.firstObject retain];
    [sTTSQueue removeObjectAtIndex:0];

    if (atomic_load_explicit(&sGenAV, memory_order_relaxed) != it.gen) {
        [it release];
        [self sn_startNextLocked];
        return;
    }

    atomic_store(&sSpeaking, YES);
    atomic_store(&sActiveTransaction, it.transaction);
    [self sn_cancelTimeoutLocked];

    __unsafe_unretained SNEngineAV *me = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            if (atomic_load_explicit(&sGenAV, memory_order_relaxed) != it.gen) {
                uint64_t expectedTxn = it.transaction;
                (void)atomic_compare_exchange_strong(&sActiveTransaction, &expectedTxn, 0);
                dispatch_async(me.snSerialQ, ^{ [me sn_startNextLocked]; });
                return;
            }
            if (!me || !me.synth) {
                uint64_t expectedTxn = it.transaction;
                (void)atomic_compare_exchange_strong(&sActiveTransaction, &expectedTxn, 0);
                SNPostTerminalWakeup(@"noSpeech", it.transaction);
                dispatch_async(me.snSerialQ, ^{ [me sn_startNextLocked]; });
                return;
            }

            AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:it.text];
            objc_setAssociatedObject(u, &kSNUtteranceTransactionKey, @(it.transaction), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            AVSpeechSynthesisVoice *v = nil;
            BOOL isEnglish = SNLangIsEnglish(it.lang);
            NSString *voiceSource = @"fallback";
            if (it.lang.length) {
                @try {
                    if (isEnglish) {
                        NSString *preferredIdentifier = SNResolvedEnglishPreferredIdentifier();
                        if (preferredIdentifier.length) {
                            v = [AVSpeechSynthesisVoice voiceWithIdentifier:preferredIdentifier];
                            if (v) {
                                voiceSource = SNResolvedEnglishPreferredSource() ?: @"fixed-enhanced";
                            }
                        }
                        if (!v) {
                            v = [AVSpeechSynthesisVoice voiceWithIdentifier:@"com.apple.voice.compact.en-US.Samantha"];
                            if (v) {
                                voiceSource = @"fixed-compact-fallback";
                            }
                        }
                    }
                    if (!v) {
                        NSString *cachedIdentifier = [sVoiceIdentifierCache objectForKey:it.lang];
                        if (cachedIdentifier.length) {
                            v = [AVSpeechSynthesisVoice voiceWithIdentifier:cachedIdentifier];
                            if (v) {
                                voiceSource = @"cache";
                            }
                        }
                    }
                    if (!v) {
                        v = [AVSpeechSynthesisVoice voiceWithLanguage:it.lang];
                        NSString *resolvedIdentifier = v.identifier;
                        if (resolvedIdentifier.length) {
                            [sVoiceIdentifierCache setObject:resolvedIdentifier forKey:it.lang];
                        }
                        if (v) {
                            voiceSource = @"fallback";
                        }
                    }
                } @catch (__unused id e) {
                    v = nil;
                }
            }
            if (v) {
                u.voice = v;
                NSDictionary *info = @{
                    kSNEngineAVUserInfoLang: (it.lang ?: @""),
                    kSNEngineAVUserInfoVoiceName: (v.name ?: @""),
                    kSNEngineAVUserInfoVoiceIdentifier: (v.identifier ?: @""),
                    kSNEngineAVUserInfoVoiceSource: voiceSource
                };
                [[NSNotificationCenter defaultCenter] postNotificationName:kSNEngineAVDidSelectVoice object:nil userInfo:info];
            } else {
                NSDictionary *info = @{
                    kSNEngineAVUserInfoLang: (it.lang ?: @""),
                    kSNEngineAVUserInfoVoiceName: @"-",
                    kSNEngineAVUserInfoVoiceIdentifier: @"-",
                    kSNEngineAVUserInfoVoiceSource: @"unavailable"
                };
                [[NSNotificationCenter defaultCenter] postNotificationName:kSNEngineAVDidSelectVoice object:nil userInfo:info];
            }
            u.rate = AVSpeechUtteranceDefaultSpeechRate;

            [SNCancellation resetMuteCancelLatch];
            [SNCancellation setSpeaking:YES];

            dispatch_async(me.snSerialQ, ^{
                [me sn_startTimeoutLocked:it.timeout transaction:it.transaction generation:it.gen];
                [me sn_verifyStartedLockedAfter:0.5 transaction:it.transaction generation:it.gen]; // start-watchdog
            });

            [me.synth speakUtterance:u];
        }
    });
    [it release];
}

- (void)sn_startTimeoutLocked:(NSTimeInterval)sec transaction:(uint64_t)txn generation:(uint32_t)gen
{
    if (sec <= 0) return;
    sSpeakTimeout = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.snSerialQ);
    dispatch_source_set_timer(sSpeakTimeout,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (1ull * NSEC_PER_SEC));
    __unsafe_unretained SNEngineAV *me = self;
    dispatch_source_set_event_handler(sSpeakTimeout, ^{
        if (atomic_load_explicit(&sGenAV, memory_order_relaxed) != gen ||
            atomic_load(&sActiveTransaction) != txn) {
            [me sn_cancelTimeoutLocked];
            return;
        }
        [me sn_cancelTimeoutLocked];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (atomic_load_explicit(&sGenAV, memory_order_relaxed) != gen ||
                atomic_load(&sActiveTransaction) != txn) return;

            BOOL stopRequested = NO;
            @try { stopRequested = [me.synth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate]; }
            @catch (__unused id e) { stopRequested = NO; }
            atomic_store(&sSpeaking, NO);
            [SNCancellation setSpeaking:NO];
            uint64_t expectedTxn = txn;
            (void)atomic_compare_exchange_strong(&sActiveTransaction, &expectedTxn, 0);
            SNPostTerminalWakeup(@"timeout", txn);
            if (!stopRequested) {
                dispatch_async(me.snSerialQ, ^{ [me sn_startNextLocked]; });
            }
        });
    });
    dispatch_resume(sSpeakTimeout);
}

- (void)sn_cancelTimeoutLocked
{
    if (sSpeakTimeout) {
        dispatch_source_t timeout = sSpeakTimeout;
        sSpeakTimeout = nil;
        dispatch_source_cancel(timeout);
        dispatch_release(timeout);
    }
}

// Verifies that speech actually started; if not, advance the queue
- (void)sn_verifyStartedLockedAfter:(NSTimeInterval)delay transaction:(uint64_t)txn generation:(uint32_t)gen
{
    if (delay <= 0) delay = 0.8; // give AV more time to start
    __unsafe_unretained SNEngineAV *me = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), self.snSerialQ, ^{
        @autoreleasepool {
            if (!me) return;
            if (atomic_load_explicit(&sGenAV, memory_order_relaxed) != gen ||
                atomic_load(&sActiveTransaction) != txn) return;
            BOOL speakingNow = NO;
            @try { speakingNow = me.synth.isSpeaking; } @catch (__unused id e) { speakingNow = NO; }
            if (!speakingNow) {
                // do a second short confirmation before advancing
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)), self.snSerialQ, ^{
                    if (atomic_load_explicit(&sGenAV, memory_order_relaxed) != gen ||
                        atomic_load(&sActiveTransaction) != txn) return;
                    BOOL speakingNow2 = NO;
                    @try { speakingNow2 = me.synth.isSpeaking; } @catch (__unused id e) { speakingNow2 = NO; }
                    if (!speakingNow2) {
                        [me sn_cancelTimeoutLocked];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (atomic_load_explicit(&sGenAV, memory_order_relaxed) != gen ||
                                atomic_load(&sActiveTransaction) != txn) return;

                            BOOL stopRequested = NO;
                            @try { stopRequested = [me.synth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate]; }
                            @catch (__unused id e) { stopRequested = NO; }
                            atomic_store(&sSpeaking, NO);
                            [SNCancellation setSpeaking:NO];
                            uint64_t expectedTxn = txn;
                            (void)atomic_compare_exchange_strong(&sActiveTransaction, &expectedTxn, 0);
                            SNPostTerminalWakeup(@"watchdog", txn);
                            if (!stopRequested) {
                                dispatch_async(me.snSerialQ, ^{ [me sn_startNextLocked]; });
                            }
                        });
                    }
                });
            }
        }
    });
}

// Arms a short keepalive; must be called on snSerialQ
- (void)sn_armFinishKeepaliveLocked:(NSTimeInterval)sec
{
    if (sec <= 0) sec = 0.30;
    atomic_store(&sLastKeepaliveSec, sec);
    if (sFinishKeepalive) {
        dispatch_source_cancel(sFinishKeepalive);
    #if !__has_feature(objc_arc)
        dispatch_release(sFinishKeepalive);
    #endif
        sFinishKeepalive = nil;
    }
    atomic_store(&sKeepaliveArmed, YES);

    __unsafe_unretained SNEngineAV *me = self;
    sFinishKeepalive = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.snSerialQ);
    dispatch_source_set_timer(sFinishKeepalive,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (1ull * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(sFinishKeepalive, ^{
        atomic_store(&sKeepaliveArmed, NO);
        if (!me) {
            dispatch_source_cancel(sFinishKeepalive);
        #if !__has_feature(objc_arc)
            dispatch_release(sFinishKeepalive);
        #endif
            sFinishKeepalive = nil;
            return;
        }
        BOOL speakingNow = NO;
        @try { speakingNow = me.synth.isSpeaking; } @catch (__unused id e) { speakingNow = NO; }
        if (!speakingNow && sTTSQueue.count == 0) {
            [SNEngineAV teardownVoicePrompt];
        }
        dispatch_source_cancel(sFinishKeepalive);
    #if !__has_feature(objc_arc)
        dispatch_release(sFinishKeepalive);
    #endif
        sFinishKeepalive = nil;
    });
    dispatch_resume(sFinishKeepalive);
}

// Cancels keepalive; must be called on snSerialQ
- (void)sn_cancelFinishKeepaliveLocked
{
    if (sFinishKeepalive) {
        dispatch_source_cancel(sFinishKeepalive);
    #if !__has_feature(objc_arc)
        dispatch_release(sFinishKeepalive);
    #endif
        sFinishKeepalive = nil;
    }
    atomic_store(&sKeepaliveArmed, NO);
}

// ================== Stop / dealloc ==================

- (void)stopNow
{
    [self stopNowForTransaction:0];
}

- (void)stopNowForTransaction:(uint64_t)txn
{
    __unsafe_unretained SNEngineAV *me = self;
    uint64_t stopTxn = txn ? txn : atomic_load(&sActiveTransaction);
    (void)atomic_fetch_add_explicit(&sGenAV, 1, memory_order_relaxed);

    dispatch_sync(self.snSerialQ, ^{
        @autoreleasepool {
            [sTTSQueue removeAllObjects];
            [self sn_cancelTimeoutLocked];
            [self sn_cancelFinishKeepaliveLocked];
            atomic_store(&sSpeaking, NO);
        }
    });

    void (^stopOnMain)(void) = ^{
        @autoreleasepool {
            uint64_t warmupTxn = me.a2dpWarmupTransaction;
            if (warmupTxn && (!txn || warmupTxn == txn)) {
                [me sn_finishA2DPWarmupForTransaction:warmupTxn completed:NO reason:@"cancel"];
            }
            if (me && me.synth && me.synth.isSpeaking) {
                [me.synth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
            }
            [SNCancellation setSpeaking:NO];
            uint64_t expectedTxn = stopTxn;
            (void)atomic_compare_exchange_strong(&sActiveTransaction, &expectedTxn, 0);
        }
    };

    if ([NSThread isMainThread]) {
        stopOnMain();
    } else {
        dispatch_sync(dispatch_get_main_queue(), stopOnMain);
    }
}

- (void)dealloc
{
    __unsafe_unretained SNEngineAV *me = self;
    (void)atomic_fetch_add_explicit(&sGenAV, 1, memory_order_relaxed);

    dispatch_sync(self.snSerialQ, ^{
        @autoreleasepool {
            dispatch_async(dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    if (me.a2dpWarmupTransaction) {
                        [me sn_finishA2DPWarmupForTransaction:me.a2dpWarmupTransaction completed:NO reason:@"dealloc"];
                    }
                    if (me.synth && me.synth.isSpeaking) {
                        [me.synth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
                    }
                    [SNCancellation setSpeaking:NO];
                    [SNEngineAV teardownVoicePrompt];
                    me.synth.delegate = nil;
                    [me.synth release];
                    me.synth = nil;
                }
            });
        }
    });

#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag
{
    __unsafe_unretained SNEngineAV *me = self;
    uint64_t transaction = self.a2dpWarmupTransaction;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!me || !transaction || me.a2dpWarmupPlayer != player) return;
        [me sn_finishA2DPWarmupForTransaction:transaction completed:flag reason:(flag ? @"finished" : @"player")];
    });
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *__unused)error
{
    __unsafe_unretained SNEngineAV *me = self;
    uint64_t transaction = self.a2dpWarmupTransaction;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!me || !transaction || me.a2dpWarmupPlayer != player) return;
        [me sn_finishA2DPWarmupForTransaction:transaction completed:NO reason:@"player"];
    });
}

// ================== AVSpeechSynthesizerDelegate ==================

- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didFinishSpeechUtterance:(AVSpeechUtterance *)u
{
    uint64_t txn = SNTransactionForUtterance(u);
    uint64_t activeTxn = atomic_load(&sActiveTransaction);
    BOOL ownsActiveSpeech = (txn != 0 && txn == activeTxn);
    if (ownsActiveSpeech) {
        [SNCancellation setSpeaking:NO];
    }

    __unsafe_unretained SNEngineAV *me = self;
    dispatch_async(self.snSerialQ, ^{
        uint64_t currentTxn = atomic_load(&sActiveTransaction);
        BOOL ownsCurrentSpeech = (txn != 0 && txn == currentTxn);
        if (!ownsCurrentSpeech) {
            [[NSNotificationCenter defaultCenter] postNotificationName:kSNEngineAVDidFinish
                                                                object:nil
                                                              userInfo:@{
                                                                  kSNEngineAVUserInfoTransaction: @(txn)
                                                              }];
            if (currentTxn == 0 && sTTSQueue.count > 0) [me sn_startNextLocked];
            return;
        }

        atomic_store(&sSpeaking, NO);
        uint64_t expectedTxn = txn;
        (void)atomic_compare_exchange_strong(&sActiveTransaction, &expectedTxn, 0);
        [me sn_cancelTimeoutLocked];

        BOOL speakingNow = NO;
        @try { speakingNow = me.synth.isSpeaking; } @catch (...) {}

        BOOL hasNext = (speakingNow || sTTSQueue.count > 0);
        if (!hasNext) {
            [me sn_armFinishKeepaliveLocked:sn_finish_keepalive_sec()];
        }
        NSString *routeType = sn_current_port() ?: @"";
        [[NSNotificationCenter defaultCenter] postNotificationName:kSNEngineAVDidFinish
                                                            object:nil
                                                          userInfo:@{
                                                            kSNEngineAVUserInfoTailSec: @(SNEngineAVLastKeepaliveSec()),
                                                            kSNEngineAVUserInfoRouteType: routeType,
                                                            kSNEngineAVUserInfoTransaction: @(txn)
                                                          }];
        if (hasNext) {
            [me sn_startNextLocked];
            return;
        }
    });
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didCancelSpeechUtterance:(AVSpeechUtterance *)u
{
    uint64_t txn = SNTransactionForUtterance(u);
    uint64_t activeTxn = atomic_load(&sActiveTransaction);
    BOOL ownsActiveSpeech = (txn != 0 && txn == activeTxn);
    if (ownsActiveSpeech) {
        [SNCancellation setSpeaking:NO];
    }

    __unsafe_unretained SNEngineAV *me = self;
    dispatch_async(self.snSerialQ, ^{
        uint64_t currentTxn = atomic_load(&sActiveTransaction);
        BOOL ownsCurrentSpeech = (txn != 0 && txn == currentTxn);
        if (!ownsCurrentSpeech) {
            [[NSNotificationCenter defaultCenter] postNotificationName:kSNEngineAVDidCancel
                                                                object:nil
                                                              userInfo:@{
                                                                  kSNEngineAVUserInfoTerminalReason: @"cancel",
                                                                  kSNEngineAVUserInfoTransaction: @(txn)
                                                              }];
            if (currentTxn == 0 && sTTSQueue.count > 0) [me sn_startNextLocked];
            return;
        }

        atomic_store(&sSpeaking, NO);
        uint64_t expectedTxn = txn;
        (void)atomic_compare_exchange_strong(&sActiveTransaction, &expectedTxn, 0);
        [me sn_cancelTimeoutLocked];

        BOOL speakingNow = NO;
        @try { speakingNow = me.synth.isSpeaking; } @catch (...) {}

        BOOL hasNext = (speakingNow || sTTSQueue.count > 0);
        if (!hasNext) {
            [me sn_armFinishKeepaliveLocked:sn_finish_keepalive_sec()];
        }
        NSString *routeType = sn_current_port() ?: @"";
        [[NSNotificationCenter defaultCenter] postNotificationName:kSNEngineAVDidCancel
                                                            object:nil
                                                          userInfo:@{
                                                            kSNEngineAVUserInfoTailSec: @(SNEngineAVLastKeepaliveSec()),
                                                            kSNEngineAVUserInfoRouteType: routeType,
                                                            kSNEngineAVUserInfoTerminalReason: @"cancel",
                                                            kSNEngineAVUserInfoTransaction: @(txn)
                                                          }];
        if (hasNext) {
            [me sn_startNextLocked];
            return;
        }
    });
}

@end
