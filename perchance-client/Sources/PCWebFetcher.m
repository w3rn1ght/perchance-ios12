#import "PCWebFetcher.h"
#import "PCProxy.h"
#import "PCLog.h"
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

/// Проверяем, что перед нами ещё страница Cloudflare, а не настоящий сайт.
///
/// Нельзя искать просто «challenge-platform» в HTML: Cloudflare вставляет
/// ссылку на jsd-скрипт и в обычные страницы сайта, и тогда любая рабочая
/// страница считалась бы challenge'ем. Смотрим на заголовок, на элементы
/// самой формы проверки и на адрес.
static NSString * const kPCChallengeCheckJS =
    @"(function(){"
    @"var title=document.title||'';"
    @"var body=document.body?String(document.body.innerText||''):'';"
    @"var c=/Just a moment|Checking your browser|Verify you are human|Attention Required|One more step/i.test(title)"
    @"||!!document.querySelector('#challenge-form,#cf-challenge-running,#cf-please-wait,.cf-browser-verification')"
    @"||location.href.indexOf('/cdn-cgi/challenge-platform')!==-1"
    @"||(body.length<400&&/cloudflare/i.test(body)&&/checking|verify|moment|подождите/i.test(body));"
    @"return JSON.stringify({challenge:c,title:title,url:location.href,len:body.length});"
    @"})()";

/// Забираем DOM вместе с doctype.
static NSString * const kPCHTMLJS =
    @"(function(){"
    @"var d=document.doctype?new XMLSerializer().serializeToString(document.doctype)+'\\n':'';"
    @"return d+(document.documentElement?document.documentElement.outerHTML:'');"
    @"})()";

static NSError *PCFetcherError(NSString *message) {
    return [NSError errorWithDomain:@"PCWebFetcher"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// Куки из общего хранилища → в хранилище скрытого WKWebView.
static void PCCopyCookiesToWebStore(WKWebView *web, NSURL *url, void (^done)(void)) {
    NSArray<NSHTTPCookie *> *cookies =
        [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:url];
    WKHTTPCookieStore *store = web.configuration.websiteDataStore.httpCookieStore;
    if (cookies.count == 0 || store == nil) {
        done();
        return;
    }
    dispatch_group_t group = dispatch_group_create();
    for (NSHTTPCookie *cookie in cookies) {
        dispatch_group_enter(group);
        [store setCookie:cookie completionHandler:^{
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), done);
}

/// Куки, полученные WebKit (в том числе cf_clearance), → в общее хранилище.
static void PCCopyCookiesFromWebStore(WKWebView *web, void (^done)(void)) {
    WKHTTPCookieStore *store = web.configuration.websiteDataStore.httpCookieStore;
    if (store == nil) {
        done();
        return;
    }
    [store getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        NSInteger copied = 0;
        for (NSHTTPCookie *cookie in cookies) {
            if ([cookie.domain hasSuffix:@"perchance.org"]) {
                [[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookie:cookie];
                copied++;
            }
        }
        PCLog(@"fetcher: cookies из WebKit %ld (всего %lu)",
              (long)copied, (unsigned long)cookies.count);
        done();
    }];
}

@interface PCWebFetcher () <WKNavigationDelegate, WKUIDelegate>
@property (nonatomic, strong, nullable) WKWebView *webView;
@property (nonatomic, strong, nullable) NSTimer *timeoutTimer;
@property (nonatomic, strong, nullable) NSTimer *recheckTimer;
@property (nonatomic, copy, nullable) void (^completion)(NSString * _Nullable, NSError * _Nullable);
@property (nonatomic, strong) NSMutableArray<dispatch_block_t> *queue;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) BOOL challengeSeen;
@end

@implementation PCWebFetcher

+ (instancetype)shared {
    static PCWebFetcher *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[PCWebFetcher alloc] init];
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = [NSMutableArray array];
    }
    return self;
}

#pragma mark - Очередь

- (void)fetchHTMLForURL:(NSURL *)url
             completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    if (url == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, PCFetcherError(@"пустой URL"));
        });
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        PCWebFetcher *s = weakSelf;
        if (s == nil) { return; }
        // Внутри блока — снова weak: очередь принадлежит self, и сильный
        // захват дал бы цикл «self → queue → block → self».
        __weak PCWebFetcher *weakS = s;
        [s.queue addObject:^{
            PCWebFetcher *strongS = weakS;
            if (strongS == nil) { return; }
            [strongS startFetchForURL:url completion:completion];
        }];
        [s pump];
    });
}

- (void)pump {
    if (self.busy || self.queue.count == 0) { return; }
    self.busy = YES;
    dispatch_block_t block = self.queue.firstObject;
    [self.queue removeObjectAtIndex:0];
    block();
}

- (void)finishQueue {
    self.busy = NO;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf pump];
    });
}

#pragma mark - Загрузка

- (WKWebView *)ensureWebView {
    if (self.webView != nil) { return self.webView; }

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
    cfg.preferences.javaScriptCanOpenWindowsAutomatically = NO;
    cfg.suppressesIncrementalRendering = YES;

    WKWebView *web = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)
                                       configuration:cfg];
    web.customUserAgent = PCUserAgentString();
    web.navigationDelegate = self;
    web.UIDelegate = self;
    web.userInteractionEnabled = NO;
    web.alpha = 0.01;
    web.hidden = NO;

    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (window != nil) {
        [window insertSubview:web atIndex:0];
    }
    self.webView = web;
    PCLog(@"fetcher: скрытый WKWebView создан");
    return web;
}

