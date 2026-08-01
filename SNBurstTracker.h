// SNBurstTracker.h
// Mechanics only: burst detection per app/sender key (no logging).

#import <Foundation/Foundation.h>

@interface SNBurstEvent : NSObject
@property (nonatomic, assign) BOOL isFirst;              // first in window
@property (nonatomic, assign) NSUInteger collapsedCount; // extra notes in current window
@property (nonatomic, assign) NSTimeInterval sinceStart; // seconds since first in window
@end

@interface SNBurstTracker : NSObject

// Registers an event for a given key and returns burst status for a sliding window.
// 'key' should be stable per (sectionID + normalizedTitle).
- (SNBurstEvent *)registerEventForKey:(NSString *)key
                                  now:(NSTimeInterval)now
                               window:(NSTimeInterval)windowSec;

// Body de-duplication helper: YES if body equals previous for this key (and updates stored).
- (BOOL)isIdenticalBodyAndUpdateForKey:(NSString *)key body:(NSString *)body;

// Remove keys that have been idle longer than 'maxIdleSec' (keeps memory small).
- (void)pruneIdleEntriesOlderThan:(NSTimeInterval)maxIdleSec;


@end
