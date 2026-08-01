// SNLogger.h
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void logTextIntoFile(NSString *log, const char *file, int line);

#ifdef __cplusplus
}
#endif

static inline NSString *SNStr(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static inline NSString *SNStr(NSString *format, ...) {
    if (!format || format.length == 0) return @"";
    va_list args;
    va_start(args, format);
    NSString *s = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!s) return @"";
    return [s autorelease];
}

#define SNLOGFMT(fmt, ...) logTextIntoFile(SNStr(fmt, ##__VA_ARGS__), __FILE__, __LINE__)
#ifndef SNLOG
    #define SNLOG(fmt, ...) SNLOGFMT(fmt, ##__VA_ARGS__)
#endif
