#import <Foundation/Foundation.h>
#import "PCJSTranspiler.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const PCScheme;
extern NSString * const PCSchemeHost;
extern NSString * const PCCacheDirectory;

/// UA настоящего Safari этого устройства. Один и тот же в заголовках,
/// в navigator (legacy.js) и в скрытом WKWebView.
FOUNDATION_EXPORT NSString *PCUserAgentString(void);

/// Этапы одной загрузки. Порядок всегда такой:
///   Head (один раз) → Data (0+ раз) → End (один раз).
///
/// Потоковый ответ нужен генераторам ИИ: сервер отдаёт текст токенами, и
/// страница ждёт заголовки не дольше 60 секунд. Если копить ответ целиком
/// (как было раньше), fetch на странице резолвится только после последнего
/// токена — для длинных ответов это гарантированный обрыв.
typedef NS_ENUM(NSInteger, PCProxyEvent) {
    PCProxyEventHead = 0,
    PCProxyEventData = 1,
    PCProxyEventEnd = 2
};

/// Все вызовы приходят на главном потоке и строго по порядку.
typedef void (^PCProxyHandler)(PCProxyEvent event,
                               NSInteger status,
                               NSString * _Nullable mime,
                               NSDictionary<NSString *, id> * _Nullable headers,
                               NSData * _Nullable data,
                               NSError * _Nullable error);

/// «Прокси» внутри приложения: скачивает файлы с perchance.org и переписывает
/// их под Safari 12 (JS → Babel, CSS-фолбэки, HTML-полифилы).
@interface PCProxy : NSObject

- (nullable instancetype)initWithTranspiler:(PCJSTranspiler *)transpiler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)prepare;

/// Единственная точка входа для схемы wk://.
- (void)loadRequest:(NSURLRequest *)request handler:(PCProxyHandler)handler;

- (void)clearCache;

@property (nonatomic, readonly) NSInteger transformedCount;
@property (nonatomic, readonly) NSInteger failedCount;

@end

NS_ASSUME_NONNULL_END
