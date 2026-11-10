#import "PCHttpProxy.h"
#import "PCProxy.h"

#if PC_SYSTEM_MODE

#import <Security/Security.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

@interface PCHttpProxy ()
@property (nonatomic, strong) PCProxy *proxy;
@property (nonatomic, assign) int listenSocket;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) uint16_t listeningPort;
@end

@implementation PCHttpProxy

- (instancetype)initWithProxy:(PCProxy *)proxy {
    if ((self = [super init])) {
        _proxy = proxy;
        _listenSocket = -1;
        _listeningPort = 8443;
    }
    return self;
}

- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error {
    uint16_t port = 443;
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"PCHttpProxy" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"socket() failed"}];
        }
        return NO;
    }
    int yes = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(s, (const struct sockaddr *)&a, sizeof(a)) < 0) {
        close(s);
        port = 8443;
        s = socket(AF_INET, SOCK_STREAM, 0);
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        a.sin_port = htons(port);
        if (bind(s, (const struct sockaddr *)&a, sizeof(a)) < 0) {
            if (error != NULL) {
                *error = [NSError errorWithDomain:@"PCHttpProxy" code:2
                                         userInfo:@{NSLocalizedDescriptionKey: @"bind(127.0.0.1) failed"}];
            }
            close(s);
            return NO;
        }
    }

    if (listen(s, 32) < 0) {
        close(s);
        return NO;
    }

    self.listeningPort = port;
    self.listenSocket = s;
    self.running = YES;
    return YES;
}

- (void)stop {
    self.running = NO;
    if (self.listenSocket >= 0) {
        close(self.listenSocket);
        self.listenSocket = -1;
    }
}

@end

#else

@implementation PCHttpProxy {
    uint16_t _listeningPort;
}

- (instancetype)initWithProxy:(PCProxy *)proxy {
    if ((self = [super init])) {
        _listeningPort = 8443;
    }
    return self;
}

- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error {
    if (error != NULL) {
        *error = [NSError errorWithDomain:@"PCHttpProxy" code:0 userInfo:@{
            NSLocalizedDescriptionKey:
                @"Системный режим не собран (нужен PC_SYSTEM_MODE=1). "
                "По умолчанию работает встроенный режим — сайт открывается внутри приложения."}];
    }
    return NO;
}

- (void)stop {
}

- (BOOL)running {
    return NO;
}

- (uint16_t)listeningPort {
    return _listeningPort;
}

@end

#endif
