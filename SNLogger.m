#import <Foundation/Foundation.h>
#import <os/lock.h>
#import <sys/stat.h>
#import <pwd.h>
#import <unistd.h>

#define SN_LOG_MAX_BYTES (10 * 1024 * 1024)
#define SN_LOG_RETENTION_DAYS 7

static NSString *SN_LogDir(void) {
    return @"/var/mobile/Library/Logs";
}

static NSString *SN_LogBaseName(void) {
    return @"log_speaknotification16";
}

static NSString *SN_LogExt(void) {
    return @"txt";
}

static NSString *SN_LogLegacyPath(void) {
    return [SN_LogDir() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.%@", SN_LogBaseName(), SN_LogExt()]];
}

static NSDateFormatter *SN_LogDayFormatter(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        [formatter setDateFormat:@"yyyy-MM-dd"];
        [formatter setLocale:[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease]];
        [formatter setTimeZone:[NSTimeZone localTimeZone]];
    });
    return formatter;
}

static NSDateFormatter *SN_LogTimeFormatter(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        [formatter setDateFormat:@"HH:mm:ss"];
        [formatter setLocale:[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease]];
        [formatter setTimeZone:[NSTimeZone localTimeZone]];
    });
    return formatter;
}

static NSString *SN_LogDayKeyForDate(NSDate *date) {
    return [SN_LogDayFormatter() stringFromDate:date ?: [NSDate date]];
}

static NSString *SN_LogTimeForDate(NSDate *date) {
    return [SN_LogTimeFormatter() stringFromDate:date ?: [NSDate date]];
}

static NSString *SN_LogDailyPath(NSString *dayKey, NSUInteger part) {
    NSString *suffix = (part > 1) ? [NSString stringWithFormat:@"_%lu", (unsigned long)part] : @"";
    NSString *name = [NSString stringWithFormat:@"%@_%@%@.%@",
                      SN_LogBaseName(), dayKey, suffix, SN_LogExt()];
    return [SN_LogDir() stringByAppendingPathComponent:name];
}

static BOOL SN_IsDateKey(NSString *value) {
    if (value.length != 10) return NO;
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        if (i == 4 || i == 7) {
            if (c != '-') return NO;
        } else if (c < '0' || c > '9') {
            return NO;
        }
    }
    return YES;
}

static BOOL SN_ParseDailyFilename(NSString *filename, NSString **outDayKey, NSUInteger *outPart) {
    NSString *prefix = [NSString stringWithFormat:@"%@_", SN_LogBaseName()];
    NSString *extension = [NSString stringWithFormat:@".%@", SN_LogExt()];
    if (![filename hasPrefix:prefix] || ![filename hasSuffix:extension]) return NO;

    NSUInteger stemLength = filename.length - extension.length;
    NSString *stem = [filename substringToIndex:stemLength];
    NSString *value = [stem substringFromIndex:prefix.length];
    if (value.length < 10) return NO;

    NSString *dayKey = [value substringToIndex:10];
    if (!SN_IsDateKey(dayKey)) return NO;

    NSUInteger part = 1;
    if (value.length > 10) {
        if ([value characterAtIndex:10] != '_' || value.length == 11) return NO;
        NSString *partText = [value substringFromIndex:11];
        for (NSUInteger i = 0; i < partText.length; i++) {
            unichar c = [partText characterAtIndex:i];
            if (c < '0' || c > '9') return NO;
        }
        part = (NSUInteger)partText.integerValue;
        if (part < 2) return NO;
    }

    if (outDayKey) *outDayKey = dayKey;
    if (outPart) *outPart = part;
    return YES;
}

static void SN_ApplyFilePolicy(NSString *path) {
    if (path.length == 0) return;
    chmod([path fileSystemRepresentation], 0644);

    struct passwd *mobile = getpwnam("mobile");
    if (mobile) {
        (void)chown([path fileSystemRepresentation], mobile->pw_uid, mobile->pw_gid);
    }
}

static void SN_EnsureDir(void) {
    NSString *dir = SN_LogDir();
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @(0755)}
                                                    error:NULL];
    chmod([dir fileSystemRepresentation], 0755);
}

