// SNCallMonitor.m — event-driven via CoreTelephony (no polling, no timeouts)
#import "SNCallMonitor.h"
#import <objc/message.h>
#import <Contacts/Contacts.h>
#import <CoreTelephony/CTCallCenter.h>
#import <CoreTelephony/CTCall.h>

// Run a block synchronously on main queue (no deadlock if already on main)
static inline void SN_RunOnMainSync(void (^block)(void)) {
    if (!block) return;
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

static inline id SN_MSG0(id o, SEL s) { return ((id(*)(id,SEL))objc_msgSend)(o, s); }
static inline BOOL SN_MSG0_BOOL(id o, SEL s) { return ((BOOL(*)(id,SEL))objc_msgSend)(o, s); }

// Monotonic-ish millisecond clock (cheap)
static inline uint64_t SNCM_NowMS(void) {
    return (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0);
}

@implementation SNCallInfo
@end

@interface SNCallMonitor () {
    CTCallCenter *_ct;
    BOOL _telephonyActive;          // call is active
    uint64_t _gateUntilMS;          // cooldown gate after call events
    uint64_t _lastStartMS;          // debounce window for START
    uint64_t _lastEndMS;            // debounce window for END
}
@property(nonatomic, retain) NSMutableDictionary<NSString*, SNCallInfo*> *active; // keyed by CTCall pointer string
@property(nonatomic, copy) SNCallMonitorHandler handler;
@end

@implementation SNCallMonitor

+ (instancetype)shared {
    static SNCallMonitor *S;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ S = [SNCallMonitor new]; });
    return S;
}

- (instancetype)init {
    if ((self = [super init])) {
        _active = [[NSMutableDictionary alloc] init];
        _telephonyActive = NO;
        _gateUntilMS = 0;
        _lastStartMS = 0;
        _lastEndMS = 0;
    }
    return self;
}

- (void)dealloc {
    [self stop];
    [_active release];
    [_handler release];
    [super dealloc];
}

- (void)startWithHandler:(SNCallMonitorHandler)handler {
    self.handler = handler;
    if (_ct) return;

    _ct = [CTCallCenter new];
    __unsafe_unretained typeof(self) weakSelf = self; // MRC friendly
    _ct.callEventHandler = ^(CTCall *call) {
        [weakSelf handleCTEvent:call];
    };
}

- (void)stop {
    if (_ct) {
        _ct.callEventHandler = nil;
        [_ct release];
        _ct = nil;
    }
    [self.active removeAllObjects];
    self.handler = nil;
}

#pragma mark - Public call-gate API (lightweight)

- (BOOL)telephonyActive {
    return _telephonyActive;
}

- (BOOL)shouldAllowSpeechNow {
    uint64_t now = SNCM_NowMS();
    if (_telephonyActive) return NO;
    if (now < _gateUntilMS) return NO;
    return YES;
}

- (void)cooldownAfterCallMS:(uint32_t)ms {
    _gateUntilMS = SNCM_NowMS() + (uint64_t)ms;
}

#pragma mark - CoreTelephony event handling

// Use CTCall pointer identity as key
- (NSString *)keyForCTCall:(CTCall *)call {
    return [NSString stringWithFormat:@"%p", call];
}

