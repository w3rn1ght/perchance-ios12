//
//  PCSaveImage.m
//

#import "PCSaveImage.h"

#import "PCLog.h"

@interface PCImageScriptProxy ()
@property (nonatomic, weak) id<WKScriptMessageHandler> target;
@end

@implementation PCImageScriptProxy

- (instancetype)initWithTarget:(id<WKScriptMessageHandler>)target {
    if ((self = [super init])) {
        _target = target;
    }
    return self;
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.target userContentController:userContentController didReceiveScriptMessage:message];
}

@end

#pragma mark -

@interface PCSaveImage ()

@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, assign) BOOL busy;

- (void)saveSource:(NSString *)source presenter:(UIViewController *)presenter;
- (nullable UIImage *)imageFromDataURL:(NSString *)dataURL;
- (void)writeImage:(UIImage *)image;
- (void)reportMessage:(NSString *)message title:(NSString *)title;

@end

@implementation PCSaveImage

+ (PCSaveImage *)sharedSaver {
    static PCSaveImage *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[PCSaveImage alloc] init];
    });
    return shared;
}

+ (void)saveImageSource:(NSString *)source presenter:(UIViewController *)presenter {
    [[self sharedSaver] saveSource:source presenter:presenter];
}

- (void)saveSource:(NSString *)source presenter:(UIViewController *)presenter {
    self.presenter = presenter;

    if (![source isKindOfClass:[NSString class]] || source.length == 0) {
        [self reportMessage:@"Пустая ссылка на изображение." title:@"Не удалось сохранить"];
        return;
    }

    if ([source hasPrefix:@"data:image/"]) {
        UIImage *image = [self imageFromDataURL:source];
        if (image == nil) {
            [self reportMessage:@"Не удалось декодировать изображение."
                          title:@"Не удалось сохранить"];
            return;
        }
        [self writeImage:image];
        return;
    }

    NSURL *url = [NSURL URLWithString:source];
    NSString *scheme = url.scheme.lowercaseString;
    if (url == nil || (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"])) {
        [self reportMessage:@"Эту картинку нельзя скачать напрямую."
                      title:@"Не удалось сохранить"];
        return;
    }

    if (self.busy) {
        PCLog(@"[save] уже сохраняю, второй запрос пропущен");
        return;
    }
    self.busy = YES;
    PCLog(@"[save] скачиваю %@", url.absoluteString);

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"Mozilla/5.0 (iPad; CPU OS 12_5 like Mac OS X) AppleWebKit/605.1.15 "
                      @"(KHTML, like Gecko) Version/12.1 Mobile/15E148 Safari/604.1"
   forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"https://perchance.org/" forHTTPHeaderField:@"Referer"];
    request.timeoutInterval = 30.0;

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:request
                                        completionHandler:^(NSData *data,
                                                            NSURLResponse *response,
                                                            NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            PCSaveImage *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            strongSelf.busy = NO;
            if (error != nil || data.length == 0) {
                PCLogError(@"[save] ошибка загрузки: %@", error.localizedDescription);
                [strongSelf reportMessage:@"Не удалось скачать изображение. Проверьте соединение."
                                    title:@"Не удалось сохранить"];
                return;
            }
            UIImage *image = [UIImage imageWithData:data];
            if (image == nil) {
                [strongSelf reportMessage:@"Сервер вернул не изображение."
                                    title:@"Не удалось сохранить"];
                return;
            }
            [strongSelf writeImage:image];
        });
    }];
    [task resume];
}

#pragma mark - Внутреннее

- (nullable UIImage *)imageFromDataURL:(NSString *)dataURL {
    NSRange commaRange = [dataURL rangeOfString:@","];
    if (commaRange.location == NSNotFound) {
        return nil;
    }
    NSString *header = [dataURL substringToIndex:commaRange.location];
    NSString *payload = [dataURL substringFromIndex:NSMaxRange(commaRange)];
    NSData *data = nil;

    if ([header rangeOfString:@"base64"].location != NSNotFound) {
        data = [[NSData alloc] initWithBase64EncodedString:payload
                                                   options:NSDataBase64DecodingIgnoreUnknownCharacters];
    } else {
        NSString *decoded = [payload stringByRemovingPercentEncoding];
        if (decoded != nil) {
            data = [decoded dataUsingEncoding:NSUTF8StringEncoding];
        }
    }
    if (data == nil) {
        return nil;
    }
    return [UIImage imageWithData:data];
}

- (void)writeImage:(UIImage *)image {
    PCLog(@"[save] пишу в «Фото» %.0fx%.0f", image.size.width, image.size.height);
    UIImageWriteToSavedPhotosAlbum(image, self,
                                   @selector(image:didFinishSavingWithError:contextInfo:), NULL);
}

- (void)image:(UIImage *)image
    didFinishSavingWithError:(nullable NSError *)error
                 contextInfo:(void *)contextInfo {
    if (error != nil) {
        PCLogError(@"[save] Фото отказало: %@", error.localizedDescription);
        NSString *message = @"Разрешите доступ к «Фото» в Настройках и попробуйте снова.";
        if (error.localizedDescription.length > 0) {
            message = error.localizedDescription;
        }
        [self reportMessage:message title:@"Не удалось сохранить"];
        return;
    }
    PCLog(@"[save] готово");
    [self reportMessage:@"Картинка в «Фото»." title:@"Сохранено"];
}

- (void)reportMessage:(NSString *)message title:(NSString *)title {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = self.presenter;
        while (presenter.presentedViewController != nil) {
            presenter = presenter.presentedViewController;
        }
        while (presenter.isBeingDismissed && presenter.presentingViewController != nil) {
            presenter = presenter.presentingViewController;
        }
        if (presenter == nil || presenter.view.window == nil) {
            PCLog(@"[save] %@: %@", title, message);
            return;
        }
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:title
                                                message:message
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

@end
