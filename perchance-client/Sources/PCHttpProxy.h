#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class PCProxy;

/// Системный режим: локальный HTTPS-сервер на 127.0.0.1:443.
///
/// Нужен, чтобы https://perchance.org открывался через нас не только внутри
/// приложения, но и в Safari / других приложениях. Требует установленного
/// CA-сертификата (certs/ca.crt) и парного DNS-сервера (PCDNSServer).
///
/// Включается флагом компилятора PC_SYSTEM_MODE=1 — см. README.
@interface PCHttpProxy : NSObject

- (instancetype)initWithProxy:(PCProxy *)proxy NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error;
- (void)stop;

@property (nonatomic, readonly) BOOL running;

/// Реально занятый порт: 443 под root, иначе 8443.
@property (nonatomic, readonly) uint16_t listeningPort;

@end

NS_ASSUME_NONNULL_END
