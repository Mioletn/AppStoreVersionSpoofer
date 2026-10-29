// ios12stub — 给 iOS 12.2 补"这台机器上根本没有"的系统库
//
// 背景：iOS 13+ 编出来的 App，load commands 里会挂上一批本机不存在的库
// （CoreHaptics、libswiftUniformTypeIdentifiers…）。iOS 12.2 的 dyld 遇到
// "image not found" 直接 abort，连 App 的第一行代码都跑不到 —— 哪怕那些库
// 一次都没被真正调用（Swift autolink 会把 import 到的模块的库硬塞进来）。
//
// 这里提供一个 dylib，把所有这类库需要的符号都导出来。安装时由 patch_deps.py
// 把 App 里那几条 load command 的路径改指到这里，一份桩库顶五份。
//
// 两类符号：
//   1. __swift_FORCE_LOAD_$_*  —— 纯占位，Swift 编译器为了让链接器别优化掉那条
//      LC_LOAD_DYLIB 而生成的。永远不被调用，有定义就够。
//   2. 真 API（目前是 CoreHaptics）—— 用 resolveInstanceMethod/resolveClassMethod
//      动态挂 no-op，任何 selector 都不会 unrecognized 崩掉，统一返回 nil/0。
//      触觉反馈在这台机器上本来就没有硬件支持，做成静音是正确行为。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdlib.h>

// ---------------------------------------------------------------- Swift autolink 占位符
// `$` 在 clang 标识符里合法，正好对上符号名，不用写 __asm__ 别名。
char _swift_FORCE_LOAD_$_swiftDataDetection;
char _swift_FORCE_LOAD_$_swiftFileProvider;
char _swift_FORCE_LOAD_$_swiftOSLog;
char _swift_FORCE_LOAD_$_swiftUniformTypeIdentifiers;
char _swift_FORCE_LOAD_$_swiftSpatial;
char _swift_FORCE_LOAD_$_swift_Concurrency;
char _swift_FORCE_LOAD_$_swiftObservation;
char _swift_FORCE_LOAD_$_swiftRegexBuilder;
char _swift_FORCE_LOAD_$_swiftCrypto;
char _swift_FORCE_LOAD_$_swiftDistributed;
char _swift_FORCE_LOAD_$_swift_StringProcessing;

// ---------------------------------------------------------------- 万能 no-op
// arm64 上所有返回值走 x0，统一清 0 就等价于"返回 nil / 0 / false / 0.0"。
// 结构体返回值走 x8 间接寻址，这里不写内存，调用方拿到的是栈上残值 ——
// 对这些"反正没硬件"的 API 来说可以接受。
__attribute__((naked)) static void mp_noop(void) {
    __asm__ volatile("mov x0, #0\n\tret");
}

static BOOL mp_resolve_instance(id self, SEL _cmd, SEL sel) {
    // self 是类对象，实例方法挂在它身上
    class_addMethod(self, sel, (IMP)mp_noop, "v@:");
    return YES;
}

static BOOL mp_resolve_class(id self, SEL _cmd, SEL sel) {
    // 类方法要挂到元类上
    class_addMethod(object_getClass(self), sel, (IMP)mp_noop, "v@:");
    return YES;
}

// ---------------------------------------------------------------- CoreHaptics
// 只实现类本体；方法全部由 resolve*Method 兜住。
// Moonlight / 各类播放器用它的地方都是"有则震一下"，静音不影响功能。

@interface CHHapticEngine : NSObject
@end
@interface CHHapticPattern : NSObject
@end
@interface CHHapticEvent : NSObject
@end
@interface CHHapticEventParameter : NSObject
@end
@interface CHHapticDynamicParameter : NSObject
@end
@interface CHHapticParameterCurve : NSObject
@end
@interface CHHapticParameterCurveControlPoint : NSObject
@end
@interface CHHapticAdvancedPatternPlayer : NSObject
@end

#define MP_NOOP_CLASS(NAME)                                    \
    @implementation NAME                                       \
    + (BOOL)resolveInstanceMethod:(SEL)sel {                   \
        return mp_resolve_instance(self, _cmd, sel);           \
    }                                                          \
    + (BOOL)resolveClassMethod:(SEL)sel {                      \
        return mp_resolve_class(self, _cmd, sel);              \
    }                                                          \
    @end

