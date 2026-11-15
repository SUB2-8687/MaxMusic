// Bridge Google's stock widget storage after a signing tool renames App Groups.
// Load this file in BOTH the host and WidgetKit extension. Only groups actually
// granted to both signatures are considered; private Documents is never shared.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/loader.h>

static NSArray<NSString *> *YTMUOwnGroups;
static NSString *YTMUCommonGroup;
static NSURL *(*YTMUOriginalContainer)(id, SEL, NSString *);
static void *(*YTMUOriginalSuite)(void *, SEL, NSString *);

static uint32_t YTMUBE32(const uint8_t *p) {
    uint32_t n; memcpy(&n, p, sizeof(n)); return CFSwapInt32BigToHost(n);
}

// Read XML entitlements from the on-disk signature, not Info.plist assertions.
// Unsupported/DER-only signatures fail closed instead of guessing a group.
static NSArray *YTMUFileGroups(NSBundle *bundle) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundle.bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *exe = info[@"CFBundleExecutable"];
    if (![exe isKindOfClass:NSString.class]) return nil;
    NSData *data = [NSData dataWithContentsOfFile:[bundle.bundlePath stringByAppendingPathComponent:exe]
                                       options:NSDataReadingMappedIfSafe error:nil];
    if (data.length < sizeof(struct mach_header_64)) return nil;
    const uint8_t *bytes = data.bytes;
    struct mach_header_64 header; memcpy(&header, bytes, sizeof(header));
    if (header.magic != MH_MAGIC_64 || header.sizeofcmds > data.length - sizeof(header)) return nil;
    NSUInteger pos = sizeof(header), end = pos + header.sizeofcmds;
    for (uint32_t i = 0; i < header.ncmds; i++) {
        if (pos > end || end - pos < sizeof(struct load_command)) return nil;
        struct load_command cmd; memcpy(&cmd, bytes + pos, sizeof(cmd));
        if (cmd.cmdsize < sizeof(cmd) || cmd.cmdsize > end - pos) return nil;
        if (cmd.cmd == LC_CODE_SIGNATURE) {
            if (cmd.cmdsize < sizeof(struct linkedit_data_command)) return nil;
            struct linkedit_data_command sig; memcpy(&sig, bytes + pos, sizeof(sig));
            if (sig.dataoff > data.length || sig.datasize > data.length - sig.dataoff || sig.datasize < 12) return nil;
            const uint8_t *blob = bytes + sig.dataoff;
            uint32_t length = YTMUBE32(blob + 4), count = YTMUBE32(blob + 8);
            if (YTMUBE32(blob) != 0xfade0cc0 || length > sig.datasize || length < 12 || count > (length - 12) / 8) return nil;
            for (uint32_t n = 0; n < count; n++) {
                uint32_t offset = YTMUBE32(blob + 16 + n * 8);
                if (offset > length || length - offset < 8) return nil;
                uint32_t size = YTMUBE32(blob + offset + 4);
                if (size < 8 || size > length - offset) return nil;
                if (YTMUBE32(blob + offset) != 0xfade7171) continue;
                NSData *xml = [NSData dataWithBytes:blob + offset + 8 length:size - 8];
                id entitlements = [NSPropertyListSerialization propertyListWithData:xml options:0 format:NULL error:nil];
                id groups = [entitlements isKindOfClass:NSDictionary.class] ? entitlements[@"com.apple.security.application-groups"] : nil;
                if (![groups isKindOfClass:NSArray.class]) return nil;
                for (id group in groups) if (![group isKindOfClass:NSString.class]) return nil;
                return groups;
            }
            return nil;
        }
        pos += cmd.cmdsize;
    }
    return nil;
}

static NSArray *YTMUTaskGroups(void) {
    CFTypeRef (*create)(CFAllocatorRef) = dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    CFTypeRef (*copy)(CFTypeRef, CFStringRef, CFErrorRef *) = dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!create || !copy) return nil;
    CFTypeRef task = create(NULL);
    if (!task) return nil;
    CFTypeRef value = copy(task, CFSTR("com.apple.security.application-groups"), NULL);
    CFRelease(task);
    id groups = CFBridgingRelease(value);
    if (![groups isKindOfClass:NSArray.class]) return nil;
    for (id group in groups) if (![group isKindOfClass:NSString.class]) return nil;
    return groups;
}

