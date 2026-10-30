// i16_symbol.m —— SF Symbols：在 12.2 上让 systemImageNamed: 画出真字形
//
// 这一项和其他几项性质不同：别的条目缺的是**代码**，SF Symbols 缺的是**字形**。
// 12.2 系统里没有这些矢量图，重写代码也画不出来。所以这件事只有「搬资源」一条路，
// 差别只在搬什么、以什么形态搬。下面这段是**实测过的取舍**，不是拍脑袋：
//
// —— 走过的第一条路：直接搬 iOS 16.5 的 CoreGlyphs.bundle（Assets.car，5115 个符号）
//    12.2 的 CUICatalog 确实能打开它（入口是 +defaultUICatalogForBundle:，
//    不是 13+ 文档里的 catalogWithName:fromBundle:），能枚举出 4824 个名字，
//    imageExistsWithName:@"heart.fill" 也返回 1 —— 名字这一层完全通。
//    但取图这一层不通：
//      · imageWithName:scaleFactor:deviceIdiom:deviceSubtype: 在
//        3 尺度 × 3 体型 × 10 子类型 = 90 种组合下全部返回 nil
//      · 换 12.2 的私有入口 _namedVectorImageWithName:...（9 个参数，含 appearance）
//        直接触发 CoreUI 断言崩溃（_CUIRenditionKeySetIntegerValueForAttribute）
//    根因在 rendition 的负载：car 里全是 dmp2 + bvx2（LZFSE）包起来的矢量，
//    12.2 的 CoreUI 生成于这套格式之前 —— 挑得出条目，解不开数据。
//    （顺带确认过：12.2 的 libcompression 自己能解 LZFSE，解出 92992 字节。
//      所以不是系统没能力，是 CoreUI 那一层不走这条路。）
//
// —— 现在的这条路：矢量就是矢量，用 PDF 装
//    brendanballon/sfsymbols-svg 从 SF Symbols 字体导出了 6404 个 SVG，
//    单 path、只有 M/L/Q/Z。build_symbols.py 把它们合成一份多页 PDF：
//    一页一个符号，页尺寸 = 该符号的固有尺寸，下标即页码。
//    运行时只需要 CoreGraphics —— CGPDFPage 从 iOS 2 起就能画，矢量、无级缩放。
//    和 car 相比少了一层私有容器，也就少了一整类「系统版本对不上」的失败。
//
// 已知的近似（不粉饰）：
//   · 只有 regular 字重。bold / light 是同一符号的另一套轮廓，这份素材里没有，
//     所以 configuration 里的 weight 收得下但不生效。形状对，粗细不对。
//   · 覆盖 4128 个名字（iOS 16.5 的 5115 个里，缺的主要是 .ar/.he/.ja 这类
//     本地化字符符号，它们不在导出集中）。取不到的名字返回 nil，和系统行为一致。

#import "i16.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CoreGraphics/CoreGraphics.h>

// ============================================================ 声明
// 12.4 的 SDK 里没有 iOS 13 的这些方法。编译器对「未知的类方法」是硬报错，
// 不是 warning，所以不能靠 -Wno-objc-method-access 糊过去。
// 这里只写声明、不写实现 —— 实现是运行时 class_addMethod 加上去的。
@interface UIImage (I16SymbolAPI)
+ (UIImage *)systemImageNamed:(NSString *)name;
+ (UIImage *)systemImageNamed:(NSString *)name withConfiguration:(id)configuration;
- (UIImage *)imageWithConfiguration:(id)configuration;
- (BOOL)isSymbolImage;
@end

// UIImageSymbolConfiguration 的工厂方法挂在 NSObject 上声明：
// 调用点的接收者是 Class 类型的变量，clang 会去元类里找 + 方法。
@interface NSObject (I16SymbolConfigAPI)
+ (instancetype)configurationWithPointSize:(CGFloat)pointSize;
+ (instancetype)configurationWithPointSize:(CGFloat)pointSize weight:(long)weight;
+ (instancetype)configurationWithPointSize:(CGFloat)pointSize weight:(long)weight scale:(long)scale;
+ (instancetype)configurationWithWeight:(long)weight;
+ (instancetype)configurationWithScale:(long)scale;
+ (instancetype)unspecifiedConfiguration;
@end

static void *I16Imp(id obj, const char *name) {
    if (!obj) return NULL;
    SEL s = sel_registerName(name);
    if (![(id)obj respondsToSelector:s]) return NULL;
    return (void *)[(id)obj methodForSelector:s];
}

static BOOL I16AddClassMethod(Class cls, SEL sel, IMP imp, const char *types) {
    if (!cls || class_getClassMethod(cls, sel)) return NO;   // 有就放手
    return class_addMethod(object_getClass(cls), sel, imp, types);
}

