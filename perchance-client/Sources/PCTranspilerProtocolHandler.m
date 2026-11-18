#import "PCTranspilerProtocolHandler.h"
#import "PCLog.h"

@interface PCTranspilerProtocolHandler ()
@property (nonatomic, strong) PCProxy *proxy;

/// Активные задачи схемы. WKURLSchemeTask можно вызывать только пока он
/// «живой»: после stopURLSchemeTask любой вызов — аварийное завершение
/// WebContent-процесса (SIGABRT), а не просто ошибка. Поэтому храним задачи
/// по идентичности и никогда не трогаем остановленные.
@property (nonatomic, strong) NSHashTable<id<WKURLSchemeTask>> *active;
@end

@implementation PCTranspilerProtocolHandler

- (instancetype)initWithProxy:(PCProxy *)proxy {
    if ((self = [super init])) {
        _proxy = proxy;
        _active = [NSHashTable hashTableWithOptions:
                   NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality];
    }
    return self;
}

- (void)webView:(WKWebView *)webView
    startURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
    NSURLRequest *request = urlSchemeTask.request;
    NSString *url = request.URL.absoluteString ?: @"";

    if ([self.active containsObject:urlSchemeTask]) {
        PCLogError(@"scheme: задача уже активна, пропускаю %@", url);
        return;
    }
    [self.active addObject:urlSchemeTask];
    PCLog(@"scheme: → %@ %@", request.HTTPMethod ?: @"GET", url);

    NSString *method = request.HTTPMethod.length > 0 ? request.HTTPMethod.uppercaseString : @"GET";

    // CORS-preflight: WebKit спрашивает разрешение перед POST с JSON на
    // другой поддомен. Настоящий сервер его не увидит (запрос идёт от
    // wk://), поэтому отвечаем сами — иначе fetch генератора не стартует.
    if ([method isEqualToString:@"OPTIONS"]) {
        [self respondPreflight:urlSchemeTask request:request];
        return;
    }

    __weak typeof(self) weakSelf = self;
    __weak id<WKURLSchemeTask> weakTask = urlSchemeTask;

    [self.proxy loadRequest:request handler:^(PCProxyEvent event,
                                              NSInteger statusCode,
                                              NSString *mime,
                                              NSDictionary<NSString *, id> *headers,
                                              NSData *body,
                                              NSError *error) {
        PCTranspilerProtocolHandler *strongSelf = weakSelf;
        id<WKURLSchemeTask> task = weakTask;
        if (strongSelf == nil || task == nil) { return; }

        // Навигация уже отменила запрос — отвечать нельзя ни при каких условиях.
        if (![strongSelf.active containsObject:task]) {
            return;
        }

        switch (event) {
            case PCProxyEventHead: {
                NSHTTPURLResponse *response =
                    [strongSelf responseForRequest:request status:statusCode mime:mime headers:headers];
                @try {
                    [task didReceiveResponse:response];
                } @catch (NSException *exception) {
                    PCLogError(@"scheme: didReceiveResponse: %@", exception.reason);
                }
                break;
            }
            case PCProxyEventData: {
                if (body.length == 0) { break; }
                @try {
                    [task didReceiveData:body];
                } @catch (NSException *exception) {
                    PCLogError(@"scheme: didReceiveData: %@", exception.reason);
                }
                break;
            }
            case PCProxyEventEnd: {
                [strongSelf.active removeObject:task];
                if (error != nil) {
                    PCLogError(@"scheme: ошибка %@ — %@", url, error.localizedDescription);
                    @try {
                        [task didFailWithError:error];
                    } @catch (NSException *exception) {
                        PCLogError(@"scheme: didFailWithError: %@", exception.reason);
                    }
                    break;
                }
                @try {
                    [task didFinish];
                } @catch (NSException *exception) {
                    PCLogError(@"scheme: didFinish: %@", exception.reason);
                }
                break;
            }
        }
    }];
}

/// Заголовки ответа для страницы. CSP и CORS настоящего сервера выкидываем:
/// они относятся к https://, а страница живёт на wk://. Вместо них —
/// разрешающие заголовки, иначе Safari 12 считает ответ «непрозрачным».
- (NSHTTPURLResponse *)responseForRequest:(NSURLRequest *)request
                                   status:(NSInteger)statusCode
                                     mime:(NSString *)mime
                                  headers:(NSDictionary<NSString *, id> *)headers {
    NSString *contentType = mime.length > 0 ? mime : @"application/octet-stream";

    NSMutableDictionary *responseHeaders = [NSMutableDictionary dictionary];
    for (NSString *key in headers) {
        NSString *lower = key.lowercaseString;
        if ([lower hasPrefix:@"content-security-policy"] ||
            [lower hasPrefix:@"cross-origin"] ||
            [lower hasPrefix:@"access-control-"] ||
            [lower isEqualToString:@"content-type"] ||
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

    NSString *origin = request.allHTTPHeaderFields[@"Origin"];
    if (origin.length > 0) {
        responseHeaders[@"Access-Control-Allow-Origin"] = origin;
        responseHeaders[@"Access-Control-Allow-Credentials"] = @"true";
    } else {
        responseHeaders[@"Access-Control-Allow-Origin"] = @"*";
    }
    responseHeaders[@"Access-Control-Allow-Methods"] = @"GET, POST, PUT, PATCH, DELETE, OPTIONS";
    NSString *requestHeaders = request.allHTTPHeaderFields[@"Access-Control-Request-Headers"];
    if (requestHeaders.length > 0) {
        responseHeaders[@"Access-Control-Allow-Headers"] = requestHeaders;
    }

    // Реальный статус важен: по нему генератор отличает ошибку от ответа
    // (раньше любой 4xx/5xx превращался в 200 и страница падала позже).
    NSInteger status = statusCode >= 100 && statusCode <= 599 ? statusCode : 200;

    return [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                       statusCode:status
                                      HTTPVersion:@"HTTP/1.1"
                                     headerFields:responseHeaders];
}

- (void)respondPreflight:(id<WKURLSchemeTask>)task request:(NSURLRequest *)request {
    NSString *url = request.URL.absoluteString ?: @"";
    if (![self.active containsObject:task]) {
        return;
    }
    [self.active removeObject:task];

    NSString *origin = request.allHTTPHeaderFields[@"Origin"];
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    headers[@"Access-Control-Allow-Origin"] = origin.length > 0 ? origin : @"*";
    headers[@"Access-Control-Allow-Credentials"] = @"true";
    headers[@"Access-Control-Allow-Methods"] = @"GET, POST, PUT, PATCH, DELETE, OPTIONS";
    headers[@"Access-Control-Max-Age"] = @"600";
    NSString *requestHeaders = request.allHTTPHeaderFields[@"Access-Control-Request-Headers"];
    if (requestHeaders.length > 0) {
        headers[@"Access-Control-Allow-Headers"] = requestHeaders;
    }
    headers[@"Content-Length"] = @"0";

    PCLog(@"scheme: preflight %@", url);
    NSHTTPURLResponse *response =
        [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                    statusCode:204
                                   HTTPVersion:@"HTTP/1.1"
                                  headerFields:headers];
    @try {
        [task didReceiveResponse:response];
        [task didFinish];
    } @catch (NSException *exception) {
        PCLogError(@"scheme: preflight не отдан %@: %@", url, exception.reason);
    }
}

- (void)webView:(WKWebView *)webView
    stopURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
    if ([self.active containsObject:urlSchemeTask]) {
        [self.active removeObject:urlSchemeTask];
        PCLog(@"scheme: стоп %@", urlSchemeTask.request.URL.absoluteString ?: @"");
    }
}

@end