static NSURL *YTMURedirect(NSString *requested) {
    if (![requested isKindOfClass:NSString.class] ||
        ![requested hasPrefix:@"group.com.google."] || [requested containsString:@"/"] ||
        [YTMUOwnGroups containsObject:requested] || !YTMUCommonGroup) return nil;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *base = YTMUOriginalContainer(manager, @selector(containerURLForSecurityApplicationGroupIdentifier:), YTMUCommonGroup);
    if (!base) return nil;
    // Separate original groups even when a signer grants only one replacement.
    NSURL *folder = [[base URLByAppendingPathComponent:@"YTMUAppGroups" isDirectory:YES]
                     URLByAppendingPathComponent:requested isDirectory:YES];
    if (![manager createDirectoryAtURL:[folder URLByAppendingPathComponent:@"Library/Preferences" isDirectory:YES]
          withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    return folder;
}

static NSURL *YTMUContainer(id self, SEL selector, NSString *group) {
    return YTMURedirect(group) ?: YTMUOriginalContainer(self, selector, group);
}

// Keep init's +1 return and consumed receiver outside ARC's C-function rules.
static void *YTMUSuite(void *receiver, SEL selector, NSString *suite) {
    NSUserDefaults *self = (__bridge NSUserDefaults *)receiver;
    NSURL *container = YTMURedirect(suite);
    SEL init = NSSelectorFromString(@"_initWithSuiteName:container:");
    if (container && [self respondsToSelector:init])
        return ((void *(*)(void *, SEL, NSString *, NSURL *))objc_msgSend)(receiver, init, suite, container);
    return YTMUOriginalSuite(receiver, selector, suite);
}

__attribute__((constructor)) static void YTMUInstallGroups(void) {
    @autoreleasepool {
        NSBundle *own = NSBundle.mainBundle;
        NSBundle *host = [own.bundlePath.pathExtension isEqualToString:@"appex"] ?
            [NSBundle bundleWithPath:own.bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent] : own;
        NSDictionary *hostInfo = [NSDictionary dictionaryWithContentsOfFile:[host.bundlePath stringByAppendingPathComponent:@"Info.plist"]];
        if (![hostInfo[@"CFBundleExecutable"] isEqualToString:@"YouTubeMusic"]) return;
        YTMUOwnGroups = YTMUTaskGroups() ?: YTMUFileGroups(own);
        NSArray *hostGroups = YTMUFileGroups(host);
        NSMutableSet *common = [NSMutableSet setWithArray:hostGroups ?: @[]];
        [common intersectSet:[NSSet setWithArray:YTMUOwnGroups ?: @[]]];
        NSString *plugins = [host.bundlePath stringByAppendingPathComponent:@"PlugIns"];
        BOOL foundWidget = NO;
        for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:plugins error:nil]) {
            if (![entry.pathExtension isEqualToString:@"appex"]) continue;
            NSBundle *widget = [NSBundle bundleWithPath:[plugins stringByAppendingPathComponent:entry]];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[widget.bundlePath stringByAppendingPathComponent:@"Info.plist"]];
            if (![info[@"NSExtension"][@"NSExtensionPointIdentifier"] isEqualToString:@"com.apple.widgetkit-extension"]) continue;
            foundWidget = YES;
            [common intersectSet:[NSSet setWithArray:YTMUFileGroups(widget) ?: @[]]];
        }
        if (!foundWidget) return;
        YTMUCommonGroup = [[common allObjects] sortedArrayUsingSelector:@selector(compare:)].firstObject;
        if (!YTMUCommonGroup) { NSLog(@"[YTMU] Widget bridge: no readable common signed App Group"); return; }
        Method container = class_getInstanceMethod(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:));
        Method suite = class_getInstanceMethod(NSUserDefaults.class, @selector(initWithSuiteName:));
        if (!container || !suite) return;
        YTMUOriginalContainer = (void *)method_setImplementation(container, (IMP)YTMUContainer);
        YTMUOriginalSuite = (void *)method_setImplementation(suite, (IMP)YTMUSuite);
    }
}
