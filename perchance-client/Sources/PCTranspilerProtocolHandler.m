#import "PCTranspilerProtocolHandler.h"

@interface PCTranspilerProtocolHandler ()
@property (nonatomic, strong) PCProxy *proxy;
@end

@implementation PCTranspilerProtocolHandler

- (instancetype)initWithProxy:(PCProxy *)proxy {
    if ((self = [super init])) {
        _proxy = proxy;
    }
    return self;
}

- (NSString *)originForRequest:(NSURLRequest *)request {
    NSString *raw = request.URL.absoluteString;
    NSString *prefix = [NSString stringWithFormat:@"%@://%@/", PCScheme, PCSchemeHost];
    if (![raw hasPrefix:prefix]) { return raw; }
    return [raw substringFromIndex:prefix.length];
}

- (void)webView:(WKWebView *)webView
startURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
    NSURLRequest *request = urlSchemeTask.request;
    __weak typeof(urlSchemeTask) weakTask = urlSchemeTask;
    __weak typeof(self) weakSelf = self;

    [self.proxy loadRequest:request completion:^(NSString *mime,
                                                NSDictionary<NSString *, id> *headers,
                                                NSData *body,
                                                NSError *error) {
        id<WKURLSchemeTask> task = weakTask;
        if (!task) { return; }

        if (error || !body) {
            NSError *e = error ?: [NSError errorWithDomain:@"PCProxy" code:1
                                                  userInfo:@{NSLocalizedDescriptionKey: @"Пустой ответ"}];
            @try { [task didFailWithError:e]; } @catch (NSException *ex) {}
            return;
        }

        if ([mime isEqualToString:@"__html__"]) {
            NSString *pageURL = headers[@"pageURL"];
            NSString *html = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
            WKWebView *wv = weakSelf.webView ?: webView;
            @try { [task didFinish]; } @catch (NSException *ex) {}
            if (wv && html) {
                [wv loadHTMLString:html baseURL:(pageURL ? [NSURL URLWithString:pageURL] : request.URL)];
            }
            return;
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
        responseHeaders[@"Content-Type"] = mime;
        responseHeaders[@"Cache-Control"] = @"no-store";

        NSHTTPURLResponse *response =
            [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                        statusCode:200
                                       HTTPVersion:@"HTTP/1.1"
                                      headerFields:responseHeaders];

        @try {
            [task didReceiveResponse:response];
            [task didReceiveData:body];
            [task didFinish];
        } @catch (NSException *ex) {
            // Задача могла быть отменена навигацией — это нормально.
        }
    }];
}

- (void)webView:(WKWebView *)webView
stopURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
    // Отмену не обрабатываем: запрос короткий.
}

@end
