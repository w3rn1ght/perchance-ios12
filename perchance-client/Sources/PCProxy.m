#import "PCProxy.h"
#import "PCJSBridge.h"
#import "PCJSTranspiler.h"
#import "PCLog.h"
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

NSString * const PCScheme = @"wk";
NSString * const PCSchemeHost = @"pc";
NSString * const PCCacheDirectory = @"PCProxyCache19";

/// User-Agent настоящего Safari на этом же устройстве, а не «Chrome на macOS».
///
/// Раньше здесь стоял Chrome/macOS. Cloudflare видит набор несовместимостей —
/// TLS-отпечаток CFNetwork вместо Chrome, отсутствие Sec-CH-UA при UA Chrome,
/// экран iPad — и выдаёт managed challenge. Пройти его на схеме wk:// нельзя:
/// страница не в secure context, crypto.subtle недоступен, а JS-детектор
/// сообщает свой origin «wk://…», который не совпадает с заголовком Referer.
/// В итоге весь сайт превращался в «Just a moment…» и белый экран.
///
/// UA должен совпадать с реальным окружением: iOS 12.5.8, Safari 12.1.2.
/// Тогда TLS, WebKit и navigator.userAgent говорят одно и то же.
static NSString * const kPCUserAgent =
    @"Mozilla/5.0 (iPad; CPU OS 12_5_8 like Mac OS X) AppleWebKit/605.1.15 "
    @"(KHTML, like Gecko) Version/12.1.2 Mobile/15E148 Safari/604.1";

static NSString * const kRootDomain = @"perchance.org";

/// Заголовки, которые нельзя пересылать в настоящий запрос: их выставляет
/// NSURLSession, либо они относятся к схеме wk:// и сломают сервер.
static BOOL PCHopByHopHeader(NSString *lower) {
    return [lower isEqualToString:@"host"] ||
           [lower isEqualToString:@"connection"] ||
           [lower isEqualToString:@"keep-alive"] ||
           [lower isEqualToString:@"content-length"] ||
           [lower isEqualToString:@"transfer-encoding"] ||
           [lower isEqualToString:@"accept-encoding"] ||
           [lower isEqualToString:@"upgrade"] ||
           [lower isEqualToString:@"te"] ||
           [lower isEqualToString:@"trailer"] ||
           [lower isEqualToString:@"proxy-connection"] ||
           [lower isEqualToString:@"cookie"];
}

/// wk://host/path → https://host/path (для Origin/Referer).
static NSString *PCHTTPSString(NSString *value) {
    if ([value hasPrefix:@"wk://"]) {
        return [@"https://" stringByAppendingString:[value substringFromIndex:5]];
    }
    return value;
}

/// Убирает параметры Cloudflare-challenge из URL.
///
/// После неудачного challenge Cloudflare переводит страницу на
/// `?__cf_chl_rt_tk=…` и повторяет проверку. На схеме wk:// проверка не
/// проходит никогда, а приложение затем перезагружает именно этот «билет» —
/// получается вечный цикл 403. Запрашиваем исходный чистый URL.
static NSString *PCStripChallengeParams(NSString *urlString) {
    if (urlString.length == 0) { return urlString; }
    if ([urlString rangeOfString:@"__cf_chl"].location == NSNotFound) {
        return urlString;
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    if (components == nil) { return urlString; }
    NSArray<NSString *> *names = @[
        @"__cf_chl_rt_tk", @"__cf_chl_f_tk", @"__cf_chl_enter",
        @"__cf_chl_jschl_tk__", @"__cf_chl_captcha_tk__", @"__cf_chl_tk"
    ];
    NSMutableArray<NSURLQueryItem *> *kept = [NSMutableArray array];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        if (![names containsObject:item.name]) {
            [kept addObject:item];
        }
    }
    if (kept.count == components.queryItems.count) {
        return urlString;
    }
    components.queryItems = kept.count > 0 ? kept : nil;
    NSString *clean = components.URL.absoluteString;
    return clean.length > 0 ? clean : urlString;
}

#pragma mark - Задача

