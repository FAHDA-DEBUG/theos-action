#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

#pragma mark - ==== XOR OBFUSCATION ====

static inline NSString *ZT_XOR(const uint8_t *b, size_t n, uint8_t k) {
    NSMutableData *d = [NSMutableData dataWithLength:n];
    uint8_t *o = (uint8_t *)d.mutableBytes;
    for (size_t i=0;i<n;i++) o[i] = b[i]^k;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}
#define ZT_S(name,key,...) \
static const uint8_t name##_b[] = { __VA_ARGS__ }; \
static inline NSString* name(){ return ZT_XOR(name##_b,sizeof(name##_b),key); }

// Example obfuscated keys
ZT_S(kJSChannel, 0xAA, 0xDE^0xAA,0xDF^0xAA,0xC5^0xAA,0xC7^0xAA) // "ztom" (placeholder)

#pragma mark - ==== CONFIG ====

static NSArray<NSString*> *ZT_AllowedImagePrefixes(void) {
    return @[
        @"/System/Library/",
        @"/usr/lib/",
        [[NSBundle mainBundle] bundlePath],
    ];
}

// Base64(SHA256(SPKI)) pins
static NSSet<NSString*> *ZT_SPKIPins(void) {
    return [NSSet setWithArray:@[
        @"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", // replace
        @"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=", // backup
    ]];
}

#pragma mark - ==== UTIL ====

static NSString *ZT_Base64SHA256(NSData *data) {
    uint8_t hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSData *h = [NSData dataWithBytes:hash length:sizeof(hash)];
    return [h base64EncodedStringWithOptions:0];
}

static NSData *ZT_SPKIFromTrust(SecTrustRef trust) {
    SecKeyRef key = SecTrustCopyKey(trust);
    if (!key) return nil;
    CFDataRef rep = SecKeyCopyExternalRepresentation(key, NULL);
    CFRelease(key);
    return CFBridgingRelease(rep);
}

#pragma mark - ==== LAYER 1: IDENTITY (QA-SAFE VIRTUAL) ====

@interface ZTIdentity : NSObject
+ (NSUUID *)virtualID;      // app-scoped persistent UUID
+ (NSString *)deviceClass;  // coarse model string
@end

@implementation ZTIdentity
+ (NSUUID *)virtualID {
    NSString *k = @"zt.virtual.id";
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSString *s = [ud stringForKey:k];
    if (!s.length) {
        s = NSUUID.UUID.UUIDString;
        [ud setObject:s forKey:k];
    }
    return [[NSUUID alloc] initWithUUIDString:s];
}
+ (NSString *)deviceClass {
#if TARGET_OS_SIMULATOR
    return @"iPhone-Sim";
#else
    return @"iPhone";
#endif
}
@end

#pragma mark - ==== LAYER 2: INTEGRITY SIGNALS (IMAGES + ENV) ====

@interface ZTIntegrity : NSObject
+ (NSArray<NSString*>*)unexpectedImages;
+ (NSDictionary<NSString*,NSString*>*)suspiciousEnv;
@end

@implementation ZTIntegrity

+ (BOOL)allowed:(NSString*)p {
    for (NSString *a in ZT_AllowedImagePrefixes()) {
        if ([p hasPrefix:a]) return YES;
    }
    return NO;
}

+ (NSArray<NSString*>*)unexpectedImages {
    NSMutableArray *bad = [NSMutableArray array];
    uint32_t c = _dyld_image_count();
    for (uint32_t i=0;i<c;i++) {
        const char *n = _dyld_get_image_name(i);
        if (!n) continue;
        NSString *p = [NSString stringWithUTF8String:n];
        if (![self allowed:p]) [bad addObject:p];
    }
    return bad;
}

+ (NSDictionary<NSString*,NSString*>*)suspiciousEnv {
    NSArray *keys = @[@"DYLD_INSERT_LIBRARIES",@"DYLD_LIBRARY_PATH",@"DYLD_FRAMEWORK_PATH"];
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    NSMutableDictionary *hits = [NSMutableDictionary dictionary];
    for (NSString *k in keys) {
        NSString *v = env[k];
        if (v.length) hits[k] = v;
    }
    return hits;
}

@end

#pragma mark - ==== METHOD INTEGRITY (ANTI-SWIZZLING DETECTION) ====

@interface ZTMethodGuard : NSObject
@property (nonatomic,strong) NSMutableDictionary<NSString*,NSValue*> *baseline;
- (void)capture:(Class)cls selectors:(NSArray<NSString*>*)sels;
- (NSArray<NSString*>*)check;
@end

@implementation ZTMethodGuard

- (instancetype)init { if((self=[super init])) _baseline=[NSMutableDictionary dictionary]; return self; }

static NSString *ZTKey(Class c, SEL s) {
    return [NSString stringWithFormat:@"%s::%s", class_getName(c), sel_getName(s)];
}

- (void)capture:(Class)cls selectors:(NSArray<NSString*>*)sels {
    for (NSString *s in sels) {
        SEL sel = NSSelectorFromString(s);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) continue;
        IMP imp = method_getImplementation(m);
        self.baseline[ZTKey(cls,sel)] = [NSValue valueWithPointer:imp];
    }
}

- (NSArray<NSString*>*)check {
    NSMutableArray *chg = [NSMutableArray array];
    [self.baseline enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSValue *v, BOOL *stop) {
        NSArray *p = [k componentsSeparatedByString:@"::"];
        if (p.count!=2) return;
        Class c = NSClassFromString(p[0]);
        SEL s = NSSelectorFromString(p[1]);
        Method m = class_getInstanceMethod(c, s);
        if (!m) return;
        if (method_getImplementation(m) != v.pointerValue) [chg addObject:k];
    }];
    return chg;
}

