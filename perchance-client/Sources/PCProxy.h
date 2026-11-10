#import <Foundation/Foundation.h>
#import "PCJSTranspiler.h"

/// Схема, которой подменяются запросы к perchance.org из нашего WKWebView.
extern NSString * const PCScheme;
/// Служебный «хост» схемы: wk://pc/<настоящий-host>/<путь>
extern NSString * const PCSchemeHost;
/// Подкаталог кэша внутри Library/Caches.
extern NSString * const PCCacheDirectory;

typedef void (^PCProxyCompletion)(NSString * _Nullable mime,
                                  NSDictionary<NSString *, id> * _Nullable headers,
                                  NSData * _Nullable body,
                                  NSError * _Nullable error);

/// Скачивает файлы с perchance.org, переписывает их под Safari 12
/// (JS через Babel, CSS-фолбэки, HTML-полифилы) и отдаёт WKWebView.
/// Это «прокси», встроенный в приложение.
@interface PCProxy : NSObject

- (instancetype)initWithTranspiler:(PCJSTranspiler *)transpiler;

/// Готовит каталог кэша.
- (void)prepare;

/// Запрос из WKURLSchemeHandler: wk://pc/…
- (void)loadRequest:(NSURLRequest *)request completion:(PCProxyCompletion)completion;

/// Навигация по настоящему адресу без схемы: "perchance.org/welcome".
- (void)loadPath:(NSString *)originPath completion:(PCProxyCompletion)completion;

/// Сбросить кэш переписанных файлов.
- (void)clearCache;

/// Сколько файлов реально переписано / не удалось переписать.
@property (nonatomic, readonly) NSInteger transformedCount;
@property (nonatomic, readonly) NSInteger failedCount;

@end
