// SNRuntime.h
// Tiny inline helpers shared across modules. Pure motorics; no logging.

#import <Foundation/Foundation.h>
#import <objc/message.h>

static inline id SN_PerformNoArg(id obj, NSString *selName)
{
    if (!obj || selName.length == 0) return nil;
    SEL sel = NSSelectorFromString(selName);
    if (![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static inline BOOL SN_PerformBoolNoArg(id obj, NSString *selName, BOOL *outVal)
{
    if (!obj || selName.length == 0) return NO;
    SEL sel = NSSelectorFromString(selName);
    if (![obj respondsToSelector:sel]) return NO;
    BOOL v = ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel);
    if (outVal) *outVal = v;
    return YES;
}
