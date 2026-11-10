#import "PCHttpProxy.h"

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
@property (nonatomic, assign, readwrite) uint16_t listeningPort;
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

- (BOOL)startWithError:(NSError **)error {
    uint16_t portToTry = 443;
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) {
        if (error) {
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
    a.sin_port = htons(portToTry);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(s, (struct sockaddr *)&a, sizeof(a)) < 0) {
        close(s);
        // Права не дали 443 → работаем на 8443
        portToTry = 8443;
        s = socket(AF_INET, SOCK_STREAM, 0);
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        a.sin_port = htons(portToTry);
        if (bind(s, (struct sockaddr *)&a, sizeof(a)) < 0) {
            if (error) {
                *error = [NSError errorWithDomain:@"PCHttpProxy" code:2
                                         userInfo:@{NSLocalizedDescriptionKey: @"bind(127.0.0.1) failed"}];
            }
            close(s);
            return NO;
        }
    }

    self.listeningPort = portToTry;
    self.listenSocket = s;
    self.running = YES;
    if (listen(s, 32) < 0) { self.running = NO; return NO; }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self acceptLoop];
    });
    return YES;
}

- (void)acceptLoop {
    while (self.running) {
        struct sockaddr_in cli;
        socklen_t len = sizeof(cli);
        int c = accept(self.listenSocket, (struct sockaddr *)&cli, &len);
        if (c < 0) {
            if (!self.running) { break; }
            continue;
        }
        @autoreleasepool {
            [self serveClient:c];
        }
        close(c);
    }
}

- (void)stop {
    self.running = NO;
    if (self.listenSocket >= 0) { close(self.listenSocket); self.listenSocket = -1; }
}

// TLS и HTTP/1.1 обмен — заглушка: это следующий шаг сборки системного
// режима. Подключается на SecureTransport (SSLCreateContext), код HTTP-разбора
// — тот же, что на сервере в Lib/proxy.js.
- (void)serveClient:(int)client {
    const char *msg = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 30\r\n\r\nСистемный режим: TLS ещё не подключён";
    send(client, msg, strlen(msg), 0);
}

@end

#else

@implementation PCHttpProxy
- (instancetype)initWithProxy:(PCProxy *)proxy {
    if ((self = [super init])) { _proxy = proxy; _listeningPort = 8443; }
    return self;
}
- (BOOL)startWithError:(NSError **)error {
    if (error) {
        *error = [NSError errorWithDomain:@"PCHttpProxy" code:0 userInfo:@{
            NSLocalizedDescriptionKey:
                @"Системный режим не собран (PC_SYSTEM_MODE=1 в Makefile). "
                "По умолчанию работает встроенный режим — сайт открывается внутри приложения."}];
    }
    return NO;
}
- (void)stop {}
@end

#endif
