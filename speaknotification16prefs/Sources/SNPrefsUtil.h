#import <Foundation/Foundation.h>

@interface SNPrefsUtil : NSObject
+ (NSUserDefaults *)suite;
+ (void)postPrefsChanged;

+ (NSString *)normalizeBID:(NSString *)s;
+ (NSArray<NSString *> *)normalizeIDArray:(NSArray *)arr;
+ (NSDictionary<NSString *, NSString *> *)normalizePerAppDict:(NSDictionary *)inDict;

/// One-time migration: normalize all ID lists and perAppFormats in plist
+ (void)normalizePrefsIfNeeded;
@end
