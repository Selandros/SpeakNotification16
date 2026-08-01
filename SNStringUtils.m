// SNStringUtils.m
// Small string & language utilities. Pure motorics; no logging.
// MRC-only (no ARC)

#import "SNStringUtils.h"

#pragma mark - Private helpers (MRC)

static inline BOOL sn_cp_is_emoji(uint32_t cp) {
    if ((cp >= 0x2600 && cp <= 0x27BF)) return YES;
    if (cp == 0x3030 || cp == 0x303D || cp == 0x3297 || cp == 0x3299) return YES;
    if (cp == 0xFE0F || cp == 0x200D || cp == 0x20E3) return YES;
    if ((cp >= 0x1F000 && cp <= 0x1FAFF)) return YES;
    if ((cp >= 0x1FB00 && cp <= 0x1FBFF)) return YES;
    return NO;
}

static inline NSString *sn_norm_bcp47(NSString *tag)
{
    if (![tag isKindOfClass:NSString.class] || tag.length == 0) return @"en-US";
    NSString *t = [[tag stringByReplacingOccurrencesOfString:@"_" withString:@"-"] copy];
    NSArray *parts = [t componentsSeparatedByString:@"-"];
    if (parts.count == 1) {
        NSString *lang = [parts[0] lowercaseString];
        if ([lang hasPrefix:@"zh"]) {
            [t release];
            return [lang containsString:@"hant"] ? @"zh-Hant-TW" : ([lang containsString:@"hans"] ? @"zh-Hans-CN" : @"zh-CN");
        }
        static NSDictionary *kDef; static dispatch_once_t once;
        dispatch_once(&once, ^{
            kDef = [@{
                @"en":@"US",@"sv":@"SE",@"de":@"DE",@"fr":@"FR",@"es":@"ES",@"it":@"IT",@"pt":@"PT",
                @"nl":@"NL",@"da":@"DK",@"nb":@"NO",@"nn":@"NO",@"fi":@"FI",@"is":@"IS",@"pl":@"PL",@"cs":@"CZ",
                @"sk":@"SK",@"sl":@"SI",@"hu":@"HU",@"ro":@"RO",@"bg":@"BG",@"ru":@"RU",@"uk":@"UA",
                @"tr":@"TR",@"el":@"GR",@"he":@"IL",@"ar":@"SA",@"fa":@"IR",@"hi":@"IN",@"bn":@"BD",
                @"ur":@"PK",@"id":@"ID",@"ms":@"MY",@"vi":@"VN",@"th":@"TH",@"ko":@"KR",@"ja":@"JP",
                @"zh-hant":@"TW"
            } copy];
        });
        NSString *REG = kDef[lang] ?: @"US";
        NSString *res = [NSString stringWithFormat:@"%@-%@", lang, REG];
        [t release];
        return res;
    } else {
        NSString *lang = [parts[0] lowercaseString];
        NSString *p1 = parts[1];
        BOOL isScript = (p1.length == 4);
        if (isScript) {
            NSString *script = [[p1 substringToIndex:1] uppercaseString];
            script = [script stringByAppendingString:[[p1 substringFromIndex:1] lowercaseString]];
            if (parts.count >= 3) {
                NSString *region = [parts[2] uppercaseString];
                NSString *res = [NSString stringWithFormat:@"%@-%@-%@", lang, script, region];
                [t release];
                return res;
            } else {
                if ([p1 caseInsensitiveCompare:@"Hant"] == NSOrderedSame) { [t release]; return @"zh-Hant-TW"; }
                if ([p1 caseInsensitiveCompare:@"Hans"] == NSOrderedSame) { [t release]; return @"zh-Hans-CN"; }
                NSString *res = [NSString stringWithFormat:@"%@-%@", lang, script];
                [t release];
                return res;
            }
        } else {
            NSString *region = [p1 uppercaseString];
            NSString *res = [NSString stringWithFormat:@"%@-%@", lang, region];
            [t release];
            return res;
        }
    }
}

