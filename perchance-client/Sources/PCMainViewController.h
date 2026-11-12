#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

@class PCProxy;
@class PCTranspilerProtocolHandler;
@class PCJSTranspiler;

NS_ASSUME_NONNULL_BEGIN

/// Экран Perchance: адресная строка + WKWebView.
/// Все запросы идут через схему wk:// (уже переписанный JS).
@interface PCMainViewController : UIViewController

- (instancetype)initWithProxy:(PCProxy *)proxy
                      handler:(PCTranspilerProtocolHandler *)handler
                   transpiler:(PCJSTranspiler *)transpiler
                    startPath:(nullable NSString *)path;

@property (nonatomic, strong, readonly) WKWebView *web;
@property (nonatomic, strong, readonly) PCTranspilerProtocolHandler *handler;
@property (nonatomic, copy) NSString *startPath;

- (void)loadHome;
- (void)loadPath:(NSString *)path;
- (void)loadOrigin:(NSString *)origin;

@end

NS_ASSUME_NONNULL_END
