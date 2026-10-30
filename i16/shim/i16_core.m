// i16_core.m —— 能力清单
//
// 这张表是"iOS 16 在 iOS 12 上"的全部答案。每条都写清楚：补到什么程度、
// 卡在哪。标 gap 的不粉饰 —— 一项假装能补的 API，比明说补不了危险得多。

#import "i16.h"
#import <UIKit/UIKit.h>

@implementation I16Feature
@end

@implementation I16Catalog

+ (NSString *)labelForState:(I16State)s {
    switch (s) {
        case I16StateNative: return @"原生";
        case I16StateShim:   return @"已实现";
        case I16StateApprox: return @"近似";
        case I16StateGap:    return @"不可补";
    }
    return @"?";
}

static I16Feature *mk(NSString *title, NSString *api, NSString *since,
                      I16State state, NSString *note,
                      NSString *(^demo)(void)) {
    I16Feature *f = [I16Feature new];
    f.title = title;
    f.api   = api;
    f.since = since;
    f.state = state;
    f.note  = note;
    f.demo  = demo;
    return f;
}

+ (NSArray<I16Feature *> *)all {
    static NSArray *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *a = [NSMutableArray array];

        // ============================================================ 已实现
        [a addObject:mk(@"语义色", @"UIColor.labelColor 等 30 个角色色", @"iOS 13",
                        I16StateShim,
                        @"角色 → 固定值映射。12.2 没有动态外观，取明亮外观下的标准值；补的是「角色」这件事本身，调用方不再 unrecognized selector。",
                        ^NSString *{ return I16ColorDemo(); })];

        [a addObject:mk(@"文件类型", @"UTType / -conformsToType:", @"iOS 14",
                        I16StateShim,
                        @"给 12.2 一直就有的 UTI 套上 14 的面向对象门面。一致性判断直接交给系统的 UTTypeConformsTo，不自己编类型表。",
                        ^NSString *{ return I16TypeDemo(); })];

        // ============================================================ 近似
        [a addObject:mk(@"菜单", @"UIAction / UIMenu / UIContextMenu", @"iOS 13",
                        I16StateApprox,
                        @"数据层完整：构造、两层嵌套、handler 全通。呈现层降到 actionSheet —— 项数和行为对得上，浮层外观没有。",
                        ^NSString *{ return I16MenuDemo(); })];

        [a addObject:mk(@"列表外观", @"UIListContentConfiguration", @"iOS 14",
                        I16StateApprox,
                        @"配置对象是真的：text / secondaryText / image 写进 cell 再读回来，值一致。UITableViewCell 侧用 class_addMethod 补 setter，iOS 14+ 上系统实现优先。差异在布局层：14 的配置参与自适应高度和多行 accessory，12.2 的 textLabel 是固定 frame，复杂布局对不齐。",
                        ^NSString *{ return I16ListDemo(); })];

        [a addObject:mk(@"SF Symbols", @"UIImage systemImageNamed:", @"iOS 13",
                        I16StateApprox,
                        @"字形是真的：4340 个名字（4128 个字形 + 212 条老名别名），一页一个的矢量 PDF（页尺寸=符号固有尺寸），运行时用 CGPDFPage 按目标点高重新光栅化 —— 是矢量重画，不是位图放大，所以形状、宽高比、任意尺寸都对，且是模板图能跟 tintColor 变色。直接搬 iOS 16.5 的 Assets.car 走不通：12.2 的 CUICatalog 认得出 4824 个名字，但 90 种参数组合取图全 nil，私有矢量入口还会断言崩溃——car 里的 rendition 是 dmp2+LZFSE，CoreUI 12 解不开。近似在字重：只有 regular，bold/light 是另一套轮廓，这份素材里没有，weight 收得下但不生效。",
                        ^NSString *{ return I16SymbolDemo(); })];

        // ============================================================ 不可补
        [a addObject:mk(@"深色模式", @"UITraitCollection.userInterfaceStyle", @"iOS 13",
                        I16StateGap,
                        @"外观由 SpringBoard 经窗口服务下发，12.2 没有这条通道。用户态改不了系统画出来的东西，只能改自己视图里的颜色。",
                        nil)];

        [a addObject:mk(@"场景生命周期", @"UIScene / UIWindowScene", @"iOS 13",
                        I16StateGap,
                        @"12.2 的 UIKit 只有 UIApplicationDelegate 一套窗口生命周期，没有 scene 会话层。模拟只能覆盖冷启动，多窗口和状态恢复做不到。",
                        nil)];

        [a addObject:mk(@"SwiftUI", @"SwiftUI 框架", @"iOS 13",
                        I16StateGap,
                        @"需要 Swift 运行时加整套声明式渲染框架，且深度依赖 13 的 CoreAnimation 新接口。用户态重写等于重做一个框架。",
                        nil)];

        [a addObject:mk(@"Combine", @"Publisher / AnyCancellable", @"iOS 13",
                        I16StateGap,
                        @"纯 Swift 库，随系统二进制分发。没有 Swift 运行时就没有它，和上一条卡在同一处。",
                        nil)];

        [a addObject:mk(@"组合布局", @"UICollectionViewCompositionalLayout", @"iOS 13",
                        I16StateGap,
                        @"要在 12.2 的 UICollectionViewLayout 上重写一套布局引擎（group、orthogonal scrolling、estimated 尺寸）。工程量大但原理可行，目前没做。",
                        nil)];

        [a addObject:mk(@"差异数据源", @"UICollectionViewDiffableDataSource", @"iOS 13",
                        I16StateGap,
                        @"依赖 13 的 diffable snapshot 与 collection view 的新批量更新路径。可以自己算 diff 再 reload，但会和调用方对动画的假设冲突。",
                        nil)];

        [a addObject:mk(@"触觉引擎", @"CoreHaptics", @"iOS 13",
                        I16StateGap,
                        @"A12X 的 iPad 没有 Taptic Engine，通道本身不存在。可以给全套桩让它不崩（i12s.dylib 已经在做），但那不叫实现。",
                        nil)];

        list = [a copy];
    });
    return list;
}

