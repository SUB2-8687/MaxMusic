// macOS harness for the app-local WireGuard core (Source/WireGuard).
//
// Built by tests/wireguard/run_macos.py together with YTMUWGCore.m,
// YTMUWGTransport.m (compiled with -DYTMUWG_TESTING) and the Go engine built for
// macOS. It runs Apple's real NSURLSession + Network.framework proxy stack:
//
//   NSURLSession -> nw_proxy_config SOCKS5 (auth, no failover) -> Go engine
//   -> gVisor netstack -> WireGuard UDP -> test peer (DNS/HTTP/HTTPS/206)
//
// The Google classes below are mocks that model the selectors and type
// encodings observed in YouTube Music 9.42.2; they test the patch logic only.

#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import "../../Source/WireGuard/YTMUWGCore.h"

#define CHECK(cond, ...)                                                    \
    do {                                                                    \
        if (!(cond)) {                                                      \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);            \
            fprintf(stderr, __VA_ARGS__);                                   \
            fprintf(stderr, "\n");                                          \
            exit(1);                                                        \
        }                                                                   \
    } while (0)

static NSString *Env(NSString *name) { return NSProcessInfo.processInfo.environment[name]; }

#pragma mark - Google mocks

@interface MockEnumDescriptor : NSObject
@end
@implementation MockEnumDescriptor
- (uint32_t)enumNameCount { return 2; }
- (NSString *)getEnumNameForIndex:(uint32_t)index { return index == 0 ? @"NETWORK_STACK_TYPE_URL_SESSION" : @"NETWORK_STACK_TYPE_ENVOY"; }
- (BOOL)getValue:(int32_t *)value forEnumName:(NSString *)name {
    if ([name isEqualToString:@"NETWORK_STACK_TYPE_URL_SESSION"]) *value = 0;
    else if ([name isEqualToString:@"NETWORK_STACK_TYPE_ENVOY"]) *value = 3;
    else return NO;
    return YES;
}
@end
@interface MockFieldDescriptor : NSObject
@end
@implementation MockFieldDescriptor
- (id)enumDescriptor { return [MockEnumDescriptor new]; }
@end
@interface MockDescriptor : NSObject
@end
@implementation MockDescriptor
- (id)fieldWithName:(NSString *)name { return [name isEqualToString:@"networkStackType"] ? [MockFieldDescriptor new] : nil; }
@end

@interface YTIHamplayerUrlSessionDataLoaderConfig : NSObject
@property(readonly) BOOL useCronet, useCronetNative, assumeHTTP3Capable;
@property(readonly) int32_t networkStackType;
@end
@implementation YTIHamplayerUrlSessionDataLoaderConfig
+ (id)descriptor { return [Env(@"YTMUWG_TEST_ENUM_NAMES") boolValue] ? [MockDescriptor new] : nil; }
- (BOOL)useCronet { return YES; }
- (BOOL)useCronetNative { return YES; }
- (BOOL)assumeHTTP3Capable { return YES; }
- (int32_t)networkStackType { return 3; }
@end

// Declared BOOL property without a getter (protobuf lazily resolved style).
@interface YTIMediaCommonConfig : NSObject
@property(readonly) BOOL platypusUseEnvoyNetFetch;
@end
@implementation YTIMediaCommonConfig
@dynamic platypusUseEnvoyNetFetch;
@end

@interface YTIOnesieConfig : NSObject
@property(readonly) int enableQuic; // wrong type on purpose: must not be patched
@end
@implementation YTIOnesieConfig
- (int)enableQuic { return 7; }
@end

@interface HAMURLSessionDataLoader : NSObject
@property NSURLSession *session;
- (NSURLSessionDataTask *)taskWithRequest:(NSURLRequest *)request userInfo:(id)userInfo;
@end
@implementation HAMURLSessionDataLoader
- (NSURLSessionDataTask *)taskWithRequest:(NSURLRequest *)request userInfo:(id)userInfo {
    return [self.session dataTaskWithRequest:request completionHandler:userInfo[@"completion"]];
}
@end
@interface HAMEnvoyDataLoader : NSObject
- (id)taskWithRequest:(NSURLRequest *)request userInfo:(id)userInfo;
@end
@implementation HAMEnvoyDataLoader
- (id)taskWithRequest:(NSURLRequest *)request userInfo:(id)userInfo { return nil; }
@end
@interface HAMURLSessionDataLoadTask : NSObject
@property NSHTTPURLResponse *response;
@property NSError *error;
- (void)didReceiveResponse:(NSHTTPURLResponse *)response absoluteTime:(double)time;
- (void)didCompleteWithError:(NSError *)error absoluteTime:(double)time;
@end
@implementation HAMURLSessionDataLoadTask
- (void)didReceiveResponse:(NSHTTPURLResponse *)response absoluteTime:(double)time { self.response = response; }
- (void)didCompleteWithError:(NSError *)error absoluteTime:(double)time { self.error = error; }
@end

