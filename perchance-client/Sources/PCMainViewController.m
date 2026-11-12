#import "PCMainViewController.h"
#import <WebKit/WebKit.h>
#import "PCProxy.h"
#import "PCTranspilerProtocolHandler.h"
#import "PCJSTranspiler.h"
#import "PCLog.h"
#import "PCLogViewController.h"

@interface PCMainViewController () <WKNavigationDelegate, WKUIDelegate, UITextFieldDelegate>
@property (nonatomic, strong) PCProxy *proxy;
@property (nonatomic, strong, readwrite) PCTranspilerProtocolHandler *handler;
@property (nonatomic, strong) PCJSTranspiler *transpiler;
@property (nonatomic, strong, readwrite) WKWebView *web;
@property (nonatomic, strong) UITextField *addressField;
@property (nonatomic, strong) UIProgressView *progress;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UIButton *reloadButton;
@property (nonatomic, strong) UIView *chromeBar;

@property (nonatomic, strong) UIView *bootView;
@property (nonatomic, strong) UILabel *bootLabel;
@property (nonatomic, strong) UILabel *bootHint;
@property (nonatomic, strong) UIActivityIndicatorView *bootSpinner;
@property (nonatomic, strong) UIButton *bootRetry;

@property (nonatomic, strong) UIView *errorBar;
@property (nonatomic, strong) UILabel *errorLabel;

@property (nonatomic, assign) BOOL pageLoaded;
@property (nonatomic, assign) BOOL terminatedOnce;
@end

@implementation PCMainViewController

- (instancetype)initWithProxy:(PCProxy *)proxy
                      handler:(PCTranspilerProtocolHandler *)handler
                   transpiler:(PCJSTranspiler *)transpiler
                    startPath:(NSString *)path {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _proxy = proxy;
        _handler = handler;
        _transpiler = transpiler;
        _startPath = path.length > 0 ? path : @"/welcome";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    PCLog(@"ui: viewDidLoad");
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];
    [self buildChrome];
    [self buildWebView];
    [self buildBootOverlay];
    [self buildErrorBar];
    [self prepareTranspiler];
}

#pragma mark - Запуск Babel

- (void)prepareTranspiler {
    PCLog(@"ui: ждём Babel");
    self.bootLabel.text = @"Готовлю JavaScript для iOS 12…";
    self.bootLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    self.bootHint.text = @"Первый запуск занимает несколько секунд.";
    self.bootRetry.hidden = YES;
    self.bootView.hidden = NO;
    [self.bootSpinner startAnimating];

    __weak typeof(self) weakSelf = self;
    [self.transpiler startWithCompletion:^(id result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            PCMainViewController *strongSelf = weakSelf;
            if (strongSelf == nil) { return; }
            if (error != nil) {
                [strongSelf showBootError:error.localizedDescription];
                return;
            }
            [strongSelf.bootSpinner stopAnimating];
            strongSelf.bootView.hidden = YES;
            if (!strongSelf.pageLoaded) {
                [strongSelf loadHome];
            }
        });
    }];
}

- (void)showBootError:(NSString *)message {
    PCLogError(@"ui: Babel недоступен: %@", message);
    [self.bootSpinner stopAnimating];
    self.bootView.hidden = NO;
    self.bootLabel.text = @"Не удалось подготовить JavaScript";
    self.bootLabel.textColor = [UIColor colorWithRed:0.95 green:0.45 blue:0.45 alpha:1];
    self.bootHint.text = [NSString stringWithFormat:@"%@\n\nЛог: %@\nДолгое нажатие на ⟳ открывает лог.",
                          message ?: @"неизвестная ошибка", PCLogSessionPath()];
    self.bootRetry.hidden = NO;
}

- (void)retryTapped {
    PCLog(@"ui: кнопка «Повторить»");
    self.errorBar.hidden = YES;
    if (self.transpiler.isReady) {
        self.bootView.hidden = YES;
        [self loadHome];
        return;
    }
    [self.transpiler restart];
    [self prepareTranspiler];
}

#pragma mark - Навигация

- (void)loadHome {
    [self loadPath:self.startPath ?: @"/welcome"];
}

- (void)loadPath:(NSString *)path {
    if (path.length == 0) {
        [self loadOrigin:@"perchance.org/welcome"];
        return;
    }
    NSString *normalized = path;
    if (![normalized hasPrefix:@"/"]) {
        normalized = [@"/" stringByAppendingString:normalized];
    }
    [self loadOrigin:[@"perchance.org" stringByAppendingString:normalized]];
}