- (void)startFetchForURL:(NSURL *)url
              completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    WKWebView *web = [self ensureWebView];
    self.completion = completion;
    self.finished = NO;
    self.challengeSeen = NO;
    [self armTimeout];

    PCLog(@"fetcher: GET %@", url.absoluteString);
    __weak typeof(self) weakSelf = self;
    PCCopyCookiesToWebStore(web, url, ^{
        PCWebFetcher *s = weakSelf;
        if (s == nil || s.finished) { return; }
        NSMutableURLRequest *request =
            [NSMutableURLRequest requestWithURL:url
                                    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                timeoutInterval:30];
        [request setValue:PCUserAgentString() forHTTPHeaderField:@"User-Agent"];
        [web loadRequest:request];
    });
}

- (void)armTimeout {
    [self.timeoutTimer invalidate];
    __weak typeof(self) weakSelf = self;
    // 30 с хватает: challenge обычно решается за 5–10 с, а всё это время
    // пользователь смотрит на пустой экран.
    self.timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                        repeats:NO
                                                          block:^(NSTimer *timer) {
        PCWebFetcher *s = weakSelf;
        if (s == nil || s.finished) { return; }
        NSString *message = s.challengeSeen
            ? @"Cloudflare challenge не пройден за 30 секунд"
            : @"таймаут загрузки страницы";
        [s finishWithHTML:nil error:PCFetcherError(message)];
    }];
}

- (void)finishWithHTML:(nullable NSString *)html error:(nullable NSError *)error {
    if (self.finished) { return; }
    self.finished = YES;
    [self.timeoutTimer invalidate];
    self.timeoutTimer = nil;
    [self.recheckTimer invalidate];
    self.recheckTimer = nil;
    [self.webView stopLoading];

    void (^completion)(NSString * _Nullable, NSError * _Nullable) = self.completion;
    self.completion = nil;
    if (completion == nil) {
        [self finishQueue];
        return;
    }

    if (html.length > 0) {
        PCCopyCookiesFromWebStore(self.webView, ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(html, nil);
                [self finishQueue];
            });
        });
    } else {
        completion(nil, error ?: PCFetcherError(@"пустая страница"));
        [self finishQueue];
    }
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView
    didStartProvisionalNavigation:(WKNavigation *)navigation {
    if (self.finished) { return; }
    PCLog(@"fetcher: старт %@", webView.URL.absoluteString ?: @"-");
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (self.finished) { return; }
    [self checkPageState];
}

/// Спрашиваем страницу, пройден ли challenge. Если ещё нет — перепроверяем
/// через 2 секунды: некоторые проверки подменяют содержимое без перехода на
/// новый адрес, и didFinishNavigation больше не придёт.
- (void)checkPageState {
    if (self.finished) { return; }
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:kPCChallengeCheckJS completionHandler:^(id result, NSError *error) {
        PCWebFetcher *s = weakSelf;
        if (s == nil || s.finished) { return; }
        if (error != nil) {
            [s finishWithHTML:nil error:error];
            return;
        }
        NSDictionary *info = nil;
        if ([result isKindOfClass:[NSString class]]) {
            NSData *data = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
            info = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        }
        if ([info[@"challenge"] boolValue]) {
            s.challengeSeen = YES;
            PCLog(@"fetcher: challenge %@ (%@)", info[@"url"] ?: s.webView.URL.absoluteString ?: @"-",
                  info[@"title"] ?: @"-");
            [s scheduleRecheck];
            return;
        }
        [s extractHTML];
    }];
}

- (void)scheduleRecheck {
    [self.recheckTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.recheckTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                        repeats:NO
                                                          block:^(NSTimer *timer) {
        [weakSelf checkPageState];
    }];
}

- (void)extractHTML {
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:kPCHTMLJS completionHandler:^(id html, NSError *htmlError) {
        PCWebFetcher *s = weakSelf;
        if (s == nil || s.finished) { return; }
        if (htmlError != nil || ![html isKindOfClass:[NSString class]] || [html length] == 0) {
            [s finishWithHTML:nil error:htmlError ?: PCFetcherError(@"пустой HTML")];
            return;
        }
        [s finishWithHTML:html error:nil];
    }];
}

- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error {
    if (self.finished || error.code == NSURLErrorCancelled) { return; }
    [self finishWithHTML:nil error:error];
}

- (void)webView:(WKWebView *)webView
    didFailNavigation:(WKNavigation *)navigation
            withError:(NSError *)error {
    if (self.finished || error.code == NSURLErrorCancelled) { return; }
    [self finishWithHTML:nil error:error];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    if (self.finished) { return; }
    [self finishWithHTML:nil error:PCFetcherError(@"процесс WebKit завершился")];
}

#pragma mark - WKUIDelegate

- (void)webView:(WKWebView *)webView
    runJavaScriptAlertPanelWithMessage:(NSString *)message
                      initiatedByFrame:(WKFrameInfo *)frame
                     completionHandler:(void (^)(void))completionHandler {
    completionHandler();
}

- (void)webView:(WKWebView *)webView
    runJavaScriptConfirmPanelWithMessage:(NSString *)message
                        initiatedByFrame:(WKFrameInfo *)frame
                       completionHandler:(void (^)(BOOL))completionHandler {
    completionHandler(NO);
}

- (void)webView:(WKWebView *)webView
    runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
                              defaultText:(NSString *)defaultText
                         initiatedByFrame:(WKFrameInfo *)frame
                        completionHandler:(void (^)(NSString * _Nullable))completionHandler {
    completionHandler(nil);
}

- (nullable WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
    return nil;
}

@end
