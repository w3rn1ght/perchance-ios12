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

- (void)webView:(WKWebView *)webView
startURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
    NSURLRequest *request = urlSchemeTask.request;
    __weak id<WKURLSchemeTask> weakTask = urlSchemeTask;

    [self.proxy loadRequest:request completion:^(NSString *mime,
                                                NSDictionary<NSString *, id> *headers,
                                                NSData *body,
                                                NSError *error) {
        id<WKURLSchemeTask> task = weakTask;
        if (task == nil) { return; }

        // Протокол задачи строгий: сначала didReceiveResponse, потом данные,
        // потом didFinish. Любая другая последовательность — assertion в WebKit.
        if (error != nil || body == nil) {
            NSError *e = error;
            if (e == nil) {
                e = [NSError errorWithDomain:@"PCProxy" code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"Пустой ответ"}];
            }
            @try { [task didFailWithError:e]; } @catch (NSException *ex) {}
            return;
        }

        NSString *contentType = mime;
        if (contentType.length == 0) { contentType = @"application/octet-stream"; }

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
        responseHeaders[@"Content-Type"] = contentType;
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
            // Задачу отменили навигацией — нормальная ситуация.
        }
    }];
}

- (void)webView:(WKWebView *)webView
stopURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
}

@end
