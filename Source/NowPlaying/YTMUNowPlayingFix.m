// Experimental launch association repair for sideloaded YouTube Music.
// No networking, URL scheme interception, entitlement rewriting, or launch loops.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#ifndef YTMU_NP_TEST
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#endif

static NSString *const NPPreference = @"YTMU.NowPlayingLaunchFix.enabled";
static NSDictionary *NPInfo;
static NSObject *NPLock;
static void *(*NPGetOrigin)(void);
static void (*NPSetParent)(void *, CFStringRef);
static NSUInteger NPPublishCount, NPBindCount;
static BOOL NPBound, NPInstalled;
static BOOL NPSPIFailed;

static BOOL NPEnabled(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:NPPreference];
    return value == nil || [value boolValue];
}

static NSString *NPBundleID(void) { return NPInfo[@"CFBundleIdentifier"]; }

static void NPBind(void) {
    if (!NPEnabled() || !NPBundleID().length || !NPGetOrigin || !NPSetParent || NPSPIFailed) return;
    // WebKit's MediaRemoteSoftLink.h declares this exact two-argument ABI.
    // The void return means "request sent", never "iOS accepted".
    @try {
        void *origin = NPGetOrigin();
        if (!origin) return;
        NPSetParent(origin, (__bridge CFStringRef)NPBundleID());
        @synchronized (NPLock) { NPBindCount++; NPBound = YES; }
    } @catch (NSException *exception) {
        @synchronized (NPLock) { NPSPIFailed = YES; }
    }
}

static void NPSetEnabled(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:NPPreference];
    if (enabled) { NPBind(); return; }
    @synchronized (NPLock) {
        if (NPBound && NPGetOrigin && NPSetParent && !NPSPIFailed) {
            @try {
                void *origin = NPGetOrigin();
                if (origin) NPSetParent(origin, NULL);
            } @catch (NSException *exception) { NPSPIFailed = YES; }
        }
        NPBound = NO;
    }
}

static NSString *NPSignedAppID(void) {
    // Dynamically resolve: these Security functions are not public iOS SDK API.
    CFTypeRef (*create)(CFAllocatorRef) = dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    CFTypeRef (*copy)(CFTypeRef, CFStringRef, CFErrorRef *) =
        dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!create || !copy) return nil;
    CFTypeRef task = create(kCFAllocatorDefault);
    if (!task) return nil;
    CFTypeRef value = copy(task, CFSTR("application-identifier"), NULL);
    CFRelease(task);
    if (!value) return nil;
    NSString *result = CFGetTypeID(value) == CFStringGetTypeID() ? [(__bridge NSString *)value copy] : nil;
    CFRelease(value);
    return result;
}

static NSString *NPSigningAssessment(NSString *bundle, NSString *signedID) {
    if (!signedID.length) return @"서명 App ID를 읽지 못함: 일치 여부 미확인";
    if ([signedID hasSuffix:[@"." stringByAppendingString:bundle ?: @""]])
        return @"서명 App ID와 번들 ID가 일치함";
    return @"서명 App ID 불일치: 서명 도구/프로파일 확인 필요. 이 dylib는 서명 권한을 바꾸지 못함.";
}

static NSString *NPReport(void) {
    NSString *signedID = NPSignedAppID();
    NSUInteger published, bound;
    @synchronized (NPLock) { published = NPPublishCount; bound = NPBindCount; }
    return [NSString stringWithFormat:
        @"YTMU NowPlaying Launch v0.1 (실기기 검증 필요)\n"
        "패치: %@\n앱 버전: %@\n실제 번들 ID: %@\n서명 App ID: %@\n%@\n"
        "재생 정보 전달: %lu회\nMediaRemote API: %@\n앱 연결 요청: %lu회\n\n"
        "요청 횟수는 iOS의 승인이나 탭 동작 성공을 뜻하지 않습니다.\n"
        "곡을 재생하고 화면을 잠근 뒤 위젯/다이나믹 아일랜드를 눌러 확인하세요.",
        NPEnabled() ? @"켜짐" : @"꺼짐", NPInfo[@"CFBundleShortVersionString"] ?: @"?",
        NPBundleID() ?: @"?", signedID ?: @"읽기 불가", NPSigningAssessment(NPBundleID(), signedID),
        (unsigned long)published, NPSPIFailed ? @"예외 발생: 이번 실행에서는 중단됨" :
            (NPGetOrigin && NPSetParent ? @"사용 가능" : @"사용 불가 (적용 안 됨)"),
        (unsigned long)bound];
}