/// Одна загрузка. Живёт от старта запроса до End; после End вызовы
/// игнорируются, чтобы не отдать данные в уже остановленную задачу схемы.
@interface PCProxyJob : NSObject
@property (nonatomic, copy, nullable) PCProxyHandler handler;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy, nullable) NSString *cachePath;
@property (nonatomic, assign) BOOL transformable;
@property (nonatomic, assign) BOOL serviceWorker;
@property (nonatomic, assign) BOOL headSent;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) NSInteger status;
@property (nonatomic, copy, nullable) NSString *mime;
@property (nonatomic, strong, nullable) NSDictionary<NSString *, id> *headers;
@property (nonatomic, strong) NSMutableData *buffer;
@end

@implementation PCProxyJob

- (instancetype)init {
    if ((self = [super init])) {
        _buffer = [NSMutableData data];
        _status = 200;
    }
    return self;
}

@end

#pragma mark - Прокси

@interface PCProxy () <NSURLSessionDataDelegate>
@property (nonatomic, strong) PCJSTranspiler *transpiler;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, PCProxyJob *> *jobs;
@property (nonatomic, assign) NSInteger transformed;
@property (nonatomic, assign) NSInteger failed;
@end

@implementation PCProxy

- (nullable instancetype)initWithTranspiler:(PCJSTranspiler *)transpiler {
    self = [super init];
    if (self != nil) {
        _transpiler = transpiler;
        _jobs = [NSMutableDictionary dictionary];

        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        // 60 с — это пауза между пакетами, а не общее время ответа. Общий
        // лимит нужен большой: генерация ИИ может идти минутами, и раньше
        // ответ обрывался на 120-й секунде.
        cfg.timeoutIntervalForRequest = 60;
        cfg.timeoutIntervalForResource = 3600;
        cfg.HTTPCookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        cfg.HTTPShouldSetCookies = YES;
        // Cloudflare ставит __cf_bm с Domain=.perchance.org. Политика
        // «только с основного домена» может его отбросить, и тогда каждый
        // запрос выглядит как первый — то есть как бот.
        cfg.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.HTTPAdditionalHeaders = @{
            @"User-Agent": kPCUserAgent,
            @"Accept-Language": @"ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7"
        };
        // Делегат нужен ради потоковой отдачи: ответ приходит кусками, и
        // каждый кусок сразу уходит в WKURLSchemeTask. NSURLSession держит
        // делегата до invalidate, а прокси живёт столько же, сколько
        // приложение, поэтому цикл здесь безопасен.
        _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    }
    return self;
}

- (NSInteger)transformedCount { return self.transformed; }
- (NSInteger)failedCount { return self.failed; }

#pragma mark - Кэш

- (NSString *)cachePath {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [base stringByAppendingPathComponent:PCCacheDirectory];
}

- (void)prepare {
    [[NSFileManager defaultManager] createDirectoryAtPath:[self cachePath]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
}

- (NSString *)cacheKeyForURL:(NSString *)urlString kind:(NSString *)kind {
    NSData *data = [urlString dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:40];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [NSString stringWithFormat:@"%@-%@.dat", kind, hex];
}

- (NSString *)cachePathForURL:(NSString *)url kind:(NSString *)kind {
    return [[self cachePath] stringByAppendingPathComponent:[self cacheKeyForURL:url kind:kind]];
}

- (void)clearCache {
    [[NSFileManager defaultManager] removeItemAtPath:[self cachePath] error:NULL];
    [self prepare];
}

- (NSString *)mimeForKind:(NSString *)kind {
    if ([kind isEqualToString:@"js"]) { return @"application/javascript; charset=utf-8"; }
    if ([kind isEqualToString:@"css"]) { return @"text/css; charset=utf-8"; }
    return @"text/html; charset=utf-8";
}

#pragma mark - Адреса

/// wk://a257….perchance.org/welcome?x=1 → https://a257….perchance.org/welcome?x=1
///
/// ВАЖНО: хост живёт в самом URL схемы, а не в пути. Иначе абсолютные пути
/// вида `/lib/appExtras.js` резолвятся от origin (wk://pc) и хост теряется.
- (nullable NSString *)originURLStringForRequest:(NSURLRequest *)request {
    NSString *raw = request.URL.absoluteString;
    NSString *prefix = [NSString stringWithFormat:@"%@://", PCScheme];
    if (![raw hasPrefix:prefix]) { return nil; }
    NSString *rest = [raw substringFromIndex:prefix.length];
    if (rest.length == 0) { return nil; }
    return [@"https://" stringByAppendingString:rest];
}

- (BOOL)isPerchanceHost:(NSString *)host {
    NSString *h = [host lowercaseString];
    if ([h isEqualToString:kRootDomain]) { return YES; }
    return [h hasSuffix:[@"." stringByAppendingString:kRootDomain]];
}

/// Полифилы, Babel и compat.css лежат в Resources/web — отдаём их из бандла.
- (BOOL)bundledResourceForPath:(NSString *)path mime:(NSString **)outMime body:(NSData **)outBody {
    static NSDictionary<NSString *, NSArray<NSString *> *> *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"/__legacy/polyfills.js":      @[ @"polyfills.js", @"application/javascript" ],
            @"/__legacy/legacy.js":         @[ @"legacy.js", @"application/javascript" ],
            @"/__legacy/pc-bootstrap.js":   @[ @"pc-bootstrap.js", @"application/javascript" ],
            @"/__legacy/runtime-hooks.js":  @[ @"runtime-hooks.js", @"application/javascript" ],
            @"/__legacy/babel.min.js":      @[ @"babel.min.js", @"application/javascript" ],
            @"/__legacy/core-js-bundle.js": @[ @"core-js-bundle.js", @"application/javascript" ],
            @"/__legacy/compat.css":        @[ @"compat.css", @"text/css" ]
        };
    });
    NSArray<NSString *> *entry = map[path];
    if (entry == nil) { return NO; }

    NSString *file = [[NSBundle mainBundle] pathForResource:entry[0] ofType:nil inDirectory:@"web"];
    if (file == nil) {
        file = [[NSBundle mainBundle] pathForResource:entry[0] ofType:nil];
    }
    NSData *data = [NSData dataWithContentsOfFile:file];
    if (data == nil) { return NO; }

    if (outMime != NULL) {
        *outMime = [entry[1] stringByAppendingString:@"; charset=utf-8"];
    }
    if (outBody != NULL) {
        *outBody = data;
    }
    return YES;
}

