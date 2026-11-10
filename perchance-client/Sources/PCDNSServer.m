#import "PCDNSServer.h"

#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

static NSString * const kRootDomain = @"perchance.org";
static NSString * const kUpstreamDNS = @"1.1.1.1";

@interface PCDNSServer ()
@property (nonatomic, assign) int sock;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) NSUInteger queryCount;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation PCDNSServer

- (instancetype)init {
    if ((self = [super init])) {
        _sock = -1;
        _queue = dispatch_queue_create("pc.dns", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)startOnPort:(uint16_t)port error:(NSError **)error {
    if (self.running) { return YES; }

    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) {
        if (error) { *error = [self errorWithCode:errno message:@"socket() не удался"]; }
        return NO;
    }
    int yes = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        int e = errno;
        close(s);
        if (error) {
            *error = [self errorWithCode:e message:
                [NSString stringWithFormat:@"bind(127.0.0.1:%u) не удался (errno %d). "
                 "Для порта 53 нужны права root — запускай приложение из джейлбрейка.", port, e]];
        }
        return NO;
    }

    self.sock = s;
    self.running = YES;

    dispatch_async(self.queue, ^{
        uint8_t buffer[1500];
        while (self.running) {
            struct sockaddr_in client;
            socklen_t len = sizeof(client);
            ssize_t n = recvfrom(s, buffer, sizeof(buffer), 0, (struct sockaddr *)&client, &len);
            if (n <= 0) {
                if (!self.running) { break; }
                continue;
            }
            @autoreleasepool {
                [self handlePacket:[NSData dataWithBytes:buffer length:(NSUInteger)n]
                            from:client];
            }
        }
    });

    return YES;
}

- (void)stop {
    self.running = NO;
    if (self.sock >= 0) { close(self.sock); self.sock = -1; }
}

- (NSError *)errorWithCode:(NSInteger)code message:(NSString *)message {
    return [NSError errorWithDomain:@"PCDNS" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - Разбор пакета

- (void)handlePacket:(NSData *)packet from:(struct sockaddr_in)client {
    const uint8_t *p = packet.bytes;
    NSUInteger len = packet.length;
    if (len < 12) { return; }

    uint16_t qdcount = (uint16_t)((p[4] << 8) | p[5]);
    if (qdcount < 1) { return; }

    NSUInteger off = 12;
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    while (off < len) {
        uint8_t l = p[off];
        if (l == 0) { off += 1; break; }
        if ((l & 0xC0) == 0xC0) { return; } // сжатие в вопросе не поддерживаем
        if (off + 1 + l > len) { return; }
        NSString *label = [[NSString alloc] initWithBytes:p + off + 1
                                                  length:l
                                                encoding:NSASCIIStringEncoding];
        if (label) { [labels addObject:label]; }
        off += 1 + l;
    }
    if (off + 4 > len) { return; }
    uint16_t qtype = (uint16_t)((p[off] << 8) | p[off + 1]);
    NSString *name = [[labels componentsJoinedByString:@"."] lowercaseString];

    self.queryCount++;

    BOOL isPerchance = [name isEqualToString:kRootDomain] ||
                       [name hasSuffix:[@"." stringByAppendingString:kRootDomain]];

    if (isPerchance) {
        NSData *reply = nil;
        if (qtype == 1) {                 // A
            reply = [self answerAFor:packet questionEnd:off + 4];
        } else {                          // AAAA и прочее — пустой NOERROR
            reply = [self emptyAnswerFor:packet questionEnd:off + 4];
        }
        if (reply) { [self send:reply to:client]; }
        return;
    }

    [self forward:packet to:client];
}

- (NSData *)answerAFor:(NSData *)query questionEnd:(NSUInteger)end {
    const uint8_t *q = query.bytes;
    NSMutableData *out = [NSMutableData data];
    uint8_t header[12] = {0};
    header[0] = q[0]; header[1] = q[1];              // id
    header[2] = 0x81; header[3] = 0x80;              // QR|RD|RA|NOERROR
    header[5] = 1;                                   // qdcount=1
    header[7] = 1;                                   // ancount=1
    [out appendBytes:header length:12];
    [out appendBytes:q + 12 length:end - 12];

    uint8_t ans[16] = {0};
    ans[0] = 0xC0; ans[1] = 0x0C;                    // указатель на имя
    ans[2] = 0x00; ans[3] = 0x01;                    // A
    ans[4] = 0x00; ans[5] = 0x01;                    // IN
    ans[6] = 0x00; ans[7] = 0x00; ans[8] = 0x00; ans[9] = 0x3C;  // TTL 60
    ans[10] = 0x00; ans[11] = 0x04;
    ans[12] = 127; ans[13] = 0; ans[14] = 0; ans[15] = 1;
    [out appendBytes:ans length:16];
    return out;
}

- (NSData *)emptyAnswerFor:(NSData *)query questionEnd:(NSUInteger)end {
    const uint8_t *q = query.bytes;
    NSMutableData *out = [NSMutableData data];
    uint8_t header[12] = {0};
    header[0] = q[0]; header[1] = q[1];
    header[2] = 0x81; header[3] = 0x80;
    header[5] = 1;
    [out appendBytes:header length:12];
    [out appendBytes:q + 12 length:end - 12];
    return out;
}

#pragma mark - Пересылка «чужих» доменов

- (void)forward:(NSData *)query to:(struct sockaddr_in)client {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) { return; }

    struct timeval tv = {3, 0};
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    struct sockaddr_in up;
    memset(&up, 0, sizeof(up));
    up.sin_family = AF_INET;
    up.sin_port = htons(53);
    inet_pton(AF_INET, kUpstreamDNS.UTF8String, &up.sin_addr);

    if (sendto(s, query.bytes, query.length, 0, (struct sockaddr *)&up, sizeof(up)) < 0) {
        close(s);
        return;
    }

    uint8_t buf[1500];
    struct sockaddr_in from;
    socklen_t fromLen = sizeof(from);
    ssize_t n = recvfrom(s, buf, sizeof(buf), 0, (struct sockaddr *)&from, &fromLen);
    close(s);

    if (n > 0) {
        [self send:[NSData dataWithBytes:buf length:(NSUInteger)n] to:client];
    }
}

- (void)send:(NSData *)data to:(struct sockaddr_in)client {
    if (self.sock < 0) { return; }
    sendto(self.sock, data.bytes, data.length, 0, (struct sockaddr *)&client, sizeof(client));
}

@end
