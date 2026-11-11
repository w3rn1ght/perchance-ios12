#import <UIKit/UIKit.h>
#import "PCAppDelegate.h"

/* ---------------------------------------------------------------------------
 * Лог падений на устройстве.
 *
 * Приложение устанавливается из .deb, и посмотреть консоль на iOS 12 без
 * компьютера непросто. Поэтому пишем необработанные исключения в файл,
 * который видно в Filza (Documents приложения) и в syslog через NSLog.
 * ------------------------------------------------------------------------- */
static NSString *PCCrashLogPath(void) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                        NSUserDomainMask, YES);
    NSString *docs = dirs.firstObject;
    if (docs.length == 0) { docs = NSTemporaryDirectory(); }
    return [docs stringByAppendingPathComponent:@"perchance-crash.log"];
}

static void PCWriteCrash(NSString *text) {
    NSLog(@"[perchance-client] %@", text);
    NSString *path = PCCrashLogPath();
    NSMutableString *all = [NSMutableString string];
    NSString *old = [NSString stringWithContentsOfFile:path
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    if (old.length) { [all appendString:old]; }
    [all appendFormat:@"\n=== %@ ===\n%@\n", [NSDate date], text];
    [all writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static void PCExceptionHandler(NSException *exception) {
    NSString *text = [NSString stringWithFormat:
        @"НЕОБРАБОТАННОЕ ИСКЛЮЧЕНИЕ: %@\nПричина: %@\nСтек:\n%@",
        exception.name,
        exception.reason,
        [exception.callStackSymbols componentsJoinedByString:@"\n"]];
    PCWriteCrash(text);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSSetUncaughtExceptionHandler(&PCExceptionHandler);

        @try {
            return UIApplicationMain(argc, argv,
                                     nil,
                                     NSStringFromClass([PCAppDelegate class]));
        } @catch (NSException *exception) {
            PCExceptionHandler(exception);
            @throw;
        }
    }
}
