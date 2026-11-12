#import "PCAppDelegate.h"
#import "PCMainViewController.h"
#import "PCJSTranspiler.h"
#import "PCProxy.h"
#import "PCTranspilerProtocolHandler.h"
#import "PCLog.h"
#import "PCLogViewController.h"
#import <WebKit/WebKit.h>

@interface PCAppDelegate ()
@property (nonatomic, strong) PCJSTranspiler *transpiler;
@property (nonatomic, strong) PCProxy *proxy;
@property (nonatomic, strong) PCTranspilerProtocolHandler *handler;
@property (nonatomic, assign) BOOL started;
@end

@implementation PCAppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    PCLog(@"app: didFinishLaunching");

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];

    // Если прошлый сеанс не отметил чистое завершение — сначала показываем
    // его лог. Никаких WKWebView на этом экране нет, поэтому даже если
    // страница стабильно роняет приложение, лог всё равно будет видно.
    NSString *previous = PCLogPreviousCrashText();
    if (previous.length > 0) {
        PCLogError(@"app: прошлый запуск завершился аварийно — открываю лог");
        PCLogViewController *log = [[PCLogViewController alloc] init];
        log.logText = previous;
        __weak typeof(self) weakSelf = self;
        log.onContinue = ^{
            PCAppDelegate *strongSelf = weakSelf;
            if (strongSelf == nil) { return; }
            [strongSelf startBrowser];
        };
        self.window.rootViewController = log;
    } else {
        [self startBrowser];
    }

    [self.window makeKeyAndVisible];
    PCLogMemory(@"after-launch");
    return YES;
}

/// Создание браузера вынесено отдельно: его вызывает либо обычный запуск,
/// либо кнопка «Продолжить» на экране лога.
- (void)startBrowser {
    if (self.started) { return; }
    self.started = YES;

    @try {
        PCJSTranspiler *transpiler = [[PCJSTranspiler alloc] init];
        self.transpiler = transpiler;

        PCProxy *proxy = [[PCProxy alloc] initWithTranspiler:transpiler];
        [proxy prepare];
        self.proxy = proxy;

        PCTranspilerProtocolHandler *handler =
            [[PCTranspilerProtocolHandler alloc] initWithProxy:proxy];
        self.handler = handler;

        PCMainViewController *controller =
            [[PCMainViewController alloc] initWithProxy:proxy
                                                handler:handler
                                             transpiler:transpiler
                                              startPath:@"/welcome"];
        self.window.rootViewController = controller;
        PCLog(@"app: интерфейс создан");
    } @catch (NSException *exception) {
        PCLogError(@"app: не удалось создать интерфейс: %@ — %@",
                   exception.name, exception.reason);
        self.window.rootViewController = [self fatalControllerFor:exception];
        return;
    }

    PCLogMemory(@"before-babel");
    __weak typeof(self) weakSelf = self;
    [self.transpiler startWithCompletion:^(id result, NSError *error) {
        PCAppDelegate *strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        if (error != nil) {
            PCLogError(@"app: Babel не запустился: %@", error.localizedDescription);
            return;
        }
        PCLog(@"app: Babel готов");
        PCLogMemory(@"babel-ready");
    }];
}

- (UIViewController *)fatalControllerFor:(NSException *)exception {
    UIViewController *controller = [[UIViewController alloc] init];
    controller.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];

    UITextView *text = [[UITextView alloc] initWithFrame:controller.view.bounds];
    text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    text.editable = NO;
    text.backgroundColor = [UIColor clearColor];
    text.textColor = [UIColor whiteColor];
    text.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    text.text = [NSString stringWithFormat:
        @"Perchance не смог запуститься.\n\n%@\n\n%@\n\nЛог: %@",
        exception.reason,
        [exception.callStackSymbols componentsJoinedByString:@"\n"],
        PCLogSessionPath()];
    [controller.view addSubview:text];
    return controller;
}

#pragma mark - Жизненный цикл

- (void)applicationDidBecomeActive:(UIApplication *)application {
    PCLog(@"app: active");
    PCLogMarkRunning();
    PCLogMemory(@"active");
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    PCLog(@"app: background");
    PCLogMemory(@"background");
    // В фоне приложение может быть выгружено системой — это не наш вылет.
    PCLogMarkCleanExit();
}

- (void)applicationWillTerminate:(UIApplication *)application {
    PCLog(@"app: terminate");
    PCLogMarkCleanExit();
}

@end
