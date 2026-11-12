#import "PCJSTranspiler.h"
#import "PCLog.h"
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

/// Babel на iOS 12 грузится несколько секунд, а один прогон на большом файле
/// может занять десятки секунд. Ограничиваем ожидание, чтобы интерфейс
/// показывал ошибку с кнопкой «Повторить», а не висел вечно.
static const NSTimeInterval PCBridgeStartTimeout = 40.0;
static const NSTimeInterval PCBridgeCallTimeout = 90.0;
static const NSInteger PCBridgeMaxRestarts = 2;

/// Прокси, чтобы WKUserContentController не удерживал транспайлер навсегда.
@interface PCWeakScriptHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak, nullable) id<WKScriptMessageHandler> target;
@end

@implementation PCWeakScriptHandler

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message {
    id<WKScriptMessageHandler> target = self.target;
    if (target == nil) { return; }
    [target userContentController:controller didReceiveScriptMessage:message];
}

@end

@interface PCJSTranspiler () <WKScriptMessageHandler, WKNavigationDelegate>
@property (nonatomic, strong, nullable) WKWebView *web;
@property (nonatomic, strong, nullable) UIWindow *hostWindow;
@property (nonatomic, assign) BOOL ownsWindow;
@property (nonatomic, strong) NSMutableArray *startCompletions;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id> *pending;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *jobs;
@property (nonatomic, assign) NSInteger seq;
@property (nonatomic, assign) BOOL ready;
@property (nonatomic, assign) BOOL starting;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) NSInteger restarts;
@end

@implementation PCJSTranspiler

- (instancetype)init {
    if ((self = [super init])) {
        _startCompletions = [NSMutableArray array];
        _pending = [NSMutableDictionary dictionary];
        _jobs = [NSMutableArray array];
        _seq = 0;
    }
    return self;
}

- (BOOL)isReady { return self.ready; }

- (void)attachToWindow:(UIWindow *)window {
    self.hostWindow = window;
    self.ownsWindow = NO;
}

- (NSError *)error:(NSString *)message {
    return [NSError errorWithDomain:@"PCJSTranspiler" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"ошибка Babel"}];
}

#pragma mark - Запуск

- (void)startWithCompletion:(PCHandler)completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startWithCompletion:completion];
        });
        return;
    }
    if (self.ready) {
        if (completion) { completion(@YES, nil); }
        return;
    }
    if (completion) {
        [self.startCompletions addObject:[completion copy]];
    }
    if (self.starting) {
        PCLog(@"babel: мост уже запускается, ждём");
        return;
    }
    [self boot];
}

- (void)boot {
    self.starting = YES;
    self.busy = NO;

    // Защита от второго моста: старый WebView обязательно убираем.
    if (self.web != nil) {
        WKWebView *old = self.web;
        self.web = nil;
        old.navigationDelegate = nil;
        [old stopLoading];
        [old removeFromSuperview];
    }

    PCLog(@"babel: создаю мост");
    PCLogMemory(@"babel-boot");

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    PCWeakScriptHandler *proxy = [[PCWeakScriptHandler alloc] init];
    proxy.target = self;
    WKUserContentController *controller = [[WKUserContentController alloc] init];
    [controller addScriptMessageHandler:proxy name:@"pc"];
    configuration.userContentController = controller;
    configuration.allowsInlineMediaPlayback = YES;

    WKWebView *web = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 320, 480)
                                        configuration:configuration];
    web.navigationDelegate = self;
    web.scrollView.scrollEnabled = NO;
    web.backgroundColor = [UIColor clearColor];
    web.opaque = NO;
    self.web = web;

    if (self.hostWindow != nil) {
        [self.hostWindow insertSubview:web atIndex:0];
    } else {
        // Реальное окно: невидимый (не прикреплённый к окну) WKWebView
        // на iOS 12 «засыпает» и перестаёт выполнять JS.
        UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(-4000, -4000, 320, 480)];
        window.windowLevel = UIWindowLevelNormal - 1;
        UIViewController *controller2 = [[UIViewController alloc] init];
        controller2.view.backgroundColor = [UIColor clearColor];
        controller2.view.frame = window.bounds;
        web.frame = controller2.view.bounds;
        [controller2.view addSubview:web];
        window.rootViewController = controller2;
        window.hidden = NO;
        self.hostWindow = window;
        self.ownsWindow = YES;
    }

    NSString *path = [[NSBundle mainBundle] pathForResource:@"bridge"
                                                     ofType:@"html"
                                                inDirectory:@"web"];
    if (path == nil) {
        [self failStart:[self error:@"bridge.html не найден в бандле"]];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(PCBridgeStartTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PCJSTranspiler *strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        if (strongSelf.ready || !strongSelf.starting) { return; }
        [strongSelf failStart:[strongSelf error:@"Babel не загрузился за 40 секунд"]];
    });

    NSURL *directory = [NSURL fileURLWithPath:[path stringByDeletingLastPathComponent]];
    [web loadFileURL:[NSURL fileURLWithPath:path] allowingReadAccessToURL:directory];
}