// Try to match END to an existing START using: UUID → normalized phone → start time proximity (±5s)
- (NSString *)keyForExistingInfoMatching:(SNCallInfo *)probe {
    if (!probe) return nil;

    // 0) If exactly one active candidate exists, prefer it (very low ambiguity, cheap)
    if (self.active.count == 1) {
        return self.active.allKeys.firstObject;
    }

    // 1) Exact UUID match
    if (probe.uuid) {
        for (NSString *k in self.active) {
            SNCallInfo *cand = self.active[k];
            if (cand.uuid && [cand.uuid isEqual:probe.uuid]) return k;
        }
    }

    // 2) Normalized phone match
    NSString *pnum = [self normalizePhone:probe.number];
    if (pnum.length) {
        for (NSString *k in self.active) {
            SNCallInfo *cand = self.active[k];
            if (cand.number.length && [pnum isEqualToString:[self normalizePhone:cand.number]]) {
                return k;
            }
        }
    }

    // 3) Proximity fallback: widen window to be robust for short calls
    //    Keep it modest to avoid mismatching long-lived calls.
    static const NSTimeInterval kProximitySec = 180.0; // 3 minutes
    NSDate *ps = probe.startDate ?: [NSDate date];
    NSTimeInterval psec = ps.timeIntervalSince1970;

    NSString *bestKey = nil;
    NSTimeInterval bestDelta = DBL_MAX;

    for (NSString *k in self.active) {
        SNCallInfo *cand = self.active[k];
        NSDate *cs = cand.startDate ?: ps;
        NSTimeInterval delta = fabs(cs.timeIntervalSince1970 - psec);
        if (delta <= kProximitySec && delta < bestDelta) {
            bestDelta = delta;
            bestKey = k;
        }
    }
    if (bestKey) return bestKey;

    // 4) As a very last resort: prefer most recent outgoing if probe suggests outgoing
    if (probe.direction == SNCallDirectionOutgoing) {
        NSString *latestKey = nil; NSDate *latest = nil;
        for (NSString *k in self.active) {
            SNCallInfo *cand = self.active[k];
            if (cand.direction == SNCallDirectionOutgoing) {
                NSDate *sd = cand.startDate ?: [NSDate dateWithTimeIntervalSince1970:0];
                if (!latest || [sd timeIntervalSinceDate:latest] > 0) {
                    latest = sd; latestKey = k;
                }
            }
        }
        if (latestKey) return latestKey;
    }

    return nil;
}

- (void)handleCTEvent:(CTCall *)call {
    if (!call) return;
    NSString *key = [self keyForCTCall:call];
    if (key.length == 0) return;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSString *state = call.callState ?: @"";

    if ([state isEqualToString:CTCallStateDialing] || [state isEqualToString:CTCallStateIncoming]) {
        uint64_t now = SNCM_NowMS();
        if (now - _lastStartMS < 400) return; // debounce START (400 ms)
        _lastStartMS = now;

        _telephonyActive = YES;              // mark call active
        _gateUntilMS = now + 500;            // short cooldown to absorb route churn

        SNCallInfo *info = self.active[key];
        if (!info) {
            info = [SNCallInfo new];
            info.startDate = [NSDate date];
            info.direction = [state isEqualToString:CTCallStateDialing] ? SNCallDirectionOutgoing : SNCallDirectionIncoming;
            [self fillNameAndNumberForInfo:info];
            self.active[key] = info;
            [info release];
        } else {
            if (info.direction == SNCallDirectionUnknown) {
                info.direction = [state isEqualToString:CTCallStateDialing] ? SNCallDirectionOutgoing : SNCallDirectionIncoming;
            }
            if (info.number.length == 0 || info.name.length == 0) {
                [self fillNameAndNumberForInfo:info];
            }
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self fillNameAndNumberForInfo:info];
            SNCallInfo *copy = [self shallowCopy:info];
            if (self.handler) self.handler(YES, copy);
            [copy release];
        });
        return;
    }

    if ([state isEqualToString:CTCallStateConnected]) {
        SNCallInfo *info = self.active[key];
        if (info) info.wasConnected = YES;
        return;
    }

    if ([state isEqualToString:CTCallStateDisconnected]) {
        uint64_t now = SNCM_NowMS();
        if (now - _lastEndMS < 400) return; // debounce END (400 ms)
        _lastEndMS = now;

        SNCallInfo *info = self.active[key];
        if (!info) {
            SNCallInfo *probe = [SNCallInfo new];
            // If we already have a single active call, the matcher will grab it.
            // startDate=now is fine because proximity window is 180 s.
            probe.startDate = [NSDate date];
            [self fillNameAndNumberForInfo:probe];

            NSString *matchKey = [self keyForExistingInfoMatching:probe];
            if (matchKey) {
                info = [self.active[matchKey] retain];
                [self.active removeObjectForKey:matchKey];

                if (info.number.length == 0 && probe.number.length) info.number = probe.number;
                if (info.name.length   == 0 && probe.name.length)   info.name   = probe.name;
                if (info.direction == SNCallDirectionUnknown && probe.direction != SNCallDirectionUnknown) {
                    info.direction = probe.direction;
                }
            } else {
                info = [SNCallInfo new];
                info.startDate  = [NSDate date];
                info.direction  = SNCallDirectionUnknown;
                info.number     = probe.number ?: @"";
                info.name       = probe.name   ?: @"";
                info.missedStart = YES;
            }
            self.active[key] = info;
            [probe release];
            [info release];
        }

        info.endDate = [NSDate date];

        _telephonyActive = NO;               // clear call active
        _gateUntilMS = now + 500;            // post-call cooldown

        if (self.handler) {
            SNCallInfo *copy = [self shallowCopy:info];
            self.handler(NO, copy);
            [copy release];
        }
        [self.active removeObjectForKey:key];
        return;
    }
