//
// PCProxy.m — «прокси без прокси»: загрузка perchance.org через wk://
//
// Раньше эту работу делал Node-сервер: скачать файл, переписать JS/CSS/HTML,
// отдать браузеру. Здесь то же самое делает нативное приложение.
//
// Важно: WKWebView при scheme handler получает только запросы, сделанные
// из этого документа. Поэтому страницы (.html) грузятся через
// loadHTMLString с адресом wk://pc/<настоящий URL>, а все относительные
// ссылки внутри документа остаются внутри этой же схемы и тоже попадают
// в обработчик.
//

#import "PCProxy.h"
#import "PCJSTranspiler.h"
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

NSString * const PCScheme = @"wk";
NSString * const PCSchemeHost = @"pc";
NSString * const PCCacheDirectory = @"PCProxyCache";

static NSString * const kRootDomain = @"perchance.org";

@interface PCProxy ()
@property (nonatomic, strong) PCJSTranspiler *transpiler;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, assign) NSInteger transformed;
@property (nonatomic, assign) NSInteger failed;
@end

@implementation PCProxy

- (instancetype)initWithTranspiler:(PCJSTranspiler *)transpiler {
    if ((self = [super init])) {
        _transpiler = transpiler;
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 30;
        cfg.timeoutIntervalForResource = 60;
        cfg.HTTPCookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        cfg.HTTPShouldSetCookies = YES;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.HTTPAdditionalHeaders = @{
            @"User-Agent": @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                           "AppleWebKit/537.36 (KHTML, like Gecko) "
                           "Chrome/131.0.0.0 Safari/537.36",
            @"Accept-Language": @"ru,en;q=0.9"
        };
        _session = [NSURLSession sessionWithConfiguration:cfg];
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
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) { [hex appendFormat:@"%02x", digest[i]]; }
    return [NSString stringWithFormat:@"%@-%@.dat", kind, hex];
}

- (void)clearCache {
    [[NSFileManager defaultManager] removeItemAtPath:[self cachePath] error:NULL];
    [self prepare];
}

#pragma mark - Адреса

/// wk://pc/a257….perchance.org/welcome?x=1 → https://a257….perchance.org/welcome?x=1
- (NSString *)originURLStringForRequest:(NSURLRequest *)request {
    NSString *raw = request.URL.absoluteString;
    NSString *prefix = [NSString stringWithFormat:@"%@://%@/", PCScheme, PCSchemeHost];
    if (![raw hasPrefix:prefix]) { return nil; }
    NSString *encoded = [raw substringFromIndex:prefix.length];
    NSString *decoded = [encoded stringByRemovingPercentEncoding] ?: encoded;

    NSRange slash = [decoded rangeOfString:@"/"];
    NSString *host = slash.location == NSNotFound ? decoded : [decoded substringToIndex:slash.location];
    NSString *rest = slash.location == NSNotFound ? @"" : [decoded substringFromIndex:slash.location];
    if (host.length == 0) { host = kRootDomain; }
    return [NSString stringWithFormat:@"https://%@%@", host, rest];
}

- (BOOL)isPerchanceHost:(NSString *)host {
    NSString *h = [host lowercaseString];
    return [h isEqualToString:kRootDomain] || [h hasSuffix:[@"." stringByAppendingString:kRootDomain]];
}

/** Публичный адрес нужен контроллеру, чтобы строить итоговую ссылку. */
- (NSURL *)webURLForOrigin:(NSString *)origin {
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@/%@", PCScheme, PCSchemeHost, origin]];
}

#pragma mark - Загрузка

