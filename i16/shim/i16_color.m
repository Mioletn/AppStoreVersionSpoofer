// i16_color.m —— iOS 13 的语义色，用 iOS 12 的固定色实现出来
//
// 为什么这一项最值得先补：
//   iOS 13 起，UIKit 把"颜色"从"具体值"改成了"语义角色"。App 里写
//   `UIColor.labelColor` 表达的是"正文该有的颜色"，具体是黑是白由系统按
//   外观决定。iOS 12 只有具体值，没有这层角色。
//
//   影响面极大：任何一个用 iOS 13+ SDK 编译的 App，只要碰过
//   systemBackgroundColor / labelColor / separatorColor，在 12.2 上就是
//   unrecognized selector。这一步补上，很多 App 的第一个界面就能画出来。
//
// 怎么补：12.2 没有动态外观，所以每个角色给一个固定值 —— 取明亮外观下的
// 标准值。这不是"假装支持深色模式"，是把"角色"这件事先补上，让调用方别崩；
// 真深色模式需要系统的 appearance 通道，那不在用户态能解决的范围里。
//
// 组织方式：X-Macro。每个颜色只在 I16_COLOR_LIST 里写一次，然后被展开两遍 ——
// 一遍在文件作用域生成 C 函数（C 不允许函数里套函数定义，早先的写法就栽在这），
// 一遍在安装函数里生成 class_addMethod 调用。

#import "i16.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// 下面这些 selector 的名字来自 iOS 13+，12.4 的 SDK 头文件里没有。
// @selector() 里写字面量会被 clang 判为「未声明的 selector」，这里只是警告，
// 不是错误 —— 但把警告关掉，真正的错误才好看。
#pragma clang diagnostic ignored "-Wundeclared-selector"

static void i16_add_class_method(Class cls, SEL sel, IMP imp, const char *types) {
    // 有就放手：注入到 13+ 的进程里时，系统实现必须优先。
    if (class_getClassMethod(cls, sel)) return;
    class_addMethod(object_getClass(cls), sel, imp, types);
}

// ---------------------------------------------------------------- 颜色表
// 每行：selector 名字, 实现体。值取 iOS 13 明亮外观下的标准色。
#define I16_COLOR_LIST(X)                                                       \
    /* ---- 背景层级（iOS 13）---- */                                            \
    X(systemBackgroundColor,             [UIColor whiteColor])                  \
    X(secondarySystemBackgroundColor,                                            \
      [UIColor colorWithWhite:0.949f alpha:1.0f])                               \
    X(tertiarySystemBackgroundColor,     [UIColor whiteColor])                  \
    /* ---- 分组列表背景（iOS 13）---- */                                        \
    X(systemGroupedBackgroundColor,                                              \
      [UIColor colorWithWhite:0.949f alpha:1.0f])                               \
    X(secondarySystemGroupedBackgroundColor, [UIColor whiteColor])              \
    X(tertiarySystemGroupedBackgroundColor,                                      \
      [UIColor colorWithWhite:0.949f alpha:1.0f])                               \
    /* ---- 文字层级（iOS 13）---- */                                            \
    X(labelColor,                        [UIColor blackColor])                  \
    X(secondaryLabelColor,               [UIColor colorWithWhite:0.235f alpha:0.6f])  \
    X(tertiaryLabelColor,                [UIColor colorWithWhite:0.235f alpha:0.3f])  \
    X(quaternaryLabelColor,              [UIColor colorWithWhite:0.235f alpha:0.18f]) \
    X(placeholderTextColor,              [UIColor colorWithWhite:0.235f alpha:0.3f])  \
    /* ---- 分隔线 / 填充（iOS 13）---- */                                        \
    X(separatorColor,                    [UIColor colorWithWhite:0.235f alpha:0.29f]) \
    X(opaqueSeparatorColor,              [UIColor colorWithWhite:0.776f alpha:1.0f])  \
    X(systemFillColor,                   [UIColor colorWithWhite:0.471f alpha:0.2f])  \
    X(secondarySystemFillColor,          [UIColor colorWithWhite:0.471f alpha:0.16f]) \
    X(tertiarySystemFillColor,           [UIColor colorWithWhite:0.471f alpha:0.12f]) \
    X(quaternarySystemFillColor,         [UIColor colorWithWhite:0.463f alpha:0.08f]) \
    /* ---- 系统强调色（iOS 13 的标准值）---- */                                  \
    X(systemBlueColor,                   [UIColor colorWithRed:0.000f green:0.478f blue:1.000f alpha:1.0f]) \
    X(systemGreenColor,                  [UIColor colorWithRed:0.204f green:0.780f blue:0.349f alpha:1.0f]) \
    X(systemIndigoColor,                 [UIColor colorWithRed:0.345f green:0.337f blue:0.839f alpha:1.0f]) \
    X(systemOrangeColor,                 [UIColor colorWithRed:1.000f green:0.584f blue:0.000f alpha:1.0f]) \
    X(systemPinkColor,                   [UIColor colorWithRed:1.000f green:0.176f blue:0.333f alpha:1.0f]) \
    X(systemPurpleColor,                 [UIColor colorWithRed:0.686f green:0.322f blue:0.871f alpha:1.0f]) \
    X(systemRedColor,                    [UIColor colorWithRed:1.000f green:0.231f blue:0.188f alpha:1.0f]) \
    X(systemTealColor,                   [UIColor colorWithRed:0.188f green:0.690f blue:0.780f alpha:1.0f]) \
    X(systemYellowColor,                 [UIColor colorWithRed:1.000f green:0.800f blue:0.000f alpha:1.0f]) \
    X(systemGrayColor,                   [UIColor colorWithRed:0.557f green:0.557f blue:0.576f alpha:1.0f]) \
    X(systemGray2Color,                  [UIColor colorWithRed:0.682f green:0.682f blue:0.698f alpha:1.0f]) \
    X(linkColor,                         [UIColor colorWithRed:0.000f green:0.478f blue:1.000f alpha:1.0f]) \
    /* iOS 15 的 —— Builder 生成的界面会碰 */                                    \
    X(tintColor,                         [UIColor colorWithRed:0.000f green:0.478f blue:1.000f alpha:1.0f])