@end

// ---------------------------------------------------------------- 自检
// 为什么需要它：面板上写"已实现"，去看一眼界面并不能证明 API 真的调通了。
// 这个函数把每一项的 demo 都执行一遍，把返回值原样记下来 —— 屏幕上看到
// "label=0.00,0.00,0.00" 和文件里记着同一句话，才算证据。
NSString *I16RunSelfTest(void) {
    NSMutableString *s = [NSMutableString string];
    UIDevice *d = [UIDevice currentDevice];
    // 记 host bundle id：同一份报告，在 i16 自己进程里和在别人进程里含义完全不同。
    NSString *host = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
    [s appendFormat:@"i16 selftest · host=%@ · %@ · %@ %@\n\n",
                    host, d.model, d.systemName, d.systemVersion];

    I16ColorInstall();
    I16MenuInstall();
    I16TypeInstall();
    I16ListInstall();
    I16SymbolInstall();

    NSInteger ran = 0, bad = 0;
    for (I16Feature *f in [I16Catalog all]) {
        if (!f.demo) {
            [s appendFormat:@"[跳过] %@ —— 标为「%@」，没有可执行 demo\n",
                            f.title, [I16Catalog labelForState:f.state]];
            continue;
        }
        NSString *r = nil;
        @try {
            r = f.demo();
        } @catch (NSException *e) {
            r = [NSString stringWithFormat:@"!! 抛异常 %@: %@", e.name, e.reason];
            bad++;
        }
        if (!r) {
            r = @"(demo 返回 nil)";
            bad++;
        }
        ran++;
        [s appendFormat:@"[%@] %@ (%@)\n    %@\n",
                        [I16Catalog labelForState:f.state], f.title, f.since, r];
    }
    [s appendFormat:@"\n执行 %ld 项，异常 %ld 项\n", (long)ran, (long)bad];
    return s;
}
