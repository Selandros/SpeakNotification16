// SNEngineRunner.h
// Passive runner shim — NOT IN USE currently.
// Kept for compatibility; no logging; CPU-cheap motorics only.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@interface SNEngineRunner : NSObject
+ (void)runWithTitle:(NSString *)title body:(NSString *)body lang:(NSString *)lang;
+ (void)clearQueue;    // cancels all pending jobs (does not stop currently speaking)
@end