#pragma mark - Отдача в схему

/// Все emit-вызовы обязаны идти на главном потоке: главная очередь
/// последовательная, поэтому Head всегда окажется раньше Data.
- (void)emit:(PCProxyJob *)job
       event:(PCProxyEvent)event
        data:(nullable NSData *)data
       error:(nullable NSError *)error {
    if (job.finished) { return; }
    if (event == PCProxyEventHead) {
        if (job.headSent) { return; }
        job.headSent = YES;
    } else if (event == PCProxyEventEnd) {
        job.finished = YES;
    }
    PCProxyHandler handler = job.handler;
    if (handler != nil) {
        handler(event, job.status, job.mime, job.headers, data, error);
    }
}

- (void)emitHeadAndBody:(PCProxyJob *)job data:(nullable NSData *)data {
    [self emit:job event:PCProxyEventHead data:nil error:nil];
    if (data.length > 0) {
        [self emit:job event:PCProxyEventData data:data error:nil];
    }
}

/// Немедленный ответ (бандл, ошибка, кэш) без сети.
- (void)deliverImmediate:(nullable PCProxyHandler)handler
                  status:(NSInteger)status
                    mime:(nullable NSString *)mime
                 headers:(nullable NSDictionary<NSString *, id> *)headers
                    body:(nullable NSData *)body
                   error:(nullable NSError *)error {
    if (handler == nil) { return; }
    if (error != nil) {
        handler(PCProxyEventEnd, 0, nil, nil, nil, error);
        return;
    }
    handler(PCProxyEventHead, status, mime, headers, nil, nil);
    if (body.length > 0) {
        handler(PCProxyEventData, status, mime, headers, body, nil);
    }
    handler(PCProxyEventEnd, status, mime, headers, nil, nil);
}

- (PCProxyJob *)jobForTask:(NSURLSessionTask *)task {
    @synchronized (self.jobs) {
        return self.jobs[@(task.taskIdentifier)];
    }
}

- (void)removeJob:(PCProxyJob *)job {
    @synchronized (self.jobs) {
        NSArray<NSNumber *> *keys = [self.jobs allKeysForObject:job];
        for (NSNumber *key in keys) {
            [self.jobs removeObjectForKey:key];
        }
    }
}

#pragma mark - Загрузка