#pragma mark - Trust delegate (test only: pins the generated fixture certificate)

@interface FixtureTrust : NSObject <NSURLSessionDelegate>
@end
@implementation FixtureTrust
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion {
    NSString *host = challenge.protectionSpace.host;
    NSData *der = Env(@"YTMUWG_TEST_CERT") ? [NSData dataWithContentsOfFile:Env(@"YTMUWG_TEST_CERT")] : nil;
    NSString *suffix = Env(@"YTMUWG_TEST_TRUST_SUFFIX") ?: @"fixture.test";
    if (der && [host hasSuffix:suffix] &&
        [challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        SecTrustRef trust = challenge.protectionSpace.serverTrust;
        SecCertificateRef cert = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)der);
        SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)@[(__bridge id)cert]);
        SecTrustSetAnchorCertificatesOnly(trust, true);
        CFRelease(cert);
        if (SecTrustEvaluateWithError(trust, NULL)) {
            completion(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
            return;
        }
    }
    completion(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
@end

#pragma mark - Helpers

typedef struct {
    NSInteger status;
    NSString *body;
    NSError *error;
    NSDictionary *headers;
} Result;

static Result Run(NSURLSessionDataTask * (^make)(void (^)(NSData *, NSURLResponse *, NSError *))) {
    __block Result r = {0};
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = make(^(NSData *data, NSURLResponse *response, NSError *error) {
        r.status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        r.headers = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response allHeaderFields] : nil;
        r.body = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        r.error = error;
        dispatch_semaphore_signal(done);
    });
    [task resume];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC))) {
        [task cancel];
        r.error = [NSError errorWithDomain:@"harness" code:-1 userInfo:nil];
    }
    return r;
}

static Result Get(NSURLSession *session, NSString *url, NSString *range) {
    return Run(^NSURLSessionDataTask *(void (^done)(NSData *, NSURLResponse *, NSError *)) {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
        request.timeoutInterval = 12;
        if (range) [request setValue:range forHTTPHeaderField:@"Range"];
        return [session dataTaskWithRequest:request completionHandler:done];
    });
}

static NSString *ReportText(void) { return YTMUWGDiagnosticsReport(@{@"harness": @"run"}); }

static void WaitForEngine(void) {
    for (int i = 0; i < 200 && YTMUWGCurrentState() != YTMUWGStateRunning; i++) usleep(50000);
    CHECK(YTMUWGCurrentState() == YTMUWGStateRunning, "engine state %s", YTMUWGStateDescription(YTMUWGCurrentState()).UTF8String);
}

#pragma mark - Modes

