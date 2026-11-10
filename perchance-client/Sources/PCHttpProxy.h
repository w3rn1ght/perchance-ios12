#import <Foundation/Foundation.h>
#import "PCProxy.h"

NS_ASSUME_NONNULL_BEGIN

/// Системный режим: локальный DNS + HTTPS, чтобы https://perchance.org
/// открывался через нас во ВСЕХ приложениях, а не только в нашем.
///
/// Упрощённая схема, полностью соответствующая модели iOS 12:
///   • HTTPS-сервер на 127.0.0.1:443 (SecureTransport, сертификат cert.pem/key.pem);
///   • DNS-сервер отвечает 127.0.0.1 на *.perchance.org (см. PCHttpDNSServer);
///   • приложение (или твик /etc/hosts) направляет запросы домена на localhost.
///
/// Сборка системного режима включается флагом компилятора PC_SYSTEM_MODE=1.
@interface PCHttpProxy : NSObject

- (instancetype)initWithProxy:(PCProxy *)proxy;

- (BOOL)startWithError:(NSError **)error;
- (void)stop;

@property (nonatomic, readonly) BOOL running;

/// Порт, который реально удалось занять (443 в джейлбрейке или 8443).
@property (nonatomic, readonly) uint16_t listeningPort;

@end

NS_ASSUME_NONNULL_END
