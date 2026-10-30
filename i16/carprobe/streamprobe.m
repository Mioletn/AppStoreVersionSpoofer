// streamprobe.m —— 屏幕串流 + 触控注入的可行性探针
//
// 要做的效果是「电脑上看到 iPad 画面，鼠标点下去 iPad 有反应」。
// 这条链路有两个不可猜的环节：
//
//   A. 拿帧 —— 能不能从 WindowServer 手里读到显示内容
//   B. 注入 —— 能不能把一次触摸塞进 HID 事件流，让系统当成真手指
//
// 两个都不确定，所以先探，不写正式实现。探针的判据是硬的：
//   采集：拿到 IOSurface 的宽高/stride，读若干采样点，连续 30 帧计时
//   注入：在屏幕上点一下，**再用采集读一次像素，看有没有变**
//
// 最后那条闭环是关键。只看到「函数返回 0」证明不了触摸生效 ——
// 界面对点击的反应必须从像素里看出来。

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach/mach.h>
#import <mach/mach_init.h>
#import <mach/task.h>
#import <dlfcn.h>

// IOReturn 本来是 IOKit 的 IOTypes.h 定义的。这里没链 IOKit（符号全走 dlsym），
// 所以自己补一个 —— 它就是 kern_return_t，int 的 typedef。
typedef kern_return_t IOReturn;

static NSMutableString *LOG;

static void L(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [LOG appendFormat:@"%@\n", s];
    printf("%s\n", [s UTF8String]);
    fflush(stdout);
}

// ============================================================ IOSurface（运行时）
// 12.4 的 SDK 里 IOSurface 是私有框架，没有 Headers 目录 —— #import 直接编译失败。
// 所以整组函数都走 dlsym。这不是为了好看，是这台机器上唯一能编过的写法。
typedef struct __IOSurface *IOSurfaceRef;

static IOSurfaceRef (*pSurfCreate)(CFDictionaryRef);
static kern_return_t (*pSurfLock)(IOSurfaceRef, uint32_t, uint32_t *);
static kern_return_t (*pSurfUnlock)(IOSurfaceRef, uint32_t, uint32_t *);
static size_t (*pSurfGetW)(IOSurfaceRef);
static size_t (*pSurfGetH)(IOSurfaceRef);
static size_t (*pSurfGetBPR)(IOSurfaceRef);
static void *(*pSurfBase)(IOSurfaceRef);
static OSType (*pSurfFmt)(IOSurfaceRef);

#define kLockReadOnly 0x00000001

static CFStringRef gKeyW, gKeyH, gKeyBPE, gKeyPF;

static BOOL LoadIOSurface(void) {
    const char *paths[] = {
        "/System/Library/PrivateFrameworks/IOSurface.framework/IOSurface",
        "/System/Library/Frameworks/IOSurface.framework/IOSurface",
    };
    void *h = NULL;
    for (size_t i = 0; i < sizeof(paths)/sizeof(*paths) && !h; i++) {
        h = dlopen(paths[i], RTLD_NOW);
    }
    if (!h) return NO;

    pSurfCreate = dlsym(h, "IOSurfaceCreate");
    pSurfLock   = dlsym(h, "IOSurfaceLock");
    pSurfUnlock = dlsym(h, "IOSurfaceUnlock");
    pSurfGetW   = dlsym(h, "IOSurfaceGetWidth");
    pSurfGetH   = dlsym(h, "IOSurfaceGetHeight");
    pSurfGetBPR = dlsym(h, "IOSurfaceGetBytesPerRow");
    pSurfBase   = dlsym(h, "IOSurfaceGetBaseAddress");
    pSurfFmt    = dlsym(h, "IOSurfaceGetPixelFormat");

    // 键是 CFString 常量。取不到就退到同名 CFSTR —— CFString 按内容比较，
    // 这两个在字典查找上是等价的，不至于因为一个符号拿不到就整条路断掉。
    CFStringRef *pw = dlsym(h, "kIOSurfaceWidth");
    CFStringRef *ph = dlsym(h, "kIOSurfaceHeight");
    CFStringRef *pb = dlsym(h, "kIOSurfaceBytesPerElement");
    CFStringRef *pf = dlsym(h, "kIOSurfacePixelFormat");
    gKeyW   = pw ? *pw : CFSTR("IOSurfaceWidth");
    gKeyH   = ph ? *ph : CFSTR("IOSurfaceHeight");
    gKeyBPE = pb ? *pb : CFSTR("IOSurfaceBytesPerElement");
    gKeyPF  = pf ? *pf : CFSTR("IOSurfacePixelFormat");

    return pSurfCreate && pSurfLock && pSurfUnlock && pSurfBase;
}

// ============================================================ 类型
typedef struct __IOMobileFramebuffer *IOMobileFramebufferRef;

typedef IOReturn (*FBObjOpen)(uint32_t, mach_port_t, uint32_t, IOMobileFramebufferRef *);
typedef IOReturn (*FBMainDisplay)(IOMobileFramebufferRef *);
typedef IOReturn (*FBLayerSurface)(IOMobileFramebufferRef, int, IOSurfaceRef *);
typedef IOReturn (*FBDisplaySize)(IOMobileFramebufferRef, int *, int *);