static void UnitChecks(void) {
    BOOL expectActive = [Env(@"YTMUWG_EXPECT_ACTIVE") boolValue];
    CHECK(YTMUWGActiveThisLaunch() == expectActive, "active=%d expected %d", YTMUWGActiveThisLaunch(), expectActive);
    YTIHamplayerUrlSessionDataLoaderConfig *google = [YTIHamplayerUrlSessionDataLoaderConfig new];
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    NSArray *proxies = [config valueForKey:@"proxyConfigurations"];
    if (!expectActive) {
        CHECK(proxies.count == 0, "proxy applied while disabled");
        CHECK(google.useCronet && google.assumeHTTP3Capable && google.networkStackType == 3, "patched while disabled");
        puts("PASS disabled: no proxy, no Google patches");
        return;
    }
    CHECK(proxies.count == 1, "ephemeral configuration has %lu proxies", (unsigned long)proxies.count);
    bool (*getFailover)(void *) = (bool (*)(void *))dlsym(RTLD_DEFAULT, "nw_proxy_config_get_failover_allowed");
    CHECK(getFailover && !getFailover((__bridge void *)proxies.firstObject), "direct failover must be disabled");
    NSURLSessionConfiguration *background = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:@"ytmuwg.harness"];
    // Background sessions run out of process; record (do not assert) whether
    // the platform keeps the proxy on such a configuration.
    printf("INFO background configuration proxies: %lu\n", (unsigned long)[[background valueForKey:@"proxyConfigurations"] count]);
    // A session made from a configuration the app later stripped is re-proxied.
    NSURLSessionConfiguration *stripped = NSURLSessionConfiguration.defaultSessionConfiguration;
    [stripped setValue:@[] forKey:@"proxyConfigurations"];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:stripped];
    CHECK([[session.configuration valueForKey:@"proxyConfigurations"] count] == 1, "session constructor did not re-apply proxy");
    [session invalidateAndCancel];

    CHECK(!google.useCronet && !google.useCronetNative && !google.assumeHTTP3Capable, "BOOL transport flags not forced off");
    CHECK(![YTIMediaCommonConfig new].platypusUseEnvoyNetFetch, "declared-property flag not added");
    CHECK([YTIOnesieConfig new].enableQuic == 7, "wrong-typed selector must not be patched");
    int expectStack = Env(@"YTMUWG_EXPECT_STACK").intValue;
    CHECK(google.networkStackType == expectStack, "networkStackType=%d expected %d", google.networkStackType, expectStack);

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://fixture.test/"]];
    if ([request respondsToSelector:NSSelectorFromString(@"setAssumesHTTP3Capable:")]) {
        [request setValue:@YES forKey:@"assumesHTTP3Capable"];
        CHECK(![[request valueForKey:@"assumesHTTP3Capable"] boolValue], "assumesHTTP3Capable not cleared");
    }

    // Loader diagnostics must preserve events and keep only status/domain/code.
    HAMURLSessionDataLoadTask *events = [HAMURLSessionDataLoadTask new];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://rr1---sn-x.googlevideo.com/videoplayback?sig=SECRETSIG&expire=1"]
                                                              statusCode:403 HTTPVersion:@"HTTP/1.1" headerFields:nil];
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:-1005 userInfo:@{
        NSLocalizedDescriptionKey: @"private-error-text https://rr1---sn-x.googlevideo.com/videoplayback?sig=SECRETSIG",
        NSURLErrorFailingURLStringErrorKey: @"https://rr1---sn-x.googlevideo.com/videoplayback?sig=SECRETSIG"}];
    [events didReceiveResponse:response absoluteTime:1];
    [events didCompleteWithError:error absoluteTime:2];
    CHECK(events.response == response && events.error == error, "loader events not forwarded");
    [[HAMEnvoyDataLoader new] taskWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://rr2---sn-y.googlevideo.com/videoplayback"]] userInfo:nil];

    NSString *profile = [NSString stringWithContentsOfFile:Env(@"YTMUWG_TEST_PROFILE") encoding:NSUTF8StringEncoding error:NULL];
    NSString *privateKey = nil;
    for (NSString *line in [profile componentsSeparatedByString:@"\n"])
        if ([line hasPrefix:@"PrivateKey = "]) privateKey = [line substringFromIndex:13];
    NSString *report = ReportText();
    for (NSString *expected in @[@"music.http-status: 403 x1", @"NSURLErrorDomain -1005 x1", @"Envoy tasks 1 (media-cdn 1)",
                                 @"HAMEnvoyDataLoader x1", @"transport.flag YTIOnesieConfig.enableQuic: not patched: return type i",
                                 @"original values 3 x"])
        CHECK([report containsString:expected], "report missing '%s':\n%s", expected.UTF8String, report.UTF8String);
    for (NSString *secret in @[privateKey ?: @"<none>", @"SECRETSIG", @"private-error-text", @"googlevideo", @"videoplayback"])
        CHECK(![report containsString:secret], "report leaks '%s':\n%s", secret.UTF8String, report.UTF8String);
    printf("PASS unit: proxy without failover, flags, networkStackType=%d, HTTP/3 cleared, redacted diagnostics\n", expectStack);
}

