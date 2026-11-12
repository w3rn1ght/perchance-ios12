#import "PCLog.h"

#import <UIKit/UIKit.h>
#import <execinfo.h>
#import <fcntl.h>
#import <mach/mach.h>
#import <mach/task.h>
#import <pthread.h>
#import <signal.h>
#import <stdio.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <time.h>
#import <unistd.h>

static int PCLogFD = -1;
static int PCCrashFD = -1;
static pthread_mutex_t PCLogMutex = PTHREAD_MUTEX_INITIALIZER;

static BOOL PCPreviousCrashed = NO;
static NSString *PCLogDir = nil;
static NSString *PCSessionFile = nil;
static NSString *PCCrashFile = nil;
static NSString *PCPreviousFile = nil;
static NSString *PCFlagFile = nil;

#pragma mark - Пути

static NSString *PCDocumentsDirectory(void) {
    NSArray<NSString *> *dirs =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = dirs.firstObject;
    if (docs.length == 0) { docs = NSTemporaryDirectory(); }
    return docs;
}

NSString *PCLogDirectoryPath(void) {
    if (PCLogDir.length > 0) { return PCLogDir; }
    return [PCDocumentsDirectory() stringByAppendingPathComponent:@"PerchanceLogs"];
}

NSString *PCLogSessionPath(void) {
    if (PCSessionFile.length > 0) { return PCSessionFile; }
    return [PCLogDirectoryPath() stringByAppendingPathComponent:@"session.log"];
}

#pragma mark - Запись

/// Отметка времени без NSDateFormatter: функция вызывается из любых потоков,
/// а в аварийной ситуации — как можно ближе к «просто write()».
static void PCStamp(char *buffer, size_t length) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    time_t seconds = tv.tv_sec;
    struct tm parts;
    localtime_r(&seconds, &parts);
    snprintf(buffer, length, "%02d:%02d:%02d.%03d",
             parts.tm_hour, parts.tm_min, parts.tm_sec, (int)(tv.tv_usec / 1000));
}

static void PCWriteLine(NSString *line, BOOL echo) {
    if (line.length == 0) { return; }
    char stamp[32];
    PCStamp(stamp, sizeof(stamp));
    NSString *full = [NSString stringWithFormat:@"[%s] %@\n", stamp, line];
    NSData *data = [full dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > 0) {
        pthread_mutex_lock(&PCLogMutex);
        if (PCLogFD >= 0) {
            ssize_t written = write(PCLogFD, data.bytes, data.length);
            (void)written;
        }
        pthread_mutex_unlock(&PCLogMutex);
    }
    if (echo) { NSLog(@"[perchance] %@", line); }
}

void PCLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    PCWriteLine(message, NO);
}

void PCLogError(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    PCWriteLine([@"!! " stringByAppendingString:(message ?: @"")], YES);
}

void PCLogMemory(NSString *tag) {
    // phys_footprint есть только в task_vm_info (в mach_task_basic_info его
    // нет в SDK 12.4), а именно он ближе всего к тому, за что убивает jetsam.
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO,
                                 (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS) {
        PCLog(@"memory[%@]: недоступно (%d)", tag, (int)kr);
        return;
    }
    PCLog(@"memory[%@]: %.1f MB (resident %.1f MB, virtual %.1f MB)",
          tag,
          (double)info.phys_footprint / 1048576.0,
          (double)info.resident_size / 1048576.0,
          (double)info.virtual_size / 1048576.0);
}

#pragma mark - Сессия

