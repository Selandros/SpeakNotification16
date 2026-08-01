// SNStringUtils.h
// Small string & language utilities. Pure motorics; no logging.
// MRC-only (no ARC)

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SNStringUtils : NSObject

// Existing API (unchanged)
+ (NSString *)sanitizedBodyQuick:(NSString *)s;
+ (NSString *)normalizedTitle:(NSString *)s;
+ (NSString *)sanitizeForTTS:(NSString *)s;
+ (NSString *)sanitizeLightForTTS:(NSString *)s;
+ (NSString *)stripURLsFast:(NSString *)s;
+ (NSString *)stripEmoji:(NSString *)s;

+ (NSString *)systemPrimaryBCP47;
+ (NSString *)mapPrefixToBCP47:(NSString *)prefix;
+ (NSString *)clampAllowedBCP47:(NSString *)lang;

+ (NSString *)formatTokens:(NSString *)fmt
                       app:(NSString *)app
                     title:(NSString *)title
                    sender:(NSString *)sender
                      body:(NSString *)body
                   timeHHMM:(NSString *)timeHHMM;

+ (NSString *)stripNotificationsSuffix:(NSString *)s;
+ (NSString *)stripTrailingIndex:(NSString *)s;
+ (nullable NSString *)trimOrNil:(id)obj;
+ (NSString *)safeStr:(id)obj;
+ (NSString *)normalizePhoneSimple:(NSString *)raw;
+ (NSString *)safeSubstring:(NSString *)s maxLen:(NSUInteger)maxLen;
+ (NSString *)normalizeWhitespace:(NSString *)s;

@end

NS_ASSUME_NONNULL_END