static inline BOOL sn_is_ascii_digit(unichar c)
{
    return (c >= '0' && c <= '9');
}

static inline BOOL sn_is_invisible_format_char(unichar c)
{
    return c == 0x061C ||
           c == 0x180E ||
           (c >= 0x200B && c <= 0x200F) ||
           (c >= 0x202A && c <= 0x202E) ||
           c == 0x2060 ||
           (c >= 0x2066 && c <= 0x2069) ||
           c == 0x034F ||
           c == 0xFEFF;
}

static inline NSString *sn_strip_invisible_format_chars(NSString *s)
{
    if (![s isKindOfClass:NSString.class] || s.length == 0) return @"";

    const NSUInteger len = s.length;
    NSMutableString *out = nil;
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [s characterAtIndex:i];
        if (sn_is_invisible_format_char(c)) {
            if (!out) {
                out = [NSMutableString stringWithCapacity:len];
                if (i > 0) [out appendString:[s substringToIndex:i]];
            }
            continue;
        }
        if (out) [out appendFormat:@"%C", c];
    }
    return out ?: s;
}

@implementation SNStringUtils

#pragma mark - New API (migrated from Tweak.xm)

+ (NSString *)stripNotificationsSuffix:(NSString *)s
{
    if (s.length == 0) return s;
    static NSString *const kDotNotif = @".notifications";
    if ([s hasSuffix:kDotNotif]) {
        return [s substringToIndex:(s.length - (NSUInteger)kDotNotif.length)];
    }
    return s;
}

+ (NSString *)stripTrailingIndex:(NSString *)s
{
    if (s.length == 0) return s;
    NSRange dot = [s rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location == NSNotFound || dot.location + 1 >= s.length) return s;
    for (NSUInteger i = dot.location + 1; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (!sn_is_ascii_digit(c)) return s;
    }
    return [s substringToIndex:dot.location];
}

+ (nullable NSString *)trimOrNil:(id)obj
{
    if (![obj isKindOfClass:NSString.class]) return nil;
    NSString *t = [(NSString *)obj stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return (t.length ? t : nil);
}

+ (NSString *)safeStr:(id)obj
{
    if ([obj isKindOfClass:NSString.class]) return (NSString *)obj;
    return @"";
}

+ (NSString *)normalizePhoneSimple:(NSString *)raw
{
    if (raw.length == 0) return @"";
    NSMutableString *out = [NSMutableString stringWithCapacity:raw.length];
    BOOL keepPlus = YES;
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if (c == '+' && keepPlus && out.length == 0) {
            [out appendString:@"+"];
            keepPlus = NO;
            continue;
        }
        if (c >= '0' && c <= '9') {
            [out appendFormat:@"%C", c];
        }
    }
    return out;
}

+ (NSString *)safeSubstring:(NSString *)s maxLen:(NSUInteger)maxLen
{
    if (s.length <= maxLen) return s;
    if (maxLen == 0) return @"";
    NSRange r = [s rangeOfComposedCharacterSequenceAtIndex:maxLen - 1];
    NSUInteger end = NSMaxRange(r);
    if (end > maxLen && end <= s.length) {
        return [s substringToIndex:end];
    }
    return [s substringToIndex:maxLen];
}

+ (NSString *)normalizeWhitespace:(NSString *)s
{
    if (s.length == 0) return s;
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    BOOL inWS = NO;
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ([ws characterIsMember:c]) {
            if (!inWS) {
                [out appendString:@" "];
                inWS = YES;
            }
        } else {
            [out appendFormat:@"%C", c];
            inWS = NO;
        }
    }
    return [out stringByTrimmingCharactersInSet:ws];
}

#pragma mark - Existing API

