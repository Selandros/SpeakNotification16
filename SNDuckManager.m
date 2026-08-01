// SNDuckManager.m
// Pure motorics for pause/duck orchestration (no logging here).

#import "SNDuckManager.h"
#import <stdatomic.h>

@interface SNDuckManager () {
    SNDuckConfig _cfg;
    SNDuckCallbacks _cb;
    void *_ctx;

    dispatch_queue_t _q;                 // serializes state/timers
    dispatch_source_t _tPre;             // pre-roll timer
    dispatch_source_t _tConfirm;         // confirm timer
    dispatch_source_t _tPost;            // post-roll timer

    atomic_uint_fast64_t _gen;           // generation to invalidate pending timers/callbacks
    BOOL _readyFired;                    // onReady invoked for current generation
    BOOL _aborted;                       // terminal state
    BOOL _applyAttemptedOnce;            // first requestApply() issued
    BOOL _applyAttemptedTwice;           // retry issued
    BOOL _confirmPassed;                 // confirmApplied returned YES
    BOOL _activeDuck;                    // property backing
    BOOL _inPostRoll;                    // property backing
    BOOL _pausedByUs;                    // property backing (we initiated pause)
}
@end

@implementation SNDuckManager

- (instancetype)initWithConfig:(SNDuckConfig)cfg
                     callbacks:(SNDuckCallbacks)cb
                        ctxPtr:(void * _Nullable)cbCtx
{
    self = [super init];
    if (!self) return nil;
    _cfg = cfg;
    _cb  = cb;
    _ctx = cbCtx;
    atomic_store(&_gen, 1);

    _q = dispatch_queue_create("com.selandros.speaknotification16.duckmgr", DISPATCH_QUEUE_SERIAL);

    return self;
}

- (void)dealloc
{
    (void)atomic_fetch_add(&_gen, 1);
    [self sn_cancelTimer:&_tPre];
    [self sn_cancelTimer:&_tConfirm];
    [self sn_cancelTimer:&_tPost];
#if !__has_feature(objc_arc)
    if (_q) { dispatch_release(_q); _q = NULL; }
    [super dealloc];
#endif
}

#pragma mark - Phase 1: pre-roll → apply → confirm

- (void)startWithReady:(void (^)(void))onReady
                 abort:(void (^)(void))onAbort
{
    if (!onReady || !onAbort) return;

    (void)atomic_fetch_add(&_gen, 1); // bump generation

    dispatch_async(_q, ^{
        if (_aborted) return;

        _readyFired = NO;
        _applyAttemptedOnce = NO;
        _applyAttemptedTwice = NO;
        _confirmPassed = NO;
        _activeDuck = NO;
        _inPostRoll = NO;
        _pausedByUs = NO;

        [self sn_cancelTimer:&_tPre];
        [self sn_cancelTimer:&_tConfirm];
        [self sn_cancelTimer:&_tPost];

        uint64_t g = atomic_load(&_gen);
        [self sn_schedulePreRoll:g onReady:onReady onAbort:onAbort];
    });
}

#pragma mark - Phase 2: TTS end → post-roll → release

- (void)noteTTSEndedCancelled:(BOOL)cancelled
{
    [self noteTTSEndedCancelled:cancelled onComplete:nil];
}

- (void)noteTTSEndedCancelled:(BOOL)cancelled
                  onComplete:(void (^ _Nullable)(void))completion
{
    dispatch_async(_q, ^{
        if (_aborted) { if (completion) completion(); return; }

        // Nothing applied: release path is trivial.
        if (!_activeDuck) {
            [self sn_releaseNowWithResume:(cancelled && _cfg.resumeOnCancel)];
            if (completion) completion();
            return;
        }

        // Immediate resume on cancel if configured.
        if (cancelled && _cfg.resumeOnCancel) {
            [self sn_releaseNowWithResume:YES];
            if (completion) completion();
            return;
        }

        // Hold post-roll before releasing.
        _inPostRoll = YES;
        [self sn_cancelTimer:&_tPost];
        uint64_t g = atomic_load(&_gen);
        _tPost = [self sn_makeOneShotTimer:_cfg.postRollMs gen:g block:^{
            _inPostRoll = NO;
            [self sn_releaseNowWithResume:YES];
            if (completion) completion();
        }];
        if (_tPost) dispatch_resume(_tPost);
        else {
            // If timer scheduled as immediate (0ms), block has already executed.
        }
    });
}

#pragma mark - Step 9: Burst / Queue behavior

- (BOOL)beginFastChainIfPossibleWithReady:(void (^)(void))onReady
                                    abort:(void (^)(void))onAbort
{
    if (!onReady || !onAbort) return NO;

    __block BOOL didChain = NO;
    dispatch_sync(_q, ^{
        if (_aborted) { didChain = NO; return; }

        // We only allow fast-chain if we have a stable applied state or we are in post-roll.
        if (_activeDuck || _inPostRoll) {
            [self sn_cancelTimer:&_tPost];
            _inPostRoll = NO;

            if (!_readyFired) _readyFired = YES;
            didChain = YES;
        } else {
            didChain = NO;
        }
    });

    if (didChain) {
        onReady();
    }
    return didChain;
}

- (void)extendPostRoll
{
    [self extendPostRollBy:_cfg.postRollMs];
}

