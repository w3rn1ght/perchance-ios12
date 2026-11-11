#import "PCMainViewController.h"
#import <WebKit/WebKit.h>
#import "PCProxy.h"
#import "PCTranspilerProtocolHandler.h"
#import "PCJSTranspiler.h"

@interface PCMainViewController () <WKNavigationDelegate, WKUIDelegate, UITextFieldDelegate>
@property (nonatomic, strong) PCProxy *proxy;
@property (nonatomic, strong) PCTranspilerProtocolHandler *handler;
@property (nonatomic, strong) PCJSTranspiler *transpiler;
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, strong) UITextField *addressField;
@property (nonatomic, strong) UIProgressView *progress;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UIButton *reloadButton;
@property (nonatomic, strong) UIView *chromeBar;
@property (nonatomic, strong) UILabel *bootLabel;
@property (nonatomic, copy) NSString *startPath;
@end

@implementation PCMainViewController

@synthesize web = _web;
@synthesize handler = _handler;

- (instancetype)initWithProxy:(PCProxy *)proxy
                      handler:(PCTranspilerProtocolHandler *)handler
                   transpiler:(PCJSTranspiler *)transpiler
                    startPath:(NSString *)path {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _proxy = proxy;
        _handler = handler;
        _transpiler = transpiler;
        _startPath = path.length ? path : @"/welcome";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];
    [self buildChrome];
    [self buildWebView];
    [self waitForTranspilerThenLoad];
}

/// Пока Babel не готов, страницу грузить нельзя: HTML и скрипты ушли бы
/// наверх без переписывания — интерфейс отрисовался бы «мёртвым».
- (void)waitForTranspilerThenLoad {
    self.bootLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.bootLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.bootLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1];
    self.bootLabel.font = [UIFont systemFontOfSize:13];
    self.bootLabel.textAlignment = NSTextAlignmentCenter;
    self.bootLabel.numberOfLines = 0;
    self.bootLabel.text = @"Готовлю JavaScript для iOS 12…";
    [self.view addSubview:self.bootLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.bootLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.bootLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.bootLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [self.bootLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24]
    ]];

    if (self.transpiler.isReady) {
        [self beginLoading];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [self.transpiler startWithCompletion:^(id result, NSError *error) {
        PCMainViewController *strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        if (error != nil) {
            strongSelf.bootLabel.text = [NSString stringWithFormat:
                @"Не удалось подготовить JavaScript:\n%@", error.localizedDescription];
            return;
        }
        [strongSelf beginLoading];
    }];
}

- (void)beginLoading {
    [self.bootLabel removeFromSuperview];
    self.bootLabel = nil;
    [self loadHome];
}

- (void)loadHome {
    [self loadPath:@"/welcome"];
}

#pragma mark - Верхняя панель

- (UIColor *)barColor {
    return [UIColor colorWithWhite:0.11 alpha:1];
}

- (void)buildChrome {
    UIView *bar = [[UIView alloc] init];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.backgroundColor = [self barColor];
    self.chromeBar = bar;
    [self.view addSubview:bar];

    self.backButton = [self iconButton:@"chevron.left" action:@selector(goBack)];
    self.reloadButton = [self iconButton:@"arrow.clockwise" action:@selector(reload)];
    // ВАЖНО: без addSubview активация constraint-ов ниже бросит
    // «no common ancestor» и приложение упадёт на старте.
    [bar addSubview:self.backButton];
    [bar addSubview:self.reloadButton];

    self.addressField = [[UITextField alloc] init];
    self.addressField.translatesAutoresizingMaskIntoConstraints = NO;
    self.addressField.borderStyle = UITextBorderStyleRoundedRect;
    self.addressField.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1];
    self.addressField.textColor = [UIColor whiteColor];
    self.addressField.tintColor = [UIColor whiteColor];
    self.addressField.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.addressField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.addressField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.addressField.keyboardType = UIKeyboardTypeURL;
    self.addressField.returnKeyType = UIReturnKeyGo;
    self.addressField.delegate = self;
    self.addressField.text = @"perchance.org/welcome";
    [bar addSubview:self.addressField];

    self.progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    self.progress.translatesAutoresizingMaskIntoConstraints = NO;
    self.progress.progressTintColor = [UIColor colorWithRed:0.2 green:0.55 blue:0.95 alpha:1];
    self.progress.trackTintColor = [UIColor clearColor];
    self.progress.hidden = YES;
    [bar addSubview:self.progress];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.hidesWhenStopped = YES;
    [bar addSubview:self.spinner];

    CGFloat top = UIApplication.sharedApplication.statusBarFrame.size.height;
    if (top < 20) { top = 20; }

    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.heightAnchor constraintEqualToConstant:top + 44],

        [self.backButton.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:6],
        [self.backButton.centerYAnchor constraintEqualToAnchor:bar.bottomAnchor constant:-22],
        [self.backButton.widthAnchor constraintEqualToConstant:32],
        [self.backButton.heightAnchor constraintEqualToConstant:32],

        [self.reloadButton.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-6],
        [self.reloadButton.centerYAnchor constraintEqualToAnchor:self.backButton.centerYAnchor],
        [self.reloadButton.widthAnchor constraintEqualToConstant:32],
        [self.reloadButton.heightAnchor constraintEqualToConstant:32],

        [self.addressField.leadingAnchor constraintEqualToAnchor:self.backButton.trailingAnchor constant:6],
        [self.addressField.trailingAnchor constraintEqualToAnchor:self.reloadButton.leadingAnchor constant:-6],
        [self.addressField.centerYAnchor constraintEqualToAnchor:self.backButton.centerYAnchor],
        [self.addressField.heightAnchor constraintEqualToConstant:32],

        [self.progress.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [self.progress.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
        [self.progress.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [self.progress.heightAnchor constraintEqualToConstant:2],

        [self.spinner.trailingAnchor constraintEqualToAnchor:self.addressField.trailingAnchor constant:-6],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.addressField.centerYAnchor]
    ]];
}

