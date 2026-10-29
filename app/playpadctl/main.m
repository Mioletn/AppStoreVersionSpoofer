// playpadctl — PlayPad 的 root 侧执行器
//
// 为什么必须有它：App 进程是 mobile 用户，既不能把包写进 /Applications，
// 也不能调 ldid 重签。安装/卸载/启动这些动作要 root 来做，所以单独做成一个
// 以 root 运行的命令行工具（daemon 之后会调它，SSH 也能直接用）。
//
// 它承担"超越 iOS 12.2"的第一道门：
//   1. 解开 ipa
//   2. 改写 Info.plist：MinimumOSVersion 降下来、去掉挡路的 UIRequiredDeviceCapabilities
//   3. 用 ldid 按给定 entitlements 重签可执行文件
//   4. 装进 /Applications + uicache，让 SpringBoard 认得（于是有原生窗口和原生触控）
//   5. 用 URL scheme / bundle id 拉起
//
// 用法：
//   playpadctl list
//   playpadctl install <ipa> [--minos 12.2] [--scheme <url>] [--no-launch]
//   playpadctl launch  <bundleid>
//   playpadctl uninstall <bundleid>
//   playpadctl info <ipa>

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>

static BOOL gVerbose = NO;
#define V(...) do { if (gVerbose) fprintf(stderr, __VA_ARGS__); } while (0)
#define SAY(...) do { printf(__VA_ARGS__); fflush(stdout); } while (0)

// iOS SDK 里 system() 被标为不可用（会直接编译失败），所以自己 fork/exec。
// 这个工具是以 root 跑的，执行 unzip / ldid / uicache 都需要这一点。
static int sh(NSString *cmd, BOOL echo) {
    if (echo || gVerbose) fprintf(stderr, "  $ %s\n", cmd.UTF8String);
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        execl("/bin/sh", "sh", "-c", cmd.UTF8String, (char *)NULL);
        _exit(127);
    }
    int st = 0;
    if (waitpid(pid, &st, 0) < 0) return -1;
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

static NSArray<NSString *> *lines(NSString *cmd) {
    FILE *p = popen(cmd.UTF8String, "r");
    if (!p) return @[];
    NSMutableArray *out = [NSMutableArray array];
    char buf[4096];
    while (fgets(buf, sizeof(buf), p)) {
        NSString *s = [[NSString stringWithUTF8String:buf] stringByTrimmingCharactersInSet:
                       [NSCharacterSet newlineCharacterSet]];
        if (s.length) [out addObject:s];
    }
    pclose(p);
    return out;
}

// ---------------------------------------------------------------- zip 取条目
// 只需要"列出条目"和"取 Info.plist 出来看"，直接借系统 unzip 更省事。
static NSString *findInfoPlistInZip(NSString *ipa) {
    for (NSString *e in lines([NSString stringWithFormat:@"/usr/bin/unzip -Z1 '%@'", ipa])) {
        if ([e hasPrefix:@"Payload/"] && [e hasSuffix:@".app/Info.plist"]) return e;
    }
    return nil;
}

static NSDictionary *plistFromZip(NSString *ipa, NSString *entry) {
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ppctl_tmp.plist"];
    if (sh([NSString stringWithFormat:@"/usr/bin/unzip -p '%@' '%@' > '%@'", ipa, entry, tmp], NO) != 0)
        return nil;
    NSData *d = [NSData dataWithContentsOfFile:tmp];
    if (!d) return nil;
    id p = [NSPropertyListSerialization propertyListWithData:d options:NSPropertyListImmutable
                                                      format:NULL error:nil];
    return [p isKindOfClass:[NSDictionary class]] ? p : nil;
}

// ---------------------------------------------------------------- 私有 API
typedef void (*MICallback)(NSDictionary *info);

static int (*pMIInstall)(CFStringRef, CFDictionaryRef, MICallback, void *);

static void loadMI(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_LAZY);
    if (!h) h = dlopen("/usr/lib/libMobileInstallation.dylib", RTLD_LAZY);
    if (h) pMIInstall = (int (*)(CFStringRef, CFDictionaryRef, MICallback, void *))
                        dlsym(h, "MobileInstallationInstall");
    V("MobileInstallation: %s\n", pMIInstall ? "ok" : "无");
}

