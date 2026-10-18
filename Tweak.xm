// AppStoreVersionSpoofer — 核心 Hook 源码
//
// 伪装 iOS 系统版本，绕过 App Store 的版本校验（服务端 + 本地双通道）：
//  1. User-Agent 通道（关键）：App Store 判断"此 App 需要更高 iOS 版本、禁止下载"
//     是服务端依据请求 User-Agent 里的 `iOS/版本号` 决定的。这里拦截
//     NSMutableURLRequest 设置 User-Agent 的调用，无条件把 `iOS/x` 改写为伪装版本。
//     （旧版只在"购买接口"才改 UA，且误判"UA 是否含 URL 路径"导致该分支永不成立，
//       UA 实际从未被改 —— 这就是"下载无效果"的根因。因本 tweak 仅注入
//       AppStore/appstored，直接对所有请求生效，无副作用。）
//  2. 本地通道：hook MGCopyAnswer，对 ProductVersion 返回伪装版本，覆盖本地检测。
//
// 免责声明：本插件用于 iOS 越狱环境个人学习研究，修改 App Store 请求绕过
// 版本校验违反 Apple 用户协议，可能导致 Apple ID 封禁、设备异常。风险自担。

#import <substrate.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// MGCopyAnswer 是 libMobileGestalt 的私有函数，SDK 不含其头文件。
// 不可直接引用该符号（链接期 undefined），改为运行时 dlsym 取地址后再 hook。
typedef CFTypeRef (*MGCopyAnswerFn)(CFStringRef question, uint32_t *outType);

#pragma mark - 偏好读取（与配置 App 共用同一 suite/key）

static NSString *const kPrefsSuite  = @"com.custom.appstoreversionspoofer";
static NSString *const kPrefEnable  = @"enableSpoof";
static NSString *const kPrefFakeVer  = @"fakeVer";
static NSString *const kDefaultFakeVer = @"15.0";

static NSString *GetFakeVersion(void) {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
    if (![prefs boolForKey:kPrefEnable]) {
        return nil;
    }
    NSString *v = [prefs stringForKey:kPrefFakeVer];
    if (v.length > 0) {
        return v;
    }
    return kDefaultFakeVer;
}

#pragma mark - User-Agent 伪装

// 把 UA 里的 `iOS/12.2`（或 `iOS 12.2`）改写为 `iOS/<fakeVer>`。
static id RewriteUserAgent(id value) {
    NSString *fakeVer = GetFakeVersion();
    if (!fakeVer) return value;                                  // 未开启伪装
    if (![value isKindOfClass:[NSString class]]) return value;
    NSString *ua = (NSString *)value;
    if (ua.length == 0) return value;

    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"iOS[/ ][0-9.]+"
                                                          options:NSRegularExpressionCaseInsensitive
                                                            error:nil];
    });
    NSString *newUA = [regex stringByReplacingMatchesInString:ua
                                                      options:0
                                                        range:NSMakeRange(0, ua.length)
                                                 withTemplate:[NSString stringWithFormat:@"iOS/%@", fakeVer]];
    return newUA.length ? newUA : value;
}

static void (*orig_setValueForHTTPHeaderField)(id, SEL, id, id);
static void (*orig_addValueForHTTPHeaderField)(id, SEL, id, id);

static void HookedSetValueForHTTPHeaderField(id self, SEL _cmd, id value, id field) {
    if ([field isEqualToString:@"User-Agent"]) {
        value = RewriteUserAgent(value);
    }
    orig_setValueForHTTPHeaderField(self, _cmd, value, field);
}

static void HookedAddValueForHTTPHeaderField(id self, SEL _cmd, id value, id field) {
    if ([field isEqualToString:@"User-Agent"]) {
        value = RewriteUserAgent(value);
    }
    orig_addValueForHTTPHeaderField(self, _cmd, value, field);
}

#pragma mark - 本地 ProductVersion 伪装

static MGCopyAnswerFn orig_MGCopyAnswer = NULL;

static CFTypeRef HookedMGCopyAnswer(CFStringRef key, uint32_t *outType) {
    NSString *fakeVer = GetFakeVersion();
    NSString *k = (__bridge NSString *)key;
    if (fakeVer && [k isEqualToString:@"ProductVersion"]) {
        // MGCopyAnswer 遵循 Copy 语义：调用方负责 CFRelease，需 CFRetain 转移所有权。
        return CFRetain((__bridge CFTypeRef)fakeVer);
    }
    return orig_MGCopyAnswer(key, outType);
}

#pragma mark - 构造函数

%ctor {
    Class reqCls = objc_getClass("NSMutableURLRequest");
    if (reqCls) {
        MSHookMessageEx(reqCls,
                        @selector(setValue:forHTTPHeaderField:),
                        (IMP)HookedSetValueForHTTPHeaderField,
                        (IMP *)&orig_setValueForHTTPHeaderField);
        MSHookMessageEx(reqCls,
                        @selector(addValue:forHTTPHeaderField:),
                        (IMP)HookedAddValueForHTTPHeaderField,
                        (IMP *)&orig_addValueForHTTPHeaderField);
    }
    MGCopyAnswerFn mgFn = (MGCopyAnswerFn)dlsym(RTLD_DEFAULT, "MGCopyAnswer");
    if (mgFn) {
        MSHookFunction(mgFn, HookedMGCopyAnswer, &orig_MGCopyAnswer);
    }
}
