#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^PCHandler)(id _Nullable result, NSError * _Nullable error);

@class WKWebView;

/// Мост между нативным кодом и JavaScript-транспайлером в WKWebView.
/// Внутри бандла лежит WKWebView, в который загружен `web/bridge.html`:
/// там запускается Babel (@babel/standalone) и обслуживаются запросы
/// страниц Perchance.
@interface PCJSTranspiler : NSObject

/// Загружает bridge.html. Обработчик вызывается один раз, когда Babel готов.
- (void)startWithCompletion:(PCHandler)completion;

/// Переписывает JS-код под Safari 12.
/// result.data — строка с новым кодом.
- (void)transformJS:(NSString *)code
           filename:(NSString *)filename
          completion:(PCHandler)completion;

/// Патчит CSS (inset/aspect-ratio/gap/light-dark/oklch…).
- (void)patchCSS:(NSString *)css completion:(PCHandler)completion;

/// Выполняет произвольный JS в bridge (для отладки).
- (void)evaluate:(NSString *)script completion:(PCHandler)completion;

@property (nonatomic, readonly) BOOL isReady;

@end

NS_ASSUME_NONNULL_END