static BOOL I16AddInstanceMethod(Class cls, SEL sel, IMP imp, const char *types) {
    if (!cls || class_getInstanceMethod(cls, sel)) return NO;
    return class_addMethod(cls, sel, imp, types);
}

// ============================================================ 资源
// 两个候选位置：
//   1. /Library/i16/     —— 一次装好，所有进程共用，注入到别的 App 也找得到
//   2. App 自己的 bundle —— 便携，但要背着 12MB
static NSString *I16SymbolResource(NSString *file) {
    NSArray *dirs = @[@"/Library/i16"];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *d in dirs) {
        NSString *p = [d stringByAppendingPathComponent:file];
        if ([fm fileExistsAtPath:p]) return p;
    }
    NSString *p = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:file];
    return [fm fileExistsAtPath:p] ? p : nil;
}

static NSString *I16SymbolLastError;

// 名字 -> {页号, 宽, 高}。索引是 JSON，读一次常驻。
static NSDictionary *I16SymbolIndex(void) {
    static NSDictionary *idx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *p = I16SymbolResource(@"i16symbols.json");
        if (!p) { I16SymbolLastError = @"找不到 i16symbols.json"; return; }
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (!d) { I16SymbolLastError = @"索引读不出来"; return; }

        NSDictionary *raw = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        NSArray *names = raw[@"names"], *sizes = raw[@"sizes"];
        if (names.count != sizes.count) { I16SymbolLastError = @"索引里名字与尺寸数量不一致"; return; }

        NSMutableDictionary *m = [NSMutableDictionary dictionaryWithCapacity:names.count];
        for (NSUInteger i = 0; i < names.count; i++) {
            NSArray *wh = sizes[i];
            if (wh.count < 2) continue;
            m[names[i]] = @{ @"p": @(i + 1),          // PDF 页码从 1 开始
                             @"w": wh[0], @"h": wh[1] };
        }
        // 别名直接摊平进同一张表：调用方拿老名字查，命中的是同一个页。
        // 素材来自更新的导出集，有些符号改过名（battery.100 -> battery.100percent），
        // 不接线的话这些名字会返回 nil，看起来像「这个符号不存在」。
        NSDictionary *alias = raw[@"aliases"];
        if ([alias isKindOfClass:[NSDictionary class]]) {
            [alias enumerateKeysAndObjectsUsingBlock:^(NSString *old, NSString *now, BOOL *stop) {
                NSDictionary *meta = m[now];
                if (meta && !m[old]) m[old] = meta;
            }];
        }
        idx = m;
    });
    return idx;
}

// 一份多页 PDF，只开一次。CGPDFDocument 是惰性的，不会把 12MB 全读进内存。
static CGPDFDocumentRef I16SymbolDoc(void) {
    static CGPDFDocumentRef doc;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *p = I16SymbolResource(@"i16symbols.pdf");
        if (!p) { I16SymbolLastError = @"找不到 i16symbols.pdf"; return; }
        doc = CGPDFDocumentCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:p]);
        if (!doc) I16SymbolLastError = @"PDF 打不开";
    });
    return doc;
}

// ============================================================ 取图
// 目标：给定点高，画出等比、且能跟着 tintColor 变色的图。
// 三个决定值得记下来：
//   1. 宽按符号固有宽高比算。符号几乎都不是正方形（heart 比 gear 宽，
//      trash 比 gear 高），一律塞方框会把形状拉歪 —— 肉眼一眼能看出来。
//   2. 画成黑色、透明底，再标成 AlwaysTemplate。模板图只看 alpha，
//      颜色由 tintColor 决定；少了这一步，调用方设了 tintColor 却不变色。
//   3. 每次都是重新光栅化，不是放大旧位图。PDF 是矢量的，放多大都清楚。
static UIImage *I16SymbolRender(NSString *name, CGFloat pointSize, double scale) {
    NSDictionary *meta = I16SymbolIndex()[name];
    if (!meta) { if (!I16SymbolLastError) I16SymbolLastError = @"名字不在索引里"; return nil; }
    CGPDFDocumentRef doc = I16SymbolDoc();
    if (!doc) return nil;

    CGPDFPageRef page = CGPDFDocumentGetPage(doc, [meta[@"p"] unsignedIntValue]);
    if (!page) { I16SymbolLastError = @"页码取不到"; return nil; }

    CGRect box = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
    if (box.size.width <= 1 || box.size.height <= 1) {
        I16SymbolLastError = @"页尺寸异常";
        return nil;
    }

    CGFloat h = pointSize;
    CGFloat w = pointSize * (box.size.width / box.size.height);
    size_t pw = (size_t)lround(w * scale), ph = (size_t)lround(h * scale);
    if (pw < 1 || ph < 1) return nil;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, pw, ph, 8, pw * 4, cs,
                                             kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { I16SymbolLastError = @"位图上下文创建失败"; return nil; }

    // 铺满整块画布：PDF 的 MediaBox 原点是左下、Y 向上，
    // 和 CGBitmapContext 一致，所以不需要额外翻转。
    CGContextScaleCTM(ctx, pw / box.size.width, ph / box.size.height);
    CGContextTranslateCTM(ctx, -box.origin.x, -box.origin.y);
    CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
    CGContextDrawPDFPage(ctx, page);

    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!img) { I16SymbolLastError = @"光栅化失败"; return nil; }

    UIImage *out = [[UIImage alloc] initWithCGImage:img scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(img);
    out = [out imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    objc_setAssociatedObject(out, @selector(isSymbolImage), name, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return out;
}

// 缓存：表格里同一个图标被反复渲染，每次重走一遍光栅化太浪费。
// 简单封顶而不是 LRU —— 实际命中量很小，键里带尺寸，重复率低。
static NSMutableDictionary *I16SymbolCache(void) {
    static NSMutableDictionary *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [NSMutableDictionary dictionary]; });
    return c;
}