static BOOL launchBundle(NSString *bid) {
    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    id ws = wsCls ? ((id (*)(id, SEL))objc_msgSend)(wsCls, @selector(defaultWorkspace)) : nil;
    if (!ws) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, @selector(openApplicationWithBundleID:), bid);
}

// ---------------------------------------------------------------- 安装
static int cmdInfo(int argc, char **argv) {
    if (argc < 3) { SAY("用法: playpadctl info <ipa>\n"); return 2; }
    NSString *ipa = @(argv[2]);
    NSString *entry = findInfoPlistInZip(ipa);
    if (!entry) { SAY("不是有效 IPA：找不到 Payload/*.app/Info.plist\n"); return 1; }
    NSDictionary *info = plistFromZip(ipa, entry);
    SAY("bundle     : %s\n", [info[@"CFBundleIdentifier"] ?: @"?" UTF8String]);
    SAY("name       : %s\n", [(info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: @"?") UTF8String]);
    SAY("MinimumOS  : %s\n", [info[@"MinimumOSVersion"] ?: @"(未标注)" UTF8String]);
    SAY("SDK        : %s\n", [info[@"DTSDKName"] ?: @"?" UTF8String]);
    SAY("exec       : %s\n", [info[@"CFBundleExecutable"] ?: @"?" UTF8String]);
    SAY("app path   : %s\n", [entry stringByDeletingLastPathComponent].UTF8String);
    return 0;
}

