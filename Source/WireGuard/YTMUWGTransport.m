// Google transport selection and music-loader diagnostics.
//
// YouTube Music can move requests off NSURLSession (Envoy Mobile, Cronet/QUIC),
// which would bypass the app-local proxy. These patches are applied only when
// the tunnel is active and only after the exact class, selector and return type
// have been verified at runtime in the running binary. Class and value choices
// were observed in YouTube Music 9.42.2 and are re-checked here for every
// version instead of being assumed:
//
//  * BOOL flags whose names state "use/enable Cronet/QUIC/Envoy/HTTP3" are
//    forced to NO. That meaning does not depend on the version.
//  * YTIHamplayerUrlSessionDataLoaderConfig.networkStackType is an enum. In
//    9.42.2, 3 selected HAMEnvoyDataLoader and 0 the NSURLSession loader. The
//    URLSession value is taken from the protobuf enum descriptor's value names
//    when the binary carries them; otherwise 0 is used only on a verified
//    version or when the user enables the override. Other versions are
//    observed (original values recorded) but not changed.

#import "YTMUWGCore.h"
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>

#pragma mark - Generic helpers

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<NSString *> *gMissing; // hooks skipped because the signature differed

static IMP Replace(Class cls, SEL sel, IMP replacement, const char *types) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NULL;
    IMP original = method_getImplementation(method);
    if (!class_addMethod(cls, sel, replacement, types ?: method_getTypeEncoding(method)))
        original = method_setImplementation(class_getInstanceMethod(cls, sel), replacement);
    return original;
}

static BOOL IsBoolType(const char *t) { return !strcmp(t, "B") || !strcmp(t, "c") || !strcmp(t, "C"); }

static NSString *ReturnType(Method m) {
    char buf[32];
    method_getReturnType(m, buf, sizeof(buf));
    return [NSString stringWithUTF8String:buf];
}

static void NoteMissing(NSString *what) {
    os_unfair_lock_lock(&gLock);
    if (!gMissing) gMissing = [NSMutableArray array];
    [gMissing addObject:what];
    os_unfair_lock_unlock(&gLock);
}

static void Bump(NSMutableDictionary *dict, id key) {
    os_unfair_lock_lock(&gLock);
    if (dict.count < 32 || dict[key]) dict[key] = @([dict[key] unsignedIntegerValue] + 1);
    os_unfair_lock_unlock(&gLock);
}

