// carprobe v3 —— iOS 12.2 上的 CAR（Assets.car）能力探针
//
// 已实测的两轮结论：
//   v1：CoreUI 可 dlopen，CUICatalog 存在（128 实例方法 / 11 类方法），
//       但 catalogWithName:fromBundle: 不存在 —— 12.2 用的是 defaultUICatalogForBundle:。
//   v2：改用 defaultUICatalogForBundle: 之后，8/8 份 car 全部打开，
//       含 26.x SDK 编的 app 的 car；imageExistsWithName: 行为正确；
//       colorWithName:displayGamut:appearanceName: 的 light/dark 都取到了。
//
// 这一轮补最后一环：能不能真的取出像素。
//   「能列出名字」和「能取到位图」是两件事 —— 前者只证明 TOC 能解析，
//   后者才证明 rendition 解码 + 渲染链路完整。
//
// 另外把 CUINamedImage 的方法表打出来：真实 selector 只能这样拿。
//
// 全部反射调用，不 include 私有头：私有 API 签名猜错，编译期看不出来。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <unistd.h>
#import <stdio.h>
#import <stdlib.h>
#import <stdarg.h>

static NSMutableString *g_log;

static void L(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [g_log appendFormat:@"%@\n", s];
    printf("%s\n", [s UTF8String]);
    fflush(stdout);
}

static void *imp_of(id obj, SEL sel) {
    if (!obj || ![(id)obj respondsToSelector:sel]) return NULL;
    return (void *)[(id)obj methodForSelector:sel];
}

// deviceIdiom：0=unspecified 1=phone 2=pad。这台是 iPad，用 2。
static const long kIdiomPad = 2;

static id cat_for_bundle(Class CU, NSBundle *b) {
    SEL s = @selector(defaultUICatalogForBundle:);
    void *f = imp_of(CU, s);
    if (!f) return nil;
    return ((id (*)(id, SEL, id))f)(CU, s, b);
}

static NSArray *cat_names(id cat) {
    SEL s = @selector(allImageNames);
    void *f = imp_of(cat, s);
    return f ? ((id (*)(id, SEL))f)(cat, s) : nil;
}

static BOOL cat_exists(id cat, NSString *name) {
    SEL s = @selector(imageExistsWithName:);
    void *f = imp_of(cat, s);
    return f ? ((BOOL (*)(id, SEL, id))f)(cat, s, name) : NO;
}

static id cat_color(id cat, NSString *name, NSString *appearance) {
    SEL s = @selector(colorWithName:displayGamut:appearanceName:);
    void *f = imp_of(cat, s);
    if (!f) return nil;
    return ((id (*)(id, SEL, id, long, id))f)(cat, s, name, 0, appearance);
}

static void dump_methods(const char *cname, unsigned limit) {
    Class c = objc_getClass(cname);
    if (!c) { L(@"  %s: 不存在", cname); return; }
    unsigned n = 0;
    Method *ms = class_copyMethodList(c, &n);
    L(@"  %s 实例方法 %u 个:", cname, n);
    for (unsigned i = 0; i < n && i < limit; i++)
        L(@"      - %s", sel_getName(method_getName(ms[i])));
    if (n > limit) L(@"      ... 其余 %u 个略", n - limit);
    free(ms);
}

// 取一张图，走到 CGImage 为止。返回 YES 表示拿到了真实位图。
static BOOL take_image(id cat, NSString *name) {
    SEL s = @selector(imageWithName:scaleFactor:deviceIdiom:deviceSubtype:);
    void *f = imp_of(cat, s);
    if (!f) {
        L(@"        取图: 没有 imageWithName:scaleFactor:deviceIdiom:deviceSubtype:");
        return NO;
    }
    id ni = ((id (*)(id, SEL, id, double, long, long))f)(cat, s, name, 2.0, kIdiomPad, 0);
    if (!ni) {
        L(@"        取图: %@ -> nil", name);
        return NO;
    }
    L(@"        取图: %@ -> %s", name, class_getName(object_getClass(ni)));

    // 从 CUINamedImage 拿 CGImage。不同版本 selector 名不一样，逐个试。
    const char *cands[] = { "image", "CGImage", "_image", "createImage", "createCGImage" };
    for (unsigned i = 0; i < sizeof(cands) / sizeof(cands[0]); i++) {
        SEL sel = sel_registerName(cands[i]);
        void *fi = imp_of(ni, sel);
        if (!fi) continue;
        CGImageRef cg = ((CGImageRef (*)(id, SEL))fi)(ni, sel);
        if (cg) {
            L(@"        - %s -> CGImage %zux%zu (bitsPerPixel=%zu)",
              cands[i], CGImageGetWidth(cg), CGImageGetHeight(cg),
              CGImageGetBitsPerPixel(cg));
            return YES;
        }
        L(@"        - %s 返回 NULL", cands[i]);
    }
    L(@"        CUINamedImage 里没有可用的取图 selector");
    return NO;
}