typedef mach_port_t (*RenderServerPort)(mach_port_t);
typedef void (*RenderDisplay)(mach_port_t, CFStringRef, IOSurfaceRef, int, int);

// ============================================================ 符号查找
static void *gFB, *gQC, *gIOKit;

static void *Sym(void *h, const char *name, BOOL *ok) {
    void *p = h ? dlsym(h, name) : NULL;
    if (ok) *ok = (p != NULL);
    return p;
}

// ============================================================ 像素采样
// 取 9 个点（四角 + 中心 + 边中点），拼成一行十六进制。
// 全 0 或全同色说明拿到的不是真实帧。
static NSString *SampleIOSurface(IOSurfaceRef surf) {
    if (!surf || !pSurfLock) return @"(null surface)";
    pSurfLock(surf, kLockReadOnly, NULL);

    size_t w  = pSurfGetW(surf);
    size_t h  = pSurfGetH(surf);
    size_t br = pSurfGetBPR(surf);
    uint8_t *base = (uint8_t *)pSurfBase(surf);

    NSMutableString *s = [NSMutableString string];
    if (base && w > 4 && h > 4) {
        CGFloat fx[] = { 0.5, 0.2, 0.8, 0.2, 0.8, 0.5, 0.5, 0.35, 0.65 };
        CGFloat fy[] = { 0.5, 0.2, 0.2, 0.8, 0.8, 0.2, 0.8, 0.5, 0.5 };
        for (int i = 0; i < 9; i++) {
            size_t x = (size_t)(fx[i] * w), y = (size_t)(fy[i] * h);
            if (x >= w) x = w - 1;
            if (y >= h) y = h - 1;
            uint8_t *p = base + y * br + x * 4;
            [s appendFormat:@"%02x%02x%02x ", p[0], p[1], p[2]];
        }
    } else {
        [s appendString:@"(no base address)"];
    }
    pSurfUnlock(surf, kLockReadOnly, NULL);
    return s;
}