MP_NOOP_CLASS(CHHapticEngine)
MP_NOOP_CLASS(CHHapticPattern)
MP_NOOP_CLASS(CHHapticEvent)
MP_NOOP_CLASS(CHHapticEventParameter)
MP_NOOP_CLASS(CHHapticDynamicParameter)
MP_NOOP_CLASS(CHHapticParameterCurve)
MP_NOOP_CLASS(CHHapticParameterCurveControlPoint)
MP_NOOP_CLASS(CHHapticAdvancedPatternPlayer)

// ================================================================ iOS 13 才导出的运行时符号
//
// 这一组是"用 iOS 13+ SDK 编出来的二进制"在 12.2 上的第一道坎，与框架无关：
// 编译器会内联生成对这些快速路径函数的调用，而 iOS 12.2 的 libobjc 里
// 它们是**内部函数，未导出**（实测 dlsym 全为 0）。dyld 绑定阶段直接
//   Symbol not found: _objc_opt_class
// 连 main 都进不去。
//
// 用 __asm__ 标签把 C 名和导出符号名分开：C 名的下划线与符号名无关，
// 汇编器统一加一个前导下划线（这条在 force-load 占位符上踩过一次）。

// 等价实现就是运行时自己的公开 API —— 苹果内部那版只是为了省掉一次
// objc_msgSend 的分支预测开销，语义完全一致。
//
// PP_HIT：PPTRACE=1 时报告"我被调到了"（每符号最多两次，避免刷屏）。
// 用来区分"符号没接上"和"接上了但语义不对"这两种失败。
extern void pp_note(const char *what);

static int pp_on(void) {
    static int v = -1;
    if (v < 0) v = getenv("PPTRACE") ? 1 : 0;
    return v;
}

#define PP_HIT() do { \
    static int _ppn = 0; \
    if (_ppn < 2 && pp_on()) { _ppn++; pp_note(__func__); } \
} while (0)

Class mp_objc_opt_class(id obj) __asm__("_objc_opt_class");
Class mp_objc_opt_class(id obj) {
    PP_HIT();
    return object_getClass(obj);           // tagged pointer 也走这条，正确
}

BOOL mp_objc_opt_isKindOfClass(id obj, Class cls) __asm__("_objc_opt_isKindOfClass");
BOOL mp_objc_opt_isKindOfClass(id obj, Class cls) {
    PP_HIT();
    return [obj isKindOfClass:cls];
}

BOOL mp_objc_opt_respondsToSelector(id obj, SEL sel) __asm__("_objc_opt_respondsToSelector");
BOOL mp_objc_opt_respondsToSelector(id obj, SEL sel) {
    PP_HIT();
    return [obj respondsToSelector:sel];
}

// 只在 12 上补：13+ 若也导出了同名符号，动态库加载时以先到者为准，
// 但我们的 App 场景里 12 是唯一目标，没有歧义。
id mp_objc_opt_new(Class cls) __asm__("_objc_opt_new");
id mp_objc_opt_new(Class cls) {
    PP_HIT();
    return [[cls alloc] init];
}

Class mp_objc_opt_self(id obj) __asm__("_objc_opt_self");
Class mp_objc_opt_self(id obj) {
    PP_HIT();
    return object_getClass(obj);
}

// ---------------------------------------------------------------- __availability_version_check
// clang 的 @available / __builtin_available 会编译成对它的调用，参数是
// (请求的版本号, dyld 提供的版本信息指针)，返回"当前系统是否满足"。
//
// 这里返回 0 —— 即"不满足" —— 让所有 @available(iOS 13, *) 都走 else 分支。
// 这是刻意的：返回 1 会让 App 直接调用本机不存在的新 API，崩在更难定位的地方；
// 返回 0 只是让它退化到兼容路径，行为可预期。
BOOL mp_avail_check(void) __asm__("___availability_version_check");
BOOL mp_avail_check(void) {
    PP_HIT();
    return 0;
}

