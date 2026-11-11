#import "PCAppDelegate.h"
#import "PCMainViewController.h"
#import "PCJSTranspiler.h"
#import "PCProxy.h"
#import "PCTranspilerProtocolHandler.h"
#import <WebKit/WebKit.h>

@interface PCAppDelegate ()
@property (nonatomic, strong) PCJSTranspiler *transpiler;
@property (nonatomic, strong) PCProxy *proxy;
@property (nonatomic, strong) PCTranspilerProtocolHandler *handler;
@end

@implementation PCAppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];

    @try {
        PCJSTranspiler *transpiler = [[PCJSTranspiler alloc] init];
        self.transpiler = transpiler;

        PCProxy *proxy = [[PCProxy alloc] initWithTranspiler:transpiler];
        [proxy prepare];
        self.proxy = proxy;

        PCTranspilerProtocolHandler *handler =
            [[PCTranspilerProtocolHandler alloc] initWithProxy:proxy];
        self.handler = handler;

        PCMainViewController *vc =
            [[PCMainViewController alloc] initWithProxy:proxy
                                                handler:handler
                                              startPath:@"/welcome"];
        self.window.rootViewController = vc;
    } @catch (NSException *exception) {
        NSLog(@"[perchance-client] launch failed: %@ %@", exception.name, exception.reason);
        self.window.rootViewController = [self fatalControllerFor:exception];
    }

    [self.window makeKeyAndVisible];

    [self.transpiler startWithCompletion:^(id result, NSError *error) {
        if (error != nil) {
            NSLog(@"[perchance-client] Babel: %@", error);
        }
    }];

    return YES;
}

/// Если что-то упало при сборке интерфейса — показываем причину прямо на экране,
/// а не молча выходим (на iOS 12 без Xcode лог достать сложно).
- (UIViewController *)fatalControllerFor:(NSException *)exception {
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor whiteColor];

    UITextView *text = [[UITextView alloc] initWithFrame:vc.view.bounds];
    text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    text.editable = NO;
    text.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
    text.text = [NSString stringWithFormat:
        @"Perchance не смог запуститься.\n\n%@\n\n%@\n\nПришли этот текст разработчику.",
        exception.reason,
        [exception.callStackSymbols componentsJoinedByString:@"\n"]];
    [vc.view addSubview:text];
    return vc;
}

@end