/// SF Symbols появились только в SDK 13, а мы собираемся SDK 12.4 —
/// поэтому кнопки рисуем обычными типографскими глифами (работают везде).
- (UIButton *)iconButton:(NSString *)symbol action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.tintColor = [UIColor colorWithWhite:0.9 alpha:1];
    BOOL isBack = [symbol containsString:@"chevron"];
    [b setTitle:(isBack ? @"\u2039" : @"\u27F3") forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightRegular];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - WebView

- (void)buildWebView {
    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.allowsInlineMediaPlayback = YES;
    cfg.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    cfg.preferences.javaScriptCanOpenWindowsAutomatically = YES;

    [cfg setURLSchemeHandler:self.handler forURLScheme:PCScheme];

    WKUserContentController *ucc = [[WKUserContentController alloc] init];
    WKUserScript *us = [[WKUserScript alloc] initWithSource:@"window.__perchanceClient = true;"
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:NO];
    [ucc addUserScript:us];
    cfg.userContentController = ucc;

    self.web = [[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
    self.web.translatesAutoresizingMaskIntoConstraints = NO;
    self.web.navigationDelegate = self;
    self.web.UIDelegate = self;
    self.web.allowsBackForwardNavigationGestures = YES;
    self.web.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];
    if (@available(iOS 11.0, *)) {
        self.web.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    self.handler.webView = self.web;

    [self.web addObserver:self forKeyPath:@"estimatedProgress"
                  options:NSKeyValueObservingOptionNew
                  context:NULL];
    [self.view addSubview:self.web];

    [NSLayoutConstraint activateConstraints:@[
        [self.web.topAnchor constraintEqualToAnchor:self.chromeBar.bottomAnchor],
        [self.web.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.web.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.web.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (void)dealloc {
    @try {
        [self.web removeObserver:self forKeyPath:@"estimatedProgress"];
    } @catch (NSException *e) {}
}

- (void)loadPath:(NSString *)path {
    NSString *p = path;
    if (![p hasPrefix:@"/"]) {
        p = [@"/" stringByAppendingString:p];
    }
    [self loadOrigin:[@"perchance.org" stringByAppendingString:p]];
}

/// origin — «хост/путь» без схемы: "perchance.org/welcome",
/// "a257….perchance.org/welcome". Схема подставляется своя (wk://), чтобы
/// запрос попал в наш WKURLSchemeHandler.
- (void)loadOrigin:(NSString *)origin {
    NSString *o = origin.length ? origin : @"perchance.org/welcome";
    if ([o hasPrefix:@"/"]) {
        o = [@"perchance.org" stringByAppendingString:o];
    }
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@", PCScheme, o]];
    if (url == nil) { return; }
    NSURLRequest *req = [NSURLRequest requestWithURL:url
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                     timeoutInterval:45];
    [self.web loadRequest:req];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    NSString *text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    [textField resignFirstResponder];
    if (!text.length) { return YES; }

    if (![text hasPrefix:@"http"]) {
        text = [@"https://" stringByAppendingString:text];
    }
    NSURLComponents *c = [NSURLComponents componentsWithString:text];
    NSString *host = [[c.host lowercaseString] copy];
    if (host.length == 0 || ![host containsString:@"perchance.org"]) {
        host = @"perchance.org";
    }
    NSString *path = c.path.length ? c.path : @"/welcome";
    if (c.query) {
        path = [path stringByAppendingFormat:@"?%@", c.query];
    }
    [self loadOrigin:[NSString stringWithFormat:@"%@%@", host, path]];
    return YES;
}

- (void)goBack {
    if (self.web.canGoBack) { [self.web goBack]; }
}

- (void)reload {
    [self.web reload];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if (![keyPath isEqualToString:@"estimatedProgress"]) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    double p = self.web.estimatedProgress;
    if (p < 1.0) {
        self.progress.hidden = NO;
        self.progress.progress = (float)p;
        [self.spinner startAnimating];
    } else {
        self.progress.progress = 1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            self.progress.hidden = YES;
            [self.spinner stopAnimating];
        });
    }
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.addressField.text = [self displayURLFor:webView.URL];
    self.progress.hidden = YES;
    [self.spinner stopAnimating];
}

- (void)webView:(WKWebView *)webView
didFailProvisionalNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
    [self.spinner stopAnimating];
    self.progress.hidden = YES;
    if (error.code == NSURLErrorCancelled) { return; }
    NSLog(@"[perchance-client] %@", error);
}

- (NSString *)displayURLFor:(NSURL *)url {
    NSString *s = url.absoluteString ?: @"";
    NSString *prefix = [NSString stringWithFormat:@"%@://", PCScheme];
    if ([s hasPrefix:prefix]) {
        s = [s substringFromIndex:prefix.length];
    }
    return s;
}

#pragma mark - WKUIDelegate

/// window.open() и target=_blank: Perchance открывает так главное меню и
/// ссылки сообщества. Раньше мы возвращали nil, а action.request мог быть
/// с враждебной схемой (http/https) — WebKit на этом падал.
/// Теперь: переводим навигацию в нашу схему и грузим в том же WebView.
- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)action
                    windowFeatures:(WKWindowFeatures *)features {
    NSURL *target = action.request.URL;
    if (target != nil) {
        NSString *origin = [self originStringForExternalURL:target];
        if (origin.length > 0) {
            [self loadOrigin:origin];
        } else if ([[target scheme] isEqualToString:@"http"] ||
                   [[target scheme] isEqualToString:@"https"]) {
            // Внешний сайт (например форум lemmy.world) — открываем в Safari.
            [[UIApplication sharedApplication] openURL:target options:@{} completionHandler:nil];
        }
    }
    return nil;
}

/// https://perchance.org/x и https://<id>.perchance.org/x → "perchance.org/x"
/// (или "<id>.perchance.org/x"). Всё остальное — "" (игнорируем).
- (NSString *)originStringForExternalURL:(NSURL *)url {
    NSString *scheme = [url.scheme lowercaseString];
    NSString *host = [url.host lowercaseString];
    NSString *path = url.path;
    if (path.length == 0) { path = @"/"; }

    if ([scheme isEqualToString:PCScheme]) {
        // уже внутри прокси: host уже настоящий
        if (host.length == 0) { return @""; }
        return [host stringByAppendingString:path];
    }
    if ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]) {
        if (host.length == 0) { return @""; }
        if (![host isEqualToString:@"perchance.org"] &&
            ![host hasSuffix:@".perchance.org"]) {
            return @"";
        }
        NSString *query = url.query;
        NSString *out = [host stringByAppendingString:path];
        if (query.length) { out = [out stringByAppendingFormat:@"?%@", query]; }
        return out;
    }
    return @"";
}

- (void)webView:(WKWebView *)webView
    runJavaScriptAlertPanelWithMessage:(NSString *)message
                      initiatedByFrame:(WKFrameInfo *)frame
                     completionHandler:(void (^)(void))completionHandler {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Perchance"
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *x) { completionHandler(); }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView
    runJavaScriptConfirmPanelWithMessage:(NSString *)message
                        initiatedByFrame:(WKFrameInfo *)frame
                       completionHandler:(void (^)(BOOL))completionHandler {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Perchance"
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction *x) { completionHandler(NO); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *x) { completionHandler(YES); }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