- (void)loadRequest:(NSURLRequest *)request
         completion:(PCProxyCompletion)completion {
    NSString *origin = [self originURLStringForRequest:request];
    if (!origin) {
        [self finish:completion mime:nil headers:nil body:nil error:[self error:@"Неизвестный URL"]];
        return;
    }

    // Полифилы и прочие служебные файлы — из бандла, без сети.
    NSString *originPath = [[NSURL URLWithString:origin] path] ?: @"";
    NSString *mime = nil;
    NSData *body = nil;
    if ([self bundledResourceForPath:originPath mime:&mime body:&body]) {
        [self finish:completion mime:mime headers:@{@"Cache-Control": @"no-cache"} body:body error:nil];
        return;
    }

    NSURL *realURL = [NSURL URLWithString:origin];
    if (!realURL || ![self isPerchanceHost:realURL.host]) {
        [self finish:completion mime:nil headers:nil body:nil
               error:[self error:@"Прокси обслуживает только perchance.org"]];
        return;
    }
    [self loadOriginURL:origin userReferer:nil completion:completion];
}

- (void)loadPath:(NSString *)originPath completion:(PCProxyCompletion)completion {
    [self loadOriginURL:originPath userReferer:nil completion:completion];
}

- (void)loadOriginURL:(NSString *)origin
          userReferer:(NSString *)referer
           completion:(PCProxyCompletion)completion {
    NSURL *realURL = [NSURL URLWithString:origin];
    if (!realURL) {
        [self finish:completion mime:nil headers:nil body:nil error:[self error:@"Плохой URL"]];
        return;
    }

    NSMutableURLRequest *up = [NSMutableURLRequest requestWithURL:realURL];
    up.HTTPMethod = @"GET";
    NSString *originHeader = [NSString stringWithFormat:@"https://%@", realURL.host];
    [up setValue:originHeader forHTTPHeaderField:@"Referer"];
    [up setValue:@"text/html,application/xhtml+xml,*/*;q=0.8" forHTTPHeaderField:@"Accept"];

    NSURLSessionDataTask *task =
        [self.session dataTaskWithRequest:up
                        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            [self finish:completion mime:nil headers:nil body:nil error:err];
            return;
        }
        NSHTTPURLResponse *http = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
        NSString *mime = resp.MIMEType ?: @"application/octet-stream";
        // Cloudflare: если пришёл challenge — сообщаем честно
        if ([mime containsString:@"text/html"] && [[http.allHeaderFields description] containsString:@"cf-mitigated"]) {
            // всё равно отдадим HTML: на iOS без JS он не пройдёт, но человек увидит страницу
        }
        [self processData:data mime:mime headers:http.allHeaderFields ?: @{} url:origin completion:completion];
    }];
    [task resume];
}