// 第一遍：文件作用域，生成 30 个 C 函数。返回值走 x0，签名是 "@@:"。
#define I16_DEF(name, body) \
    static id i16_##name(id self, SEL _cmd) { return (body); }
I16_COLOR_LIST(I16_DEF)
#undef I16_DEF

static void I16ColorInstallOnce(void) {
    static int done = 0;
    if (done) return;
    done = 1;

    // 第二遍：在安装函数里生成注册调用。
#define I16_REG(name, body) \
    i16_add_class_method([UIColor class], @selector(name), (IMP)i16_##name, "@@:");
    I16_COLOR_LIST(I16_REG)
#undef I16_REG
}

void I16ColorInstall(void) { I16ColorInstallOnce(); }

// 取一个语义色。名字是字符串，因为 12.4 的 UIColor.h 里根本没有这些声明，
// 直接写 [UIColor systemBackgroundColor] 是编译错误，不是运行时问题。
static UIColor *i16_color_by_name(NSString *name) {
    SEL s = NSSelectorFromString(name);
    if (![[UIColor class] respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)([UIColor class], s);
}

NSString *I16ColorDemo(void) {
    I16ColorInstall();

    // 真去取一遍。取不到会抛 unrecognized selector，正是我们要排除的情况。
    UIColor *bg  = i16_color_by_name(@"systemBackgroundColor");
    UIColor *lb  = i16_color_by_name(@"labelColor");
    UIColor *sep = i16_color_by_name(@"separatorColor");
    if (!bg || !lb || !sep) return @"语义色取到了 nil，安装没生效";

    // 不能走 CGColorGetComponents：blackColor / whiteColor 是灰度色彩空间，
    // 只有 2 个分量，读 c[2] 是越界。getRed:green:blue:alpha: 会自己做转换。
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [lb getRed:&r green:&g blue:&b alpha:&a];

    CGFloat sepAlpha = 0;
    [sep getRed:NULL green:NULL blue:NULL alpha:&sepAlpha];

    return [NSString stringWithFormat:
            @"systemBackground 分量=%d  label=%.2f,%.2f,%.2f  separator alpha=%.2f",
            (int)(CGColorGetNumberOfComponents(bg.CGColor)),
            r, g, b, sepAlpha];
}