static NSString *Histogram(NSDictionary *dict) {
    os_unfair_lock_lock(&gLock);
    NSDictionary *copy = [dict copy];
    os_unfair_lock_unlock(&gLock);
    if (!copy.count) return @"none";
    NSMutableArray *parts = [NSMutableArray array];
    for (id key in [copy.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [parts addObject:[NSString stringWithFormat:@"%@ x%@", key, copy[key]]];
    return [parts componentsJoinedByString:@", "];
}

static NSArray<NSString *> *AppImages(void) {
    NSString *bundle = NSBundle.mainBundle.bundlePath.stringByResolvingSymlinksInPath;
    NSMutableArray *images = [NSMutableArray array];
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *path = [NSString stringWithUTF8String:name];
        if (i == 0 || [path.stringByResolvingSymlinksInPath hasPrefix:bundle]) [images addObject:path];
    }
    return images;
}

static void ForEachAppClassName(void (^block)(const char *name)) {
    for (NSString *image in AppImages()) {
        unsigned int count = 0;
        const char **names = objc_copyClassNamesForImage(image.UTF8String, &count);
        for (unsigned int i = 0; i < count; i++) block(names[i]);
        free(names);
    }
}

#pragma mark - BOOL transport flags

typedef struct {
    const char *cls;
    const char *sel;
} BoolPatch;

static const BoolPatch kBoolPatches[] = {
    {"YTIHamplayerUrlSessionDataLoaderConfig", "useCronet"},
    {"YTIHamplayerUrlSessionDataLoaderConfig", "useCronetNative"},
    {"YTIHamplayerUrlSessionDataLoaderConfig", "assumeHTTP3Capable"},
    {"YTIOnesieConfig", "enableCronet"},
    {"YTIOnesieConfig", "enableQuic"},
    {"YTIInnerTubeUploadsConfig", "cronetEnabled"},
    {"YTIInnerTubeUploadsConfig", "cronetQuicEnabled"},
    {"YTIMediaCommonConfig", "platypusUseEnvoyNetFetch"},
    {"YTHotConfig", "onesiePlatypusUseEnvoyNetFetch"},
};
#define kBoolCount (sizeof(kBoolPatches) / sizeof(kBoolPatches[0]))
static atomic_uint gBoolSeen[kBoolCount][2];
static NSString *gBoolStatus[kBoolCount];

static void InstallBoolPatch(NSUInteger index) {
    BoolPatch patch = kBoolPatches[index];
    Class cls = objc_getClass(patch.cls);
    if (!cls) {
        gBoolStatus[index] = @"class not present";
        return;
    }
    SEL sel = sel_registerName(patch.sel);
    // class_getInstanceMethod also runs +resolveInstanceMethod:, which is how
    // protobuf (GPBMessage) installs its lazily generated getters.
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        NSString *type = ReturnType(m);
        if (!IsBoolType(type.UTF8String) || method_getNumberOfArguments(m) != 2) {
            gBoolStatus[index] = [NSString stringWithFormat:@"not patched: return type %@", type];
            return;
        }
        BOOL (*original)(id, SEL) = (BOOL (*)(id, SEL))method_getImplementation(m);
        IMP imp = imp_implementationWithBlock(^BOOL(id self) {
            BOOL value = original(self, sel);
            atomic_fetch_add(&gBoolSeen[index][value ? 1 : 0], 1);
            return NO;
        });
        Replace(cls, sel, imp, method_getTypeEncoding(m));
        gBoolStatus[index] = @"patched -> NO";
        return;
    }
    objc_property_t property = class_getProperty(cls, patch.sel);
    const char *attrs = property ? property_getAttributes(property) : NULL;
    if (!attrs || (strncmp(attrs, "TB,", 3) && strncmp(attrs, "Tc,", 3))) {
        gBoolStatus[index] = @"selector not present";
        return;
    }
    if (class_addMethod(cls, sel, imp_implementationWithBlock(^BOOL(id self) { return NO; }), "B@:"))
        gBoolStatus[index] = @"patched -> NO (declared property, no original getter)";
    else
        gBoolStatus[index] = @"not patched: getter could not be added";
}

#pragma mark - networkStackType

static NSString *gStackStatus = @"not evaluated";
static NSString *gStackEnum = @"";
static NSMutableDictionary *gStackSeen;

