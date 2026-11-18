#import "PCJSBridge.h"
#import "PCLog.h"

/// Сколько тел держим одновременно и сколько кадров помним. Всё ограничено,
/// чтобы долгая сессия не съела память.
static const NSUInteger PCJSMaxBodies = 32;
static const NSUInteger PCJSMaxFrames = 24;

@interface PCJSBridge ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *bodies;
@property (nonatomic, strong) NSMutableArray<NSString *> *bodyOrder;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *frames;
@property (nonatomic, strong) NSMutableArray<NSString *> *frameOrder;
@end

@implementation PCJSBridge

+ (instancetype)shared {
    static PCJSBridge *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[PCJSBridge alloc] init];
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _bodies = [NSMutableDictionary dictionary];
        _bodyOrder = [NSMutableArray array];
        _frames = [NSMutableDictionary dictionary];
        _frameOrder = [NSMutableArray array];
    }
    return self;
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSDictionary *body = (NSDictionary *)message.body;

    if ([message.name isEqualToString:@"pcbody"]) {
        [self storeBody:body];
        return;
    }
    if ([message.name isEqualToString:@"pcdiag"]) {
        [self storeDiagnostics:body];
        return;
    }
}

- (void)storeBody:(NSDictionary *)body {
    NSString *identifier = body[@"id"];
    NSString *text = body[@"body"];
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) {
        return;
    }
    if (![text isKindOfClass:[NSString class]]) {
        return;
    }

    @synchronized (self) {
        if (self.bodies[identifier] == nil) {
            [self.bodyOrder addObject:identifier];
        }
        self.bodies[identifier] = text;
        while (self.bodyOrder.count > PCJSMaxBodies) {
            NSString *old = self.bodyOrder.firstObject;
            [self.bodyOrder removeObjectAtIndex:0];
            [self.bodies removeObjectForKey:old];
        }
    }
    PCLog(@"[pcbody] тело %@ (%lu симв.)", identifier, (unsigned long)text.length);
}

- (void)storeDiagnostics:(NSDictionary *)body {
    NSString *href = body[@"href"];
    if (![href isKindOfClass:[NSString class]] || href.length == 0) {
        href = @"(без адреса)";
    }
    NSDictionary *stats = body[@"stats"];
    if (![stats isKindOfClass:[NSDictionary class]]) {
        return;
    }

    @synchronized (self) {
        if (self.frames[href] == nil) {
            [self.frameOrder addObject:href];
        }
        self.frames[href] = stats;
        while (self.frameOrder.count > PCJSMaxFrames) {
            NSString *old = self.frameOrder.firstObject;
            [self.frameOrder removeObjectAtIndex:0];
            [self.frames removeObjectForKey:old];
        }
    }

    PCLog(@"[pcdiag] %@ fn=%@ ok=%@ err=%@ babel=%@",
          href, stats[@"fn"], stats[@"fnOk"], stats[@"fnErr"], stats[@"babel"]);
}

#pragma mark - Тела POST

- (nullable NSString *)takeBodyForId:(NSString *)identifier {
    if (identifier.length == 0) {
        return nil;
    }
    @synchronized (self) {
        NSString *text = self.bodies[identifier];
        if (text != nil) {
            [self.bodies removeObjectForKey:identifier];
            [self.bodyOrder removeObject:identifier];
        }
        return text;
    }
}

#pragma mark - Диагностика

- (void)reset {
    @synchronized (self) {
        [self.bodies removeAllObjects];
        [self.bodyOrder removeAllObjects];
        [self.frames removeAllObjects];
        [self.frameOrder removeAllObjects];
    }
}

- (NSString *)valueFor:(NSDictionary *)stats key:(NSString *)key {
    id value = stats[key];
    if (value == nil || value == [NSNull null]) {
        return @"0";
    }
    return [value description];
}

- (NSString *)diagnosticsReportWithExtra:(NSArray<NSString *> *)extra {
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"Perchance %@ · диагностика\n", version.length > 0 ? version : @"?"];

    for (NSString *line in extra) {
        if (line.length > 0) {
            [out appendFormat:@"%@\n", line];
        }
    }

    NSArray<NSString *> *order = nil;
    NSDictionary<NSString *, NSDictionary *> *frames = nil;
    @synchronized (self) {
        order = [self.frameOrder copy];
        frames = [self.frames copy];
    }

    [out appendFormat:@"\nКадров со статистикой: %lu\n", (unsigned long)order.count];
    NSUInteger index = 0;
    for (NSString *href in order) {
        NSDictionary *stats = frames[href];
        index++;
        [out appendFormat:@"\n%lu) %@\n", (unsigned long)index, href];
        [out appendFormat:@"   fn=%@ ok=%@ err=%@ async=%@ gen=%@ eval=%@\n",
                          [self valueFor:stats key:@"fn"],
                          [self valueFor:stats key:@"fnOk"],
                          [self valueFor:stats key:@"fnErr"],
                          [self valueFor:stats key:@"asyncFn"],
                          [self valueFor:stats key:@"genFn"],
                          [self valueFor:stats key:@"evalCalls"]];
        [out appendFormat:@"   script=%@ write=%@ html=%@ iframe=%@ babel=%@\n",
                          [self valueFor:stats key:@"script"],
                          [self valueFor:stats key:@"write"],
                          [self valueFor:stats key:@"html"],
                          [self valueFor:stats key:@"iframe"],
                          [self valueFor:stats key:@"babel"]];
        [out appendFormat:@"   fetchFallback=%@\n",
                          [self valueFor:stats key:@"fetchFallback"]];
        id lastError = stats[@"lastError"];
        if ([lastError isKindOfClass:[NSString class]] && [lastError length] > 0) {
            [out appendFormat:@"   lastError=%@\n", lastError];
        }
    }
    if (order.count == 0) {
        [out appendString:@"   (страница ещё не присылала статистику)\n"];
    }
    return out;
}

@end