static int cmdInstall(int argc, char **argv) {
    if (argc < 3) { SAY("用法: playpadctl install <ipa> [--minos 12.2] [--no-launch]\n"); return 2; }
    NSString *ipa = @(argv[2]);
    if (![[NSFileManager defaultManager] fileExistsAtPath:ipa]) {
        SAY("找不到 %s\n", ipa.UTF8String); return 1;
    }

    BOOL doLaunch = YES;
    for (int i = 3; i < argc; i++) if (!strcmp(argv[i], "--no-launch")) doLaunch = NO;

    loadMI();

    NSString *entry = findInfoPlistInZip(ipa);
    if (!entry) { SAY("不是有效 IPA\n"); return 1; }
    NSString *appRel  = [entry stringByDeletingLastPathComponent];     // Payload/Xxx.app
    NSString *appName = appRel.lastPathComponent;
    NSDictionary *info0 = plistFromZip(ipa, entry);
    NSString *bid  = info0[@"CFBundleIdentifier"];
    NSString *exec0 = info0[@"CFBundleExecutable"];
    NSString *disp = info0[@"CFBundleDisplayName"] ?: info0[@"CFBundleName"] ?: appName;
    NSString *minv = info0[@"MinimumOSVersion"] ?: @"?";
    SAY("• %s  (%s, MinimumOS %s)\n", disp.UTF8String, bid.UTF8String, minv.UTF8String);

    // 1) 解包
    NSString *work = @"/var/mobile/Library/PlayPad/work";
    sh([NSString stringWithFormat:@"/bin/mkdir -p '%@' && rm -rf '%@'/*", work, work], NO);
    SAY("• 解包…\n");
    if (sh([NSString stringWithFormat:@"/usr/bin/unzip -o -q '%@' -d '%@'", ipa, work], NO) != 0) {
        SAY("  解包失败\n"); return 1;
    }

    NSString *appPath = [work stringByAppendingPathComponent:appRel];
    NSString *infoPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:infoPath]) {
        SAY("  解包后找不到 %s\n", infoPath.UTF8String); return 1;
    }

    // 2) 改写版本门
    NSMutableDictionary *info = [[NSDictionary dictionaryWithContentsOfFile:infoPath] mutableCopy];
    if (!info) {
        NSData *d = [NSData dataWithContentsOfFile:infoPath];
        id p = [NSPropertyListSerialization propertyListWithData:d options:NSPropertyListMutableContainers
                                                          format:NULL error:nil];
        info = [p isKindOfClass:[NSDictionary class]] ? p : nil;
    }
    if (!info) { SAY("  Info.plist 读不了\n"); return 1; }

    NSString *oldMin = info[@"MinimumOSVersion"] ?: @"?";
    info[@"MinimumOSVersion"] = @"12.2";
    info[@"LSMinimumSystemVersion"] = @"12.2";
    // UIRequiredDeviceCapabilities 里常写 front-facing-camera / gps 之类，缺失会被弹簧板拒装
    id req = info[@"UIRequiredDeviceCapabilities"];
    if ([req isKindOfClass:[NSArray class]]) {
        NSMutableArray *keep = [NSMutableArray array];
        for (id c in req) if ([c isEqual:@"arm64"] || [c isEqual:@"armv7"]) [keep addObject:c];
        if (keep.count) info[@"UIRequiredDeviceCapabilities"] = keep;
        else [info removeObjectForKey:@"UIRequiredDeviceCapabilities"];
    }
    // 注入一个 URL scheme。原因：从 SSH / 非 FrontBoard 进程调
    // openApplicationWithBundleID 是拉不起 App 的（没有会话），而设备上的
    // uiopen 只接受 URL。注入 scheme 后就能 `uiopen playxxx://` 拉起，
    // 不需要重启 SpringBoard，也不用用户手点。
    NSString *leaf = [bid componentsSeparatedByString:@"."].lastObject ?: @"app";
    NSMutableString *scheme = [NSMutableString stringWithString:@"play"];
    for (NSUInteger i = 0; i < leaf.length; i++) {
        unichar ch = [leaf characterAtIndex:i];
        if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) [scheme appendFormat:@"%C", ch];
        else if (ch >= 'A' && ch <= 'Z') [scheme appendFormat:@"%C", (unichar)(ch - 'A' + 'a')];
    }
    info[@"CFBundleURLTypes"] = @[ @{ @"CFBundleURLName": bid,
                                     @"CFBundleURLSchemes": @[ scheme ] } ];
    // 去掉对更早 SDK 无效的新字段不会有害，但这里保留——iOS 12 只是忽略不认识的键。
    NSData *outData = [NSPropertyListSerialization dataWithPropertyList:info
                                                                 format:NSPropertyListBinaryFormat_v1_0
                                                                options:0 error:nil];
    if (![outData writeToFile:infoPath atomically:YES]) { SAY("  写 Info.plist 失败\n"); return 1; }
    SAY("• 版本门：MinimumOSVersion %s → 12.2\n", oldMin.UTF8String);

    // 3) 重签
    NSString *execPath = nil;
    if ([exec0 isKindOfClass:[NSString class]])
        execPath = [appPath stringByAppendingPathComponent:exec0];
    if (!execPath || ![[NSFileManager defaultManager] fileExistsAtPath:execPath]) {
        SAY("  找不到可执行文件 %s\n", exec0.UTF8String); return 1;
    }
    NSString *ent = @"/var/mobile/Library/PlayPad/ent.plist";
    sh([NSString stringWithFormat:@"/usr/bin/ldid -S'%@' '%@' 2>&1", ent, execPath], NO);
    NSString *signMsg = [[NSFileManager defaultManager] fileExistsAtPath:ent]
                        ? @"ldid -S 完成" : @"无 entitlements，仅补签名";
    SAY("• 重签：%s\n", signMsg.UTF8String);

    // 嵌套的 .app / framework 也签一遍（越狱下不签也能跑，但签了更稳）
    sh([NSString stringWithFormat:@"/usr/bin/ldid -S'%@' '%@' >/dev/null 2>&1; true", ent, appPath], NO);

    // 4) 装进 /Applications
    NSString *dest = [@"/Applications" stringByAppendingPathComponent:appName];
    sh([NSString stringWithFormat:@"rm -rf '%@' && cp -R '%@' '%@'", dest, appPath, dest], NO);
    sh([NSString stringWithFormat:@"chown -R root:wheel '%@'; chmod -R 755 '%@'; chmod 644 '%@/Info.plist'",
        dest, dest, dest], NO);
    SAY("• 已装到 %s\n", dest.UTF8String);

    SAY("• uicache（刷新 LaunchServices，可能要几十秒）…\n");
    sh([NSString stringWithFormat:@"/usr/bin/uicache '%@' >/dev/null 2>&1", dest], NO);

    // 5) 拉起
    if (doLaunch) {
        sleep(2);
        BOOL ok = launchBundle(bid);
        SAY("• 启动 %s → %s\n", bid.UTF8String, ok ? "已发出" : "失败");
        if (!ok) {
            // 非 FrontBoard 会话里 LS 拉不起来，走系统 uiopen（只吃 URL）
            SAY("• 改用 uiopen %s:// …\n", scheme.UTF8String);
            sh([NSString stringWithFormat:@"/usr/bin/uiopen %@:// 2>&1", scheme], YES);
        }
    }
    SAY("完成。bundle=%s\n", bid.UTF8String);
    return 0;
}