static NSDictionary<NSNumber *, NSString *> *ProtobufEnumNames(Class cls, NSString *field) {
    @try {
        SEL descriptorSel = NSSelectorFromString(@"descriptor");
        if (![cls respondsToSelector:descriptorSel]) return nil;
        id descriptor = ((id (*)(id, SEL))objc_msgSend)(cls, descriptorSel);
        SEL fieldSel = NSSelectorFromString(@"fieldWithName:");
        if (![descriptor respondsToSelector:fieldSel]) return nil;
        id fieldDescriptor = ((id (*)(id, SEL, id))objc_msgSend)(descriptor, fieldSel, field);
        SEL enumSel = NSSelectorFromString(@"enumDescriptor");
        if (![fieldDescriptor respondsToSelector:enumSel]) return nil;
        id enumDescriptor = ((id (*)(id, SEL))objc_msgSend)(fieldDescriptor, enumSel);
        SEL countSel = NSSelectorFromString(@"enumNameCount");
        SEL nameSel = NSSelectorFromString(@"getEnumNameForIndex:");
        SEL valueSel = NSSelectorFromString(@"getValue:forEnumName:");
        if (![enumDescriptor respondsToSelector:countSel] || ![enumDescriptor respondsToSelector:nameSel] ||
            ![enumDescriptor respondsToSelector:valueSel])
            return nil;
        uint32_t count = ((uint32_t (*)(id, SEL))objc_msgSend)(enumDescriptor, countSel);
        NSMutableDictionary *names = [NSMutableDictionary dictionary];
        for (uint32_t i = 0; i < count && i < 64; i++) {
            NSString *name = ((id (*)(id, SEL, uint32_t))objc_msgSend)(enumDescriptor, nameSel, i);
            int32_t value = 0;
            if ([name isKindOfClass:NSString.class] &&
                ((BOOL (*)(id, SEL, int32_t *, id))objc_msgSend)(enumDescriptor, valueSel, &value, name))
                names[@(value)] = name;
        }
        return names.count ? names : nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

static NSDictionary<NSString *, NSNumber *> *VerifiedStackValues(void) {
    // version -> networkStackType value of the NSURLSession music loader,
    // confirmed by disassembling MLHAMDataLoaderProviderImpl.updateDataLoader.
    return @{@"9.42.2": @0};
}

static void InstallStackPatch(void) {
    gStackSeen = [NSMutableDictionary dictionary];
    Class cls = objc_getClass("YTIHamplayerUrlSessionDataLoaderConfig");
    if (!cls) {
        gStackStatus = @"class not present";
        return;
    }
    SEL sel = sel_registerName("networkStackType");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        gStackStatus = @"selector not present";
        return;
    }
    NSString *type = ReturnType(m);
    if (![type isEqualToString:@"i"] || method_getNumberOfArguments(m) != 2) {
        gStackStatus = [NSString stringWithFormat:@"not patched: return type %@", type];
        return;
    }
    NSDictionary<NSNumber *, NSString *> *names = ProtobufEnumNames(cls, @"networkStackType");
    NSMutableArray *described = [NSMutableArray array];
    for (NSNumber *value in [names.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [described addObject:[NSString stringWithFormat:@"%@=%@", value, names[value]]];
    gStackEnum = names ? [described componentsJoinedByString:@" "] : @"(names not in binary)";

    BOOL change = NO;
    int32_t target = 0;
    NSString *basis = nil;
    if (names) {
        for (NSNumber *value in names) {
            NSString *upper = names[value].uppercaseString;
            if ([upper containsString:@"URL_SESSION"] || [upper containsString:@"URLSESSION"]) {
                target = value.intValue;
                basis = [NSString stringWithFormat:@"enum name %@", names[value]];
                change = YES;
            }
        }
        if (!change) basis = @"no URLSession value in enum";
    } else if (VerifiedStackValues()[YTMUWGAppVersion()]) {
        target = VerifiedStackValues()[YTMUWGAppVersion()].intValue;
        basis = [NSString stringWithFormat:@"verified on %@", YTMUWGAppVersion()];
        change = YES;
    } else if (YTMUWGSettingForceNativeStack()) {
        target = 0;
        basis = @"user override (unverified version)";
        change = YES;
    } else {
        basis = @"unverified version; observing only";
    }
    int32_t (*original)(id, SEL) = (int32_t (*)(id, SEL))method_getImplementation(m);
    IMP imp = imp_implementationWithBlock(^int32_t(id self) {
        int32_t value = original(self, sel);
        Bump(gStackSeen, @(value));
        return change ? target : value;
    });
    Replace(cls, sel, imp, method_getTypeEncoding(m));
    gStackStatus = change ? [NSString stringWithFormat:@"patched -> %d (%@)", target, basis]
                          : [NSString stringWithFormat:@"not changed (%@)", basis];
}

#pragma mark - Music loader diagnostics

static atomic_uint gNativeTasks, gNativeMedia, gEnvoyTasks, gEnvoyMedia, gRemoteAssets;
static NSMutableDictionary *gHTTPStatus, *gErrors, *gInstances;
static id (*origNativeTask)(id, SEL, id, id);
static id (*origEnvoyTask)(id, SEL, id, id);
static void (*origResponse)(id, SEL, id, double);
static void (*origCompletion)(id, SEL, id, double);
static id (*origAssetInit)(id, SEL, id, id);

static BOOL IsMediaRequest(id request) {
    if (![request isKindOfClass:NSURLRequest.class]) return NO;
    return [YTMUWGHostCategory([request URL].host) isEqualToString:@"media"];
}
static id NativeTask(id self, SEL _cmd, id request, id userInfo) {
    atomic_fetch_add(&gNativeTasks, 1);
    if (IsMediaRequest(request)) atomic_fetch_add(&gNativeMedia, 1);
    return origNativeTask(self, _cmd, request, userInfo);
}
static id EnvoyTask(id self, SEL _cmd, id request, id userInfo) {
    atomic_fetch_add(&gEnvoyTasks, 1);
    if (IsMediaRequest(request)) atomic_fetch_add(&gEnvoyMedia, 1);
    return origEnvoyTask(self, _cmd, request, userInfo);
}
static void LoaderResponse(id self, SEL _cmd, id response, double time) {
    if ([response isKindOfClass:NSHTTPURLResponse.class]) Bump(gHTTPStatus, @([(NSHTTPURLResponse *)response statusCode]));
    origResponse(self, _cmd, response, time);
}
static NSString *SafeDomain(NSString *domain) {
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"] invertedSet];
    if (![domain isKindOfClass:NSString.class] || [domain rangeOfCharacterFromSet:bad].location != NSNotFound) return @"(other)";
    return domain.length > 48 ? [domain substringToIndex:48] : domain;
}
static void LoaderCompletion(id self, SEL _cmd, id error, double time) {
    // Only the error domain and code are kept: localizedDescription and
    // userInfo can contain the signed media URL.
    if ([error isKindOfClass:NSError.class])
        Bump(gErrors, [NSString stringWithFormat:@"%@ %ld", SafeDomain([error domain]), (long)[error code]]);
    origCompletion(self, _cmd, error, time);
}
static id AssetInit(id self, SEL _cmd, id url, id options) {
    // AVFoundation streams remote URLs out of process, outside this proxy.
    if ([url isKindOfClass:NSURL.class]) {
        NSString *scheme = [url scheme].lowercaseString;
        if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) atomic_fetch_add(&gRemoteAssets, 1);
    }
    return origAssetInit(self, _cmd, url, options);
}

static void HookExact(const char *clsName, const char *selName, const char *types, IMP imp, IMP *original) {
    Class cls = objc_getClass(clsName);
    if (!cls) return;
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        NoteMissing([NSString stringWithFormat:@"%s.%s (absent)", clsName, selName]);
        return;
    }
    if (strcmp(method_getTypeEncoding(m), types)) {
        NoteMissing([NSString stringWithFormat:@"%s.%s (signature %s)", clsName, selName, method_getTypeEncoding(m)]);
        return;
    }
    *original = Replace(cls, sel, imp, types);
}

// Instance-creation counters show which music loader this version selected,
// independently of whether any patch matched.
#define kMaxAllocHooks 24
static Class gAllocClasses[kMaxAllocHooks];
static IMP gAllocOriginals[kMaxAllocHooks];
static int gAllocCount;

static id CountingAlloc(id self, SEL _cmd, void *zone) {
    IMP original = NULL;
    for (Class c = (Class)self; c && !original; c = class_getSuperclass(c))
        for (int i = 0; i < gAllocCount; i++)
            if (gAllocClasses[i] == c) {
                original = gAllocOriginals[i];
                break;
            }
    if (!original) original = class_getMethodImplementation(object_getClass(NSObject.class), _cmd);
    Bump(gInstances, NSStringFromClass((Class)self));
    return ((id (*)(id, SEL, void *))original)(self, _cmd, zone);
}

static BOOL HasHookedAncestor(Class cls) {
    for (Class c = cls; c; c = class_getSuperclass(c))
        for (int i = 0; i < gAllocCount; i++)
            if (gAllocClasses[i] == c) return YES;
    return NO;
}

static void InstallAllocCounters(void) {
    NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSetWithArray:@[@"HAMURLSessionDataLoader", @"HAMEnvoyDataLoader", @"EnvoyEngineImpl"]];
    ForEachAppClassName(^(const char *name) {
        size_t len = strlen(name);
        if (!strncmp(name, "HAM", 3) && len > 10 && !strcmp(name + len - 10, "DataLoader")) [names addObject:@(name)];
    });
    NSMutableArray<Class> *classes = [NSMutableArray array];
    for (NSString *name in names) {
        Class cls = objc_getClass(name.UTF8String);
        if (cls && class_respondsToSelector(object_getClass(cls), @selector(allocWithZone:))) [classes addObject:cls];
    }
    // Ancestors first, so a subclass is counted through its hooked ancestor
    // rather than hooked twice.
    [classes sortUsingComparator:^NSComparisonResult(Class a, Class b) {
        int da = 0, db = 0;
        for (Class c = a; c; c = class_getSuperclass(c)) da++;
        for (Class c = b; c; c = class_getSuperclass(c)) db++;
        return da < db ? NSOrderedAscending : da > db ? NSOrderedDescending : NSOrderedSame;
    }];
    for (Class cls in classes) {
        if (gAllocCount >= kMaxAllocHooks || HasHookedAncestor(cls)) continue;
        Class meta = object_getClass(cls);
        Method m = class_getInstanceMethod(meta, @selector(allocWithZone:));
        if (!m) continue;
        IMP original = method_getImplementation(m);
        if (!class_addMethod(meta, @selector(allocWithZone:), (IMP)CountingAlloc, method_getTypeEncoding(m)))
            original = method_setImplementation(class_getInstanceMethod(meta, @selector(allocWithZone:)), (IMP)CountingAlloc);
        gAllocOriginals[gAllocCount] = original;
        gAllocClasses[gAllocCount++] = cls;
    }
}