// ---------------------------------------------------------------- CoreFoundation 的私有常量
// 这两个符号在 iOS 13+ 的 CoreFoundation 里存在，12.2 里没有（实测 dlsym = 0）。
// 它们是**变量**，App 绑定后拿到的是变量地址，所以要给出"内容也是对的"的值。

// 空字典单例。__NSDictionary0 没有实例变量，只有 isa，
// 所以把真单例的 isa 拷过来，这份副本就能当合法的空字典用（count 恒为 0）。
__attribute__((used, visibility("default")))
void *__NSDictionary0__struct[4];          // C 名 → 符号 ___NSDictionary0__struct

// CFBoolean 的 false 单例，是个 CFBooleanRef（指针变量）。
__attribute__((used, visibility("default")))
const void *__kCFBooleanFalse;             // C 名 → 符号 ___kCFBooleanFalse

// ---------------------------------------------------------------- NSConstantArray
// `@[...]` 字面量在 clang 里编译成对 NSConstantArray 类发 arrayWithObjects:count:。
// 12.2 上这个类叫 __NSConstantArray 且不导出，所以补一个同名公开类，
// 类方法直接转交给 NSArray —— 不 alloc 自己，避免实例缺少存取方法。
// 名字没有前缀冲突：12.2 的 Foundation 里只有私有的 __NSConstantArray。
@interface NSConstantArray : NSArray
@end

@implementation NSConstantArray
// 签名必须和 NSArray 的声明对齐（ARC 下 const id* 默认 __autoreleasing，
// 而 Foundation 用的是 __unsafe_unretained）。这套 clang 不认 instancetype，
// 用 id + 显式 cast。
+ (id)arrayWithObjects:(const id __unsafe_unretained * _Nonnull)objects
                 count:(NSUInteger)cnt {
    PP_HIT();
    // 不 alloc 自己：直接返回真 NSArray，避免这个类缺少存取方法
    return (id)[NSArray arrayWithObjects:objects count:cnt];
}
@end

// 上面两个常量要在 Foundation 起来之后才有真值可抄。
__attribute__((constructor)) static void mp_fill_cf_constants(void) {
    id empty = [NSDictionary new];
    if (empty) {
        // 只搬 isa：__NSDictionary0 无非 isa 实例变量，
        // 多抄反而会碰上对象实际尺寸不确定的问题。
        __NSDictionary0__struct[0] = *(void **)(__bridge void *)empty;
    }
    // kCFBooleanFalse 也是变量，dlsym 拿到的是它的地址，要解一层引用。
    void **b = (void **)dlsym(RTLD_DEFAULT, "kCFBooleanFalse");
    if (b && *b) {
        __kCFBooleanFalse = *b;
    } else {
        __kCFBooleanFalse = (__bridge const void *)[NSNumber numberWithBool:NO];
    }
    if (pp_on()) pp_note(__kCFBooleanFalse ? "cf-const:ok" : "cf-const:null");
}

// 这几个是 NSString* 常量，Swift 侧按 struct 包一层（CHHapticEventType 之类）。
// 值本身没人读，给个稳定的空串即可；要的是符号存在，好让 dyld 绑定成功。
NSString *CHHapticEventTypeHapticTransient = @"";
NSString *CHHapticEventTypeHapticContinuous = @"";
NSString *CHHapticEventTypeAudioContinuous = @"";
NSString *CHHapticEventTypeAudioCustom = @"";
NSString *CHHapticEventParameterIDHapticIntensity = @"";
NSString *CHHapticEventParameterIDHapticSharpness = @"";
NSString *CHHapticEventParameterIDAudioVolume = @"";
NSString *CHHapticEventParameterIDAudioPitch = @"";
NSString *CHHapticEventParameterIDAudioBrightness = @"";
NSString *CHHapticDynamicParameterIDHapticIntensityControl = @"";
NSString *CHHapticDynamicParameterIDHapticSharpnessControl = @"";
NSString *CHHapticDynamicParameterIDAudioVolumeControl = @"";
NSString *CHHapticDynamicParameterIDAudioPitchControl = @"";
NSString *CHHapticDynamicParameterIDAudioBrightnessControl = @"";