- (void)loadRequest:(NSURLRequest *)request handler:(PCProxyHandler)handler {
    NSString *origin = [self originURLStringForRequest:request];
    if (origin == nil) {
        [self deliverImmediate:handler status:0 mime:nil headers:nil body:nil
                         error:[self error:@"Неизвестный URL"]];
        return;
    }

    NSString *cleanOrigin = PCStripChallengeParams(origin);
    if (![cleanOrigin isEqualToString:origin]) {
        PCLog(@"proxy: убираю CF-билет %@", origin);
        origin = cleanOrigin;
    }

    NSString *method = request.HTTPMethod.length > 0 ? request.HTTPMethod.uppercaseString : @"GET";
    BOOL bodyless = [method isEqualToString:@"GET"] || [method isEqualToString:@"HEAD"];

    NSString *originPath = [[NSURL URLWithString:origin] path];
    if (originPath.length == 0) { originPath = @"/"; }

    if (bodyless) {
        NSString *mime = nil;
        NSData *body = nil;
        if ([self bundledResourceForPath:originPath mime:&mime body:&body]) {
            [self deliverImmediate:handler status:200 mime:mime
                           headers:@{ @"Cache-Control": @"no-cache" } body:body error:nil];
            return;
        }
    }

    // Cloudflare-детектор JS (JSD) на схеме wk:// вредит: он отправляет
    // отпечаток, где origin — «wk://…», тогда как заголовки говорят https://.
    // Несовпадение Cloudflare считает признаком бота и включает managed
    // challenge, который на wk:// не проходится (нет secure context и
    // crypto.subtle). Отвечаем пустым скриптом — детектор просто не работает.
    if ([originPath hasPrefix:@"/cdn-cgi/challenge-platform/scripts/jsd/"]) {
        PCLog(@"proxy: jsd отключён %@", originPath);
        [self deliverImmediate:handler
                        status:200
                          mime:@"application/javascript; charset=utf-8"
                       headers:@{ @"Cache-Control": @"no-store" }
                          body:[@"/* jsd disabled */" dataUsingEncoding:NSUTF8StringEncoding]
                         error:nil];
        return;
    }

    NSURL *realURL = [NSURL URLWithString:origin];
    if (realURL == nil || ![self isPerchanceHost:realURL.host]) {
        PCLogError(@"proxy: отклонён хост для URL: %@ (origin: %@)", request.URL.absoluteString, origin);
        [self deliverImmediate:handler status:0 mime:nil headers:nil body:nil
                         error:[self error:@"Прокси обслуживает только perchance.org"]];
        return;
    }

    PCProxyJob *job = [[PCProxyJob alloc] init];
    job.url = origin;
    job.method = method;
    job.handler = handler;

    [self startJob:job original:request];
}

/// Достаёт тело POST из PCJSBridge. Сообщение из JS и запрос схемы идут
/// разными путями, поэтому первые ~400 мс тело может ещё не дойти.
- (void)bodyForId:(NSString *)bodyId
          attempt:(NSInteger)attempt
       completion:(void (^)(NSString * _Nullable body))completion {
    NSString *body = [[PCJSBridge shared] takeBodyForId:bodyId];
    if (body != nil || attempt >= 10) {
        if (body == nil) {
            PCLogError(@"proxy: тело %@ так и не пришло", bodyId);
        }
        completion(body);
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf bodyForId:bodyId attempt:attempt + 1 completion:completion];
    });
}

