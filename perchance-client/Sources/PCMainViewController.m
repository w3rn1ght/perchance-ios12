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
        _startPath = path;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];
    [self buildChrome];
    [self buildWebView];
    [self loadHome];
}

- (void)loadHome {
    if (_startPath.length) {
        [self loadPath:_startPath];
    } else {
        [self loadPath:@"/welcome"];
    }
}

- (void)loadPath:(NSString *)path {
    if (!path) {
        [self loadOrigin:@"perchance.org/welcome"];
        return;
    }
    NSString *p = path;
    if (![p hasPrefix:@"/"]) {
        p = [@"/" stringByAppendingString:p];
    }
    [self loadOrigin:[@"perchance.org" stringByAppendingString:p]];
}

- (void)loadOrigin:(NSString *)origin {
    if (!origin || ![origin hasPrefix:@"perchance.org"]) {
        [self loadOrigin:@"perchance.org/welcome"];
        return;
    }
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@", PCScheme, origin]];
    if (url == nil) {
        [self loadOrigin:@"perchance.org/welcome"];
        return;
    }
    NSURLRequest *req = [NSURLRequest requestWithURL:url
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                     timeoutInterval:45];
    [self.web loadRequest:req];
}

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
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.tintColor = [UIColor colorWithWhite:0.9 alpha:1];
    b.titleLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightRegular];
    [b setTitle:title forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

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
            // External links (e.g., forum) - open in Safari
            [[UIApplication sharedApplication] openURL:target options:@{} completionHandler:nil];
        }
    }
    return nil;
}

- (NSString *)originStringForExternalURL:(NSURL *)url {
    NSString *scheme = [url.scheme lowercaseString];
    NSString *host = [url.host lowercaseString];
    NSString *path = url.path;
    if (path.length == 0) { path = @"/"; }

    if ([scheme isEqualToString:PCScheme]) {
        // Already inside proxy: host is the real host
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
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction *x) { completionHandler(NO); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *x) { completionHandler(YES); }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end