static NSDate *SN_DateFromDayKey(NSString *dayKey) {
    if (!SN_IsDateKey(dayKey)) return nil;
    return [SN_LogDayFormatter() dateFromString:dayKey];
}

static void SN_CleanupOldDailyLogs(NSString *currentDayKey) {
    NSDate *currentDate = SN_DateFromDayKey(currentDayKey);
    if (!currentDate) return;

    NSCalendar *calendar = [[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian] autorelease];
    [calendar setTimeZone:[NSTimeZone localTimeZone]];
    NSDate *cutoffDate = [calendar dateByAddingUnit:NSCalendarUnitDay
                                               value:-(SN_LOG_RETENTION_DAYS - 1)
                                              toDate:currentDate
                                             options:0];
    NSString *cutoffKey = SN_LogDayKeyForDate(cutoffDate);

    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:SN_LogDir() error:NULL];
    for (NSString *filename in items) {
        NSString *dayKey = nil;
        if (!SN_ParseDailyFilename(filename, &dayKey, NULL)) continue;
        if ([dayKey compare:cutoffKey] == NSOrderedAscending) {
            NSString *path = [SN_LogDir() stringByAppendingPathComponent:filename];
            [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        }
    }
}

static NSUInteger SN_MaxPartForDay(NSString *dayKey) {
    NSUInteger maxPart = 0;
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:SN_LogDir() error:NULL];
    for (NSString *filename in items) {
        NSString *fileDay = nil;
        NSUInteger part = 0;
        if (!SN_ParseDailyFilename(filename, &fileDay, &part)) continue;
        if ([fileDay isEqualToString:dayKey] && part > maxPart) maxPart = part;
    }
    return maxPart;
}

static NSUInteger SN_FileSize(NSString *path) {
    struct stat st = {0};
    if (stat([path fileSystemRepresentation], &st) != 0 || st.st_size < 0) return 0;
    return (NSUInteger)st.st_size;
}

static NSFileHandle *SN_OpenFile(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        if (![fm createFileAtPath:path contents:nil attributes:@{NSFilePosixPermissions: @(0644)}]) {
            return nil;
        }
    }
    SN_ApplyFilePolicy(path);
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    return [handle retain];
}

static void SN_CloseHandle(NSFileHandle **handle) {
    if (!handle || !*handle) return;
    @try { [*handle synchronizeFile]; } @catch (...) {}
    @try { [*handle closeFile]; } @catch (...) {}
    [*handle release];
    *handle = nil;
}

static void SN_SetActivePath(NSString **activePath, NSString *path) {
    if (!activePath) return;
    [*activePath release];
    *activePath = [path copy];
}