static UIImage *I16SymbolImage(NSString *name, CGFloat pointSize, double scale) {
    if (![name isKindOfClass:[NSString class]] || !name.length) return nil;
    if (pointSize <= 0) pointSize = 17.0;      // iOS 的默认字号
    if (scale <= 0) scale = 2.0;

    NSMutableDictionary *cache = I16SymbolCache();
    NSString *key = [NSString stringWithFormat:@"%@|%.1f|%.1f", name, pointSize, scale];
    @synchronized (cache) {
        UIImage *hit = cache[key];
        if (hit) return hit;
        if (cache.count > 300) [cache removeAllObjects];
    }
    UIImage *img = I16SymbolRender(name, pointSize, scale);
    if (img) @synchronized (cache) { cache[key] = img; }
    return img;
}

// ============================================================ 配置对象
// UIImageSymbolConfiguration 在 12.2 上根本不存在，调用方一 [xxx class] 就崩。
// 所以不能只补 systemImageNamed:，得把这个类也造出来。
// 先定义成自己的名字，等运行时确认公开名字还空着，再挂上去 ——
// 直接 @interface UIImageSymbolConfiguration 会在 13+ 上和系统类撞名。
@interface I16SymbolConfiguration : NSObject
@property (nonatomic, assign) CGFloat pointSize;
@property (nonatomic, assign) long weight;
@property (nonatomic, assign) long scale;
@end

@implementation I16SymbolConfiguration
@end

static CGFloat I16SymbolConfigPointSize(id cfg) {
    if (cfg && [cfg respondsToSelector:@selector(pointSize)]) {
        return ((CGFloat (*)(id, SEL))[cfg methodForSelector:@selector(pointSize)])
               (cfg, @selector(pointSize));
    }
    return 0;
}

static id I16SymbolCfgMake(Class cls, CGFloat pt, BOOL hasW, long w, BOOL hasS, long sc) {
    if (!cls) return nil;
    I16SymbolConfiguration *c = (I16SymbolConfiguration *)[cls alloc];
    c = [c init];
    c.pointSize = pt;
    c.weight = hasW ? w : -1;   // -1 = 未指定，对应 iOS 的 UIImageSymbolWeightUnspecified
    c.scale  = hasS ? sc : -1;
    return c;
}