static BOOL probe(Class CU, NSString *path, NSString *label, BOOL deep) {
    NSBundle *b = [NSBundle bundleWithPath:path];
    if (!b) { L(@"  [x] %-11@ bundle 打不开", label); return NO; }
    id cat = cat_for_bundle(CU, b);
    if (!cat) { L(@"  [x] %-11@ defaultUICatalogForBundle -> nil", label); return NO; }

    NSArray *names = cat_names(cat);
    NSString *first = names.count ? names[0] : nil;
    L(@"  [v] %-11@ image 数 = %-4lu exists=%d/%d", label,
      (unsigned long)names.count,
      first ? (int)cat_exists(cat, first) : -1,
      (int)cat_exists(cat, @"__no_such_name__"));
    if (!first) return NO;

    id light = cat_color(cat, first, nil);
    if (light) L(@"        color(light)=ok  color(dark)=%s",
                  cat_color(cat, first, @"dark") ? "ok" : "nil");

    if (deep) {
        L(@"        -- 深入第一张图 --");
        for (NSUInteger k = 0; k < names.count && k < 3; k++) {
            if (take_image(cat, names[k])) break;
        }
    }
    return YES;
}

int main(int argc, char **argv) {
    g_log = [NSMutableString string];
    L(@"carprobe v3 · uid=%u · %@", (unsigned)getuid(),
      [[NSProcessInfo processInfo] operatingSystemVersionString]);

    if (!dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW)) {
        L(@"CoreUI dlopen 失败: %s", dlerror() ? dlerror() : "?");
        return 1;
    }
    Class CU = objc_getClass("CUICatalog");
    if (!CU || !imp_of(CU, @selector(defaultUICatalogForBundle:))) {
        L(@"没有 CUICatalog 或 defaultUICatalogForBundle:，无法继续");
        [g_log writeToFile:@"/var/mobile/i16_carprobe.txt" atomically:YES
                  encoding:NSUTF8StringEncoding error:nil];
        return 1;
    }

    // CUINamedImage 的真实 selector 只能这样拿
    L(@"\n== 相关类的方法表 ==");
    dump_methods("CUINamedImage", 24);
    dump_methods("CUINamedVectorImage", 12);
    dump_methods("CUINamedData", 8);

    NSMutableArray *targets = [NSMutableArray array];
    if (argc > 1) {
        NSString *p = [NSString stringWithUTF8String:argv[1]];
        [targets addObject:p.lastPathComponent];
        [targets addObject:p];
    } else {
        [targets addObjectsFromArray:@[
            @"SpringBoard", @"/System/Library/CoreServices/SpringBoard.app",
            @"MapKit",      @"/System/Library/Frameworks/MapKit.framework",
            @"AVKit",       @"/System/Library/Frameworks/AVKit.framework",
        ]];
        NSArray *dirs = [[NSFileManager defaultManager]
                         contentsOfDirectoryAtPath:@"/var/mobile/cartest" error:nil];
        for (NSString *d in [dirs sortedArrayUsingSelector:@selector(compare:)]) {
            [targets addObject:d];
            [targets addObject:[@"/var/mobile/cartest" stringByAppendingPathComponent:d]];
        }
    }

    L(@"\n== 打开 car ==");
    int ok = 0, total = 0;
    for (NSUInteger i = 0; i + 1 < targets.count; i += 2) {
        total++;
        // 只对第一份（系统自带）和外来样本各取一张图，避免输出过长
        BOOL deep = (i < 2) || (ok == 1);
        if (probe(CU, targets[i + 1], targets[i], deep)) ok++;
    }

    L(@"\n== 结论 ==");
    L(@"  %d / %d 份 car 打开成功", ok, total);

    [g_log writeToFile:@"/var/mobile/i16_carprobe.txt" atomically:YES
              encoding:NSUTF8StringEncoding error:nil];
    L(@"\n报告已写入 /var/mobile/i16_carprobe.txt");
    return 0;
}
