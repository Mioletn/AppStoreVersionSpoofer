// i16.h —— 「iOS 16 在 iOS 12 上」这一层的公开接口
//
// 设计原则（决定了很多实现长什么样）：
//
//   1. 只做用户态。任何需要内核、kext、守护进程配合的东西，一律标 gap，
//      不假装能补 —— 假装的代价是调用方崩在更难定位的地方。
//   2. 补的每个 API 都要能"就地验证"。所以每个特性带一个 demo block，
//      在设备上真跑一遍，状态是跑出来的，不是写死的。
//   3. 不覆盖系统已存在的实现。所有 install 都先查有没有，有就放手。
//      同一份 dylib 注入到 iOS 15 的进程里也不会把系统 API 弄坏。

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, I16State) {
    I16StateNative = 0,   // 12.2 本来就有，不需要做什么
    I16StateShim,         // 本层实现，语义对齐
    I16StateApprox,       // 本层实现，但只是近似（外观对得上，行为有差）
    I16StateGap,          // 补不了，note 里写明卡在哪
};

@interface I16Feature : NSObject
@property (nonatomic, copy)   NSString *title;
@property (nonatomic, copy)   NSString *api;
@property (nonatomic, copy)   NSString *since;
@property (nonatomic, assign) I16State  state;
@property (nonatomic, copy)   NSString *note;
// 真跑一次，返回一行结果文本。nil 表示这项只有静态信息。
@property (nonatomic, copy)   NSString *(^demo)(void);
@end

@interface I16Catalog : NSObject
+ (NSArray<I16Feature *> *)all;
+ (NSString *)labelForState:(I16State)s;
@end

// ---- 各模块的安装入口。重复调用安全（幂等）。----
FOUNDATION_EXPORT void I16ColorInstall(void);
FOUNDATION_EXPORT void I16MenuInstall(void);
FOUNDATION_EXPORT void I16TypeInstall(void);
FOUNDATION_EXPORT void I16ListInstall(void);
FOUNDATION_EXPORT void I16SymbolInstall(void);

// ---- 各模块的自检，返回一行人话 ----
FOUNDATION_EXPORT NSString *I16ColorDemo(void);
FOUNDATION_EXPORT NSString *I16MenuDemo(void);
FOUNDATION_EXPORT NSString *I16TypeDemo(void);
FOUNDATION_EXPORT NSString *I16ListDemo(void);
FOUNDATION_EXPORT NSString *I16SymbolDemo(void);

// 把清单里每一项的 demo 都真跑一遍，返回完整报告。
// 这项存在的理由：光看"进程活着"不能证明 API 真的被调通了 —— 要看到返回值。
FOUNDATION_EXPORT NSString *I16RunSelfTest(void);