static int cmdLaunch(int argc, char **argv) {
    if (argc < 3) { SAY("用法: playpadctl launch <bundleid>\n"); return 2; }
    BOOL ok = launchBundle(@(argv[2]));
    SAY("%s → %s\n", argv[2], ok ? "已发出" : "失败");
    return ok ? 0 : 1;
}

static int cmdList(int argc, char **argv) {
    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    id ws = wsCls ? ((id (*)(id, SEL))objc_msgSend)(wsCls, @selector(defaultWorkspace)) : nil;
    NSArray *apps = ws ? ((id (*)(id, SEL))objc_msgSend)(ws, @selector(allInstalledApplications)) : @[];
    int n = 0;
    for (id p in apps) {
        NSString *bid = ((id (*)(id, SEL))objc_msgSend)(p, @selector(bundleIdentifier));
        NSString *path = @"";
        if ([p respondsToSelector:@selector(bundleURL)]) {
            NSURL *u = ((id (*)(id, SEL))objc_msgSend)(p, @selector(bundleURL));
            path = u.path ?: @"";
        }
        if (![path hasPrefix:@"/var"]) continue;
        printf("%-44s %s\n", bid.UTF8String, path.UTF8String);
        n++;
    }
    SAY("共 %d 个用户应用\n", n);
    return 0;
}

static int cmdUninstall(int argc, char **argv) {
    if (argc < 3) { SAY("用法: playpadctl uninstall <bundleid>\n"); return 2; }
    NSString *bid = @(argv[2]);
    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    id ws = wsCls ? ((id (*)(id, SEL))objc_msgSend)(wsCls, @selector(defaultWorkspace)) : nil;
    BOOL ok = NO;
    if (ws && [ws respondsToSelector:@selector(uninstallApplication:withOptions:)])
        ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, @selector(uninstallApplication:withOptions:),
                                                       bid, @{});
    SAY("%s → %s\n", bid.UTF8String, ok ? "已卸载" : "失败");
    return ok ? 0 : 1;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (getenv("PLAYPAD_VERBOSE")) gVerbose = YES;
        if (argc < 2) {
            SAY("playpadctl — PlayPad 安装器\n"
                "  info <ipa>\n"
                "  install <ipa> [--no-launch]\n"
                "  launch <bundleid>\n"
                "  uninstall <bundleid>\n"
                "  list\n");
            return 2;
        }
        // 准备目录与默认 entitlements
        sh(@"/bin/mkdir -p /var/mobile/Library/PlayPad/work", NO);
        NSString *ent = @"/var/mobile/Library/PlayPad/ent.plist";
        if (![[NSFileManager defaultManager] fileExistsAtPath:ent]) {
            NSDictionary *e = @{
                @"platform-application": @YES,
                @"com.apple.private.security.no-sandbox": @YES,
                @"com.apple.private.security.container-required": @NO,
                @"get-task-allow": @YES,
                @"application-identifier": @"com.macpad.playpad.installed",
                @"com.apple.developer.team-identifier": @"com.macpad.playpad",
                @"keychain-access-groups": @[@"com.macpad.playpad.installed"],
            };
            [e writeToFile:ent atomically:YES];
        }

        if (!strcmp(argv[1], "info"))      return cmdInfo(argc, argv);
        if (!strcmp(argv[1], "install"))   return cmdInstall(argc, argv);
        if (!strcmp(argv[1], "launch"))    return cmdLaunch(argc, argv);
        if (!strcmp(argv[1], "list"))      return cmdList(argc, argv);
        if (!strcmp(argv[1], "uninstall")) return cmdUninstall(argc, argv);
        SAY("未知命令 %s\n", argv[1]);
        return 2;
    }
}