- (void)loadOrigin:(NSString *)origin {
    if (origin.length == 0 || ![origin hasPrefix:@"perchance.org"]) {
        PCLogError(@"ui: отклонён адрес «%@»", origin);
        if (![origin isEqualToString:@"perchance.org/welcome"]) {
            [self loadOrigin:@"perchance.org/welcome"];
        }
        return;
    }

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@", PCScheme, origin]];
    if (url == nil) {
        PCLogError(@"ui: не разобрал адрес «%@»", origin);
        return;
    }

    PCLog(@"ui: переход %@", url.absoluteString);
    self.errorBar.hidden = YES;
    NSURLRequest *request = [NSURLRequest requestWithURL:url
                                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                        timeoutInterval:60];
    [self.web loadRequest:request];
}

- (void)goBack {
    if (self.web.canGoBack) { [self.web goBack]; }
}

- (void)logLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) { return; }
    [self showLog];
}

- (void)showLog {
    PCLog(@"ui: открыт лог по долгому нажатию");
    NSString *text = [NSString stringWithContentsOfFile:PCLogSessionPath()
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    PCLogViewController *controller = [[PCLogViewController alloc] init];
    controller.logText = text.length > 0 ? text : @"(лог пуст)";
    __weak typeof(self) weakSelf = self;
    controller.onContinue = ^{
        [weakSelf dismissViewControllerAnimated:YES completion:nil];
    };
    controller.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)reload {
    PCLog(@"ui: reload");
    self.errorBar.hidden = YES;
    if (self.web.URL == nil) {
        [self loadHome];
    } else {
        [self.web reload];
    }
}

#pragma mark - Интерфейс

- (UIColor *)barColor {
    return [UIColor colorWithWhite:0.11 alpha:1];
}

- (void)buildChrome {
    UIView *bar = [[UIView alloc] init];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.backgroundColor = [self barColor];
    self.chromeBar = bar;
    [self.view addSubview:bar];

    self.backButton = [self createButton:@"\u2039" action:@selector(goBack)];
    self.reloadButton = [self createButton:@"\u27F3" action:@selector(reload)];
    [bar addSubview:self.backButton];
    [bar addSubview:self.reloadButton];

    // Скрытая диагностика: долгое нажатие на «обновить» открывает текущий лог.
    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(logLongPress:)];
    [self.reloadButton addGestureRecognizer:press];

    self.addressField = [[UITextField alloc] init];
    self.addressField.translatesAutoresizingMaskIntoConstraints = NO;
    self.addressField.borderStyle = UITextBorderStyleRoundedRect;
    self.addressField.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1];
    self.addressField.textColor = [UIColor whiteColor];
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