static void NetworkChecks(void) {
    WaitForEngine();
    FixtureTrust *trust = [FixtureTrust new];
    NSURLSession *delegateSession = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration
                                                                  delegate:trust delegateQueue:nil];
    Result r = Get(delegateSession, @"https://fixture.test/", nil);
    CHECK(r.status == 200 && [r.body isEqualToString:@"through-tunnel"], "HTTPS via tunnel: %ld %s %s", (long)r.status, r.body.UTF8String, r.error.description.UTF8String);
    puts("PASS NSURLSession HTTPS through SOCKS5 -> WireGuard (name resolved by tunnel DNS)");

    HAMURLSessionDataLoader *loader = [HAMURLSessionDataLoader new];
    loader.session = delegateSession;
    __block HAMURLSessionDataLoadTask *events = [HAMURLSessionDataLoadTask new];
    r = Run(^NSURLSessionDataTask *(void (^done)(NSData *, NSURLResponse *, NSError *)) {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://media.fixture.test/media"]];
        [request setValue:@"bytes=5-14" forHTTPHeaderField:@"Range"];
        return [loader taskWithRequest:request userInfo:@{@"completion": ^(NSData *d, NSURLResponse *resp, NSError *e) {
            [events didReceiveResponse:(NSHTTPURLResponse *)resp absoluteTime:3];
            [events didCompleteWithError:e absoluteTime:4];
            done(d, resp, e);
        }}];
    });
    CHECK(r.status == 206 && r.body.length == 10 && [r.headers[@"Content-Range"] hasPrefix:@"bytes 5-14/"], "media range: %ld %s %s", (long)r.status, r.body.UTF8String, r.error.description.UTF8String);
    puts("PASS music loader mock: HTTPS byte range (206) through tunnel");

    NSURLSession *shared = NSURLSession.sharedSession;
    CHECK([[shared.configuration valueForKey:@"proxyConfigurations"] count] == 1, "sharedSession not proxied");
    r = Get(shared, @"http://fixture.test/", nil);
    CHECK(r.status == 200 && [r.body isEqualToString:@"through-tunnel"], "sharedSession: %ld %s", (long)r.status, r.error.description.UTF8String);
    r = Get([NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration], @"http://fixture.test/", nil);
    CHECK(r.status == 200, "sessionWithConfiguration: %ld %s", (long)r.status, r.error.description.UTF8String);
    puts("PASS sharedSession and sessionWithConfiguration: through tunnel");

    NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:@"http://fixture.test/"]];
    CHECK([[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] isEqualToString:@"through-tunnel"], "NSData URL load not tunnelled");
    puts("PASS +[NSData dataWithContentsOfURL:] through tunnel");

    r = Get(delegateSession, @"https://fixture.test/cdn-cgi/trace", nil);
    CHECK(r.status == 200 && [r.body containsString:@"ip=10.66.0.2"], "trace: %s", r.body.UTF8String);
    puts("PASS origin sees the WireGuard tunnel address as the client");

    NSString *direct = Env(@"YTMUWG_TEST_DIRECT_URL");
    if (direct.length) {
        r = Get(delegateSession, direct, nil);
        CHECK(r.error != nil, "request outside the tunnel succeeded: %ld", (long)r.status);
        puts("PASS host reachable only directly: request fails (no direct fallback)");
    }

    __block NSDictionary *lookup;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    YTMUWGLookupInTunnel(@"media.fixture.test", ^(NSDictionary *result) {
        lookup = result;
        dispatch_semaphore_signal(done);
    });
    while (dispatch_semaphore_wait(done, DISPATCH_TIME_NOW)) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    CHECK([lookup[@"ok"] boolValue] && [lookup[@"count"] intValue] == 1, "tunnel lookup %s", lookup.description.UTF8String);

    NSDictionary *status = YTMUWGEngineStatus();
    CHECK([status[@"handshakeAgeSec"] longLongValue] >= 0, "no handshake: %s", status.description.UTF8String);
    CHECK([status[@"connections"][@"socks"] intValue] >= 5 && [status[@"connections"][@"domainTargets"] intValue] >= 5,
          "SOCKS hostname connections not counted: %s", status.description.UTF8String);
    NSString *report = ReportText();
    CHECK([report containsString:@"music.http-status: 206 x1"] && [report containsString:@"URLSession tasks 1"], "report: %s", report.UTF8String);
    CHECK(![report containsString:@"fixture.test"] && ![report containsString:@"127.0.0.1"], "report leaks host or address:\n%s", report.UTF8String);
    YTMUWGRequestRebind(@"harness");
    usleep(300000);
    r = Get(delegateSession, @"https://fixture.test/", nil);
    CHECK(r.status == 200, "after rebind: %ld %s", (long)r.status, r.error.description.UTF8String);
    puts("PASS diagnostics counters, tunnel DNS lookup, rebind");
    printf("%s\n", report.UTF8String);
}