#pragma clang diagnostic pop
}

#pragma mark - TU snapshot (best-effort, no polling — only at events)

// Must be called on main queue (TU requires main)
- (NSArray *)snapshotAllTUCalls {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        Class C1 = NSClassFromString(@"TUCallCenter");
        if (C1 && [C1 respondsToSelector:@selector(sharedInstance)]) {
            id center = SN_MSG0(C1, @selector(sharedInstance));
            if (center && [center respondsToSelector:@selector(currentCalls)]) {
                NSArray *arr = SN_MSG0(center, @selector(currentCalls));
                if ([arr isKindOfClass:NSArray.class] && arr.count) [out addObjectsFromArray:arr];
            }
        }
    } @catch (...) {}
    @try {
        Class C2 = NSClassFromString(@"TUCallNotificationCenter");
        if (C2 && [C2 respondsToSelector:@selector(sharedInstance)]) {
            id ncenter = SN_MSG0(C2, @selector(sharedInstance));
            if (ncenter && [ncenter respondsToSelector:@selector(allCalls)]) {
                NSArray *arr = SN_MSG0(ncenter, @selector(allCalls));
                if ([arr isKindOfClass:NSArray.class] && arr.count) [out addObjectsFromArray:arr];
            }
        }
    } @catch (...) {}
    return out;
}

- (NSString *)tuNumber:(id)tu {
    NSArray *keys = @[@"destinationID",@"remoteID",@"remoteAddress",@"phoneNumber",@"address",
                      @"normalizedAddress",@"handle",@"endpointID",@"remoteParticipantHandle"];
    for (NSString *k in keys) {
        @try {
            id v = [tu valueForKey:k];
            if ([v isKindOfClass:NSString.class] && [((NSString*)v) length] > 0) return (NSString*)v;
            if ([v respondsToSelector:@selector(stringValue)]) {
                NSString *s = [v stringValue]; if (s.length) return s;
            }
        } @catch (...) {}
    }
    return @"";
}

- (NSString *)tuDisplayName:(id)tu {
    NSArray *keys = @[@"displayName",@"displayNameOrLabel",@"remoteParticipantDisplayName",
                      @"remoteDisplayName",@"callerName",@"cnContactDisplayName",@"localizedCallerName"];
    for (NSString *k in keys) {
        @try {
            id v = [tu valueForKey:k];
            if ([v isKindOfClass:NSString.class] && [((NSString*)v) length] > 0) return (NSString*)v;
            if ([v respondsToSelector:@selector(stringValue)]) {
                NSString *s = [v stringValue]; if (s.length) return s;
            }
        } @catch (...) {}
    }
    return @"";
}

