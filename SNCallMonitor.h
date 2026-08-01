// SNCallMonitor.h
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SNCallDirection) {
    SNCallDirectionUnknown = 0,
    SNCallDirectionIncoming,
    SNCallDirectionOutgoing
};

@interface SNCallInfo : NSObject
@property(nonatomic, retain) NSUUID *uuid;
@property(nonatomic, copy) NSString *number;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, retain) NSDate *startDate;
@property(nonatomic, retain) NSDate *endDate;
@property(nonatomic, assign) SNCallDirection direction;
@property(nonatomic, assign) BOOL wasConnected;
@property(nonatomic, assign) BOOL missedStart;
@end

typedef void (^SNCallMonitorHandler)(BOOL isStart, SNCallInfo *info);

@interface SNCallMonitor : NSObject
+ (instancetype)shared;
- (void)startWithHandler:(SNCallMonitorHandler)handler;
- (void)stop;

// Lightweight call-gate API (no logging; CPU-cheap)
@property (atomic, assign, readonly) BOOL telephonyActive; // YES while a call is active
- (BOOL)shouldAllowSpeechNow; // NO during active call or cooldown
- (void)cooldownAfterCallMS:(uint32_t)ms; // optionally extend post-call cooldown
@end
