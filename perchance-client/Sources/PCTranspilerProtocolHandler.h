#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import "PCProxy.h"

NS_ASSUME_NONNULL_BEGIN

/// Обработчик схемы wk:// для WKWebView.
///
/// Отдаёт переписанные файлы, а HTML — через loadHTMLString с адресом
/// wk://pc/<host>/<path>, чтобы относительные ссылки оставались в прокси.
@interface PCTranspilerProtocolHandler : NSObject <WKURLSchemeHandler>

- (instancetype)initWithProxy:(PCProxy *)proxy NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Контроллер передаёт сюда свой WKWebView — он принимает готовый HTML.
@property (nonatomic, weak, nullable) WKWebView *webView;

/// Прокси, через который идут загрузки.
@property (nonatomic, strong, readonly) PCProxy *proxy;

@end

NS_ASSUME_NONNULL_END
