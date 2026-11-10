#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import "PCProxy.h"

NS_ASSUME_NONNULL_BEGIN

/// WKURLSchemeHandler для схемы wk:// — отдаёт переписанные файлы.
/// Страницы (HTML) уходят в WebView через loadHTMLString с адресом wk://…,
/// чтобы относительные ссылки оставались внутри прокси.
@interface PCTranspilerProtocolHandler : NSObject <WKURLSchemeHandler>

- (instancetype)initWithProxy:(PCProxy *)proxy;

/// Сюда контроллер передаёт свой WKWebView: он же принимает готовый HTML.
@property (nonatomic, weak, nullable) WKWebView *webView;

/// Копия настоящего адреса страницы (передаётся дальше).
- (NSString *)originForRequest:(NSURLRequest *)request;

@property (nonatomic, readonly) PCProxy *proxy;

@end

NS_ASSUME_NONNULL_END