@end

#pragma mark - ==== LAYER 3: NETWORK INTEGRITY (PINNING) ====

@interface ZTPinningDelegate : NSObject <NSURLSessionDelegate>
@end

@implementation ZTPinningDelegate

- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler {

    if (![challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        return;
    }

    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    if (!trust) {
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        return;
    }

    SecTrustResultType res;
    if (SecTrustEvaluate(trust, &res) != errSecSuccess) {
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        return;
    }

    NSData *spki = ZT_SPKIFromTrust(trust);
    if (!spki) {
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        return;
    }

    NSString *pin = ZT_Base64SHA256(spki);
    if ([ZT_SPKIPins() containsObject:pin]) {
        completionHandler(NSURLSessionAuthChallengeUseCredential,
                          [NSURLCredential credentialForTrust:trust]);
    } else {
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
    }
}

@end

#pragma mark - ==== MASTER LOCK: RSA GATEKEEPER (WKWebView BRIDGE) ====

@interface ZTGatekeeper : NSObject <WKScriptMessageHandler>
@property (atomic,assign) BOOL unlocked;
@property (nonatomic,strong) dispatch_semaphore_t sema;
@property (nonatomic,strong) SecKeyRef publicKey; // app-embedded public key
@end

@implementation ZTGatekeeper

- (instancetype)initWithPublicKey:(SecKeyRef)pub {
    if ((self=[super init])) {
        _publicKey = (SecKeyRef)CFRetain(pub);
        _sema = dispatch_semaphore_create(0);
    }
    return self;
}

- (void)dealloc { if (_publicKey) CFRelease(_publicKey); }

- (void)installOnWebView:(WKWebView*)wv {
    [wv.configuration.userContentController addScriptMessageHandler:self name:@"zt_auth"];
}

/// Verify RSA-SHA256 signature over "nonce|ts"
- (BOOL)verify:(NSString*)nonce ts:(NSNumber*)ts sigB64:(NSString*)sigB64 {
    NSString *msg = [NSString stringWithFormat:@"%@|%@", nonce, ts];
    NSData *data = [msg dataUsingEncoding:NSUTF8StringEncoding];
    NSData *sig = [[NSData alloc] initWithBase64EncodedString:sigB64 options:0];
    if (!sig) return NO;

    // Freshness window (e.g., 60s)
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (fabs(now - ts.doubleValue) > 60.0) return NO;

    CFErrorRef err = NULL;
    BOOL ok = SecKeyVerifySignature(self.publicKey,
                                    kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256,
                                    (__bridge CFDataRef)data,
                                    (__bridge CFDataRef)sig,
                                    &err);
    if (err) CFRelease(err);
    return ok;
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {

    if (![message.name isEqualToString:@"zt_auth"]) return;
    NSDictionary *p = (NSDictionary*)message.body;
    NSString *nonce = p[@"nonce"];
    NSNumber *ts = p[@"ts"];
    NSString *sig = p[@"sig"];
    if (nonce.length && ts && sig.length && [self verify:nonce ts:ts sigB64:sig]) {
        self.unlocked = YES;
        dispatch_semaphore_signal(self.sema);
    }
}

- (BOOL)awaitUnlock:(NSTimeInterval)timeout {
    long r = dispatch_semaphore_wait(self.sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout*NSEC_PER_SEC)));
    return (r==0) && self.unlocked;
}

@end

#pragma mark - ==== BOOTSTRAP (CALL EARLY) ====

@interface ZTGuard : NSObject
@property (nonatomic,strong) ZTMethodGuard *mg;
@property (nonatomic,strong) NSURLSession *session;
@property (nonatomic,strong) ZTGatekeeper *gk;
+ (instancetype)shared;
- (BOOL)startWithWebView:(WKWebView*)wv publicKey:(SecKeyRef)pub;
@end

@implementation ZTGuard

+ (instancetype)shared { static ZTGuard *g; static dispatch_once_t once; dispatch_once(&once, ^{ g=[ZTGuard new]; }); return g; }

- (BOOL)startWithWebView:(WKWebView*)wv publicKey:(SecKeyRef)pub {

    // Layer 2: integrity signals
    if ([ZTIntegrity unexpectedImages].count > 0) return NO;
    if ([ZTIntegrity suspiciousEnv].count > 0) return NO;

    // Method baseline
    self.mg = [ZTMethodGuard new];
    [self.mg capture:[UIApplication class] selectors:@[@"sendAction:to:from:forEvent:"]];

    // Network session with pinning
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    self.session = [NSURLSession sessionWithConfiguration:cfg
                                                 delegate:[ZTPinningDelegate new]
                                            delegateQueue:nil];

    // Gatekeeper
    self.gk = [[ZTGatekeeper alloc] initWithPublicKey:pub];
    [self.gk installOnWebView:wv];

    // Wait for unlock (short timeout)
    if (![self.gk awaitUnlock:5.0]) return NO;

    // Periodic method integrity check
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([self.mg check].count > 0) {
            // degrade or lock features
        }
    });

    return YES;
}

@end