- (UIButton *)createButton:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.tintColor = [UIColor colorWithWhite:0.9 alpha:1];
    button.titleLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightRegular];
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)buildWebView {
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.allowsInlineMediaPlayback = YES;
    configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = YES;

    [configuration setURLSchemeHandler:self.handler forURLScheme:PCScheme];

    WKUserContentController *controller = [[WKUserContentController alloc] init];
    WKUserScript *script = [[WKUserScript alloc] initWithSource:@"window.__perchanceClient = true;"
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                               forMainFrameOnly:NO];
    [controller addUserScript:script];
    configuration.userContentController = controller;

    self.web = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
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

- (void)buildBootOverlay {
    UIView *overlay = [[UIView alloc] init];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];
    self.bootView = overlay;
    [self.view addSubview:overlay];

    UILabel *icon = [[UILabel alloc] init];
    icon.text = @"🎲";
    icon.font = [UIFont systemFontOfSize:40];
    icon.textAlignment = NSTextAlignmentCenter;

    self.bootLabel = [[UILabel alloc] init];
    self.bootLabel.text = @"Готовлю JavaScript для iOS 12…";
    self.bootLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    self.bootLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.bootLabel.numberOfLines = 0;
    self.bootLabel.textAlignment = NSTextAlignmentCenter;

    self.bootSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    [self.bootSpinner startAnimating];

    self.bootHint = [[UILabel alloc] init];
    self.bootHint.text = @"Первый запуск занимает несколько секунд.";
    self.bootHint.textColor = [UIColor colorWithWhite:0.55 alpha:1];
    self.bootHint.font = [UIFont systemFontOfSize:11];
    self.bootHint.numberOfLines = 0;
    self.bootHint.textAlignment = NSTextAlignmentCenter;

    self.bootRetry = [UIButton buttonWithType:UIButtonTypeSystem];
    self.bootRetry.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    self.bootRetry.tintColor = [UIColor whiteColor];
    self.bootRetry.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.bootRetry.layer.cornerRadius = 8;
    self.bootRetry.hidden = YES;
    [self.bootRetry setTitle:@"Повторить" forState:UIControlStateNormal];
    [self.bootRetry addTarget:self action:@selector(retryTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.bootRetry.heightAnchor constraintEqualToConstant:38].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
        @[ icon, self.bootLabel, self.bootSpinner, self.bootRetry, self.bootHint ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 12;
    [overlay addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [overlay.topAnchor constraintEqualToAnchor:self.chromeBar.bottomAnchor],
        [overlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [stack.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:28],
        [stack.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor constant:-28]
    ]];
}

- (void)buildErrorBar {
    UIView *bar = [[UIView alloc] init];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.backgroundColor = [UIColor colorWithRed:0.55 green:0.13 blue:0.13 alpha:0.97];
    bar.hidden = YES;
    self.errorBar = bar;
    [self.view addSubview:bar];

    self.errorLabel = [[UILabel alloc] init];
    self.errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.errorLabel.textColor = [UIColor whiteColor];
    self.errorLabel.font = [UIFont systemFontOfSize:11];
    self.errorLabel.numberOfLines = 2;
    [bar addSubview:self.errorLabel];

    UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
    retry.translatesAutoresizingMaskIntoConstraints = NO;
    retry.tintColor = [UIColor whiteColor];
    retry.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [retry setTitle:@"Повторить" forState:UIControlStateNormal];
    [retry addTarget:self action:@selector(retryTapped) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:retry];

    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:self.chromeBar.bottomAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.heightAnchor constraintEqualToConstant:46],

        [self.errorLabel.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:12],
        [self.errorLabel.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [self.errorLabel.trailingAnchor constraintEqualToAnchor:retry.leadingAnchor constant:-8],

        [retry.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-12],
        [retry.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [retry.widthAnchor constraintEqualToConstant:88]
    ]];
}

- (void)showError:(NSString *)message {
    self.errorLabel.text = message;
    self.errorBar.hidden = NO;
}

#pragma mark - KVO

- (void)dealloc {
    @try {
        [self.web removeObserver:self forKeyPath:@"estimatedProgress"];
    } @catch (NSException *exception) {
        PCLogError(@"ui: dealloc observer: %@", exception.reason);
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if (![keyPath isEqualToString:@"estimatedProgress"]) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    double value = self.web.estimatedProgress;
    if (value < 1.0) {
        self.progress.hidden = NO;
        self.progress.progress = (float)value;
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

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    PCLogError(@"ui: memory warning");
    PCLogMemory(@"memory-warning");
}

#pragma mark - Адресная строка

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    NSString *text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    [textField resignFirstResponder];
    if (text.length == 0) { return YES; }

    if (![text hasPrefix:@"http"]) {
        text = [@"https://" stringByAppendingString:text];
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:text];
    NSString *host = [components.host lowercaseString];
    if (host.length == 0 || ![host containsString:@"perchance.org"]) {
        host = @"perchance.org";
    }
    NSString *path = components.path.length > 0 ? components.path : @"/welcome";
    if (components.query.length > 0) {
        path = [path stringByAppendingFormat:@"?%@", components.query];
    }
    [self loadOrigin:[NSString stringWithFormat:@"%@%@", host, path]];
    return YES;
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    PCLog(@"ui: старт загрузки %@", webView.URL.absoluteString);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.pageLoaded = YES;
    self.terminatedOnce = NO;
    self.addressField.text = [self displayURLFor:webView.URL];
    self.progress.hidden = YES;
    [self.spinner stopAnimating];
    self.bootView.hidden = YES;
    self.errorBar.hidden = YES;
    PCLog(@"ui: страница загружена %@", webView.URL.absoluteString);
    PCLogMemory(@"page-loaded");
}

- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error {
    [self.spinner stopAnimating];
    self.progress.hidden = YES;
    if (error.code == NSURLErrorCancelled) { return; }
    PCLogError(@"ui: не удалось загрузить: %@", error.localizedDescription);
    [self showError:[NSString stringWithFormat:@"Сеть: %@", error.localizedDescription]];
}

- (void)webView:(WKWebView *)webView
    didFailNavigation:(WKNavigation *)navigation
            withError:(NSError *)error {
    if (error.code == NSURLErrorCancelled) { return; }
    PCLogError(@"ui: сбой навигации: %@", error.localizedDescription);
    [self showError:[NSString stringWithFormat:@"Сбой: %@", error.localizedDescription]];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    PCLogError(@"ui: WebContent-процесс убит системой (вероятно, память)");
    PCLogMemory(@"webcontent-terminated");

    [self.spinner stopAnimating];
    self.progress.hidden = YES;
    self.bootLabel.text = @"Веб-процесс остановлен";
    self.bootLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    self.bootHint.text = @"Перезапускаю страницу…";
    self.bootRetry.hidden = YES;
    self.bootView.hidden = NO;
    [self.bootSpinner startAnimating];

    if (self.terminatedOnce) {
        [self.bootSpinner stopAnimating];
        [self showBootError:@"Страница падает повторно. Попробуйте перезапустить приложение."];
        return;
    }
    self.terminatedOnce = YES;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self.bootSpinner stopAnimating];
        self.bootView.hidden = YES;
        if (webView.URL != nil) {
            [webView reload];
        } else {
            [self loadHome];
        }
    });
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)action
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = action.request.URL;
    NSString *scheme = [url.scheme lowercaseString];

    if ([scheme isEqualToString:PCScheme]) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
        NSString *origin = [self originStringForExternalURL:url];
        if (origin.length > 0) {
            PCLog(@"ui: перенаправляю в прокси: %@", origin);
            decisionHandler(WKNavigationActionPolicyCancel);
            // Не начинаем навигацию синхронно внутри делегата.
            dispatch_async(dispatch_get_main_queue(), ^{
                [self loadOrigin:origin];
            });
            return;
        }
        if (action.targetFrame.isMainFrame) {
            PCLog(@"ui: внешняя ссылка → Safari: %@", url.absoluteString);
            decisionHandler(WKNavigationActionPolicyCancel);
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            return;
        }
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (NSString *)displayURLFor:(NSURL *)url {
    NSString *string = url.absoluteString ?: @"";
    NSString *prefix = [NSString stringWithFormat:@"%@://", PCScheme];
    if ([string hasPrefix:prefix]) {
        string = [string substringFromIndex:prefix.length];
    }
    return string;
}

