// AppStoreVersionSpoofer — 核心 Hook 源码（修复版）
//
// 修复点（相较原版）：
//  1. MGCopyAnswer 返回值所有权错误（原版 __bridge 不 retain，会被调用方
//     CFRelease 导致 over-release / 崩溃）—— 改为 CFRetain 遵循 Copy 契约。
//  2. UA 伪装过滤逻辑错误（原版检查 UA 字符串是否包含购买接口 URL 路径，
//     但 User-Agent 里根本不含 URL，导致伪装永不触发）—— 改为通过关联对象
//     捕获请求 URL，再按 endpoint 过滤。
//  3. 统一常量、加错误安全检查、避免每次调用重复编译正则。
//
// 免责声明：本插件用于 iOS 越狱环境个人学习研究，修改 App Store 请求绕过
// 版本校验违反 Apple 用户协议，可能导致 Apple ID 封禁、设备异常。风险自担。

#import <substrate.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// MGCopyAnswer 是 libMobileGestalt 的私有函数，SDK 不含其头文件。
// 不可在此处声明并直接引用该符号（会导致链接期 "undefined symbol" 错误），
// 改为运行时用 dlsym 取得函数地址后再 hook（见 %ctor）。
typedef CFTypeRef (*MGCopyAnswerFn)(CFStringRef question, uint32_t *outType);

#pragma mark - 偏好读取

static NSString *const kPrefsSuite  = @"com.custom.appstoreversionspoofer";
static NSString *const kPrefEnable  = @"enableSpoof";
static NSString *const kPrefFakeVer  = @"fakeVer";
static NSString *const kDefaultFakeVer = @"15.0";

// 读取伪装版本号；未开启或为空时返回 nil（表示不伪装）。
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

static void (*orig_setValueForHTTPHeaderField)(id, SEL, id, id);
static id   (*orig_initWithURL_cache)(id, SEL, NSURL *, NSURLRequestCachePolicy, NSTimeInterval);
static id   (*orig_initWithURL)(id, SEL, NSURL *);

// 用关联对象把请求 URL 绑定到 request 实例，供后续 setValue: 时按 endpoint 过滤。
static char kRequestURLKey;

static BOOL IsAppleBuyEndpoint(NSString *urlString) {
    if (urlString.length == 0) return NO;
    // 仅针对苹果购买 / 获取类接口，避免污染其它请求。
    return ([urlString containsString:@"MZBuy"]        ||
            [urlString containsString:@"buyProduct"]   ||
            [urlString containsString:@"/buy"]         ||
            [urlString containsString:@"purchase"]);
}

static void HookedSetValueForHTTPHeaderField(id self, SEL _cmd, id value, id field) {
    NSString *fakeVer = GetFakeVersion();
    if (fakeVer && value && [field isEqualToString:@"User-Agent"]) {
        NSURL *url = objc_getAssociatedObject(self, &kRequestURLKey);
        if (IsAppleBuyEndpoint(url.absoluteString)) {
            NSString *ua = (NSString *)value;
            // 编译一次正则缓存到静态变量，避免每次请求重复编译。
            static NSRegularExpression *regex;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                regex = [NSRegularExpression regularExpressionWithPattern:@"iOS/[0-9.]+"
                                                                  options:NSRegularExpressionCaseInsensitive
                                                                    error:nil];
            });
            NSString *newUA = [regex stringByReplacingMatchesInString:ua
                                                              options:0
                                                                range:NSMakeRange(0, ua.length)
                                                         withTemplate:[NSString stringWithFormat:@"iOS/%@", fakeVer]];
            if (newUA) {
                value = newUA;
            }
        }
    }
    orig_setValueForHTTPHeaderField(self, _cmd, value, field);
}

static id HookedInitWithURLCache(id self, SEL _cmd, NSURL *URL, NSURLRequestCachePolicy policy, NSTimeInterval timeout) {
    id req = orig_initWithURL_cache(self, _cmd, URL, policy, timeout);
    if (URL) {
        objc_setAssociatedObject(req, &kRequestURLKey, URL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return req;
}

static id HookedInitWithURL(id self, SEL _cmd, NSURL *URL) {
    id req = orig_initWithURL(self, _cmd, URL);
    if (URL) {
        objc_setAssociatedObject(req, &kRequestURLKey, URL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return req;
}

#pragma mark - 本地 ProductVersion 伪装

static MGCopyAnswerFn orig_MGCopyAnswer = NULL;

static CFTypeRef HookedMGCopyAnswer(CFStringRef key, uint32_t *outType) {
    NSString *fakeVer = GetFakeVersion();
    NSString *k = (__bridge NSString *)key;
    if (fakeVer && [k isEqualToString:@"ProductVersion"]) {
        // MGCopyAnswer 是 CoreFoundation 的 "Copy" 语义：调用方拥有返回值并负责
        // CFRelease。必须使用 CFRetain 转移所有权，否则原版 __bridge 不 retain
        // 会造成 over-release / 随机崩溃。
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
                        @selector(initWithURL:cachePolicy:timeoutInterval:),
                        (IMP)HookedInitWithURLCache,
                        (IMP *)&orig_initWithURL_cache);
        MSHookMessageEx(reqCls,
                        @selector(initWithURL:),
                        (IMP)HookedInitWithURL,
                        (IMP *)&orig_initWithURL);
    }
    // 运行时取 MGCopyAnswer 函数地址（避免链接期引用私有符号），
    // 再用 MSHookFunction 模板重载 hook；HookedMGCopyAnswer 签名需与之一致。
    MGCopyAnswerFn mgFn = (MGCopyAnswerFn)dlsym(RTLD_DEFAULT, "MGCopyAnswer");
    if (mgFn) {
        MSHookFunction(mgFn, HookedMGCopyAnswer, &orig_MGCopyAnswer);
    }
}
