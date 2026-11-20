#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Загружает страницу настоящим движком WebKit по https://.
///
/// Нужен только как обход Cloudflare: прокси ходит через NSURLSession, чей
/// отпечаток TLS/HTTP2 Cloudflare не считает браузером и выдаёт managed
/// challenge. На схеме wk:// пройти его нельзя — страница не в secure
/// context и не может использовать crypto.subtle. Скрытый WKWebView грузит
/// тот же адрес по https://, где challenge решается штатно, и отдаёт готовый
/// HTML. Куки после загрузки перекладываются в общее хранилище, чтобы
/// следующие запросы NSURLSession тоже проходили.
@interface PCWebFetcher : NSObject

+ (instancetype)shared;

/// Всегда вызывает completion на главном потоке, ровно один раз.
/// html == nil означает, что страницу получить не удалось (см. error).
- (void)fetchHTMLForURL:(NSURL *)url
             completion:(void (^)(NSString * _Nullable html,
                                  NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