static void FailClosedChecks(void) {
    for (int i = 0; i < 100 && YTMUWGCurrentState() == YTMUWGStateStarting; i++) usleep(50000);
    if ([Env(@"YTMUWG_EXPECT_FAILED") boolValue])
        CHECK(YTMUWGCurrentState() == YTMUWGStateFailed, "invalid profile: state %s", YTMUWGStateDescription(YTMUWGCurrentState()).UTF8String);
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration
                                                          delegate:[FixtureTrust new] delegateQueue:nil];
    Result r = Get(session, @"http://fixture.test/", nil);
    CHECK(r.error != nil, "request succeeded although the WireGuard peer is unreachable");
    NSString *direct = Env(@"YTMUWG_TEST_DIRECT_URL");
    if (direct.length) {
        r = Get(session, direct, nil);
        CHECK(r.error != nil, "direct fallback happened with a dead tunnel");
    }
    puts("PASS dead WireGuard peer: requests fail, nothing sent directly");
}

static NSDictionary *LookupSync(NSString *host) {
    __block NSDictionary *result;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    YTMUWGLookupInTunnel(host, ^(NSDictionary *r) {
        result = r;
        dispatch_semaphore_signal(done);
    });
    while (dispatch_semaphore_wait(done, DISPATCH_TIME_NOW)) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    return result;
}

// Live mode: a real WireGuard server from the user's profile (CI secret).
// Same checks as the in-app "connection diagnostics", through the hooked
// NSURLSession path the app uses. Prints no key material, full IP or URL
// query; the exit IP is masked.
static void LiveChecks(void) {
    WaitForEngine();
    NSMutableDictionary *checks = [NSMutableDictionary dictionary];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    CHECK([[session.configuration valueForKey:@"proxyConfigurations"] count] == 1, "session not proxied");

    for (NSString *host in @[@"music.youtube.com", @"youtubei.googleapis.com", @"redirector.googlevideo.com"]) {
        NSDictionary *r = LookupSync(host);
        printf("LIVE tunnel DNS %s: %s (%s addr, %s ms)\n", host.UTF8String, [r[@"ok"] boolValue] ? "ok" : "FAILED",
               [[r[@"count"] description] UTF8String], [[r[@"ms"] description] UTF8String]);
        CHECK([r[@"ok"] boolValue], "tunnel DNS failed for %s: %s", host.UTF8String, [[r[@"error"] description] UTF8String]);
        checks[[@"dns." stringByAppendingString:host]] = @"ok";
    }

    Result r = Get(session, @"https://www.cloudflare.com/cdn-cgi/trace", nil);
    NSString *ip = nil, *loc = nil;
    for (NSString *line in [r.body componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"ip="]) ip = [line substringFromIndex:3];
        if ([line hasPrefix:@"loc="]) loc = [line substringFromIndex:4];
    }
    CHECK(r.status == 200 && loc.length, "country check failed: HTTP %ld %s", (long)r.status, r.error.description.UTF8String);
    printf("LIVE exit country: %s, exit IP: %s\n", loc.UTF8String, YTMUWGRedactText(ip ?: @"?").UTF8String);
    NSString *expected = Env(@"YTMUWG_EXPECT_COUNTRY");
    if (expected.length) CHECK([loc isEqualToString:expected], "exit country %s, expected %s", loc.UTF8String, expected.UTF8String);
    checks[@"country"] = [NSString stringWithFormat:@"%@ exit %@", loc, ip];

    r = Get(session, @"https://www.google.com/generate_204", nil);
    printf("LIVE HTTPS www.google.com/generate_204: HTTP %ld %s\n", (long)r.status, r.error ? r.error.domain.UTF8String : "");
    CHECK(r.status == 204, "generate_204 failed");

    BOOL ranged = NO;
    for (NSString *url in @[@"https://www.gstatic.com/images/branding/googlelogo/2x/googlelogo_color_272x92dp.png",
                            @"https://raw.githubusercontent.com/dayanch96/YTMusicUltimate/main/LICENSE"]) {
        r = Get(session, url, @"bytes=0-1023");
        NSString *range = r.headers[@"Content-Range"];
        printf("LIVE Range %s: HTTP %ld, Content-Range %s\n", [NSURL URLWithString:url].host.UTF8String, (long)r.status,
               [range hasPrefix:@"bytes 0-1023/"] ? "ok" : "missing");
        if (r.status == 206 && [range hasPrefix:@"bytes 0-1023/"]) {
            ranged = YES;
            break;
        }
    }
    CHECK(ranged, "no HTTP 206 partial response through the tunnel");
    checks[@"range206"] = @"ok";

    // Informational: the YouTube Music web origin through the exit.
    r = Get(session, @"https://music.youtube.com/", nil);
    printf("LIVE music.youtube.com: HTTP %ld %s\n", (long)r.status, r.error ? [NSString stringWithFormat:@"%@ %ld", r.error.domain, (long)r.error.code].UTF8String : "");

    NSDictionary *status = YTMUWGEngineStatus();
    CHECK([status[@"handshakeAgeSec"] longLongValue] >= 0, "no WireGuard handshake");
    printf("PASS live: handshake, tunnel DNS, country, HTTPS, HTTP 206 through the real WireGuard server\n");
    printf("%s\n", YTMUWGDiagnosticsReport(checks).UTF8String);
}