static void SN_WriteLogLine(NSString *log, const char *file, int line, BOOL includeSource) {
    if (!log) return;

    static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;
    static NSFileHandle *sHandle = nil;
    static NSString *sActiveDay = nil;
    static NSString *sActivePath = nil;
    static NSUInteger sActivePart = 0;
    static NSUInteger sActiveSize = 0;
    static BOOL sUsingFallback = NO;

    NSDate *now = [NSDate date];
    NSString *dayKey = SN_LogDayKeyForDate(now);
    NSString *prefix = SN_LogTimeForDate(now);
    NSString *suffix = includeSource ? [NSString stringWithFormat:@" | %s:%d", file ? file : "?", line] : @"";
    NSString *lineString = [NSString stringWithFormat:@"%@ %@%@\n", prefix, log, suffix];
    NSData *data = [lineString dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;

    os_unfair_lock_lock(&sLock);

    if (sHandle) {
        NSString *expectedPath = nil;
        if (sUsingFallback) {
            expectedPath = SN_LogLegacyPath();
        } else if (sActiveDay.length && sActivePart > 0) {
            expectedPath = SN_LogDailyPath(sActiveDay, sActivePart);
        }
        BOOL pathMissing = (expectedPath.length > 0 &&
                            ![[NSFileManager defaultManager] fileExistsAtPath:expectedPath]);
        BOOL pathMismatch = (expectedPath.length > 0 &&
                             ![sActivePath isEqualToString:expectedPath]);
        if (pathMissing || pathMismatch) {
            SN_CloseHandle(&sHandle);
            SN_SetActivePath(&sActivePath, nil);
            [sActiveDay release];
            sActiveDay = nil;
            sActivePart = 0;
            sActiveSize = 0;
            sUsingFallback = NO;
        }
    }

    BOOL needsDailyOpen = (!sHandle || !sActiveDay || ![sActiveDay isEqualToString:dayKey]);
    if (needsDailyOpen) {
        SN_CloseHandle(&sHandle);
        SN_SetActivePath(&sActivePath, nil);
        [sActiveDay release];
        sActiveDay = [dayKey copy];
        sActivePart = 0;
        sActiveSize = 0;
        sUsingFallback = NO;

        SN_EnsureDir();
        SN_CleanupOldDailyLogs(dayKey);

        NSUInteger maxPart = SN_MaxPartForDay(dayKey);
        NSUInteger part = maxPart ? maxPart : 1;
        NSString *path = SN_LogDailyPath(dayKey, part);
        if (SN_FileSize(path) >= SN_LOG_MAX_BYTES) {
            part += 1;
            path = SN_LogDailyPath(dayKey, part);
        }
        sHandle = SN_OpenFile(path);
        if (sHandle) {
            SN_SetActivePath(&sActivePath, path);
            sActivePart = part;
            sActiveSize = SN_FileSize(path);
        }
    }

    if (!sHandle) {
        sUsingFallback = YES;
        sActivePart = 0;
        sActiveSize = SN_FileSize(SN_LogLegacyPath());
        sHandle = SN_OpenFile(SN_LogLegacyPath());
        if (sHandle) SN_SetActivePath(&sActivePath, SN_LogLegacyPath());
    }

    NSUInteger offset = 0;
    while (sHandle && offset < data.length) {
        if (!sUsingFallback) {
            NSUInteger room = (sActiveSize < SN_LOG_MAX_BYTES) ? (SN_LOG_MAX_BYTES - sActiveSize) : 0;
            if (room == 0) {
                SN_CloseHandle(&sHandle);
                SN_SetActivePath(&sActivePath, nil);
                sActivePart = (sActivePart > 1) ? (sActivePart + 1) : 2;
                NSString *nextPath = SN_LogDailyPath(dayKey, sActivePart);
                sHandle = SN_OpenFile(nextPath);
                if (sHandle) SN_SetActivePath(&sActivePath, nextPath);
                sActiveSize = sHandle ? SN_FileSize(nextPath) : 0;
                if (!sHandle) {
                    sUsingFallback = YES;
                    sActivePart = 0;
                    sActiveSize = SN_FileSize(SN_LogLegacyPath());
                    sHandle = SN_OpenFile(SN_LogLegacyPath());
                    if (sHandle) SN_SetActivePath(&sActivePath, SN_LogLegacyPath());
                }
                continue;
            }
            NSUInteger chunkLength = MIN(room, data.length - offset);
            NSData *chunk = (chunkLength == data.length && offset == 0)
                ? data
                : [data subdataWithRange:NSMakeRange(offset, chunkLength)];
            @try {
                [sHandle seekToEndOfFile];
                [sHandle writeData:chunk];
                sActiveSize += chunk.length;
                offset += chunk.length;
            } @catch (...) {
                SN_CloseHandle(&sHandle);
                SN_SetActivePath(&sActivePath, nil);
                sUsingFallback = YES;
                sActivePart = 0;
                sActiveSize = SN_FileSize(SN_LogLegacyPath());
                sHandle = SN_OpenFile(SN_LogLegacyPath());
                if (sHandle) SN_SetActivePath(&sActivePath, SN_LogLegacyPath());
            }
        } else {
            NSData *chunk = (offset == 0) ? data : [data subdataWithRange:NSMakeRange(offset, data.length - offset)];
            @try {
                [sHandle seekToEndOfFile];
                [sHandle writeData:chunk];
                offset += chunk.length;
            } @catch (...) {
                SN_CloseHandle(&sHandle);
                SN_SetActivePath(&sActivePath, nil);
                break;
            }
        }
    }

    os_unfair_lock_unlock(&sLock);
}

void logTextIntoFile(NSString *log, const char *file, int line) {
    SN_WriteLogLine(log, file, line, YES);
}

void logRawTextIntoFile(NSString *log) {
    SN_WriteLogLine(log, NULL, 0, NO);
}
