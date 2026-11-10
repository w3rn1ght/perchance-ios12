#import <Foundation/Foundation.h>
#import "PCProxy.h"

NS_ASSUME_NONNULL_BEGIN

/// Локальный DNS-сервер (UDP 53) для iOS-приложения.
///
/// Отвечает 127.0.0.1 на `perchance.org` и любые `*.perchance.org` —
/// поэтому и главная страница, и iframe генератора попадают в наш HTTPS-сервер.
/// Все остальные имена пересылаются в обычный DNS.
@interface PCDNSServer : NSObject

- (BOOL)startOnPort:(uint16_t)port error:(NSError **)error;
- (void)stop;

@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) NSUInteger queryCount;

@end

NS_ASSUME_NONNULL_END
