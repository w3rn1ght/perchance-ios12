#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Колбэк моста: результат (или nil) и ошибка (или nil).
typedef void (^PCHandler)(id _Nullable result, NSError * _Nullable error);

/// Транспайлер внутри приложения.
///
/// WebKit не даёт перехватывать тела ответов, поэтому переписывать код нужно
/// ДО того, как файл попадёт в страницу. Здесь — скрытый WKWebView с Babel
/// (@babel/standalone): он принимает исходный текст по мосту
/// (window.webkit.messageHandlers.pc) и возвращает совместимый код.
@interface PCJSTranspiler : NSObject

- (void)startWithCompletion:(nullable PCHandler)completion;

- (void)transformJS:(NSString *)code
           filename:(NSString *)filename
         completion:(nullable PCHandler)completion;

- (void)patchCSS:(NSString *)css completion:(nullable PCHandler)completion;

/// Переписать HTML. Асинхронно — вызывающий уже находится в главном потоке,
/// а evaluateJavaScript завершается тоже в главном: синхронное ожидание
/// семафора здесь привело бы к дедлоку.
- (void)transformHTML:(NSString *)html
             baseHref:(nullable NSString *)baseHref
           completion:(nullable PCHandler)completion;

- (void)evaluate:(NSString *)script completion:(nullable PCHandler)completion;

@property (nonatomic, readonly) BOOL isReady;

@end

NS_ASSUME_NONNULL_END
