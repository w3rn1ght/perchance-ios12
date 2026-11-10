#import "PCTranspilerProtocolHandler.h"

@interface PCTranspilerProtocolHandler ()
@property (nonatomic, strong) PCProxy *proxy;
@end

@implementation PCTranspilerProtocolHandler

@synthesize proxy = _proxy;
@synthesize webView = _webView;

- (instancetype)initWithProxy:(PCProxy *)proxy {
    if ((self = [super init])) {
        _proxy = proxy;
    }
    return self;
}

- (void)webView:(WKWebView *)webView
startURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
    NSURLRequest *request = urlSchemeTask.request;
    __weak id<WKURLSchemeTask> weakTask = urlSchemeTask;
    __weak typeof(self) weakSelf = self;

    [self.proxy loadRequest:request completion:^(NSString *mime,
                                                NSDictionary<NSString *, id> *headers,
                                                NSData *body,
                                                NSError *error) {
        id<WKURLSchemeTask> task = weakTask;
        if (!task) { return; }

        if (error != nil || body == nil) {
            NSError *e = error;
            if (e == nil) {
                e = [NSError errorWithDomain:@"PCProxy" code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"Пустой ответ"}];
            }
            @try { [task didFailWithError:e]; } @catch (NSException *ex) {}
            return;
        }

        NSString *mimeType = mime;
        NSData *payload = body;

        if ([mimeType isEqualToString:@"__html__"]) {
            NSString *pageURLString = headers[@"pageURL"];
            NSString *html = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
            WKWebView *wv = weakSelf.webView;
            NSURL *base = request.URL;
            if ([pageURLString isKindOfClass:[NSString class]]) {
                NSURL *u = [NSURL URLWithString:pageURLString];
                if (u) { base = u; }
            }
            @try { [task didFinish]; } @catch (NSException *ex) {}
            if (wv != nil && html != nil) {
                [wv loadHTMLString:html baseURL:base];
            }
            return;
        }

        if (mimeType.length == 0) {
            mimeType = @"application/octet-stream";
        }

        NSMutableDictionary *responseHeaders = [NSMutableDictionary dictionary];
        for (NSString *key in headers) {
            NSString *lower = [key lowercaseString];
            if ([lower hasPrefix:@"content-security-policy"] ||
                [lower hasPrefix:@"cross-origin"] ||
                [lower isEqualToString:@"content-encoding"] ||
                [lower isEqualToString:@"content-length"] ||
                [lower isEqualToString:@"transfer-encoding"] ||
                [lower isEqualToString:@"set-cookie"]) {
                continue;
            }
            id value = headers[key];
            if ([value isKindOfClass:[NSString class]]) {
                responseHeaders[key] = value;
            }
        }
        responseHeaders[@"Content-Type"] = mimeType;
        responseHeaders[@"Cache-Control"] = @"no-store";

        NSHTTPURLResponse *response =
            [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                        statusCode:200
                                       HTTPVersion:@"HTTP/1.1"
                                      headerFields:responseHeaders];

        @try {
            [task didReceiveResponse:response];
            [task didReceiveData:payload];
            [task didFinish];
        } @catch (NSException *ex) {
            // Задачу могли отменить навигацией — это нормально.
        }
    }];
}

- (void)webView:(WKWebView *)webView
stopURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
}

@end
