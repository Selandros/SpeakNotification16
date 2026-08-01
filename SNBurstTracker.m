// SNBurstTracker.m
// Mechanics only: burst detection per app/sender key (no logging).

#import "SNBurstTracker.h"

@implementation SNBurstEvent
@end

typedef struct {
    NSTimeInterval startTS;
    NSTimeInterval lastTS;
    NSUInteger count;
} SNBurstState;

@interface SNBurstTracker ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *map;    // key -> SNBurstState
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *last;   // key -> last body
@end

@implementation SNBurstTracker

- (instancetype)init {
    if ((self = [super init])) {
        _map = [NSMutableDictionary new];
        _last = [NSMutableDictionary new];
    }
    return self;
}

- (SNBurstEvent *)registerEventForKey:(NSString *)key
                                  now:(NSTimeInterval)now
                               window:(NSTimeInterval)windowSec {
    if (!key.length) key = @"-";
    SNBurstState st = {0};
    NSValue *boxed = self.map[key];
    if (boxed) { [boxed getValue:&st]; }

    if (st.lastTS <= 0 || (now - st.lastTS) > windowSec) {
        st.startTS = now;
        st.count = 0;
    }

    st.lastTS = now;
    st.count += 1;
    self.map[key] = [NSValue valueWithBytes:&st objCType:@encode(SNBurstState)];

    SNBurstEvent *ev = [SNBurstEvent new];
    ev.isFirst = (st.count == 1);
    ev.collapsedCount = ev.isFirst ? 0 : (st.count - 1);
    ev.sinceStart = now - st.startTS;
    return ev;
}

- (BOOL)isIdenticalBodyAndUpdateForKey:(NSString *)key body:(NSString *)body {
    if (!key.length) key = @"-";
    NSString *prev = self.last[key] ?: @"";
    BOOL same = (body.length && [prev isEqualToString:body]);
    self.last[key] = body ?: @"";
    return same;
}

- (void)pruneIdleEntriesOlderThan:(NSTimeInterval)maxIdleSec {
    if (maxIdleSec <= 0.0) return;
    NSTimeInterval now = [NSDate.date timeIntervalSince1970];
    NSArray<NSString *> *keys = self.map.allKeys.copy;
    for (NSString *k in keys) {
        SNBurstState st = {0};
        [self.map[k] getValue:&st];
        if (st.lastTS > 0 && (now - st.lastTS) > maxIdleSec) {
            [self.map removeObjectForKey:k];
            [self.last removeObjectForKey:k];
        }
    }
}

@end