- (void)processData:(NSData *)data
               mime:(NSString *)mime
            headers:(NSDictionary *)headers
                url:(NSString *)url
         completion:(PCProxyCompletion)completion {
    NSString *lower = [mime lowercaseString];
    BOOL isHTML = [lower containsString:@"text/html"];
    BOOL isJS = [lower containsString:@"javascript"] || (!isHTML && [url hasSuffix:@".js"]);
    BOOL isCSS = [lower containsString:@"text/css"];

    // Service Worker отключён: он кэширует непереписанные файлы.
    if ([[url lowercaseString] containsString:@"service-worker"] || [url hasSuffix:@"/sw.js"]) {
        NSString *shim = @"self.addEventListener('install',function(e){self.skipWaiting()});"
                          "self.addEventListener('activate',function(e){e.waitUntil(self.registration.unregister())});";
        [self finish:completion mime:@"application/javascript" headers:headers
                 body:[shim dataUsingEncoding:NSUTF8StringEncoding] error:nil];
        return;
    }

    if (!isHTML && !isJS && !isCSS) {
        [self finish:completion mime:mime headers:headers body:data error:nil];
        return;
    }

    NSString *source = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!source) {
        [self finish:completion mime:mime headers:headers body:data error:nil];
        return;
    }

    // --- кэш
    NSString *kind = isHTML ? @"html" : (isJS ? @"js" : @"css");
    NSString *key = [self cacheKeyForURL:url kind:kind];
    NSString *path = [[self cachePath] stringByAppendingPathComponent:key];
    NSString *cached = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (cached.length) {
        if (isHTML) { [self deliverHTML:cached url:url completion:completion]; }
        else { [self finish:completion mime:[self mimeForKind:kind] headers:headers
                       body:[cached dataUsingEncoding:NSUTF8StringEncoding] error:nil]; }
        return;
    }

    if (isHTML) {
        NSString *out = [self.transpiler transformHTMLString:source];
        [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        [self deliverHTML:out url:url completion:completion];
        return;
    }

    if (isCSS) {
        [self.transpiler patchCSS:source completion:^(id result, NSError *error) {
            NSString *out = [result isKindOfClass:[NSString class]] ? result : source;
            [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            [self finish:completion mime:@"text/css; charset=utf-8" headers:headers
                     body:[out dataUsingEncoding:NSUTF8StringEncoding] error:nil];
        }];
        return;
    }

    [self.transpiler transformJS:source filename:url completion:^(id result, NSError *error) {
        NSDictionary *dict = [result isKindOfClass:[NSDictionary class]] ? result : nil;
        NSString *code = [dict[@"code"] isKindOfClass:[NSString class]] ? dict[@"code"] : source;
        if ([dict[@"ok"] boolValue]) { self.transformed++; } else { self.failed++; }
        [code writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        [self finish:completion mime:@"application/javascript; charset=utf-8" headers:headers
                 body:[code dataUsingEncoding:NSUTF8StringEncoding] error:nil];
    }];
}

- (NSString *)mimeForKind:(NSString *)kind {
    if ([kind isEqualToString:@"js"]) { return @"application/javascript; charset=utf-8"; }
    if ([kind isEqualToString:@"css"]) { return @"text/css; charset=utf-8"; }
    return @"text/html; charset=utf-8";
}

/// В каталог Resources/web попадают копии полифилов и Babel.
/// Страница ищет их по путям нового сайта (/__legacy/…) — отдаём из бандла,
/// чтобы не зависеть от perchance.org и не ходить в сеть лишний раз.
- (BOOL)bundledResourceForPath:(NSString *)path
                          mime:(NSString **)outMime
                          body:(NSData **)outBody {
    static NSDictionary<NSString *, NSString *> *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"/__legacy/polyfills.js":    @[@"polyfills.js", @"application/javascript"],
            @"/__legacy/legacy.js":       @[@"legacy.js", @"application/javascript"],
            @"/__legacy/pc-bootstrap.js": @[@"pc-bootstrap.js", @"application/javascript"],
            @"/__legacy/babel.min.js":    @[@"babel.min.js", @"application/javascript"],
            @"/__legacy/compat.css":      @[@"compat.css", @"text/css"]
        };
    });
    NSArray *entry = map[path];
    if (!entry) { return NO; }

    NSString *file = [[NSBundle mainBundle] pathForResource:entry[0] ofType:nil inDirectory:@"web"];
    if (!file) { file = [[NSBundle mainBundle] pathForResource:entry[0] ofType:nil]; }
    NSData *data = [NSData dataWithContentsOfFile:file];
    if (!data) { return NO; }

    if (outMime) { *outMime = [entry[1] stringByAppendingString:@"; charset=utf-8"]; }
    if (outBody) { *outBody = data; }
    return YES;
}

/// HTML отдаём особым образом: контроллер загрузит его loadHTMLString'ом
/// с адресом wk://pc/<host>/<path>, чтобы относительные ссылки шли через нас.
- (void)deliverHTML:(NSString *)html
                url:(NSString *)url
         completion:(PCProxyCompletion)completion {
    NSURL *pageURL = [self webURLForOrigin:url];
    [self finish:completion
            mime:@"__html__"
         headers:@{@"pageURL": pageURL.absoluteString ?: @""}
            body:[html dataUsingEncoding:NSUTF8StringEncoding]
           error:nil];
}

- (void)finish:(PCProxyCompletion)completion
          mime:(NSString *)mime
       headers:(NSDictionary *)headers
          body:(NSData *)body
         error:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) { completion(mime, headers, body, error); }
    });
}

- (NSError *)error:(NSString *)message {
    return [NSError errorWithDomain:@"PCProxy" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end
