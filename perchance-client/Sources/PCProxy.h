#import <Foundation/Foundation.h>
#import "PCJSTranspiler.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const PCScheme;
extern NSString * const PCSchemeHost;
extern NSString * const PCCacheDirectory;

/// MIME-тип, заголовки, тело и ошибка загрузки.
typedef void (^PCProxyCompletion)(NSString * _Nullable mime,
                                  NSDictionary<NSString *, id> * _Nullable headers,
                                  NSData * _Nullable body,
                                  NSError * _Nullable error);

/// «Прокси» внутри приложения: скачивает файлы с perchance.org и переписывает
/// их под Safari 12 (JS → Babel, CSS-фолбэки, HTML-полифилы).
@interface PCProxy : NSObject

- (nullable instancetype)initWithTranspiler:(PCJSTranspiler *)transpiler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)prepare;
- (void)loadRequest:(NSURLRequest *)request completion:(PCProxyCompletion)completion;
- (void)loadPath:(NSString *)originPath completion:(PCProxyCompletion)completion;
- (void)clearCache;

@property (nonatomic, readonly) NSInteger transformedCount;
@property (nonatomic, readonly) NSInteger failedCount;

@end

NS_ASSUME_NONNULL_END
