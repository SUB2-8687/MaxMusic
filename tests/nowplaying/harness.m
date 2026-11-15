#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@interface MPNowPlayingInfoCenter : NSObject
@property (nonatomic, strong) NSDictionary *nowPlayingInfo;
+ (instancetype)defaultCenter;
@end
@implementation MPNowPlayingInfoCenter
+ (instancetype)defaultCenter { static id center; if (!center) center = [self new]; return center; }
@end

#define YTMU_NP_TEST 1
#include "../../Source/NowPlaying/YTMUNowPlayingFix.m"

static NSUInteger calls;
static NSString *lastTarget;
static void *origin(void) { return (void *)0x1234; }
static void *noOrigin(void) { return NULL; }
static void bindTarget(void *value, CFStringRef target) {
    NSCAssert(value == (void *)0x1234, @"origin ABI");
    lastTarget = [(__bridge NSString *)target copy]; calls++;
}
static void throwOnBind(void *value, CFStringRef target) {
    [NSException raise:@"FixtureSPIException" format:@"simulated private API failure"];
}
static NSUInteger checks;
#define CHECK(condition, label) do { if (!(condition)) { NSLog(@"FAIL: %s", label); return 1; } checks++; } while (0)

int main(void) { @autoreleasepool {
    // Fake an altered runtime NSBundle value: target must come from disk fixture.
    NPInfo = @{@"CFBundleIdentifier": @"com.google.ios.youtubemusic", @"CFBundleShortVersionString": @"9.44.2"};
    [NSUserDefaults.standardUserDefaults removeObjectForKey:NPPreference];
    CHECK(NPEnabled(), "default enabled");
    NPInstall(); NPGetOrigin = origin; NPSetParent = bindTarget;
    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
    CHECK(center != nil && calls == 1, "preserves defaultCenter; binds after creation");
    CHECK([lastTarget isEqual:NPBundleID()], "uses installed ID, not a hardcoded other app");
    NSDictionary *info = @{@"title": @"fixture", @"rate": @1, @"elapsed": @12.5};
    center.nowPlayingInfo = info;
    CHECK(center.nowPlayingInfo == info, "preserves exact metadata object");
    CHECK(NPPublishCount == 1 && calls == 2, "publishes and requests association");
    center.nowPlayingInfo = nil;
    CHECK(center.nowPlayingInfo == nil && calls == 2, "stop/clear does not rebind");
    NPSetEnabled(NO);
    CHECK(!NPEnabled() && lastTarget == nil, "disable clears association set by this patch");
    NSUInteger stoppedCalls = calls;
    center.nowPlayingInfo = info;
    CHECK(center.nowPlayingInfo == info && calls == stoppedCalls, "disabled mode preserves playback without binding");
    NPSetEnabled(YES);
    CHECK(NPEnabled() && calls == stoppedCalls + 1, "enable reapplies");
    NPSetParent = NULL;
    center.nowPlayingInfo = info;
    CHECK(center.nowPlayingInfo == info && calls == stoppedCalls + 1, "missing SPI does not break publishing");
    CHECK([NPReport() containsString:@"사용 불가"], "reports unavailable SPI honestly");
    NPSetParent = bindTarget; NPGetOrigin = noOrigin;
    NPBind();
    CHECK(calls == stoppedCalls + 1, "missing origin skips binding");
    NPGetOrigin = origin;
    NSUInteger before = NPPublishCount;
    NPInstall(); center.nowPlayingInfo = info;
    CHECK(NPPublishCount == before + 1, "install is idempotent, no recursive wrappers");
    CHECK([NPSigningAssessment(NPBundleID(), @"TEAM.com.google.ios.youtubemusic") containsString:@"일치함"], "matching signed AppID");
    CHECK([NPSigningAssessment(NPBundleID(), @"TEAM.other.app") containsString:@"불일치"], "mismatched signed AppID");
    CHECK([NPSigningAssessment(NPBundleID(), nil) containsString:@"미확인"], "unreadable entitlement is not called a match");
    CHECK([NPReport() containsString:@"승인이나 탭 동작 성공을 뜻하지"], "request count never claims device success");
    NPSetParent = throwOnBind;
    center.nowPlayingInfo = info;
    CHECK(center.nowPlayingInfo == info && NPSPIFailed, "SPI exception is isolated from metadata publishing");
    NPSetParent = bindTarget;
    NSUInteger failedCalls = calls;
    center.nowPlayingInfo = info;
    CHECK(calls == failedCalls && [NPReport() containsString:@"중단됨"], "SPI failure stops further requests for this run");
    [NSUserDefaults.standardUserDefaults removeObjectForKey:NPPreference];
    printf("PASS: %lu launch-association checks (mock MediaRemote; not an iPhone test)\n", (unsigned long)checks);
    return 0;
} }
