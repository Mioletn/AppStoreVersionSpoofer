// inapp_probe.m —— 在 App 进程里试屏幕采集
//
// 为什么要在 App 里试：
//   SSH 的 shell 里 `IOMobileFramebufferGetLayerDefaultSurface` 返回
//   0xe00002c1（kIOReturnNotPrivileged），`CARenderServerGetServerPort`
//   直接段错误。原因不是权限不够（已经是 root），是**进程没有图形上下文**：
//   bootstrap 端口是从 sshd 继承来的，查不到 WindowServer 的服务。
//
//   App 不一样。它是被 SpringBoard 拉起来的，bootstrap 是真的、图形上下文是真的。
//   所以同样的调用在这里应该能成 —— 这一轮就是验证这件事。
//
// 两条路都试：
//   A. IOMobileFramebufferGetLayerDefaultSurface（layer 0..3 全试一遍，
//      有些机型内容层不在 0）
//   B. CARenderServerRenderDisplay 渲染到自建 IOSurface
// 谁成，后面就按谁来写串流。

#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <mach/mach.h>
#import <mach/mach_init.h>
#import <dlfcn.h>

typedef kern_return_t IOReturn;

// 查 bootstrap 服务用。12.4 的 SDK 里 servers/bootstrap.h 不一定在，
// 按 ABI 自己声明：参数退化成 const char *，与 name_t 兼容。
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *service,
                                       mach_port_t *service_port);
typedef struct __IOSurface *IOSurfaceRef;
typedef struct __IOMobileFramebuffer *IOMobileFramebufferRef;

// ---- IOSurface
static IOSurfaceRef (*pCreate)(CFDictionaryRef);
static kern_return_t (*pLock)(IOSurfaceRef, uint32_t, uint32_t *);
static kern_return_t (*pUnlock)(IOSurfaceRef, uint32_t, uint32_t *);
static size_t (*pW)(IOSurfaceRef), (*pH)(IOSurfaceRef), (*pBPR)(IOSurfaceRef);
static void *(*pBase)(IOSurfaceRef);
static OSType (*pFmt)(IOSurfaceRef);
static CFStringRef gKW, gKH, gKBPE, gKPF;

// ---- IOMobileFramebuffer
static IOReturn (*pMainDisplay)(IOMobileFramebufferRef *);
static IOReturn (*pFBOpen)(uint32_t, mach_port_t, uint32_t, IOMobileFramebufferRef *);
static IOReturn (*pLayerSurface)(IOMobileFramebufferRef, int, IOSurfaceRef *);

// ---- CARenderServer
static mach_port_t (*pServerPort)(mach_port_t);
static void (*pRenderDisplay)(mach_port_t, CFStringRef, IOSurfaceRef, int, int);

// 候选符号名。QuartzCore 在 dyld shared cache 里，没有文件可以 nm，
// 只能按名字试 —— 试之前先只判断存在性，不调用，避免又把进程打挂。
static const char *kRenderSymNames[] = {
    "CARenderServerGetServerPort",
    "CARenderServerGetPort",
    "CARenderServerRenderDisplay",
    "CARenderServerRenderDisplaySurface",
    "CARenderServerSnapshot",
    "CARenderServerCreate",
    "CARenderServerStart",
    "CARenderServerRenderLayer",
    "CARenderServerRenderObject",
    "CARenderServerFlushIRDC",
    NULL
};


static NSMutableString *LOGS;

// 每条日志**立刻落盘**。这段代码的目的就是找出「哪一步会崩」，
// 如果攒在内存里，崩了以后一个字节都留不下 —— 第一次跑就是这么白跑的。
static void PL(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [LOGS appendFormat:@"%@\n", s];

    static BOOL first = YES;
    FILE *f = fopen("/var/mobile/inapp_probe.txt", first ? "w" : "a");
    if (f) {
        fputs([s UTF8String], f);
        fputc('\n', f);
        fclose(f);
    }
    first = NO;
}

