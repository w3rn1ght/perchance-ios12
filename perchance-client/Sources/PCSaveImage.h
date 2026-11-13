//
//  PCSaveImage.h
//  Сохранение картинки из веб-страницы в «Фото».
//

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Слабая обёртка: WKUserContentController держит обработчик сильно,
/// а контроллер держит webView — без обёртки получается цикл.
@interface PCImageScriptProxy : NSObject <WKScriptMessageHandler>

- (instancetype)initWithTarget:(id<WKScriptMessageHandler>)target;

@end

@interface PCSaveImage : NSObject

/// source — http(s)-URL либо data:image/...;base64,...
/// presenter — контроллер, от которого показывать результат.
+ (void)saveImageSource:(NSString *)source presenter:(UIViewController *)presenter;

@end

NS_ASSUME_NONNULL_END
