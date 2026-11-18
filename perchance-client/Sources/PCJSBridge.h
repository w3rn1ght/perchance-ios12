#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Мост «страница → нативная часть» для двух вещей, которые WKWebView на
/// iOS 12 не умеет сам:
///
///  • `pcbody` — тело POST-запроса. WKURLSchemeTask на iOS 12 не отдаёт
///    `HTTPBody` (WebKit его просто не передаёт), поэтому fetch/XHR в
///    runtime-hooks.js кладут тело сюда, а PCProxy забирает его по
///    заголовку `X-PC-Body-Id` и отправляет на настоящий сервер.
///
///  • `pcdiag` — статистика runtime-hooks из каждого кадра. localStorage
///    главного кадра бесполезен: iframe-ы живут на других origin-ах,
///    поэтому счётчики идут отдельными сообщениями.
@interface PCJSBridge : NSObject <WKScriptMessageHandler>

+ (instancetype)shared;

/// Забирает (и удаляет) тело POST по идентификатору. nil, если тела нет.
- (nullable NSString *)takeBodyForId:(NSString *)identifier;

/// Отчёт для экрана диагностики: последняя статистика всех кадров плюс
/// произвольные строки от PCProxy.
- (NSString *)diagnosticsReportWithExtra:(NSArray<NSString *> *)extra;

/// Сбрасывает накопленные тела и статистику (перед новой навигацией).
- (void)reset;

@end

NS_ASSUME_NONNULL_END