- (void)extendPostRollBy:(NSUInteger)ms
{
    dispatch_async(_q, ^{
        if (_aborted) return;
        if (!_inPostRoll) return;

        [self sn_cancelTimer:&_tPost];
        uint64_t g = atomic_load(&_gen);
        _tPost = [self sn_makeOneShotTimer:ms gen:g block:^{
            _inPostRoll = NO;
            [self sn_releaseNowWithResume:YES];
        }];
        if (_tPost) dispatch_resume(_tPost);
    });
}

#pragma mark - Abort

- (void)abortNow
{
    (void)atomic_fetch_add(&_gen, 1); // bump generation so any pending timers are no-ops

    dispatch_async(_q, ^{
        if (_aborted) return;
        _aborted = YES;

        [self sn_cancelTimer:&_tPre];
        [self sn_cancelTimer:&_tConfirm];
        [self sn_cancelTimer:&_tPost];

        if (_activeDuck) {
            _activeDuck = NO;
            BOOL pausedByUsSnapshot = _pausedByUs;
            _pausedByUs = NO;
            if (_cb.releaseState) {
                _cb.releaseState(_cfg.mode, pausedByUsSnapshot, _cfg.resumeOnCancel, _ctx);
            }
        }
    });
}

#pragma mark - Introspection

- (BOOL)activeDuck { return _activeDuck; }
- (BOOL)inPostRoll { return _inPostRoll; }
- (BOOL)pausedByUs { return _pausedByUs; }
- (BOOL)sessionHeld
{
    __block BOOL held = NO;
    dispatch_sync(_q, ^{
        held = (_activeDuck || _inPostRoll || _tPre != nil || _tConfirm != nil);
    });
    return held;
}

#pragma mark - Internals (no logging)

- (void)sn_schedulePreRoll:(uint64_t)gen
                   onReady:(void (^)(void))onReady
                    onAbort:(void (^)(void))onAbort
{
    [self sn_cancelTimer:&_tPre];
    _tPre = [self sn_makeOneShotTimer:_cfg.preRollMs gen:gen block:^{
        [self sn_attemptApplyThenConfirm:gen onReady:onReady onAbort:onAbort firstAttempt:YES];
    }];
    if (_tPre) dispatch_resume(_tPre);
}

- (void)sn_attemptApplyThenConfirm:(uint64_t)gen
                           onReady:(void (^)(void))onReady
                            onAbort:(void (^)(void))onAbort
                      firstAttempt:(BOOL)first
{
    if (_aborted) return;

    if (first) _applyAttemptedOnce = YES; else _applyAttemptedTwice = YES;

    if (_cb.requestApply) {
        (void)_cb.requestApply(_cfg.mode, _cfg.targetDb, _ctx);
    }

    [self sn_cancelTimer:&_tConfirm];
    _tConfirm = [self sn_makeOneShotTimer:_cfg.confirmMs gen:gen block:^{
        [self sn_handleConfirmTick:gen onReady:onReady onAbort:onAbort afterRetry:!first];
    }];
    if (_tConfirm) dispatch_resume(_tConfirm);
}

- (void)sn_handleConfirmTick:(uint64_t)gen
                     onReady:(void (^)(void))onReady
                      onAbort:(void (^)(void))onAbort
                  afterRetry:(BOOL)afterRetry
{
    if (_aborted) return;

    BOOL ok = NO;
    if (_cb.confirmApplied) ok = _cb.confirmApplied(_cfg.mode, _ctx);

    if (ok) {
        _confirmPassed = YES;
        _activeDuck = YES;
        if (_cfg.mode == SNDuckModePause) _pausedByUs = YES;

        if (!_readyFired) {
            _readyFired = YES;
            onReady();
        }
        return;
    }

    if (!afterRetry) {
        [self sn_attemptApplyThenConfirm:gen onReady:onReady onAbort:onAbort firstAttempt:NO];
        return;
    }

    if (_aborted) return;

    _aborted = YES;
    [self sn_cancelTimer:&_tPre];
    [self sn_cancelTimer:&_tConfirm];
    [self sn_cancelTimer:&_tPost];
    onAbort();
}

- (void)sn_releaseNowWithResume:(BOOL)resume
{
    if (_activeDuck) {
        _activeDuck = NO;
        BOOL pausedByUsSnapshot = _pausedByUs;
        _pausedByUs = NO;
        if (_cb.releaseState) {
            _cb.releaseState(_cfg.mode, pausedByUsSnapshot, resume, _ctx);
        }
    }
}

- (dispatch_source_t)sn_makeOneShotTimer:(NSUInteger)delayMs
                                     gen:(uint64_t)gen
                                   block:(dispatch_block_t)block
{
    if (delayMs == 0) {
        __unsafe_unretained SNDuckManager *weakSelf = self;
        dispatch_async(_q, ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (atomic_load(&strongSelf->_gen) != gen) return;
            block();
        });
        return nil;
    }

    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
    if (!t) return nil;

    uint64_t ns = (uint64_t)delayMs * 1000000ull;
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, ns), DISPATCH_TIME_FOREVER, 0);
    __unsafe_unretained SNDuckManager *weakSelf = self;
    dispatch_source_set_event_handler(t, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (atomic_load(&strongSelf->_gen) != gen) return;
        block();
    });
    dispatch_source_set_cancel_handler(t, ^{});
    return t;
}

- (void)sn_cancelTimer:(dispatch_source_t *)pt
{
    if (!pt || !*pt) return;
    dispatch_source_t t = *pt;
    *pt = nil;
    dispatch_source_cancel(t);
#if !__has_feature(objc_arc)
    dispatch_release(t);
#endif
}

@end
