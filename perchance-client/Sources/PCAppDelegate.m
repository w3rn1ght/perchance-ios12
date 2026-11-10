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

    // 1. Транспайлер: WKWebView с Babel внутри (см. Resources/web/bridge.html).
    self.transpiler = [[PCJSTranspiler alloc] init];

    // 2. Прокси: скачивает perchance.org и переписывает файлы.
    self.proxy = [[PCProxy alloc] initWithTranspiler:self.transpiler];
    [self.proxy prepare];

    // 3. Обработчик схемы wk:// для WKWebView.
    self.handler = [[PCTranspilerProtocolHandler alloc] initWithProxy:self.proxy];

    // 4. Интерфейс.
    PCMainViewController *vc = [[PCMainViewController alloc] initWithProxy:self.proxy
                                                                   handler:self.handler
                                                                 startPath:@"/welcome"];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    // 5. Прогреваем Babel заранее — загрузка ~3 МБ, на iOS 12 это заметно.
    [self.transpiler startWithCompletion:^(id result, NSError *error) {
        if (error) {
            NSLog(@"[perchance-client] Babel: %@", error);
        } else {
            NSLog(@"[perchance-client] Babel готов");
        }
    }];

    return YES;
}

@end