// ============================================================ 安装
void I16SymbolInstall(void) {
    static BOOL done;
    if (done) return;
    done = YES;

    Class UI = [UIImage class];

    // ---- 1) UIImageSymbolConfiguration（12.2 完全没有这个类）
    if (!objc_getClass("UIImageSymbolConfiguration")) {
        Class pair = objc_allocateClassPair([I16SymbolConfiguration class],
                                            "UIImageSymbolConfiguration", 0);
        if (pair) {
            objc_registerClassPair(pair);
            I16AddClassMethod(pair, @selector(configurationWithPointSize:),
                imp_implementationWithBlock(^id(id cls, CGFloat pt) {
                    return I16SymbolCfgMake(cls, pt, NO, 0, NO, 0);
                }), "@@:d");
            I16AddClassMethod(pair, @selector(configurationWithPointSize:weight:),
                imp_implementationWithBlock(^id(id cls, CGFloat pt, long w) {
                    return I16SymbolCfgMake(cls, pt, YES, w, NO, 0);
                }), "@@:dq");
            I16AddClassMethod(pair, @selector(configurationWithPointSize:weight:scale:),
                imp_implementationWithBlock(^id(id cls, CGFloat pt, long w, long sc) {
                    return I16SymbolCfgMake(cls, pt, YES, w, YES, sc);
                }), "@@:dqq");
            I16AddClassMethod(pair, @selector(configurationWithWeight:),
                imp_implementationWithBlock(^id(id cls, long w) {
                    return I16SymbolCfgMake(cls, 0, YES, w, NO, 0);
                }), "@@:q");
            I16AddClassMethod(pair, @selector(configurationWithScale:),
                imp_implementationWithBlock(^id(id cls, long sc) {
                    return I16SymbolCfgMake(cls, 0, NO, 0, YES, sc);
                }), "@@:q");
            I16AddClassMethod(pair, @selector(unspecifiedConfiguration),
                imp_implementationWithBlock(^id(id cls) {
                    return I16SymbolCfgMake(cls, 0, NO, 0, NO, 0);
                }), "@@:");
        }
    }

    I16AddClassMethod(UI, @selector(systemImageNamed:),
                      imp_implementationWithBlock(^id(id self_, NSString *name) {
                          double sc = [UIScreen mainScreen].scale ?: 2.0;
                          return I16SymbolImage(name, 17.0, sc);
                      }), "@@:@");

    I16AddClassMethod(UI, @selector(systemImageNamed:withConfiguration:),
                      imp_implementationWithBlock(^id(id self_, NSString *name, id cfg) {
                          CGFloat pt = I16SymbolConfigPointSize(cfg);
                          double sc = [UIScreen mainScreen].scale ?: 2.0;
                          return I16SymbolImage(name, pt > 0 ? pt : 17.0, sc);
                      }), "@@:@@");

    // 拿到图之后改尺寸很常见（cell 里一套图两处用）。按名字重画，
    // 不是把旧位图放大 —— 放大会糊，而符号本来就该是矢量。
    I16AddInstanceMethod(UI, @selector(imageWithConfiguration:),
                         imp_implementationWithBlock(^id(id self_, id cfg) {
                             UIImage *base = self_;
                             CGFloat pt = I16SymbolConfigPointSize(cfg);
                             if (pt <= 0) return base;
                             NSString *name = objc_getAssociatedObject(base, @selector(isSymbolImage));
                             if (name) {
                                 UIImage *re = I16SymbolImage(name, pt, base.scale ?: 2.0);
                                 if (re) return re;
                             }
                             return base;
                         }), "@@:@");

    // 13+ 的代码常靠它判断「这是不是符号图」，进而决定要不要当模板用。
    I16AddInstanceMethod(UI, @selector(isSymbolImage),
                         imp_implementationWithBlock(^BOOL(id self_) {
                             return objc_getAssociatedObject(self_, @selector(isSymbolImage)) != nil;
                         }), "B@:");
}

// ============================================================ 自检
NSString *I16SymbolDemo(void) {
    NSMutableString *s = [NSMutableString string];
    NSDictionary *idx = I16SymbolIndex();
    if (!idx.count) {
        [s appendFormat:@"索引读不出来：%@", I16SymbolLastError ?: @"原因未知"];
        return s;
    }
    [s appendFormat:@"索引 %lu 个名字；PDF 页数 %zu；",
     (unsigned long)idx.count,
     (size_t)CGPDFDocumentGetNumberOfPages(I16SymbolDoc())];

    // 走公开入口，不直接调内部函数 —— 要证明的是「补上去的方法能调通」，
    // 不是「我的内部函数能跑」。
    NSArray *probe = @[@"heart.fill", @"gear", @"square.and.arrow.up", @"trash"];
    NSMutableArray *ok = [NSMutableArray array];
    for (NSString *n in probe) {
        UIImage *img = [UIImage systemImageNamed:n];
        if (img) {
            [ok addObject:[NSString stringWithFormat:@"%@(%.0fx%.0f)", n, img.size.width, img.size.height]];
        }
    }
    [s appendFormat:@"systemImageNamed: %lu/%lu -> %@",
     (unsigned long)ok.count, (unsigned long)probe.count,
     ok.count ? [ok componentsJoinedByString:@", "] : @"全空"];
    if (ok.count < probe.count) {
        [s appendFormat:@"；失败原因：%@", I16SymbolLastError ?: @"名字不在索引里"];
    }

    // 配置对象：类补上了没、尺寸会不会跟着变。这两点决定了它是不是个真类，
    // 而不是一个只会返回 nil 的空壳。
    Class Cfg = objc_getClass("UIImageSymbolConfiguration");
    if (Cfg) {
        UIImage *a = [UIImage systemImageNamed:@"gear" withConfiguration:[Cfg configurationWithPointSize:11]];
        UIImage *b = [UIImage systemImageNamed:@"gear" withConfiguration:[Cfg configurationWithPointSize:44]];
        [s appendFormat:@"；配置类=有 11pt->%.0f 44pt->%.0f", a.size.height, b.size.height];
    } else {
        [s appendString:@"；配置类=没有"];
    }
    return s;
}