- (void)failStart:(NSError *)error {
    self.starting = NO;
    PCLogError(@"babel: старт не удался: %@", error.localizedDescription);

    NSArray *completions = [self.startCompletions copy];
    [self.startCompletions removeAllObjects];
    for (id object in completions) {
        PCHandler handler = (PCHandler)object;
        handler(nil, error);
    }
}

- (void)restart {
    self.restarts = self.restarts + 1;
    PCLogError(@"babel: перезапуск моста (%ld)", (long)self.restarts);

    self.ready = NO;
    self.starting = NO;
    self.busy = NO;
    [self.jobs removeAllObjects];
    [self failAllPending:[self error:@"мост перезапускается"]];

    WKWebView *web = self.web;
    self.web = nil;
    web.navigationDelegate = nil;
    [web stopLoading];
    [web removeFromSuperview];

    if (self.ownsWindow) {
        self.hostWindow.hidden = YES;
        self.hostWindow = nil;
    }

    [self boot];
}

- (void)failAllPending:(NSError *)error {
    NSDictionary<NSNumber *, id> *snapshot = [self.pending copy];
    [self.pending removeAllObjects];
    for (NSNumber *key in snapshot) {
        PCHandler handler = (PCHandler)snapshot[key];
        handler(nil, error);
    }
}

#pragma mark - Мост

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"pc"]) { return; }
    id body = message.body;
    if (![body isKindOfClass:[NSDictionary class]]) { return; }
    NSDictionary *dict = (NSDictionary *)body;

    NSInteger identifier = [dict[@"id"] integerValue];
    if (identifier == 0) {
        if ([dict[@"ready"] boolValue]) {
            PCLog(@"babel: мост готов");
            self.ready = YES;
            self.starting = NO;
            self.restarts = 0;
            PCLogMemory(@"babel-ready");

            NSArray *completions = [self.startCompletions copy];
            [self.startCompletions removeAllObjects];
            for (id object in completions) {
                PCHandler handler = (PCHandler)object;
                handler(@YES, nil);
            }
            [self pump];
        }
        return;
    }

    [self finishJob:identifier result:dict[@"value"] error:nil];
}

- (void)webView:(WKWebView *)webView
    didFinishNavigation:(WKNavigation *)navigation {
    PCLog(@"babel: bridge.html загружен");
}

- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error {
    [self failStart:error];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    PCLogError(@"babel: WebContent-процесс моста убит системой");
    if (self.restarts >= PCBridgeMaxRestarts) {
        PCLogError(@"babel: лимит автоматических перезапусков исчерпан");
        [self failAllPending:[self error:@"мост Babel остановлен системой"]];
        return;
    }
    [self restart];
}

#pragma mark - Очередь заданий

