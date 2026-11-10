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

    // 1. Транспайлер: отдельный WKWebView с Babel (Resources/web/bridge.html).
    PCJSTranspiler *transpiler = [[PCJSTranspiler alloc] init];
    self.transpiler = transpiler;

    // 2. «Прокси»: скачивает perchance.org и переписывает файлы.
    PCProxy *proxy = [[PCProxy alloc] initWithTranspiler:transpiler];
    [proxy prepare];
    self.proxy = proxy;

    // 3. Обработчик схемы wk:// для WKWebView.
    PCTranspilerProtocolHandler *handler = [[PCTranspilerProtocolHandler alloc] initWithProxy:proxy];
    self.handler = handler;

    // 4. Интерфейс.
    PCMainViewController *vc = [[PCMainViewController alloc] initWithProxy:proxy
                                                                   handler:handler
                                                                 startPath:@"/welcome"];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    // 5. Прогреваем Babel (~3 МБ) — к первому запросу он уже готов.
    [transpiler startWithCompletion:^(id result, NSError *error) {
        if (error != nil) {
            NSLog(@"[perchance-client] Babel: %@", error);
        }
    }];

    return YES;
}

@end