+ (NSString *)sanitizedBodyQuick:(NSString *)s
{
    if (s.length == 0) return @"";

    static NSRegularExpression *reHttp, *reWww, *reMention, *reEmail, *reWs, *reEmptyParens;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        reHttp = [[NSRegularExpression alloc] initWithPattern:@"\\(?https?://\\S+\\)?"
                                                      options:NSRegularExpressionCaseInsensitive
                                                        error:NULL];
        reWww  = [[NSRegularExpression alloc] initWithPattern:@"\\(?\\bwww\\.[^\\s]+\\)?"
                                                      options:NSRegularExpressionCaseInsensitive
                                                        error:NULL];
        reMention = [[NSRegularExpression alloc] initWithPattern:@"(?<!\\w)@[A-Za-z0-9_]+"
                                                         options:0
                                                           error:NULL];
        reEmail = [[NSRegularExpression alloc] initWithPattern:@"[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}"
                                                       options:NSRegularExpressionCaseInsensitive
                                                         error:NULL];
        reWs = [[NSRegularExpression alloc] initWithPattern:@"\\s{2,}"
                                                    options:0
                                                      error:NULL];
        reEmptyParens = [[NSRegularExpression alloc] initWithPattern:@"\\(\\s*\\)|\\[\\s*\\]|<\\s*>"
                                                             options:0
                                                               error:NULL];
    });

    NSString *source = sn_strip_invisible_format_chars(s);
    NSMutableString *clean = [[source mutableCopy] autorelease];
    [reHttp replaceMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@""];
    [reWww replaceMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@""];
    [reMention replaceMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@""];
    [reEmail replaceMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@""];
    [reEmptyParens replaceMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@""];

    NSString *trimmed = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableString *collapsed = [[trimmed mutableCopy] autorelease];
    [reWs replaceMatchesInString:collapsed options:0 range:NSMakeRange(0, collapsed.length) withTemplate:@" "];

    return [[collapsed copy] autorelease];
}

+ (NSString *)normalizedTitle:(NSString *)s
{
    if (s.length == 0) return @"";
    NSString *source = sn_strip_invisible_format_chars(s);
    NSString *t = [source stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    t = [t stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    t = [t stringByReplacingOccurrencesOfString:@"\r" withString:@" "];

    static NSRegularExpression *reWs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        reWs = [[NSRegularExpression regularExpressionWithPattern:@"\\s{2,}" options:0 error:NULL] retain];
    });

    NSMutableString *m = [[t mutableCopy] autorelease];
    [reWs replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:@" "];
    return [[m copy] autorelease];
}

+ (NSString *)sanitizeForTTS:(NSString *)s
{
    if (s.length == 0) return @"";
    NSString *msg = [self sanitizedBodyQuick:s];

    static NSRegularExpression *reHttpParen = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        reHttpParen = [[NSRegularExpression regularExpressionWithPattern:@"\\(?https?://\\S+\\)?"
                                                                 options:NSRegularExpressionCaseInsensitive
                                                                   error:NULL] retain];
    });

    NSMutableString *m = [[msg mutableCopy] autorelease];
    [reHttpParen replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:@""];
    NSString *trimmed = [m stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [[trimmed copy] autorelease];
}


+ (NSString *)sanitizeLightForTTS:(NSString *)s
{
    if (s.length == 0) return @"";
    static NSCharacterSet *bad; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *m = [[NSMutableCharacterSet alloc] init];
        [m addCharactersInString:@"\u200B\u200C\u200D\u2060\u034F\u00A0•…‧∙·"];
        bad = [m copy]; [m release];
    });
    NSString *source = sn_strip_invisible_format_chars(s);
    NSArray *parts = [source componentsSeparatedByCharactersInSet:bad];
    NSString *t = [parts componentsJoinedByString:@""];
    while ([t containsString:@"  "]) t = [t stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    return t;
}