static id (*NPOriginalDefaultCenter)(id, SEL);
static void (*NPOriginalSetInfo)(id, SEL, NSDictionary *);

static id NPDefaultCenter(id self, SEL cmd) {
    id center = NPOriginalDefaultCenter(self, cmd);
    if (center) NPBind();
    return center;
}

static void NPSetInfo(id self, SEL cmd, NSDictionary *info) {
    NPOriginalSetInfo(self, cmd, info);
    if (info.count) {
        @synchronized (NPLock) { NPPublishCount++; }
        NPBind();
    }
}

static BOOL NPHook(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    *original = method_getImplementation(method);
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    return YES;
}

#ifndef YTMU_NP_TEST
@interface YTMUNPDiagnosticAction : NSObject
@property (nonatomic, weak) UIViewController *controller;
- (void)show;
@end
@implementation YTMUNPDiagnosticAction
- (void)show {
    UIViewController *controller = self.controller;
    if (!controller || controller.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"재생 위젯 → 앱 열기"
        message:NPReport() preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"진단 복사" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = NPReport();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NPEnabled() ? @"패치 끄기" : @"패치 켜기"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { NPSetEnabled(!NPEnabled()); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"닫기" style:UIAlertActionStyleCancel handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}
@end

static const char NPActionKey;
static void (*NPOriginalSettingsLoad)(id, SEL);
static void NPSettingsLoad(UIViewController *self, SEL cmd) {
    NPOriginalSettingsLoad(self, cmd);
    YTMUNPDiagnosticAction *action = [YTMUNPDiagnosticAction new];
    action.controller = self;
    objc_setAssociatedObject(self, &NPActionKey, action, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSMutableArray *items = [self.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray new];
    [items addObject:[[UIBarButtonItem alloc] initWithTitle:@"앱 열기 진단"
        style:UIBarButtonItemStylePlain target:action action:@selector(show)]];
    self.navigationItem.rightBarButtonItems = items;
}
#endif

static void NPInstall(void) {
    if (NPInstalled) return;
    NPInstalled = YES;
    NPLock = [NSObject new];
    Class center = NSClassFromString(@"MPNowPlayingInfoCenter");
    NPHook(object_getClass(center), NSSelectorFromString(@"defaultCenter"),
        (IMP)NPDefaultCenter, (IMP *)&NPOriginalDefaultCenter);
    NPHook(center, NSSelectorFromString(@"setNowPlayingInfo:"),
        (IMP)NPSetInfo, (IMP *)&NPOriginalSetInfo);
#ifndef YTMU_NP_TEST
    // dlopen handle intentionally lives for the process lifetime.
    void *framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL);
    if (framework) {
        NPGetOrigin = dlsym(framework, "MRMediaRemoteGetLocalOrigin");
        NPSetParent = dlsym(framework, "MRMediaRemoteSetParentApplication");
    }
    Class settings = NSClassFromString(@"YTMUWGSettingsController");
    NPHook(settings, @selector(viewDidLoad), (IMP)NPSettingsLoad, (IMP *)&NPOriginalSettingsLoad);
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { NPBind(); }];
#endif
}

#ifndef YTMU_NP_TEST
__attribute__((constructor)) static void NPStart(void) {
    @autoreleasepool {
        // Read the actual on-disk plist, bypassing YTMU's NSBundle identity hooks.
        NSString *file = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:file];
        if (![info[@"CFBundleExecutable"] isEqualToString:@"YouTubeMusic"]) return;
        NPInfo = [info copy];
        dispatch_async(dispatch_get_main_queue(), ^{ NPInstall(); });
    }
}
#endif