static void PCEnsureDirectory(void) {
    [[NSFileManager defaultManager] createDirectoryAtPath:PCLogDirectoryPath()
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
}

static void PCOpenLogFiles(void) {
    PCEnsureDirectory();
    if (PCLogFD < 0 && PCSessionFile.length > 0) {
        PCLogFD = open(PCSessionFile.fileSystemRepresentation,
                       O_WRONLY | O_APPEND | O_CREAT, 0644);
    }
    if (PCCrashFD < 0 && PCCrashFile.length > 0) {
        PCCrashFD = open(PCCrashFile.fileSystemRepresentation,
                         O_WRONLY | O_APPEND | O_CREAT, 0644);
    }
}

void PCLogBeginSession(void) {
    NSFileManager *fm = [NSFileManager defaultManager];

    PCLogDir = [PCDocumentsDirectory() stringByAppendingPathComponent:@"PerchanceLogs"];
    PCSessionFile = [PCLogDir stringByAppendingPathComponent:@"session.log"];
    PCCrashFile = [PCLogDir stringByAppendingPathComponent:@"crash.log"];
    PCPreviousFile = [PCLogDir stringByAppendingPathComponent:@"previous.log"];
    PCFlagFile = [PCLogDir stringByAppendingPathComponent:@"running.flag"];

    PCEnsureDirectory();

    // Флаг существует → прошлый сеанс не отметил чистое завершение.
    PCPreviousCrashed = [fm fileExistsAtPath:PCFlagFile];
    if (PCPreviousCrashed) {
        [fm removeItemAtPath:PCPreviousFile error:NULL];
        if ([fm fileExistsAtPath:PCSessionFile]) {
            [fm moveItemAtPath:PCSessionFile toPath:PCPreviousFile error:NULL];
        }
    } else {
        [fm removeItemAtPath:PCPreviousFile error:NULL];
    }

    [fm removeItemAtPath:PCSessionFile error:NULL];
    [fm createFileAtPath:PCSessionFile contents:nil attributes:nil];
    [fm createFileAtPath:PCFlagFile
                 contents:[@"running" dataUsingEncoding:NSUTF8StringEncoding]
               attributes:nil];

    PCOpenLogFiles();

    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = info[@"CFBundleVersion"] ?: @"?";
    PCLog(@"=== Perchance %@ (%@) ===", version, build);
    PCLog(@"system: %@ %@", [[UIDevice currentDevice] systemName],
          [[UIDevice currentDevice] systemVersion]);
    PCLog(@"device: %@ (%@)", [[UIDevice currentDevice] model],
          [[UIDevice currentDevice] name]);
    PCLog(@"paths: %@", PCLogDir);
    if (PCPreviousCrashed) {
        PCLog(@"предыдущий запуск завершился аварийно");
    }
}

void PCLogMarkRunning(void) {
    if (PCFlagFile.length == 0) { return; }
    PCEnsureDirectory();
    [[NSFileManager defaultManager] createFileAtPath:PCFlagFile
                                             contents:[@"running" dataUsingEncoding:NSUTF8StringEncoding]
                                           attributes:nil];
}

void PCLogMarkCleanExit(void) {
    if (PCFlagFile.length == 0) { return; }
    [[NSFileManager defaultManager] removeItemAtPath:PCFlagFile error:NULL];
}

NSString * _Nullable PCLogPreviousCrashText(void) {
    if (!PCPreviousCrashed) { return nil; }

    NSMutableString *out = [NSMutableString string];
    NSString *previous = [NSString stringWithContentsOfFile:PCPreviousFile
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
    if (previous.length > 0) { [out appendString:previous]; }

    NSString *crash = [NSString stringWithContentsOfFile:PCCrashFile
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL];
    if (crash.length > 0) {
        [out appendString:@"\n===== фатальный сигнал (crash.log) =====\n"];
        [out appendString:crash];
    }

    if (out.length == 0) {
        return @"Прошлый запуск завершился аварийно, но лог пуст.\n"
               @"Обычно это означает, что систему не хватило памяти (jetsam) "
               @"или процесс был убит извне.";
    }
    // UITextView на iOS 12 тяжело переваривает сотни тысяч символов, а мы
    // показываем лог сразу после вылета — лишняя нагрузка на память опасна.
    // Для диагностики хватает хвоста: там и находятся последние события.
    static const NSUInteger kMaxShown = 60000;
    if (out.length > kMaxShown) {
        NSString *tail = [out substringFromIndex:out.length - kMaxShown];
        return [@"[…начало лога обрезано, показаны последние 60000 символов…]\n\n"
                stringByAppendingString:tail];
    }
    return out;
}

void PCLogClearAll(void) {
    pthread_mutex_lock(&PCLogMutex);
    if (PCLogFD >= 0) { ftruncate(PCLogFD, 0); }
    if (PCCrashFD >= 0) { ftruncate(PCCrashFD, 0); }
    pthread_mutex_unlock(&PCLogMutex);
    [[NSFileManager defaultManager] removeItemAtPath:PCPreviousFile error:NULL];
    PCLog(@"логи очищены пользователем");
}

#pragma mark - Аварийные обработчики

static const char *PCSignalName(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV (неверный адрес памяти)";
        case SIGBUS:  return "SIGBUS (ошибка шины)";
        case SIGABRT: return "SIGABRT (assert/abort)";
        case SIGILL:  return "SIGILL (недопустимая инструкция)";
        case SIGFPE:  return "SIGFPE (арифметика)";
        case SIGTRAP: return "SIGTRAP";
        default:      return "signal";
    }
}

/// В обработчике сигнала нельзя пользоваться Objective-C — только write().
static void PCSignalHandler(int sig) {
    char header[192];
    int n = snprintf(header, sizeof(header),
                     "\n=== FATAL %s (%d) ===\n", PCSignalName(sig), sig);
    if (PCCrashFD >= 0 && n > 0) {
        ssize_t written = write(PCCrashFD, header, (size_t)n);
        (void)written;
        void *frames[128];
        int count = backtrace(frames, 128);
        if (count > 0) { backtrace_symbols_fd(frames, count, PCCrashFD); }
    }

    signal(sig, SIG_DFL);
    raise(sig);
}

static void PCExceptionHandler(NSException *exception) {
    NSString *text = [NSString stringWithFormat:
        @"=== НЕОБРАБОТАННОЕ ИСКЛЮЧЕНИЕ ===\n%@\n%@\n%@\n",
        exception.name,
        exception.reason,
        [exception.callStackSymbols componentsJoinedByString:@"\n"]];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > 0 && PCCrashFD >= 0) {
        ssize_t written = write(PCCrashFD, data.bytes, data.length);
        (void)written;
    }
    PCLogError(@"исключение: %@ — %@", exception.name, exception.reason);
}

void PCLogInstallCrashHandlers(void) {
    PCOpenLogFiles();

    NSSetUncaughtExceptionHandler(&PCExceptionHandler);

    int signals[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP };
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        signal(signals[i], PCSignalHandler);
    }
    signal(SIGPIPE, SIG_IGN);
}
