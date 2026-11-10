#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

@class PCProxy;
@class PCTranspilerProtocolHandler;

NS_ASSUME_NONNULL_BEGIN

/// Экран Perchance: адресная строка + WKWebView.
/// Все запросы идут через схему wk:// (уже переписанный JS).
@interface PCMainViewController : UIViewController

- (instancetype)initWithProxy:(PCProxy *)proxy
                      handler:(PCTranspilerProtocolHandler *)handler
                    startPath:(nullable NSString *)path;

@property (nonatomic, strong, readonly) WKWebView *web;
@property (nonatomic, strong, readonly) PCTranspilerProtocolHandler *handler;

- (void)loadHome;
- (void)loadPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
