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

- (nullable instancetype)initWithTranspiler:(PCJSTranspiler *)transpiler {
    self = [super init];
    if (self != nil) {
        _transpiler = transpiler;
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 30;
        cfg.timeoutIntervalForResource = 60;
        cfg.HTTPCookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        cfg.HTTPShouldSetCookies = YES;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.HTTPAdditionalHeaders = @{
            @"User-Agent": @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                           @"AppleWebKit/537.36 (KHTML, like Gecko) "
                           @"Chrome/131.0.0.0 Safari/537.36",
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
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [NSString stringWithFormat:@"%@-%@.dat", kind, hex];
}

- (void)clearCache {
    [[NSFileManager defaultManager] removeItemAtPath:[self cachePath] error:NULL];
    [self prepare];
}

#pragma mark - Адреса

/// wk://pc/a257….perchance.org/welcome?x=1 → https://a257….perchance.org/welcome?x=1
- (nullable NSString *)originURLStringForRequest:(NSURLRequest *)request {
    NSString *raw = request.URL.absoluteString;
    NSString *prefix = [NSString stringWithFormat:@"%@://%@/", PCScheme, PCSchemeHost];
    if (![raw hasPrefix:prefix]) { return nil; }
    NSString *encoded = [raw substringFromIndex:prefix.length];
    NSString *decoded = [encoded stringByRemovingPercentEncoding];
    if (decoded.length == 0) { decoded = encoded; }

    NSRange slash = [decoded rangeOfString:@"/"];
    NSString *host = slash.location == NSNotFound ? decoded : [decoded substringToIndex:slash.location];
    NSString *rest = slash.location == NSNotFound ? @"" : [decoded substringFromIndex:slash.location];
    if (host.length == 0) { host = kRootDomain; }
    return [NSString stringWithFormat:@"https://%@%@", host, rest];
}

- (BOOL)isPerchanceHost:(NSString *)host {
    NSString *h = [host lowercaseString];
    if ([h isEqualToString:kRootDomain]) { return YES; }
    return [h hasSuffix:[@"." stringByAppendingString:kRootDomain]];
}

/// Публичный адрес страницы — нужен, чтобы относительные ссылки шли через нас.
- (NSURL *)webURLForOrigin:(NSString *)origin {
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@/%@", PCScheme, PCSchemeHost, origin]];
}

/// Полифилы, Babel и compat.css лежат в Resources/web — отдаём их из бандла.
- (BOOL)bundledResourceForPath:(NSString *)path mime:(NSString **)outMime body:(NSData **)outBody {
    static NSDictionary<NSString *, NSArray<NSString *> *> *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"/__legacy/polyfills.js":    @[ @"polyfills.js", @"application/javascript" ],
            @"/__legacy/legacy.js":       @[ @"legacy.js", @"application/javascript" ],
            @"/__legacy/pc-bootstrap.js": @[ @"pc-bootstrap.js", @"application/javascript" ],
            @"/__legacy/babel.min.js":    @[ @"babel.min.js", @"application/javascript" ],
            @"/__legacy/core-js-bundle.js": @[ @"core-js-bundle.js", @"application/javascript" ],
            @"/__legacy/compat.css":      @[ @"compat.css", @"text/css" ]
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

#pragma mark - Загрузка

- (void)loadRequest:(NSURLRequest *)request completion:(PCProxyCompletion)completion {
    NSString *origin = [self originURLStringForRequest:request];
    if (origin == nil) {
        [self finish:completion mime:nil headers:nil body:nil error:[self error:@"Неизвестный URL"]];
        return;
    }

    NSString *originPath = [[NSURL URLWithString:origin] path];
    if (originPath.length == 0) { originPath = @"/"; }

    NSString *mime = nil;
    NSData *body = nil;
    if ([self bundledResourceForPath:originPath mime:&mime body:&body]) {
        [self finish:completion mime:mime headers:@{ @"Cache-Control": @"no-cache" } body:body error:nil];
        return;
    }

    NSURL *realURL = [NSURL URLWithString:origin];
    if (realURL == nil || ![self isPerchanceHost:realURL.host]) {
        [self finish:completion mime:nil headers:nil body:nil
               error:[self error:@"Прокси обслуживает только perchance.org"]];
        return;
    }
    [self loadOriginURL:origin completion:completion];
}

- (void)loadPath:(NSString *)originPath completion:(PCProxyCompletion)completion {
    [self loadOriginURL:originPath completion:completion];
}

- (void)loadOriginURL:(NSString *)origin completion:(PCProxyCompletion)completion {
    NSURL *realURL = [NSURL URLWithString:origin];
    if (realURL == nil) {
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
        if (err != nil) {
            [self finish:completion mime:nil headers:nil body:nil error:err];
            return;
        }
        NSHTTPURLResponse *http = nil;
        if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
            http = (NSHTTPURLResponse *)resp;
        }
        NSString *mime = resp.MIMEType;
        if (mime.length == 0) { mime = @"application/octet-stream"; }
        NSDictionary *headers = http.allHeaderFields;
        if (headers == nil) { headers = @{}; }
        [self processData:data mime:mime headers:headers url:origin completion:completion];
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
    BOOL isCSS = [lower containsString:@"text/css"];
    BOOL isJS = NO;
    if ([lower containsString:@"javascript"]) { isJS = YES; }
    if (!isHTML && !isJS && [url hasSuffix:@".js"]) { isJS = YES; }

    // Service Worker отключён: он кэширует непереписанные файлы.
    NSString *lowerURL = [url lowercaseString];
    if ([lowerURL containsString:@"service-worker"] || [url hasSuffix:@"/sw.js"]) {
        NSString *shim = @"self.addEventListener('install',function(e){self.skipWaiting()});"
                         @"self.addEventListener('activate',function(e){e.waitUntil(self.registration.unregister())});";
        [self finish:completion mime:@"application/javascript" headers:headers
                 body:[shim dataUsingEncoding:NSUTF8StringEncoding] error:nil];
        return;
    }

    if (!isHTML && !isJS && !isCSS) {
        [self finish:completion mime:mime headers:headers body:data error:nil];
        return;
    }

    NSString *source = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (source == nil) {
        [self finish:completion mime:mime headers:headers body:data error:nil];
        return;
    }

    // --- кэш
    NSString *kind = @"css";
    if (isHTML) { kind = @"html"; }
    else if (isJS) { kind = @"js"; }
    NSString *path = [[self cachePath] stringByAppendingPathComponent:[self cacheKeyForURL:url kind:kind]];
    NSString *cached = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (cached.length > 0) {
        if (isHTML) {
            [self deliverHTML:cached url:url completion:completion];
        } else {
            [self finish:completion mime:[self mimeForKind:kind] headers:headers
                     body:[cached dataUsingEncoding:NSUTF8StringEncoding] error:nil];
        }
        return;
    }

    if (isHTML) {
        // <base> нужен, чтобы относительные пути (/lib/appExtras.js и т.п.)
        // резолвились в wk://pc/<host>/… и шли через обработчик схемы.
        NSString *host = [[NSURL URLWithString:url] host];
        if (host.length == 0) { host = @"perchance.org"; }
        NSString *baseHref = [NSString stringWithFormat:@"%@://%@/%@/", PCScheme, PCSchemeHost, host];
        [self.transpiler transformHTML:source baseHref:baseHref completion:^(id result, NSError *error) {
            NSString *out = source;
            if ([result isKindOfClass:[NSString class]]) { out = (NSString *)result; }
            [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            [self deliverHTML:out url:url completion:completion];
        }];
        return;
    }

    if (isCSS) {
        [self.transpiler patchCSS:source completion:^(id result, NSError *error) {
            NSString *out = source;
            if ([result isKindOfClass:[NSString class]]) { out = (NSString *)result; }
            [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            [self finish:completion mime:@"text/css; charset=utf-8" headers:headers
                     body:[out dataUsingEncoding:NSUTF8StringEncoding] error:nil];
        }];
        return;
    }

    [self.transpiler transformJS:source filename:url completion:^(id result, NSError *error) {
        NSDictionary *dict = nil;
        if ([result isKindOfClass:[NSDictionary class]]) { dict = (NSDictionary *)result; }
        NSString *code = source;
        NSString *converted = dict[@"code"];
        if ([converted isKindOfClass:[NSString class]]) { code = converted; }
        if ([dict[@"ok"] boolValue]) {
            self.transformed = self.transformed + 1;
        } else {
            self.failed = self.failed + 1;
        }
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

/// HTML отдаём как обычный документ. loadHTMLString изнутри задачи схемы
/// запускал повторную навигацию и ронял WebKit, поэтому его больше нет:
/// относительные ссылки разрешает <base>, который вставляет transform-web.js.
- (void)deliverHTML:(NSString *)html url:(NSString *)url completion:(PCProxyCompletion)completion {
    [self finish:completion
            mime:@"text/html; charset=utf-8"
         headers:@{ @"Cache-Control": @"no-store" }
            body:[html dataUsingEncoding:NSUTF8StringEncoding]
           error:nil];
}

- (void)finish:(PCProxyCompletion)completion
          mime:(NSString *)mime
       headers:(NSDictionary *)headers
          body:(NSData *)body
         error:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion != nil) {
            completion(mime, headers, body, error);
        }
    });
}

- (NSError *)error:(NSString *)message {
    return [NSError errorWithDomain:@"PCProxy" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end