static BOOL LoadAll(void) {
    void *ios = dlopen("/System/Library/PrivateFrameworks/IOSurface.framework/IOSurface", RTLD_NOW)
             ?: dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    if (ios) {
        pCreate = dlsym(ios, "IOSurfaceCreate");
        pLock   = dlsym(ios, "IOSurfaceLock");
        pUnlock = dlsym(ios, "IOSurfaceUnlock");
        pW      = dlsym(ios, "IOSurfaceGetWidth");
        pH      = dlsym(ios, "IOSurfaceGetHeight");
        pBPR    = dlsym(ios, "IOSurfaceGetBytesPerRow");
        pBase   = dlsym(ios, "IOSurfaceGetBaseAddress");
        pFmt    = dlsym(ios, "IOSurfaceGetPixelFormat");
        CFStringRef *a = dlsym(ios, "kIOSurfaceWidth");
        CFStringRef *b = dlsym(ios, "kIOSurfaceHeight");
        CFStringRef *c = dlsym(ios, "kIOSurfaceBytesPerElement");
        CFStringRef *d = dlsym(ios, "kIOSurfacePixelFormat");
        gKW = a ? *a : CFSTR("IOSurfaceWidth");
        gKH = b ? *b : CFSTR("IOSurfaceHeight");
        gKBPE = c ? *c : CFSTR("IOSurfaceBytesPerElement");
        gKPF = d ? *d : CFSTR("IOSurfacePixelFormat");
    }

    void *fb = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
                      RTLD_NOW);
    if (fb) {
        pMainDisplay  = dlsym(fb, "IOMobileFramebufferGetMainDisplay");
        pFBOpen       = dlsym(fb, "IOMobileFramebufferOpen");
        pLayerSurface = dlsym(fb, "IOMobileFramebufferGetLayerDefaultSurface");
    }

    void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
    if (qc) {
        pServerPort    = dlsym(qc, "CARenderServerGetServerPort");
        pRenderDisplay = dlsym(qc, "CARenderServerRenderDisplay");
    }
    return ios && pCreate && pLock && pBase;
}

// 存 PNG：光有数字不算证据，得能把图拿下来看一眼。
static BOOL SaveSurfacePNG(IOSurfaceRef surf, NSString *path) {
    if (!surf || !pLock) return NO;
    pLock(surf, 0x00000001, NULL);
    size_t w = pW(surf), h = pH(surf), br = pBPR(surf);
    void *base = pBase(surf);

    BOOL ok = NO;
    if (base && w && h) {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        // stride 用 surface 自己的，宽高用真实的；BGRA 在 iOS 上按
        // kCGImageAlphaNoneSkipFirst + 小端序读，顺序才正好是 B,G,R,A。
        CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, br, cs,
                            kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
        if (ctx) {
            CGImageRef img = CGBitmapContextCreateImage(ctx);
            if (img) {
                CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:path];
                CGImageDestinationRef dst =
                    CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
                if (dst) {
                    CGImageDestinationAddImage(dst, img, NULL);
                    ok = CGImageDestinationFinalize(dst);
                    CFRelease(dst);
                }
                CGImageRelease(img);
            }
            CGContextRelease(ctx);
        }
        CGColorSpaceRelease(cs);
    }
    pUnlock(surf, 0x00000001, NULL);
    return ok;
}

static NSString *Sample(IOSurfaceRef surf) {
    if (!surf) return @"(null)";
    pLock(surf, 1, NULL);
    size_t w = pW(surf), h = pH(surf), br = pBPR(surf);
    uint8_t *b = pBase(surf);
    NSMutableString *s = [NSMutableString string];
    if (b) {
        CGFloat fx[] = {0.5, 0.25, 0.75, 0.25, 0.75};
        CGFloat fy[] = {0.5, 0.25, 0.25, 0.75, 0.75};
        for (int i = 0; i < 5; i++) {
            uint8_t *p = b + (size_t)(fy[i] * h) * br + (size_t)(fx[i] * w) * 4;
            [s appendFormat:@"%02x%02x%02x ", p[0], p[1], p[2]];
        }
    }
    pUnlock(surf, 1, NULL);
    return s;
}

// 采样 9 点全 0 就认为没画上东西。黑屏有两种：真的黑，和根本没渲染 ——
// 这两者必须分开，否则「拿到 surface」会被误当成「拿到了画面」。
static BOOL IsBlank(IOSurfaceRef surf) {
    if (!surf || !pLock) return YES;
    pLock(surf, 1, NULL);
    size_t w = pW(surf), h = pH(surf), br = pBPR(surf);
    uint8_t *b = pBase(surf);
    BOOL blank = YES;
    if (b) {
        for (int i = 0; i < 9; i++) {
            CGFloat fx[] = {0.5, 0.2, 0.8, 0.2, 0.8, 0.5, 0.5, 0.35, 0.65};
            CGFloat fy[] = {0.5, 0.2, 0.2, 0.8, 0.8, 0.2, 0.8, 0.5, 0.5};
            uint8_t *px = b + (size_t)(fy[i] * h) * br + (size_t)(fx[i] * w) * 4;
            if (px[0] || px[1] || px[2] || px[3]) { blank = NO; break; }
        }
    }
    pUnlock(surf, 1, NULL);
    return blank;
}

