#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

@class PCProxy, PCTranspilerProtocolHandler;

NS_ASSUME_NONNULL_BEGIN

/// Экран с Perchance внутри WKWebView.
/// Все запросы идут через схему wk:// и уже переписанный JS (Safari 12).
@interface PCMainViewController : UIViewController

- (instancetype)initWithProxy:(PCProxy *)proxy
                      handler:(PCTranspilerProtocolHandler *)handler
                    startPath:(nullable NSString *)path;

@property (nonatomic, readonly) WKWebView *web;
@property (nonatomic, readonly) PCTranspilerProtocolHandler *handler;

- (void)loadHome;
- (void)loadPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
