#import <UIKit/UIKit.h>
#import "LumiAppDelegate.h"
#import "LumiApplication.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv,
                                 NSStringFromClass([LumiApplication class]),
                                 NSStringFromClass([LumiAppDelegate class]));
    }
}