NSString *I16InAppProbe(void) {
    LOGS = [NSMutableString string];
    PL(@"== in-app 采集探针 · %@ ==", [[NSBundle mainBundle] bundleIdentifier]);
    PL(@"IOSurface 加载: %d", LoadAll());

    IOSurfaceRef surf = NULL;
    NSString *via = @"none";

    // ---- A. IOMobileFramebuffer
    if (pLayerSurface) {
        IOMobileFramebufferRef fb = NULL;
        if (pMainDisplay) {
            IOReturn kr = pMainDisplay(&fb);
            PL(@"[iomfb] GetMainDisplay kr=0x%x fb=%p", kr, fb);
        }
        if (!fb && pFBOpen) {
            IOReturn kr = pFBOpen(0, mach_task_self(), 0, &fb);
            PL(@"[iomfb] Open kr=0x%x fb=%p", kr, fb);
        }
        // 内容层不一定是 0。全试一遍，比猜便宜。
        for (int layer = 0; layer < 4 && !surf; layer++) {
            IOSurfaceRef s = NULL;
            IOReturn kr = pLayerSurface(fb, layer, &s);
            PL(@"[iomfb] layer %d kr=0x%x surf=%p", layer, kr, s);
            if (s) { surf = s; via = [NSString stringWithFormat:@"iomfb-layer%d", layer]; }
        }
    }

    // ---- B. CARenderServer
    {
        void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
        (void)pServerPort;   // 名字里有，但调它会崩；只留作记录
        if (qc) {
            NSMutableString *have = [NSMutableString string];
            for (int i = 0; kRenderSymNames[i]; i++) {
                if (dlsym(qc, kRenderSymNames[i])) {
                    [have appendFormat:@"%s ", kRenderSymNames[i]];
                }
            }
            PL(@"[qc] 存在的符号: %@", have);
        }

        // 上一条路是直接调 CARenderServerGetServerPort(bp)，在 libxpc 里段错误。
        // 换成标准的 bootstrap 查询：失败只会返回错误码，不会崩。
        mach_port_t bp = MACH_PORT_NULL;
        kern_return_t bkr = task_get_bootstrap_port(mach_task_self(), &bp);
        PL(@"[carender] bootstrap kr=0x%x bp=%u", bkr, bp);

        mach_port_t server = MACH_PORT_NULL;
        if (bp) {
            const char *services[] = {
                "com.apple.CARenderServer",
                "com.apple.windowserver.active",
                "com.apple.WindowServer",
                NULL
            };
            for (int i = 0; services[i] && !server; i++) {
                mach_port_t p = MACH_PORT_NULL;
                kern_return_t kr = bootstrap_look_up(bp, services[i], &p);
                PL(@"[carender] look_up %s kr=0x%x port=%u", services[i], kr, p);
                if (kr == KERN_SUCCESS) server = p;
            }
        }

        if (!surf && server && pRenderDisplay) {
            CGSize scr = [UIScreen mainScreen].bounds.size;
            CGFloat sc = [UIScreen mainScreen].scale;
            NSDictionary *attrs = @{
                (__bridge id)gKW: @((NSInteger)(scr.width * sc)),
                (__bridge id)gKH: @((NSInteger)(scr.height * sc)),
                (__bridge id)gKBPE: @(4),
                (__bridge id)gKPF: @(0x42475241),
            };
            IOSurfaceRef s2 = pCreate((__bridge CFDictionaryRef)attrs);
            PL(@"[carender] create %@ surf=%p", attrs, s2);
            if (s2) {
                pRenderDisplay(server, CFSTR("LCD"), s2, 0, 0);
                PL(@"[carender] render LCD 采样 %@", Sample(s2));
                surf = s2;
                via = @"CARenderServer/LCD";
            }
        }

        // ---- C. RenderDisplay 返了成功但画面全黑，说明它没真画。
        // 按「最可能奏效」的顺序再试三种：
        //   C1 CARenderServerStart()   —— 可能要先把这个会话启动起来
        //   C2 CARenderServerGetPort() —— 无参版本，拿到的端口可能才是对的
        //   C3 CARenderServerSnapshot()-> 直接让服务端交一张，省掉自己建 surface
        if (IsBlank(surf)) {
            PL(@"[c] 画面空白，继续试");
            void *qc2 = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);

            void (*pStart)(mach_port_t) = dlsym(qc2, "CARenderServerStart");
            if (pStart && server) {
                pStart(server);
                PL(@"[c1] Start(server=%u) 已调用", server);
                if (surf) {
                    pRenderDisplay(server, CFSTR("LCD"), surf, 0, 0);
                    PL(@"[c1] 重渲染后 %@", Sample(surf));
                }
            }

            mach_port_t (*pGetPort)(void) = dlsym(qc2, "CARenderServerGetPort");
            if (pGetPort && IsBlank(surf)) {
                mach_port_t p2 = pGetPort();
                PL(@"[c2] GetPort() = %u", p2);
                if (p2 && surf) {
                    pRenderDisplay(p2, CFSTR("LCD"), surf, 0, 0);
                    PL(@"[c2] 用 GetPort 渲染后 %@ (blank=%d)", Sample(surf), IsBlank(surf));
                }
            }

            // Snapshot 在这台设备上直接段错误（签名不是 (port, CFStringRef) 那个形状），
            // 已经实测过，不再调。剩下唯一没试过的变量是「显示名」——
            // 名字不对时 RenderDisplay 不报错，只是什么都不画，症状正是全黑。
            const char *names[] = { "LCD", "Display 0", "display0", "IOMFB",
                                    "Primary", "BuiltIn", "main", NULL };
            for (int i = 0; names[i] && IsBlank(surf); i++) {
                CFStringRef dn = CFStringCreateWithCString(NULL, names[i], kCFStringEncodingUTF8);
                pRenderDisplay(server, dn, surf, 0, 0);
                CFRelease(dn);
                PL(@"[name] %s -> blank=%d", names[i], IsBlank(surf));
            }

            // 还有一种可能：surface 需要带 IsGlobal，服务端才认。
            if (IsBlank(surf)) {
                CFStringRef *pg = dlsym(qc2, "kIOSurfaceIsGlobal");
                if (pg) {
                    NSDictionary *a2 = @{
                        (__bridge id)gKW: @(2388), (__bridge id)gKH: @(1668),
                        (__bridge id)gKBPE: @(4),
                        (__bridge id)gKPF: @(0x42475241),
                        (__bridge id)*pg: @YES,
                    };
                    IOSurfaceRef s4 = pCreate((__bridge CFDictionaryRef)a2);
                    PL(@"[global] create=%p", s4);
                    if (s4) {
                        pRenderDisplay(server, CFSTR("LCD"), s4, 0, 0);
                        PL(@"[global] blank=%d 采样 %@", IsBlank(s4), Sample(s4));
                        if (!IsBlank(s4)) { surf = s4; via = @"CARenderServer/global"; }
                    }
                }
            }
        }
    }

    PL(@"[result] via=%@ surf=%p blank=%d", via, surf, surf ? IsBlank(surf) : -1);

    if (!surf) {
        PL(@"[x] 两条路都没拿到 surface");
        [LOGS writeToFile:@"/var/mobile/inapp_probe.txt" atomically:YES
                 encoding:NSUTF8StringEncoding error:nil];
        return [LOGS copy];
    }

    size_t w = pW(surf), h = pH(surf), br = pBPR(surf);
    OSType f = pFmt ? pFmt(surf) : 0;
    PL(@"[surface] %zux%zu stride=%zu fmt='%c%c%c%c'", w, h, br,
       (char)(f >> 24), (char)(f >> 16), (char)(f >> 8), (char)f);
    PL(@"[surface] 采样 %@", Sample(surf));

    BOOL png = SaveSurfacePNG(surf, @"/var/mobile/inapp_frame.png");
    PL(@"[png] 写了 %d -> /var/mobile/inapp_frame.png", png);

    // 连读 20 帧，看是不是活的（内容会变说明拿到的是实时帧）
    PL(@"[live] 连读 20 帧采样：");
    for (int i = 0; i < 20; i++) {
        if (i % 5 == 0) PL(@"  #%d %@", i, Sample(surf));
        pLock(surf, 1, NULL);
        pUnlock(surf, 1, NULL);
        usleep(30 * 1000);
    }

    [LOGS writeToFile:@"/var/mobile/inapp_probe.txt" atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
    return [LOGS copy];
}