void YTMUWGInstallTransportPatches(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gHTTPStatus = [NSMutableDictionary dictionary];
        gErrors = [NSMutableDictionary dictionary];
        gInstances = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < kBoolCount; i++) InstallBoolPatch(i);
        InstallStackPatch();
        HookExact("HAMURLSessionDataLoader", "taskWithRequest:userInfo:", "@32@0:8@16@24", (IMP)NativeTask, (IMP *)&origNativeTask);
        HookExact("HAMEnvoyDataLoader", "taskWithRequest:userInfo:", "@32@0:8@16@24", (IMP)EnvoyTask, (IMP *)&origEnvoyTask);
        HookExact("HAMURLSessionDataLoadTask", "didReceiveResponse:absoluteTime:", "v32@0:8@16d24", (IMP)LoaderResponse, (IMP *)&origResponse);
        HookExact("HAMURLSessionDataLoadTask", "didCompleteWithError:absoluteTime:", "v32@0:8@16d24", (IMP)LoaderCompletion, (IMP *)&origCompletion);
        HookExact("AVURLAsset", "initWithURL:options:", "@32@0:8@16@24", (IMP)AssetInit, (IMP *)&origAssetInit);
        InstallAllocCounters();
    });
}

NSArray<NSString *> *YTMUWGTransportReportLines(void) {
    NSMutableArray *lines = [NSMutableArray array];
    if (!gHTTPStatus) {
        [lines addObject:@"transport: patches not installed (tunnel inactive in this launch)"];
        return lines;
    }
    for (NSUInteger i = 0; i < kBoolCount; i++) {
        unsigned yes = atomic_load(&gBoolSeen[i][1]), no = atomic_load(&gBoolSeen[i][0]);
        NSString *seen = (yes || no) ? [NSString stringWithFormat:@" | original YES x%u NO x%u", yes, no] : @"";
        [lines addObject:[NSString stringWithFormat:@"transport.flag %s.%s: %@%@", kBoolPatches[i].cls, kBoolPatches[i].sel, gBoolStatus[i], seen]];
    }
    [lines addObject:[NSString stringWithFormat:@"transport.networkStackType: %@ | enum %@ | original values %@", gStackStatus, gStackEnum, Histogram(gStackSeen)]];
    [lines addObject:[NSString stringWithFormat:@"music.loader: URLSession tasks %u (media-cdn %u) | Envoy tasks %u (media-cdn %u)",
        atomic_load(&gNativeTasks), atomic_load(&gNativeMedia), atomic_load(&gEnvoyTasks), atomic_load(&gEnvoyMedia)]];
    [lines addObject:[NSString stringWithFormat:@"music.loader.instances: %@", Histogram(gInstances)]];
    [lines addObject:[NSString stringWithFormat:@"music.http-status: %@", Histogram(gHTTPStatus)]];
    [lines addObject:[NSString stringWithFormat:@"music.errors: %@", Histogram(gErrors)]];
    [lines addObject:[NSString stringWithFormat:@"bypass.suspects: AVURLAsset remote URLs %u | Envoy loader tasks %u",
        atomic_load(&gRemoteAssets), atomic_load(&gEnvoyTasks)]];
    os_unfair_lock_lock(&gLock);
    NSArray *missing = [gMissing copy];
    os_unfair_lock_unlock(&gLock);
    if (missing.count) [lines addObject:[NSString stringWithFormat:@"hooks.skipped: %@", [missing componentsJoinedByString:@"; "]]];
    return lines;
}