// ============================================================ 主流程
int main(int argc, char *argv[]) {
    @autoreleasepool {
        LOG = [NSMutableString string];

        L(@"== streamprobe · 从 SSH 的裸 shell 跑，没有 App 的 WindowServer 上下文 ==");

        BOOL iosOK = LoadIOSurface();
        L(@"[surface] IOSurface 符号加载: %d (create=%d lock=%d base=%d)",
          iosOK, pSurfCreate != NULL, pSurfLock != NULL, pSurfBase != NULL);

        // ---------------------------------------------- 1. dlopen
        const char *fbPaths[] = {
            "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
            "/System/Library/Frameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
        };
        for (size_t i = 0; i < sizeof(fbPaths) / sizeof(*fbPaths) && !gFB; i++) {
            gFB = dlopen(fbPaths[i], RTLD_NOW);
            L(@"[dlopen] %s -> %s", fbPaths[i], gFB ? "ok" : dlerror());
        }
        gQC = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
        L(@"[dlopen] QuartzCore -> %s", gQC ? "ok" : dlerror());
        gIOKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        L(@"[dlopen] IOKit -> %s", gIOKit ? "ok" : dlerror());

        // ---------------------------------------------- 2. 拿 surface
        IOSurfaceRef surf = NULL;
        NSString *via = @"none";

        // 路 A：IOMobileFramebuffer
        if (gFB) {
            BOOL ok1 = NO, ok2 = NO, ok3 = NO;
            FBMainDisplay mainDisp = (FBMainDisplay)Sym(gFB, "IOMobileFramebufferGetMainDisplay", &ok1);
            FBObjOpen   openFB   = (FBObjOpen)Sym(gFB, "IOMobileFramebufferOpen", &ok2);
            FBLayerSurface layer = (FBLayerSurface)Sym(gFB, "IOMobileFramebufferGetLayerDefaultSurface", &ok3);
            L(@"[iomfb] GetMainDisplay=%d Open=%d GetLayerDefaultSurface=%d", ok1, ok2, ok3);

            IOMobileFramebufferRef fb = NULL;
            if (mainDisp) {
                IOReturn kr = mainDisp(&fb);
                L(@"[iomfb] GetMainDisplay kr=0x%x fb=%p", kr, fb);
            }
            if (!fb && openFB) {
                IOReturn kr = openFB(0, mach_task_self(), 0, &fb);
                L(@"[iomfb] Open(0,task,0) kr=0x%x fb=%p", kr, fb);
            }
            if (fb && layer) {
                IOReturn kr = layer(fb, 0, &surf);
                L(@"[iomfb] GetLayerDefaultSurface kr=0x%x surf=%p", kr, surf);
                if (surf) via = @"IOMobileFramebuffer";
            }
        }

        // 路 B：CARenderServer 渲染到自建 surface
        if (!surf && gQC) {
            BOOL ok1 = NO, ok2 = NO;
            RenderServerPort getPort = (RenderServerPort)Sym(gQC, "CARenderServerGetServerPort", &ok1);
            RenderDisplay   render  = (RenderDisplay)Sym(gQC, "CARenderServerRenderDisplay", &ok2);
            L(@"[carender] GetServerPort=%d RenderDisplay=%d", ok1, ok2);

            if (getPort && render) {
                mach_port_t bp = MACH_PORT_NULL;
                task_get_bootstrap_port(mach_task_self(), &bp);
                mach_port_t server = getPort(bp);
                L(@"[carender] bootstrap=%u server=%u", bp, server);

                if (server) {
                    // 建一块和屏幕同尺寸的 BGRA surface
                    NSDictionary *attrs = @{
                        (__bridge id)gKeyW: @(1668),
                        (__bridge id)gKeyH: @(2388),
                        (__bridge id)gKeyBPE: @(4),
                        (__bridge id)gKeyPF: @(0x42475241),  // 'BGRA'
                    };
                    IOSurfaceRef s2 = pSurfCreate((__bridge CFDictionaryRef)attrs);
                    L(@"[carender] IOSurfaceCreate -> %p", s2);
                    if (s2) {
                        render(server, CFSTR("LCD"), s2, 0, 0);
                        pSurfLock(s2, kLockReadOnly, NULL);
                        uint8_t *b = (uint8_t *)pSurfBase(s2);
                        pSurfUnlock(s2, kLockReadOnly, NULL);
                        L(@"[carender] render 后首字节=%02x %02x %02x %02x",
                          b ? b[0] : 0, b ? b[1] : 0, b ? b[2] : 0, b ? b[3] : 0);
                        surf = s2;
                        via = @"CARenderServer";
                    }
                }
            }
        }

        L(@"[surface] via=%@ surf=%p", via, surf);

        if (surf) {
            size_t w = pSurfGetW(surf), h = pSurfGetH(surf);
            size_t br = pSurfGetBPR(surf);
            OSType fmt = pSurfFmt ? pSurfFmt(surf) : 0;
            L(@"[surface] %zux%zu stride=%zu format='%c%c%c%c' (%u)",
              w, h, br,
              (char)(fmt >> 24), (char)(fmt >> 16), (char)(fmt >> 8), (char)fmt, fmt);
            L(@"[surface] 采样 %@", SampleIOSurface(surf));

            // ------------------------------------------ 3. 连续取帧计时
            NSDate *t0 = [NSDate date];
            const int N = 30;
            uint64_t bytes = 0;
            for (int i = 0; i < N; i++) {
                pSurfLock(surf, kLockReadOnly, NULL);
                uint8_t *b = (uint8_t *)pSurfBase(surf);
                if (b) { bytes += b[0] + b[(h / 2) * br + (w / 2) * 4]; }
                pSurfUnlock(surf, kLockReadOnly, NULL);
            }
            double dt = -[t0 timeIntervalSinceNow];
            L(@"[perf] %d 次 lock+取址 耗时 %.1f ms（%.2f ms/次） checksum=%llu",
              N, dt * 1000, dt * 1000 / N, (unsigned long long)bytes);

            // 全帧拷贝的真实成本：串流能不能跑到 30fps 取决于这个数
            t0 = [NSDate date];
            size_t full = br * h;
            void *dst = malloc(full);
            for (int i = 0; i < 10; i++) {
                pSurfLock(surf, kLockReadOnly, NULL);
                memcpy(dst, pSurfBase(surf), full);
                pSurfUnlock(surf, kLockReadOnly, NULL);
            }
            dt = -[t0 timeIntervalSinceNow];
            free(dst);
            L(@"[perf] 整帧 memcpy %.1f MB × 10 耗时 %.1f ms（%.1f fps 上限）",
              full / 1048576.0, dt * 1000, 10 / dt);
        }

        // ---------------------------------------------- 4. HID 注入
        L(@"");
        L(@"-- 触控注入 --");
        if (gIOKit) {
            BOOL a = NO, b = NO, c = NO, d = NO, e = NO;
            void *createClient = Sym(gIOKit, "IOHIDEventSystemClientCreate", &a);
            void *createFinger = Sym(gIOKit, "IOHIDEventCreateDigitizerFingerEvent", &b);
            void *createFingerQ = Sym(gIOKit, "IOHIDEventCreateDigitizerFingerEventWithQuality", &c);
            void *setInt = Sym(gIOKit, "IOHIDEventSetIntegerValue", &d);
            void *dispatch = Sym(gIOKit, "IOHIDEventSystemClientDispatchEvent", &e);
            L(@"[hid] Create=%d FingerEvent=%d FingerEventWithQuality=%d SetInteger=%d Dispatch=%d",
              a, b, c, d, e);
            // 只查符号存在性；真正注入要等采集通了才能验（靠像素差判断）。
            (void)createClient; (void)createFinger; (void)createFingerQ;
            (void)setInt; (void)dispatch;
        }

        // ---------------------------------------------- 落盘
        NSString *path = @"/var/mobile/streamprobe.txt";
        [LOG writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        L(@"\n写入 %@", path);
    }
    return 0;
}