- (void)startJob:(PCProxyJob *)job original:(NSURLRequest *)original {
    NSURL *realURL = [NSURL URLWithString:job.url];
    if (realURL == nil) {
        [self deliverImmediate:job.handler status:0 mime:nil headers:nil body:nil
                         error:[self error:@"Плохой URL"]];
        return;
    }
    PCLog(@"proxy: %@ %@", job.method, job.url);

    NSString *bodyId = original.allHTTPHeaderFields[@"X-PC-Body-Id"];
    if (bodyId.length == 0) {
        bodyId = original.allHTTPHeaderFields[@"x-pc-body-id"];
    }

    __weak typeof(self) weakSelf = self;
    void (^start)(NSString *) = ^(NSString *requestBody) {
        PCProxy *strongSelf = weakSelf;
        if (strongSelf == nil) { return; }

        NSMutableURLRequest *up = [NSMutableURLRequest requestWithURL:realURL];
        up.HTTPMethod = job.method;

        NSString *referer = nil;
        NSString *webkitUA = nil;
        for (NSString *key in original.allHTTPHeaderFields) {
            NSString *lower = key.lowercaseString;
            if ([lower isEqualToString:@"x-pc-body-id"] || PCHopByHopHeader(lower)) {
                continue;
            }
            NSString *value = original.allHTTPHeaderFields[key];
            if (![value isKindOfClass:[NSString class]] || value.length == 0) {
                continue;
            }
            if ([lower isEqualToString:@"origin"] || [lower isEqualToString:@"referer"]) {
                value = PCHTTPSString(value);
                if ([lower isEqualToString:@"referer"]) { referer = value; }
            }
            if ([lower isEqualToString:@"user-agent"]) { webkitUA = value; }
            [up setValue:value forHTTPHeaderField:key];
        }

        // WebKit присылает свой User-Agent (без токена Safari), и он
        // перекрывал бы kPCUserAgent из HTTPAdditionalHeaders. Cloudflare
        // видит «Mobile/15E148» без «Version/… Safari/…» — типичный признак
        // встроенного webview. Ставим UA явно и уже после копирования.
        [up setValue:kPCUserAgent forHTTPHeaderField:@"User-Agent"];

        // Верхнеуровневая навигация приходит без Referer. Подделывать его не
        // надо: Safari при переходе по адресу Referer не отправляет, а CF
        // считает лишний Referer признаком не-браузера.
        NSString *lastComponent = realURL.lastPathComponent ?: @"";
        BOOL looksDocument = (lastComponent.length == 0 ||
                              [lastComponent rangeOfString:@"."].location == NSNotFound);
        BOOL navigation = ([job.method isEqualToString:@"GET"] && looksDocument);

        NSString *accept = [up valueForHTTPHeaderField:@"Accept"];
        if (navigation) {
            if (accept.length == 0 || [accept isEqualToString:@"*/*"]) {
                [up setValue:@"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
                  forHTTPHeaderField:@"Accept"];
            }
            if ([up valueForHTTPHeaderField:@"Upgrade-Insecure-Requests"].length == 0) {
                [up setValue:@"1" forHTTPHeaderField:@"Upgrade-Insecure-Requests"];
            }
        } else if (accept.length == 0) {
            [up setValue:@"*/*" forHTTPHeaderField:@"Accept"];
        }

        PCLog(@"proxy: hdr %@ accept=%@ ref=%@ uir=%@",
              job.url,
              [up valueForHTTPHeaderField:@"Accept"] ?: @"-",
              referer ?: @"-",
              [up valueForHTTPHeaderField:@"Upgrade-Insecure-Requests"] ?: @"-");

        if (navigation) {
            NSArray<NSHTTPCookie *> *cookies =
                [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:realURL];
            PCLog(@"proxy: cookies %lu для %@",
                  (unsigned long)cookies.count, realURL.host);
            if (webkitUA.length > 0) {
                PCLog(@"proxy: ua webkit=%@", webkitUA);
            }
        }
        if (requestBody.length > 0) {
            up.HTTPBody = [requestBody dataUsingEncoding:NSUTF8StringEncoding];
            PCLog(@"proxy: тело запроса %@ — %lu симв.", job.url, (unsigned long)requestBody.length);
        }

        NSURLSessionDataTask *task = [strongSelf.session dataTaskWithRequest:up];
        @synchronized (strongSelf.jobs) {
            strongSelf.jobs[@(task.taskIdentifier)] = job;
        }
        [task resume];
    };

    if (bodyId.length > 0) {
        [self bodyForId:bodyId attempt:0 completion:start];
    } else {
        start(nil);
    }
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    PCProxyJob *job = [self jobForTask:dataTask];
    if (job == nil) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }

    NSHTTPURLResponse *http = nil;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        http = (NSHTTPURLResponse *)response;
    }
    NSInteger status = http != nil ? http.statusCode : 200;
    NSString *mime = response.MIMEType.length > 0 ? response.MIMEType : @"application/octet-stream";
    NSDictionary *headers = http.allHeaderFields != nil ? http.allHeaderFields : @{};
    NSURL *responseURL = response.URL ?: dataTask.originalRequest.URL;

    // Set-Cookie для wk:// WebKit не сохранит — кладём в общее хранилище,
    // из которого NSURLSession берёт куки следующих запросов.
    if (http != nil && responseURL != nil) {
        NSArray<NSHTTPCookie *> *cookies =
            [NSHTTPCookie cookiesWithResponseHeaderFields:headers forURL:responseURL];
        for (NSHTTPCookie *cookie in cookies) {
            [[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookie:cookie];
        }
    }

    NSString *lower = mime.lowercaseString;
    BOOL isHTML = [lower containsString:@"text/html"];
    BOOL isCSS = [lower containsString:@"text/css"];
    BOOL isJS = [lower containsString:@"javascript"];
    NSString *path = responseURL.path ?: @"";
    if (!isHTML && !isJS && !isCSS && [path hasSuffix:@".js"]) { isJS = YES; }
    if (!isHTML && !isJS && !isCSS && [path hasSuffix:@".css"]) { isCSS = YES; }

    // Service Worker отключён: он кэширует непереписанные файлы.
    NSString *lowerURL = job.url.lowercaseString;
    BOOL sw = [lowerURL containsString:@"service-worker"] || [path hasSuffix:@"/sw.js"];

    NSString *kind = isHTML ? @"html" : (isCSS ? @"css" : (isJS ? @"js" : @""));
    BOOL transformable = (kind.length > 0) || sw;

    job.status = status;
    job.mime = mime;
    job.headers = headers;
    job.transformable = transformable;
    job.serviceWorker = sw;
    job.kind = kind;

    PCLog(@"proxy: ← %ld %@ (%@)", (long)status, job.url, mime);

    if (status == 403 && isHTML) {
        PCLogError(@"proxy: Cloudflare challenge вместо страницы: %@", job.url);
    }

    // Кэш только для GET, только для 200 и только для того, что переписываем.
    // Раньше кэшировался любой ответ, включая 403-challenge: после первого
    // «Just a moment…» приложение навсегда показывало белый экран.
    if (status == 200 && transformable && kind.length > 0 &&
        [job.method isEqualToString:@"GET"]) {
        NSString *cachePath = [self cachePathForURL:job.url kind:kind];
        NSString *cached = [NSString stringWithContentsOfFile:cachePath
                                                     encoding:NSUTF8StringEncoding
                                                        error:NULL];
        if (cached.length > 0) {
            PCLog(@"proxy: кеш %@", job.url);
            NSData *data = [cached dataUsingEncoding:NSUTF8StringEncoding];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (job.finished) { return; }
                job.mime = [self mimeForKind:kind];
                [self emitHeadAndBody:job data:data];
                [self emit:job event:PCProxyEventEnd data:nil error:nil];
                [self removeJob:job];
            });
            completionHandler(NSURLSessionResponseCancel);
            return;
        }
        job.cachePath = cachePath;
    }

    if (!transformable) {
        // JSON, картинки, text/event-stream — отдаём потоком, ничего не копим.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self emit:job event:PCProxyEventHead data:nil error:nil];
        });
        completionHandler(NSURLSessionResponseAllow);
        return;
    }

    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    PCProxyJob *job = [self jobForTask:dataTask];
    if (job == nil || job.finished || data.length == 0) { return; }

    if (job.transformable) {
        @synchronized (job) {
            [job.buffer appendData:data];
        }
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self emit:job event:PCProxyEventData data:data error:nil];
    });
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    PCProxyJob *job = [self jobForTask:task];
    if (job == nil) { return; }

    if (job.finished) {
        [self removeJob:job];
        return;
    }
    if (error != nil && error.code == NSURLErrorCancelled) {
        [self removeJob:job];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self completeJob:job error:error];
    });
}