- (SNCallDirection)tuDirection:(id)tu {
    @try { if ([tu respondsToSelector:@selector(isOutgoing)]) return SN_MSG0_BOOL(tu, @selector(isOutgoing)) ? SNCallDirectionOutgoing : SNCallDirectionIncoming; } @catch (...) {}
    @try {
        id v = [tu valueForKey:@"outgoing"];
        if ([v respondsToSelector:@selector(boolValue)] && [v boolValue]) return SNCallDirectionOutgoing;
    } @catch (...) {}
    @try {
        id v = [tu valueForKey:@"incoming"];
        if ([v respondsToSelector:@selector(boolValue)] && [v boolValue]) return SNCallDirectionIncoming;
    } @catch (...) {}
    return SNCallDirectionUnknown;
}

- (NSString *)normalizePhone:(NSString *)raw {
    if (raw.length == 0) return @"";
    NSMutableString *out = [NSMutableString stringWithCapacity:raw.length];
    BOOL seenPlus = NO;
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if (c == '+' && !seenPlus && out.length == 0) { [out appendString:@"+"]; seenPlus = YES; continue; }
        if (c >= '0' && c <= '9') [out appendFormat:@"%C", c];
    }
    return out;
}

- (NSString *)contactsNameForPhone:(NSString *)phone {
    if (phone.length == 0) return @"";
    NSString *result = @"";
    CNContactStore *store = nil;
    @try {
        CNAuthorizationStatus st = [CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts];
        if (st == CNAuthorizationStatusDenied || st == CNAuthorizationStatusRestricted) return @"";
        store = [CNContactStore new];
        NSArray *keys = @[CNContactGivenNameKey, CNContactFamilyNameKey, CNContactMiddleNameKey, CNContactNicknameKey, CNContactOrganizationNameKey];
        NSPredicate *pred = [CNContact predicateForContactsMatchingPhoneNumber:[CNPhoneNumber phoneNumberWithStringValue:phone]];
        NSError *err = nil;
        NSArray<CNContact *> *hits = [store unifiedContactsMatchingPredicate:pred keysToFetch:keys error:&err];
        if (hits.count > 0) {
            CNContact *c = hits.firstObject;
            NSMutableArray *parts = [NSMutableArray array];
            if (c.givenName.length) [parts addObject:c.givenName];
            if (c.middleName.length) [parts addObject:c.middleName];
            if (c.familyName.length) [parts addObject:c.familyName];
            NSString *full = [parts componentsJoinedByString:@" "];
            if (full.length) result = full;
            else if (c.nickname.length) result = c.nickname;
            else if (c.organizationName.length) result = c.organizationName;
        }
    } @catch (...) {
        result = @"";
    } @finally {
        [store release];
    }
    return result ?: @"";
}

- (void)fillNameAndNumberForInfo:(SNCallInfo *)info {
    if (!info) return;

    __block NSArray *calls = nil;
    SN_RunOnMainSync(^{
        calls = [[self snapshotAllTUCalls] retain];
    });

    id best = (calls.count ? [calls lastObject] : nil);
    if (calls) [calls release];
    if (!best) return;

    NSString *num = [self normalizePhone:[self tuNumber:best]];
    if (num.length) info.number = num;

    NSString *nm = [self tuDisplayName:best];
    if (nm.length == 0 && num.length) {
        NSString *cn = [self contactsNameForPhone:num];
        if (cn.length) nm = cn;
    }
    if (nm.length) info.name = nm;

    if (info.direction == SNCallDirectionUnknown) {
        info.direction = [self tuDirection:best];
    }

    @try {
        if ([best respondsToSelector:@selector(UUID)]) {
            NSUUID *u = SN_MSG0(best, @selector(UUID));
            if ([u isKindOfClass:[NSUUID class]]) info.uuid = u;
        }
    } @catch (...) {}
}

#pragma mark - utils

- (SNCallInfo *)shallowCopy:(SNCallInfo *)src {
    SNCallInfo *d = [SNCallInfo new];
    d.uuid = src.uuid;
    d.number = src.number;
    d.name = src.name;
    d.startDate = src.startDate;
    d.endDate = src.endDate;
    d.direction = src.direction;
    d.missedStart = src.missedStart;
    d.wasConnected = src.wasConnected;
    return d;
}

@end