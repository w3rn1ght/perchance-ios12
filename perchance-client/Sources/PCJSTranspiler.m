#import "PCJSTranspiler.h"
#import <WebKit/WebKit.h>

@interface PCJSTranspiler () <WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate>
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, strong) UIWindow *hostWindow;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, PCHandler> *pending;
@property (nonatomic, assign) NSInteger seq;
@property (nonatomic, assign) BOOL ready;
@property (nonatomic, copy, nullable) PCHandler startCompletion;
@end

@implementation PCJSTranspiler

- (instancetype)init {
    if ((self = [super init])) {
        _pending = [NSMutableDictionary dictionary];
        _seq = 0;
    }
    return self;
}

- (BOOL)isReady { return self.ready; }

#pragma mark - Запуск

- (void)startWithCompletion:(PCHandler)completion {
    if (self.web) {
        if (self.ready) {
            if (completion) { completion(@YES, nil); }
        } else {
            self.startCompletion = completion;
        }
        return;
    }

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    WKUserContentController *ucc = [[WKUserContentController alloc] init];
    [ucc addScriptMessageHandler:self name:@"pc"];
    cfg.userContentController = ucc;
    cfg.allowsInlineMediaPlayback = YES;

    self.web = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 320, 480) configuration:cfg];
    self.web.navigationDelegate = self;
    self.web.UIDelegate = self;

    // Реальное окно: в невидимом WKWebView iOS может «усыплять» таймеры и JS.
    // makeKeyAndVisible здесь НЕ вызываем — иначе это окно перехватит клавиатуру
    // и first responder у основного интерфейса.
    UIWindow *win = [[UIWindow alloc] initWithFrame:CGRectMake(-4000, -4000, 320, 480)];
    win.windowLevel = UIWindowLevelNormal - 1;
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.frame = win.bounds;
    self.web.frame = vc.view.bounds;
    self.web.scrollView.scrollEnabled = NO;
    [vc.view addSubview:self.web];
    win.rootViewController = vc;
    win.hidden = NO;
    self.hostWindow = win;

    NSString *path = [[NSBundle mainBundle] pathForResource:@"bridge" ofType:@"html" inDirectory:@"web"];
    if (!path) {
        if (completion) {
            completion(nil, [self error:@"bridge.html не найден в бандле"]);
        }
        return;
    }

    self.startCompletion = completion;
    NSURL *dir = [NSURL fileURLWithPath:[path stringByDeletingLastPathComponent]];
    [self.web loadFileURL:[NSURL fileURLWithPath:path] allowingReadAccessToURL:dir];
}

- (NSError *)error:(NSString *)message {
    return [NSError errorWithDomain:@"PCJSTranspiler" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - Мост из JS

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"pc"]) { return; }
    id body = message.body;
    if (![body isKindOfClass:[NSDictionary class]]) { return; }
    NSDictionary *dict = (NSDictionary *)body;

    NSInteger mid = [dict[@"id"] integerValue];
    if (mid == 0) {
        if ([dict[@"ready"] boolValue]) {
            self.ready = YES;
            PCHandler c = self.startCompletion;
            self.startCompletion = nil;
            if (c) { c(@YES, nil); }
        }
        return;
    }

    PCHandler handler = self.pending[@(mid)];
    if (!handler) { return; }
    [self.pending removeObjectForKey:@(mid)];
    handler(dict[@"value"], nil);
}

- (void)webView:(WKWebView *)webView
didFailProvisionalNavigation:(null_unspecified WKNavigation *)navigation
      withError:(NSError *)error {
    PCHandler c = self.startCompletion;
    self.startCompletion = nil;
    if (c) { c(nil, error); }
}

#pragma mark - API

- (void)evaluate:(NSString *)script completion:(PCHandler)completion {
    if (!self.web) {
        if (completion) { completion(nil, [self error:@"bridge не запущен"]); }
        return;
    }
    [self.web evaluateJavaScript:script completionHandler:^(id result, NSError *err) {
        if (completion) { completion(result, err); }
    }];
}

- (void)callFunction:(NSString *)name args:(NSArray *)args completion:(PCHandler)completion {
    NSInteger mid = ++self.seq;
    NSMutableArray *safeArgs = [NSMutableArray array];
    for (id a in args) {
        [safeArgs addObject:(a ?: [NSNull null])];
    }
    NSDictionary *payload = @{ @"f": name, @"a": safeArgs, @"id": @(mid) };
    NSError *jsonErr = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonErr];
    if (!data) {
        if (completion) { completion(nil, jsonErr); }
        return;
    }
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:@"window.__pcCall(%@)", json];

    if (completion) { self.pending[@(mid)] = [completion copy]; }
    [self.web evaluateJavaScript:script completionHandler:^(id result, NSError *err) {
        if (err) {
            PCHandler h = self.pending[@(mid)];
            [self.pending removeObjectForKey:@(mid)];
            if (h) { h(nil, err); }
        }
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
        if (completion) { completion(nil, [self error:@"bridge ещё не загружен"]); }
        return;
    }
    [self callFunction:@"patchCSS" args:@[ css ?: @"" ] completion:completion];
}

/// HTML переписывается целиком внутри JS (без сети).
- (void)transformHTML:(NSString *)html completion:(nullable PCHandler)completion {
    if (!self.ready) {
        if (completion) { completion(nil, [self error:@"Babel ещё не загружен"]); }
        return;
    }
    [self callFunction:@"transformHTML" args:@[ html ?: @"" ] completion:completion];
}

- (NSString *)jsonLiteral:(NSString *)string {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[ string ?: @"" ] options:0 error:NULL];
    if (!data) { return @"\"\""; }
    NSString *wrapped = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (wrapped.length >= 2) {
        return [wrapped substringWithRange:NSMakeRange(1, wrapped.length - 2)];
    }
    return @"\"\"";
}

@end