NSArray<NSString *> *YTMUWGScanTransportClasses(void) {
    NSArray *tokens = @[@"envoy", @"cronet", @"quic", @"http3", @"dataloader", @"networkstack"];
    BOOL (^matches)(NSString *) = ^BOOL(NSString *s) {
        NSString *lower = s.lowercaseString;
        for (NSString *t in tokens)
            if ([lower containsString:t]) return YES;
        return NO;
    };
    NSMutableArray *classes = [NSMutableArray array], *configs = [NSMutableArray array];
    NSMutableArray *configNames = [NSMutableArray array];
    ForEachAppClassName(^(const char *cname) {
        NSString *name = @(cname);
        if (matches(name) && classes.count < 150) [classes addObject:name];
        if ([name hasPrefix:@"YTI"] && [name hasSuffix:@"Config"]) [configNames addObject:name];
    });
    for (NSString *name in configNames) {
        if (configs.count >= 150) break;
        Class cls = objc_getClass(name.UTF8String);
        unsigned int count = 0;
        objc_property_t *props = cls ? class_copyPropertyList(cls, &count) : NULL;
        for (unsigned int i = 0; i < count && configs.count < 150; i++) {
            NSString *prop = @(property_getName(props[i]));
            if (!matches(prop)) continue;
            NSString *attrs = @(property_getAttributes(props[i]));
            NSString *type = [[attrs componentsSeparatedByString:@","].firstObject substringFromIndex:1];
            [configs addObject:[NSString stringWithFormat:@"%@.%@ (%@)", name, prop, type]];
        }
        free(props);
    }
    NSMutableArray *out = [NSMutableArray array];
    [out addObject:[NSString stringWithFormat:@"scan.classes (%lu): %@", (unsigned long)classes.count,
        [[classes sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]]];
    [out addObject:[NSString stringWithFormat:@"scan.config-flags (%lu): %@", (unsigned long)configs.count,
        [[configs sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]]];
    return out;
}