+ (NSString *)stripURLsFast:(NSString *)s
{
    if (![s isKindOfClass:NSString.class] || s.length == 0) return s ?: @"";
    const NSUInteger n = s.length;
    unichar tmp[256];
    const unichar *u = NULL;
    if (n <= 256) { [s getCharacters:tmp range:NSMakeRange(0, n)]; u = tmp; }
    else {
        unichar *buf = (unichar *)malloc(sizeof(unichar)*n);
        if (!buf) return s;
        [s getCharacters:buf range:NSMakeRange(0, n)];
        u = buf;
    }

    NSMutableString *out = [NSMutableString stringWithCapacity:n];
    BOOL prevWasSpace = NO;
    NSUInteger i = 0;
    while (i < n) {
        unichar c = u[i];

        if (c == '<') {
            NSUInteger j = i + 1; BOOL looksHttp = NO;
            if (j + 3 < n && (u[j]|32)=='h' && (u[j+1]|32)=='t' && (u[j+2]|32)=='t' && (u[j+3]|32)=='p') looksHttp = YES;
            if (looksHttp) { while (j < n && u[j] != '>') j++; i = (j < n ? j + 1 : n); prevWasSpace = YES; continue; }
        }

        if ((c=='h'||c=='H') && i + 7 < n) {
            BOOL https = ((u[i+1]|32)=='t' && (u[i+2]|32)=='t' && (u[i+3]|32)=='p' && (u[i+4]|32)=='s' && u[i+5]==':' && u[i+6]=='/' && u[i+7]=='/');
            BOOL http  = ((u[i+1]|32)=='t' && (u[i+2]|32)=='t' && (u[i+3]|32)=='p' && u[i+4]==':' && u[i+5]=='/' && u[i+6]=='/');
            if (https || http) {
                NSUInteger j = i + (https ? 8 : 7);
                while (j < n) { unichar cj = u[j]; if (cj <= 0x20 || cj=='>'||cj==')'||cj==']'||cj=='\"'||cj=='\'') break; j++; }
                i = j; prevWasSpace = YES; continue;
            }
        }

        if (c == '(' && i > 0 && u[i-1] == ']') {
            NSUInteger j = i + 1;
            BOOL looksHttp = (j + 3 < n && ((u[j]|32)=='h') && ((u[j+1]|32)=='t') && ((u[j+2]|32)=='t') && ((u[j+3]|32)=='p'));
            if (looksHttp) { while (j < n && u[j] != ')') j++; i = (j < n ? j + 1 : n); prevWasSpace = YES; continue; }
        }

        BOOL isSpace = (c <= 0x20);
        if (isSpace) {
            if (!prevWasSpace) [out appendString:@" "];
            prevWasSpace = YES;
        } else {
            [out appendFormat:@"%C", c];
            prevWasSpace = NO;
        }
        i++;
    }

    NSString *res = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (res.length >= 3 && [res hasSuffix:@"]"]) {
        NSRange r = [res rangeOfString:@" [" options:NSBackwardsSearch];
        if (r.location != NSNotFound && r.location + 2 < res.length) {
            res = [[res substringToIndex:r.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    }
    while ([res containsString:@" ()"]) res = [res stringByReplacingOccurrencesOfString:@" ()" withString:@""];
    while ([res containsString:@"  "])   res = [res stringByReplacingOccurrencesOfString:@"  " withString:@" "];

    if (u != tmp && n > 256) free((void *)u);
    return res;
}

+ (NSString *)stripEmoji:(NSString *)s
{
    if (![s isKindOfClass:NSString.class] || s.length == 0) return s ?: @"";

    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length)
                          options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString *sub, NSRange __unused r, NSRange __unused e, BOOL *__unused stop) {
        if (sub.length == 0) return;

        NSUInteger len = sub.length;
        unichar stackBuf[64];
        unichar *buf = (len <= 64) ? stackBuf : (unichar *)malloc(sizeof(unichar)*len);
        [sub getCharacters:buf range:NSMakeRange(0, len)];

        BOOL isEmojiSeq = NO;
        for (NSUInteger i = 0; i < len; i++) {
            uint32_t cp = buf[i];
            if (CFStringIsSurrogateHighCharacter(cp) && i + 1 < len) {
                unichar low = buf[i + 1];
                if (CFStringIsSurrogateLowCharacter(low)) {
                    uint32_t high = cp - 0xD800;
                    uint32_t lowv = low - 0xDC00;
                    cp = (high << 10) + lowv + 0x10000;
                    i++;
                }
            }
            if (sn_cp_is_emoji(cp)) { isEmojiSeq = YES; break; }
        }
        if (buf != stackBuf) free(buf);
        if (!isEmojiSeq) [out appendString:sub];
    }];

    while ([out containsString:@"  "]) {
        [out replaceOccurrencesOfString:@"  " withString:@" " options:0 range:NSMakeRange(0, out.length)];
    }
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

+ (NSString *)systemPrimaryBCP47
{
    NSString *pref = [NSLocale preferredLanguages].firstObject ?: @"en-US";
    if ([pref containsString:@"-"]) return pref;
    static NSDictionary *kDef; static dispatch_once_t once;
    dispatch_once(&once, ^{
        kDef = [@{
            @"sv": @"sv-SE", @"en": @"en-US", @"nb": @"nb-NO", @"nn": @"nn-NO",
            @"da": @"da-DK", @"fi": @"fi-FI", @"de": @"de-DE", @"fr": @"fr-FR",
            @"es": @"es-ES", @"it": @"it-IT", @"pt": @"pt-PT", @"nl": @"nl-NL"
        } retain];
    });
    NSString *lc = pref.lowercaseString;
    NSString *mapped = [kDef objectForKey:lc];
    return mapped ?: @"en-US";
}

+ (NSString *)mapPrefixToBCP47:(NSString *)prefix
{
    NSString *p = (prefix ?: @"").lowercaseString;
    if ([p isEqualToString:@"sv"]) return @"sv-SE";
    if ([p isEqualToString:@"en"]) return @"en-US";
    if ([p isEqualToString:@"de"]) return @"de-DE";
    if ([p isEqualToString:@"da"]) return @"da-DK";
    if ([p isEqualToString:@"nb"]) return @"nb-NO";
    if ([p isEqualToString:@"nn"]) return @"nn-NO";
    if ([p isEqualToString:@"fi"]) return @"fi-FI";
    if ([p isEqualToString:@"is"]) return @"is-IS";
    return p.length ? p : nil;
}

+ (NSString *)clampAllowedBCP47:(NSString *)lang
{
    return sn_norm_bcp47(lang ?: @"en-US");
}

+ (NSString *)formatTokens:(NSString *)fmt
                       app:(NSString *)app
                     title:(NSString *)title
                    sender:(NSString *)sender
                      body:(NSString *)body
                   timeHHMM:(NSString *)timeHHMM
{
    NSString *s = fmt ?: @"{TITLE} {BODY}";
    NSDictionary *map = @{
        @"{APP}": (app ?: @""),
        @"{TITLE}": (title ?: @""),
        @"{SENDER}": (sender ?: @""),
        @"{SUBTITLE}": (sender ?: @""),
        @"{BODY}": (body ?: @""),
        @"{TIME}": (timeHHMM ?: @""),
        @"%%APP%%": (app ?: @""),
        @"%%TITLE%%": (title ?: @""),
        @"%%SENDER%%": (sender ?: @""),
        @"%%SUBTITLE%%": (sender ?: @""),
        @"%%BODY%%": (body ?: @""),
        @"%%TIME%%": (timeHHMM ?: @""),
        @"$app": (app ?: @""),
        @"$title": (title ?: @""),
        @"$sender": (sender ?: @""),
        @"$subtitle": (sender ?: @""),
        @"$body": (body ?: @""),
        @"$time": (timeHHMM ?: @"")
    };
    for (NSString *k in map) s = [s stringByReplacingOccurrencesOfString:k withString:[map objectForKey:k]];

    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *trim = [s stringByTrimmingCharactersInSet:ws];
    while ([trim containsString:@"  "]) trim = [trim stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    return trim;
}

@end
