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
    PCLog(@"scheme: → %@", url);

    __weak typeof(self) weakSelf = self;
    __weak id<WKURLSchemeTask> weakTask = urlSchemeTask;

    [self.proxy loadRequest:request completion:^(NSString *mime,
                                                NSDictionary<NSString *, id> *headers,
                                                NSData *body,
                                                NSError *error) {
        PCTranspilerProtocolHandler *strongSelf = weakSelf;
        id<WKURLSchemeTask> task = weakTask;
        if (strongSelf == nil || task == nil) { return; }

        // Навигация уже отменила запрос — отвечать нельзя ни при каких условиях.
        if (![strongSelf.active containsObject:task]) {
            PCLog(@"scheme: задача отменена, ответ отброшен %@", url);
            return;
        }
        [strongSelf.active removeObject:task];

        if (error != nil || body == nil) {
            NSError *failure = error;
            if (failure == nil) {
                failure = [NSError errorWithDomain:@"PCProxy" code:1
                                          userInfo:@{NSLocalizedDescriptionKey: @"Пустой ответ"}];
            }
            PCLogError(@"scheme: ошибка %@ — %@", url, failure.localizedDescription);
            @try { [task didFailWithError:failure]; } @catch (NSException *exception) {
                PCLogError(@"scheme: didFailWithError: %@", exception.reason);
            }
            return;
        }

        NSString *contentType = mime.length > 0 ? mime : @"application/octet-stream";

        NSMutableDictionary *responseHeaders = [NSMutableDictionary dictionary];
        for (NSString *key in headers) {
            NSString *lower = [key lowercaseString];
            if ([lower hasPrefix:@"content-security-policy"] ||
                [lower hasPrefix:@"cross-origin"] ||
                [lower hasPrefix:@"access-control-"] ||
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

        // Страницы и iframe живут на разных поддоменах, но в одной схеме wk://:
        // без этих заголовков Safari 12 считает ответ «непрозрачным» и режет
        // fetch/XHR генератора.
        NSString *origin = request.allHTTPHeaderFields[@"Origin"];
        if (origin.length > 0) {
            responseHeaders[@"Access-Control-Allow-Origin"] = origin;
            responseHeaders[@"Access-Control-Allow-Credentials"] = @"true";
        } else {
            responseHeaders[@"Access-Control-Allow-Origin"] = @"*";
        }
        responseHeaders[@"Access-Control-Allow-Methods"] = @"GET, POST, OPTIONS";
        NSString *requestHeaders = request.allHTTPHeaderFields[@"Access-Control-Request-Headers"];
        if (requestHeaders.length > 0) {
            responseHeaders[@"Access-Control-Allow-Headers"] = requestHeaders;
        }

        NSHTTPURLResponse *response =
            [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                        statusCode:200
                                       HTTPVersion:@"HTTP/1.1"
                                      headerFields:responseHeaders];

        @try {
            [task didReceiveResponse:response];
            [task didReceiveData:body];
            [task didFinish];
        } @catch (NSException *exception) {
            PCLogError(@"scheme: не смог отдать %@: %@", url, exception.reason);
        }
    }];
}

- (void)webView:(WKWebView *)webView
    stopURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
    if ([self.active containsObject:urlSchemeTask]) {
        [self.active removeObject:urlSchemeTask];
        PCLog(@"scheme: стоп %@", urlSchemeTask.request.URL.absoluteString ?: @"");
    }
}

@end
