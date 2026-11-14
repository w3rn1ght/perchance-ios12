#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Экран с логом аварийно завершившейся сессии.
///
/// Показывается автоматически при запуске после вылета: приложение ещё не
/// создаёт WKWebView, поэтому лог видно даже если падение происходит при
/// загрузке страницы.
@interface PCLogViewController : UIViewController

@property (nonatomic, copy) NSString *logText;
@property (nonatomic, copy, nullable) void (^onContinue)(void);
/// Блок для диагностики: выполняет JS в WKWebView и вызывает completion с результатом строки
@property (nonatomic, copy, nullable) void (^onDiagnostics)(void (^)(NSString *result));

@end

NS_ASSUME_NONNULL_END