- (void)callFunction:(NSString *)name
                args:(NSArray *)args
          completion:(PCHandler)completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self callFunction:name args:args completion:completion];
        });
        return;
    }
    if (!self.ready) {
        if (completion) { completion(nil, [self error:@"Babel ещё не загружен"]); }
        return;
    }

    NSInteger identifier = ++self.seq;
    if (completion) {
        self.pending[@(identifier)] = [completion copy];
    }

    NSMutableArray *safeArgs = [NSMutableArray array];
    for (id argument in args) {
        [safeArgs addObject:(argument ?: [NSNull null])];
    }
    [self.jobs addObject:@{ @"f": name ?: @"",
                            @"a": safeArgs,
                            @"id": @(identifier) }];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(PCBridgeCallTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PCJSTranspiler *strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        if (strongSelf.pending[@(identifier)] == nil) { return; }
        [strongSelf finishJob:identifier
                       result:nil
                        error:[strongSelf error:@"Babel не ответил (таймаут)"]];
    });

    [self pump];
}

- (void)pump {
    if (self.busy || !self.ready || self.jobs.count == 0) { return; }

    NSDictionary *job = self.jobs.firstObject;
    [self.jobs removeObjectAtIndex:0];

    NSString *function = job[@"f"];
    NSArray *args = job[@"a"];
    NSNumber *identifier = job[@"id"];
    self.busy = YES;

    NSDictionary *payload = @{ @"f": function, @"a": args, @"id": identifier };
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload
                                                   options:0
                                                     error:&jsonError];
    if (data == nil) {
        PCLogError(@"babel: не удалось собрать запрос: %@", jsonError.localizedDescription);
        [self finishJob:identifier.integerValue result:nil error:jsonError];
        return;
    }

    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:@"window.__pcCall(%@)", json];

    __weak typeof(self) weakSelf = self;
    [self.web evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        PCJSTranspiler *strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        if (error != nil) {
            PCLogError(@"babel: %@ упал в JS: %@", function, error.localizedDescription);
            [strongSelf finishJob:identifier.integerValue result:nil error:error];
        }
        // При успехе ждём ответ через postMessage — он придёт в finishJob.
    }];
}

- (void)finishJob:(NSInteger)identifier result:(id)result error:(NSError *)error {
    PCHandler handler = (PCHandler)self.pending[@(identifier)];
    if (handler != nil) {
        [self.pending removeObjectForKey:@(identifier)];
        handler(result, error);
    }
    self.busy = NO;
    [self pump];
}

#pragma mark - API

- (void)evaluate:(NSString *)script completion:(PCHandler)completion {
    if (self.web == nil) {
        if (completion) { completion(nil, [self error:@"мост не запущен"]); }
        return;
    }
    [self.web evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        if (completion) { completion(result, error); }
    }];
}

- (void)transformJS:(NSString *)code
           filename:(NSString *)filename
         completion:(PCHandler)completion {
    if (!self.ready) {
        if (completion) { completion(nil, [self error:@"Babel ещё не загружен"]); }
        return;
    }
    [self callFunction:@"transformJS"
                  args:@[ code ?: @"", filename ?: @"inline.js" ]
            completion:completion];
}

- (void)patchCSS:(NSString *)css completion:(PCHandler)completion {
    if (!self.ready) {
        if (completion) { completion(nil, [self error:@"Babel ещё не загружен"]); }
        return;
    }
    [self callFunction:@"patchCSS" args:@[ css ?: @"" ] completion:completion];
}

- (void)transformHTML:(NSString *)html
             baseHref:(NSString *)baseHref
           completion:(PCHandler)completion {
    if (!self.ready) {
        if (completion) { completion(nil, [self error:@"Babel ещё не загружен"]); }
        return;
    }
    [self callFunction:@"transformHTML"
                  args:@[ html ?: @"", baseHref ?: @"" ]
            completion:completion];
}

@end