#pragma mark - WKUIDelegate

- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)action
                    windowFeatures:(WKWindowFeatures *)features {
    NSURL *target = action.request.URL;
    if (target == nil) { return nil; }

    NSString *origin = [self originStringForExternalURL:target];
    BOOL external = (origin.length == 0);

    PCLog(@"ui: window.open %@ → %@", target.absoluteString,
          origin.length > 0 ? origin : @"Safari");

    // ВАЖНО: нельзя начинать новую навигацию синхронно внутри этого делегата —
    // WebKit падает на вложенной навигации. Только следующим тиком RunLoop.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (origin.length > 0) {
            [self loadOrigin:origin];
        } else if (external) {
            NSString *scheme = [target.scheme lowercaseString];
            if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
                [[UIApplication sharedApplication] openURL:target options:@{} completionHandler:nil];
            }
        }
    });
    return nil;
}

- (NSString *)originStringForExternalURL:(NSURL *)url {
    NSString *scheme = [url.scheme lowercaseString];
    NSString *host = [url.host lowercaseString];
    NSString *path = url.path;
    if (path.length == 0) { path = @"/"; }

    if ([scheme isEqualToString:PCScheme]) {
        if (host.length == 0) { return @""; }
        NSString *out = [host stringByAppendingString:path];
        if (url.query.length > 0) {
            out = [out stringByAppendingFormat:@"?%@", url.query];
        }
        return out;
    }
    if ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]) {
        if (host.length == 0) { return @""; }
        if (![host isEqualToString:@"perchance.org"] &&
            ![host hasSuffix:@".perchance.org"]) {
            return @"";
        }
        NSString *out = [host stringByAppendingString:path];
        if (url.query.length > 0) {
            out = [out stringByAppendingFormat:@"?%@", url.query];
        }
        return out;
    }
    return @"";
}

- (void)webView:(WKWebView *)webView
    runJavaScriptAlertPanelWithMessage:(NSString *)message
                      initiatedByFrame:(WKFrameInfo *)frame
                     completionHandler:(void (^)(void))completionHandler {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Perchance"
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) { completionHandler(); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView
    runJavaScriptConfirmPanelWithMessage:(NSString *)message
                        initiatedByFrame:(WKFrameInfo *)frame
                       completionHandler:(void (^)(BOOL))completionHandler {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Perchance"
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Отмена"
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *action) { completionHandler(NO); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) { completionHandler(YES); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
