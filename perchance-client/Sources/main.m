#import <UIKit/UIKit.h>
#import "PCAppDelegate.h"
#import "PCLog.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // Лог открываем до UIKit: если приложение упадёт на старте,
        // запись всё равно останется на диске.
        PCLogBeginSession();
        PCLogInstallCrashHandlers();
        PCLogMemory(@"main");

        @try {
            return UIApplicationMain(argc, argv,
                                     nil,
                                     NSStringFromClass([PCAppDelegate class]));
        } @catch (NSException *exception) {
            PCLogError(@"UIApplicationMain: %@ — %@", exception.name, exception.reason);
            @throw;
        }
    }
}