#pragma mark - Завершение

- (void)completeJob:(PCProxyJob *)job error:(nullable NSError *)error {
    if (job.finished) {
        [self removeJob:job];
        return;
    }
    if (error != nil) {
        PCLogError(@"proxy: ошибка %@ — %@", job.url, error.localizedDescription);
        [self emit:job event:PCProxyEventEnd data:nil error:error];
        [self removeJob:job];
        return;
    }
    if (job.serviceWorker) {
        NSString *shim = @"self.addEventListener('install',function(e){self.skipWaiting()});"
                         @"self.addEventListener('activate',function(e){e.waitUntil(self.registration.unregister())});";
        job.mime = @"application/javascript; charset=utf-8";
        [self emitHeadAndBody:job data:[shim dataUsingEncoding:NSUTF8StringEncoding]];
        [self emit:job event:PCProxyEventEnd data:nil error:nil];
        [self removeJob:job];
        return;
    }
    if (!job.transformable) {
        [self emit:job event:PCProxyEventEnd data:nil error:nil];
        [self removeJob:job];
        return;
    }

    NSData *buffer = nil;
    @synchronized (job) {
        buffer = [job.buffer copy];
    }
    NSString *source = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding];
    if (source == nil) {
        PCLogError(@"proxy: не UTF-8 %@", job.url);
        [self emitHeadAndBody:job data:buffer];
        [self emit:job event:PCProxyEventEnd data:nil error:nil];
        [self removeJob:job];
        return;
    }

    if (!self.transpiler.isReady) {
        PCLogError(@"proxy: Babel не готов, отдаю без переписывания %@", job.url);
    }

    __weak typeof(self) weakSelf = self;
    if ([job.kind isEqualToString:@"html"]) {
        // <base> фиксирует origin схемы: относительные и абсолютные пути
        // (/lib/appExtras.js) остаются на том же хосте и идут через прокси.
        NSString *host = [[NSURL URLWithString:job.url] host];
        if (host.length == 0) { host = @"perchance.org"; }
        NSString *baseHref = [NSString stringWithFormat:@"%@://%@/", PCScheme, host];
        PCLog(@"proxy: HTML %@ (%lu симв.)", job.url, (unsigned long)source.length);
        [self.transpiler transformHTML:source baseHref:baseHref completion:^(id result, NSError *err) {
            PCProxy *s = weakSelf;
            if (s == nil) { return; }
            NSString *out = [result isKindOfClass:[NSString class]] ? (NSString *)result : nil;
            // Маркер означает, что страница реально прошла через трансформер:
            // в неё вставлены полифилы и <base>. Иначе кэшировать нельзя —
            // именно так раньше «залипал» мёртвый интерфейс.
            BOOL ok = out.length > 0 && [out containsString:@"__legacy/legacy.js"];
            if (!ok) {
                PCLogError(@"proxy: HTML не переписан %@ (%@)", job.url,
                           err.localizedDescription ?: @"нет маркера трансформации");
                out = source;
            }
            if (ok && job.cachePath.length > 0) {
                [out writeToFile:job.cachePath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            }
            job.mime = @"text/html; charset=utf-8";
            [s emitHeadAndBody:job data:[out dataUsingEncoding:NSUTF8StringEncoding]];
            [s emit:job event:PCProxyEventEnd data:nil error:nil];
            [s removeJob:job];
        }];
        return;
    }

    if ([job.kind isEqualToString:@"css"]) {
        [self.transpiler patchCSS:source completion:^(id result, NSError *err) {
            PCProxy *s = weakSelf;
            if (s == nil) { return; }
            NSString *out = [result isKindOfClass:[NSString class]] ? (NSString *)result : source;
            if (job.cachePath.length > 0) {
                [out writeToFile:job.cachePath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            }
            job.mime = @"text/css; charset=utf-8";
            [s emitHeadAndBody:job data:[out dataUsingEncoding:NSUTF8StringEncoding]];
            [s emit:job event:PCProxyEventEnd data:nil error:nil];
            [s removeJob:job];
        }];
        return;
    }

    PCLog(@"proxy: JS %@ (%lu симв.)", job.url, (unsigned long)source.length);
    [self.transpiler transformJS:source filename:job.url completion:^(id result, NSError *err) {
        PCProxy *s = weakSelf;
        if (s == nil) { return; }
        NSDictionary *dict = [result isKindOfClass:[NSDictionary class]] ? (NSDictionary *)result : nil;
        NSString *code = [dict[@"code"] isKindOfClass:[NSString class]] ? dict[@"code"] : nil;
        BOOL ok = [dict[@"ok"] boolValue] && code.length > 0;
        PCLog(@"proxy: JS результат для %@: ok=%d (len=%lu)", job.url, ok, (unsigned long)code.length);

        if (!ok) {
            s.failed = s.failed + 1;
            PCLogError(@"proxy: JS не переписан %@ (%@)", job.url,
                       dict[@"error"] ?: err.localizedDescription ?: @"неизвестная ошибка");
            code = source;
        } else {
            s.transformed = s.transformed + 1;
            if (job.cachePath.length > 0) {
                [code writeToFile:job.cachePath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            }
        }
        job.mime = @"application/javascript; charset=utf-8";
        [s emitHeadAndBody:job data:[code dataUsingEncoding:NSUTF8StringEncoding]];
        [s emit:job event:PCProxyEventEnd data:nil error:nil];
        [s removeJob:job];
    }];
}

- (NSError *)error:(NSString *)message {
    return [NSError errorWithDomain:@"PCProxy" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end