// External HTTP / HTTPS / SOCKS5 proxy modes against local fixture proxies.
static void ExternalChecks(void) {
    NSString *kind = Env(@"YTMUWG_TEST_KIND");
    BOOL expectOK = [Env(@"YTMUWG_EXPECT_OK") boolValue];
    CHECK([YTMUWGActiveKind() isEqualToString:kind], "active kind %s", YTMUWGActiveKind().UTF8String);
    CHECK(YTMUWGCurrentState() == YTMUWGStateExternalProxy, "state %s", YTMUWGStateDescription(YTMUWGCurrentState()).UTF8String);
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    NSArray *proxies = [config valueForKey:@"proxyConfigurations"];
    bool (*getFailover)(void *) = (bool (*)(void *))dlsym(RTLD_DEFAULT, "nw_proxy_config_get_failover_allowed");
    CHECK(proxies.count == 1 && !getFailover((__bridge void *)proxies.firstObject), "proxy missing or failover allowed");

    const char *ffmpeg = getenv("http_proxy");
    if ([kind isEqualToString:@"http"]) CHECK(ffmpeg && strstr(ffmpeg, Env(@"YTMUWG_TEST_PORT").UTF8String), "FFmpeg not pointed at HTTP proxy");
    else CHECK(ffmpeg && !strcmp(ffmpeg, "http://127.0.0.1:1"), "FFmpeg must be blocked for %s", kind.UTF8String);

    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:[FixtureTrust new] delegateQueue:nil];
    Result r = Get(session, Env(@"YTMUWG_TEST_ORIGIN_URL"), @"bytes=0-9");
    if (expectOK) {
        CHECK(r.status == 206 && r.body.length == 10, "%s proxy: HTTP %ld %s", kind.UTF8String, (long)r.status, r.error.description.UTF8String);
        CHECK([[NSURLSession.sharedSession.configuration valueForKey:@"proxyConfigurations"] count] == 1, "sharedSession not proxied");
    } else {
        CHECK(r.error != nil, "%s proxy request succeeded although it must fail (HTTP %ld)", kind.UTF8String, (long)r.status);
    }
    NSString *report = ReportText();
    NSString *pass = Env(@"YTMUWG_TEST_PASS");
    NSString *modeLine = [NSString stringWithFormat:@"mode: %@ (external proxy", kind];
    CHECK([report containsString:modeLine], "report mode line:\n%s", report.UTF8String);
    CHECK(!pass.length || ![report containsString:pass], "report leaks proxy password");
    printf("PASS external %s: %s\n", kind.UTF8String, expectOK ? "HTTPS byte range (206) through proxy, failover disabled" : "request failed, nothing sent directly");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *mode = argc > 1 ? @(argv[1]) : @"unit";
        if ([mode isEqualToString:@"unit"]) UnitChecks();
        else if ([mode isEqualToString:@"net"]) NetworkChecks();
        else if ([mode isEqualToString:@"failclosed"]) FailClosedChecks();
        else if ([mode isEqualToString:@"live"]) LiveChecks();
        else if ([mode isEqualToString:@"external"]) ExternalChecks();
        else CHECK(NO, "unknown mode %s", mode.UTF8String);
    }
    return 0;
}
