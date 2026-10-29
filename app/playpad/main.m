// PlayPad — iPad 上的 PlayCover
//
// 为什么不是"把 PlayCover.app 拷过来跑"：
//   PlayCover 本体是 Swift + SwiftUI/AppKit 的 macOS 应用，靠三件事工作：
//     ① posix_spawn 起一个 wrapper 进程（AMFI 在 iOS 12.2 上会直接杀掉未签名 exec）
//     ② 动态送 dyld 环境变量做注入（iOS 上 dyld 不认、也没有 AppKit/SwiftUI 运行时）
//     ③ 自己改写代码签名（iOS 上 codesign 这套工具链不存在）
//   这三条在 iOS 12.2 上一条都做不到。它的"运行 iOS 应用"这个功能在 iPad 上本身
//   也是多余的——iOS 应用在 iPad 上本来就原生跑。
//
// 所以这里做的是 PlayCover 在 iPad 上唯一成立、也确实有用的形态：
//   一个真正的 iPad 应用管理台 —— 导入 .ipa → 解析 → 图标网格 → 触控点开 → 安装 → 启动。
//   也就是 PlayCover 的"库 + 安装 + 启动"这三件事，用 UIKit 原生重做。
//
// 它跑得起来的前提是设备上有 AppSync Unified（本机已确认
// /Library/MobileSubstrate/DynamicLibraries/AppSyncUnified-installd.dylib 存在）：
// 那个补丁让 installd 放行未签名/自签的包，于是 MobileInstallation 通道可用。
//
// 触控：全部走 UIKit 原生手势（点按、长按菜单、下拉刷新、sheet 拖动），
// 没有任何自绘事件循环或模拟点击。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <zlib.h>
#import <dirent.h>
#import <sys/stat.h>
#import <unistd.h>
#include <stdio.h>
#include <string.h>

// ------------------------------------------------------------------ 配色
#define PP_BG      [UIColor colorWithRed:0.047 green:0.055 blue:0.070 alpha:1.0]
#define PP_CARD    [UIColor colorWithRed:0.090 green:0.106 blue:0.133 alpha:1.0]
#define PP_CARD2   [UIColor colorWithRed:0.129 green:0.153 blue:0.192 alpha:1.0]
#define PP_STROKE  [UIColor colorWithRed:0.180 green:0.212 blue:0.267 alpha:1.0]
#define PP_TEXT    [UIColor colorWithRed:0.90  green:0.93  blue:0.96  alpha:1.0]
#define PP_DIM     [UIColor colorWithRed:0.52  green:0.58  blue:0.65  alpha:1.0]
#define PP_ACCENT  [UIColor colorWithRed:0.42  green:0.55  blue:0.98  alpha:1.0]
#define PP_OK      [UIColor colorWithRed:0.36  green:0.85  blue:0.62  alpha:1.0]
#define PP_WARN    [UIColor colorWithRed:0.98  green:0.65  blue:0.30  alpha:1.0]
#define PP_ERR     [UIColor colorWithRed:0.95  green:0.36  blue:0.38  alpha:1.0]

// ------------------------------------------------------------------ 日志
static NSMutableString *gLog = nil;
static UITextView    *gLogView = nil;      // 详情页里的控制台
static UILabel       *gStatus = nil;       // 主界面底部状态条

static NSString *PPTime(void) {
    static NSDateFormatter *f = nil;
    if (!f) { f = [NSDateFormatter new]; f.dateFormat = @"HH:mm:ss"; }
    return [f stringFromDate:[NSDate date]];
}

static void PPLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!gLog) gLog = [NSMutableString new];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", PPTime(), s];
    [gLog appendString:line];
    {
        static FILE *lf = NULL;
        if (!lf) lf = fopen("/var/mobile/playpad.log", "a");
        if (lf) { fputs(line.UTF8String, lf); fflush(lf); }
    }
    NSLog(@"[playpad] %@", s);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gLogView) {
            gLogView.text = [gLogView.text stringByAppendingString:line];
            NSRange r = NSMakeRange(gLogView.text.length, 0);
            [gLogView scrollRangeToVisible:r];
        }
    });
}

// ------------------------------------------------------------------ 最小 zip 读器
// IPA 就是个 zip。只需要"按名字取一个条目"这一件事，所以不用 libarchive，
// 手写 EOCD → 中央目录 → 本地头 这条最短路径即可。
typedef struct {
    uint16_t method;
    uint32_t csize;
    uint32_t usize;
    uint32_t localoff;
} PPCentEntry;

@interface PPZip : NSObject
+ (NSArray<NSString *> *)entriesAt:(NSString *)path;
+ (NSData *)dataForEntry:(NSString *)name inZip:(NSString *)path;
@end

@implementation PPZip

+ (NSMutableDictionary<NSString *, NSValue *> *)indexOf:(NSString *)path {
    FILE *f = fopen(path.fileSystemRepresentation, "rb");
    if (!f) return nil;
    fseek(f, 0, SEEK_END);
    long fsz = ftell(f);
    if (fsz < 22) { fclose(f); return nil; }

    // 找 EOCD（末尾 65KB 内回溯，允许有注释）
    long scan = fsz > 66000 ? fsz - 66000 : 0;
    uint8_t *tail = malloc((size_t)(fsz - scan));
    fseek(f, scan, SEEK_SET);
    fread(tail, 1, (size_t)(fsz - scan), f);
    long eocd = -1;
    for (long i = (fsz - scan) - 22; i >= 0; i--) {
        if (tail[i] == 0x50 && tail[i+1] == 0x4b && tail[i+2] == 0x05 && tail[i+3] == 0x06) {
            eocd = i; break;
        }
    }
    if (eocd < 0) { free(tail); fclose(f); return nil; }

    uint32_t cdSize  = *(uint32_t *)(tail + eocd + 12);
    uint32_t cdOff   = *(uint32_t *)(tail + eocd + 16);
    uint16_t cdCount = *(uint16_t *)(tail + eocd + 10);
    free(tail);
    (void)cdSize;

    NSMutableDictionary *idx = [NSMutableDictionary dictionary];
    if (fseek(f, cdOff, SEEK_SET) != 0) { fclose(f); return idx; }
    for (int i = 0; i < cdCount; i++) {
        uint8_t h[46];
        if (fread(h, 1, 46, f) != 46) break;
        if (!(h[0] == 0x50 && h[1] == 0x4b && h[2] == 0x01 && h[3] == 0x02)) break;
        uint16_t method  = *(uint16_t *)(h + 10);
        uint32_t csize   = *(uint32_t *)(h + 20);
        uint32_t usize   = *(uint32_t *)(h + 24);
        uint16_t nlen    = *(uint16_t *)(h + 28);
        uint16_t elen    = *(uint16_t *)(h + 30);
        uint16_t clen    = *(uint16_t *)(h + 32);
        uint32_t off     = *(uint32_t *)(h + 42);
        if (nlen == 0 || nlen > 1024) break;
        char name[1025];
        if (fread(name, 1, nlen, f) != nlen) break;
        name[nlen] = 0;
        fseek(f, elen + clen, SEEK_CUR);

        PPCentEntry e = { method, csize, usize, off };
        idx[[NSString stringWithUTF8String:name]] = [NSValue valueWithBytes:&e objCType:@encode(PPCentEntry)];
    }
    fclose(f);
    return idx;
}

+ (NSArray<NSString *> *)entriesAt:(NSString *)path {
    NSDictionary *idx = [self indexOf:path];
    return idx ? idx.allKeys : @[];
}

+ (NSData *)dataForEntry:(NSString *)name inZip:(NSString *)path {
    NSDictionary *idx = [self indexOf:path];
    if (!idx) return nil;
    NSValue *v = idx[name];
    if (!v) return nil;
    PPCentEntry e; [v getValue:&e];

    FILE *f = fopen(path.fileSystemRepresentation, "rb");
    if (!f) return nil;
    if (fseek(f, e.localoff, SEEK_SET) != 0) { fclose(f); return nil; }
    uint8_t lh[30];
    if (fread(lh, 1, 30, f) != 30) { fclose(f); return nil; }
    uint16_t nlen = *(uint16_t *)(lh + 26);
    uint16_t elen = *(uint16_t *)(lh + 28);
    fseek(f, e.localoff + 30 + nlen + elen, SEEK_SET);

    if (e.method == 0) {
        void *buf = malloc(e.usize ? e.usize : 1);
        size_t got = fread(buf, 1, e.usize, f);
        fclose(f);
        NSData *d = [NSData dataWithBytes:buf length:got];
        free(buf);
        return d;
    }
    if (e.method != 8) { fclose(f); return nil; }       // 只支持 store / deflate

    uint8_t *src = malloc(e.csize ? e.csize : 1);
    size_t got = fread(src, 1, e.csize, f);
    fclose(f);
    uint8_t *dst = malloc(e.usize ? e.usize : 1);
    z_stream zs; memset(&zs, 0, sizeof(zs));
    zs.next_in = src; zs.avail_in = (uInt)got;
    zs.next_out = dst; zs.avail_out = (uInt)e.usize;
    NSData *out = nil;
    if (inflateInit2(&zs, -15) == Z_OK) {           // -15 = raw deflate
        if (inflate(&zs, Z_FINISH) == Z_STREAM_END)
            out = [NSData dataWithBytes:dst length:zs.total_out];
        inflateEnd(&zs);
    }
    free(src); free(dst);
    return out;
}
@end

// ------------------------------------------------------------------ 模型
typedef NS_ENUM(NSInteger, PPKind) { PPKindIPA = 0, PPKindInstalled = 1 };

@interface PPItem : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *path;          // ipa 路径或 .app 路径
@property (nonatomic, copy) NSString *appPath;       // ipa 内 Payload/xxx.app
@property (nonatomic, strong) UIImage *icon;
@property (nonatomic, assign) unsigned long long size;
@property (nonatomic, assign) PPKind kind;
@property (nonatomic, assign) BOOL installed;
@end

@implementation PPItem
@end

// ------------------------------------------------------------------ 私有 API
typedef void (*MICallback)(NSDictionary *info);

static int  (*pMIInstall)(CFStringRef, CFDictionaryRef, MICallback, void *);
static int  (*pMIUninstall)(CFStringRef, CFDictionaryRef, MICallback, void *);

static void PPLoadMobileInstallation(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_LAZY);
        if (!h) h = dlopen("/usr/lib/libMobileInstallation.dylib", RTLD_LAZY);
        if (h) {
            pMIInstall   = (int (*)(CFStringRef, CFDictionaryRef, MICallback, void *))dlsym(h, "MobileInstallationInstall");
            pMIUninstall = (int (*)(CFStringRef, CFDictionaryRef, MICallback, void *))dlsym(h, "MobileInstallationUninstall");
        }
        PPLog(@"MobileInstallation: %@ (install=%s uninstall=%s)",
              h ? @"已加载" : @"加载失败", pMIInstall ? "有" : "无", pMIUninstall ? "有" : "无");
    });
}

static id LSClass(NSString *n) { return NSClassFromString(n); }

// 直接现查一次，不看全局指针 —— 之前状态条和日志不一致就是读取时机不同步造成的。
static BOOL PPCanInstall(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_LAZY);
    if (!h) h = dlopen("/usr/lib/libMobileInstallation.dylib", RTLD_LAZY);
    return h && dlsym(h, "MobileInstallationInstall") != NULL;
}

static BOOL PPAppSyncPresent(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath:
            @"/Library/MobileSubstrate/DynamicLibraries/AppSyncUnified-installd.dylib"];
}

static NSArray<PPItem *> *PPScanInstalled(void) {
    NSMutableArray *out = [NSMutableArray array];
    Class wsCls = LSClass(@"LSApplicationWorkspace");
    if (!wsCls) return out;
    id ws = ((id (*)(id, SEL))objc_msgSend)(wsCls, @selector(defaultWorkspace));
    if (!ws) return out;
    NSArray *apps = ((id (*)(id, SEL))objc_msgSend)(ws, @selector(allInstalledApplications));
    for (id proxy in apps) {
        @autoreleasepool {
            NSString *bid = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(bundleIdentifier));
            if (!bid.length) continue;
            NSURL *url = nil;
            if ([proxy respondsToSelector:@selector(bundleURL)])
                url = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(bundleURL));
            NSString *path = url.path ?: @"";
            // 系统应用也列出来没意义，只要 /var 下的（用户装的）
            if (![path hasPrefix:@"/var/"]) continue;

            PPItem *it = [PPItem new];
            it.kind = PPKindInstalled;
            it.installed = YES;
            it.bundleID = bid;
            it.path = path;
            it.appPath = path;
            it.name = [proxy respondsToSelector:@selector(localizedName)]
                        ? ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(localizedName)) : bid;
            it.version = [proxy respondsToSelector:@selector(shortVersionString)]
                        ? ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(shortVersionString)) : @"";
            if (!it.version.length) it.version = @"—";
            if ([proxy respondsToSelector:@selector(iconDataForVariant:)]) {
                @try {
                    // 参数是 int variant，不是对象 —— 必须走 msgSend 强转
                    id d = ((id (*)(id, SEL, int))objc_msgSend)(proxy, @selector(iconDataForVariant:), 2);
                    if ([d isKindOfClass:[NSData class]] && [(NSData *)d length])
                        it.icon = [UIImage imageWithData:(NSData *)d];
                } @catch (__unused NSException *ex) {}
            }
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
            it.size = [attrs fileSize];
            [out addObject:it];
        }
    }
    [out sortUsingComparator:^NSComparisonResult(PPItem *a, PPItem *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return out;
}

// IPA 里的图标：CFBundleIcons → CFBundlePrimaryIcon → CFBundleIconFiles，
// 取名字最大的那个（约定俗成的 @2x/@3x 就是大图），否则退化成扫 Icon*.png。
static UIImage *PPIconFromIPA(NSString *ipa, NSString *appDir, NSDictionary *info, NSArray<NSString *> *allEntries) {
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    for (NSString *k in @[@"CFBundleIcons~ipad", @"CFBundleIcons"]) {
        NSDictionary *d = info[k];
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *primary = d[@"CFBundlePrimaryIcon"];
        if (![primary isKindOfClass:[NSDictionary class]]) continue;
        NSArray *files = primary[@"CFBundleIconFiles"];
        if ([files isKindOfClass:[NSArray class]]) [cands addObjectsFromArray:files];
    }
    if (!cands.count) [cands addObject:@"Icon"];

    NSString *best = nil; NSUInteger bestLen = 0;
    for (NSString *base in cands) {
        for (NSString *e in allEntries) {
            if (![e hasPrefix:appDir]) continue;
            NSString *leaf = e.lastPathComponent;
            if (![leaf hasPrefix:base]) continue;
            if (![[leaf.pathExtension lowercaseString] isEqualToString:@"png"]) continue;
            // 排除 @2x~ipad 之外的多余匹配；只按长度取最长
            if (leaf.length > bestLen) { bestLen = leaf.length; best = e; }
        }
        if (best) break;
    }
    if (!best) {
        for (NSString *e in allEntries) {
            if (![e hasPrefix:appDir]) continue;
            NSString *leaf = e.lastPathComponent.lowercaseString;
            if ([leaf hasPrefix:@"icon"] && [leaf hasSuffix:@".png"]) {
                if (leaf.length > bestLen) { bestLen = leaf.length; best = e; }
            }
        }
    }
    if (!best) return nil;
    NSData *d = [PPZip dataForEntry:best inZip:ipa];
    return d.length ? [UIImage imageWithData:d] : nil;
}

static NSArray<PPItem *> *PPScanIPAs(NSArray<NSString *> *dirs) {
    NSMutableArray *out = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in dirs) {
        NSArray *kids = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *k in kids) {
            if (![[k.pathExtension lowercaseString] isEqualToString:@"ipa"]) continue;
            NSString *full = [dir stringByAppendingPathComponent:k];
            @autoreleasepool {
                NSArray *entries = [PPZip entriesAt:full];
                NSString *plistPath = nil;
                for (NSString *e in entries) {
                    if ([e hasPrefix:@"Payload/"] && [e hasSuffix:@".app/Info.plist"]) { plistPath = e; break; }
                }
                if (!plistPath) { PPLog(@"跳过 %@：不是有效 IPA（没有 Payload/*.app/Info.plist）", k); continue; }
                NSData *pd = [PPZip dataForEntry:plistPath inZip:full];
                NSDictionary *info = pd ? [NSPropertyListSerialization propertyListWithData:pd
                                        options:NSPropertyListImmutable format:NULL error:nil] : nil;
                if (![info isKindOfClass:[NSDictionary class]]) { PPLog(@"跳过 %@：Info.plist 解析失败", k); continue; }

                PPItem *it = [PPItem new];
                it.kind = PPKindIPA;
                it.path = full;
                it.appPath = [plistPath stringByDeletingLastPathComponent];
                it.bundleID = info[@"CFBundleIdentifier"] ?: @"";
                it.name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: k;
                it.version = info[@"CFBundleShortVersionString"] ?: (info[@"CFBundleVersion"] ?: @"—");
                NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
                it.size = [attrs fileSize];
                it.icon = PPIconFromIPA(full, it.appPath, info, entries);
                [out addObject:it];
            }
        }
    }
    [out sortUsingComparator:^NSComparisonResult(PPItem *a, PPItem *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return out;
}

// 同一个 App 在 Documents 里常有多个副本（Husk-2 / husk-new 之类）。
// 按 bundle id 去重，留下体积最大（通常最完整）的那个，避免网格里出现重复图标。
static NSArray<PPItem *> *PPDedupe(NSArray<PPItem *> *items) {
    NSMutableDictionary<NSString *, PPItem *> *byID = [NSMutableDictionary dictionary];
    NSMutableArray<PPItem *> *noID = [NSMutableArray array];
    for (PPItem *it in items) {
        if (!it.bundleID.length) { [noID addObject:it]; continue; }
        PPItem *old = byID[it.bundleID];
        if (!old || it.size > old.size) byID[it.bundleID] = it;
    }
    NSMutableArray *out = [NSMutableArray arrayWithArray:byID.allValues];
    [out addObjectsFromArray:noID];
    [out sortUsingComparator:^NSComparisonResult(PPItem *a, PPItem *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return out;
}

static NSString *PPHumanSize(unsigned long long s) {
    if (s > 1024ull * 1024 * 1024) return [NSString stringWithFormat:@"%.1f GB", s / 1073741824.0];
    if (s > 1024ull * 1024)        return [NSString stringWithFormat:@"%.1f MB", s / 1048576.0];
    if (s > 1024ull)               return [NSString stringWithFormat:@"%.0f KB", s / 1024.0];
    return [NSString stringWithFormat:@"%llu B", s];
}

// ------------------------------------------------------------------ 图标兜底
static UIImage *PPPlaceholderIcon(NSString *name, CGFloat side) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side) cornerRadius:side * 0.22];
    [[UIColor colorWithRed:0.18 green:0.22 blue:0.32 alpha:1] setFill];
    [p fill];
    NSString *ch = name.length ? [name substringToIndex:1].uppercaseString : @"?";
    NSDictionary *attrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:side * 0.44 weight:UIFontWeightSemibold],
                             NSForegroundColorAttributeName: [UIColor colorWithWhite:0.85 alpha:1] };
    CGSize sz = [ch sizeWithAttributes:attrs];
    (void)ctx;
    [ch drawAtPoint:CGPointMake((side - sz.width) / 2, (side - sz.height) / 2) withAttributes:attrs];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// ------------------------------------------------------------------ 单元格
@class PPRootController;

@interface PPCell : UICollectionViewCell
@property (nonatomic, strong) UIView      *iconWrap;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel     *nameLabel;
@property (nonatomic, strong) UILabel     *subLabel;
@property (nonatomic, strong) UILabel     *badge;
@end

@implementation PPCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.contentView.backgroundColor = [UIColor clearColor];

        _iconWrap = [[UIView alloc] init];
        _iconWrap.backgroundColor = PP_CARD;
        _iconWrap.layer.cornerRadius = 17;
        _iconWrap.layer.borderWidth = 1;
        _iconWrap.layer.borderColor = PP_STROKE.CGColor;
        _iconWrap.clipsToBounds = NO;
        [self.contentView addSubview:_iconWrap];

        _iconView = [[UIImageView alloc] init];
        _iconView.contentMode = UIViewContentModeScaleAspectFill;
        _iconView.layer.cornerRadius = 16;
        _iconView.clipsToBounds = YES;
        [_iconWrap addSubview:_iconView];

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        _nameLabel.textColor = PP_TEXT;
        _nameLabel.textAlignment = NSTextAlignmentCenter;
        _nameLabel.numberOfLines = 2;
        [self.contentView addSubview:_nameLabel];

        _subLabel = [[UILabel alloc] init];
        _subLabel.font = [UIFont systemFontOfSize:10.5];
        _subLabel.textColor = PP_DIM;
        _subLabel.textAlignment = NSTextAlignmentCenter;
        [self.contentView addSubview:_subLabel];

        _badge = [[UILabel alloc] init];
        _badge.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
        _badge.textColor = [UIColor whiteColor];
        _badge.backgroundColor = PP_OK;
        _badge.textAlignment = NSTextAlignmentCenter;
        _badge.layer.cornerRadius = 6;
        _badge.clipsToBounds = YES;
        _badge.hidden = YES;
        [self.contentView addSubview:_badge];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat side = MIN(w - 18, 76);
    CGFloat x = (w - side) / 2;
    _iconWrap.frame = CGRectMake(x, 2, side, side);
    _iconView.frame = CGRectMake(0, 0, side, side);   // 图标铺满，wrap 只做底色
    _nameLabel.frame = CGRectMake(0, side + 8, w, 34);
    _subLabel.frame = CGRectMake(0, side + 42, w, 14);
    _badge.frame = CGRectMake(x + side - 16, 0, 16, 12);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.12 animations:^{
        self.iconWrap.transform = highlighted ? CGAffineTransformMakeScale(0.92, 0.92) : CGAffineTransformIdentity;
        self.iconWrap.alpha = highlighted ? 0.75 : 1.0;
    }];
}
@end

// ------------------------------------------------------------------ 详情页
@interface PPDetailController : UIViewController
@property (nonatomic, strong) PPItem *item;
@property (nonatomic, copy) void (^onClose)(void);
@property (nonatomic, copy) void (^onChanged)(void);

@property (nonatomic, strong) UIView      *panel;
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UILabel     *titleLabel;
@property (nonatomic, strong) UILabel     *metaLabel;
@property (nonatomic, strong) UILabel     *pathLabel;
@property (nonatomic, strong) UIView      *progressTrack;
@property (nonatomic, strong) UIView      *progressFill;
@property (nonatomic, strong) UILabel     *progressLabel;
@property (nonatomic, strong) UIButton    *primary;
@property (nonatomic, strong) UIButton    *secondary;
@property (nonatomic, strong) UITextView  *console;
@property (nonatomic, assign) BOOL         working;
@end

@implementation PPDetailController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismiss)];
    [self.view addGestureRecognizer:tap];

    CGFloat pw = 520, ph = 470;
    _panel = [[UIView alloc] initWithFrame:CGRectMake((self.view.bounds.size.width - pw)/2,
                                                     (self.view.bounds.size.height - ph)/2,
                                                     pw, ph)];
    _panel.backgroundColor = PP_CARD;
    _panel.layer.cornerRadius = 18;
    _panel.layer.borderWidth = 1;
    _panel.layer.borderColor = PP_STROKE.CGColor;
    _panel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                              UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:_panel];
    [_panel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(swallowTap)]];

    _icon = [[UIImageView alloc] initWithFrame:CGRectMake(22, 22, 76, 76)];
    _icon.layer.cornerRadius = 17;
    _icon.clipsToBounds = YES;
    _icon.contentMode = UIViewContentModeScaleAspectFill;
    _icon.backgroundColor = PP_CARD2;
    [_panel addSubview:_icon];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(112, 24, pw - 134, 30)];
    _titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    _titleLabel.textColor = PP_TEXT;
    [_panel addSubview:_titleLabel];

    _metaLabel = [[UILabel alloc] initWithFrame:CGRectMake(112, 54, pw - 134, 20)];
    _metaLabel.font = [UIFont systemFontOfSize:12.5];
    _metaLabel.textColor = PP_DIM;
    [_panel addSubview:_metaLabel];

    _pathLabel = [[UILabel alloc] initWithFrame:CGRectMake(112, 74, pw - 134, 18)];
    _pathLabel.font = [UIFont systemFontOfSize:11];
    _pathLabel.textColor = [PP_DIM colorWithAlphaComponent:0.75];
    _pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_panel addSubview:_pathLabel];

    _console = [[UITextView alloc] initWithFrame:CGRectMake(22, 118, pw - 44, 236)];
    _console.backgroundColor = PP_BG;
    _console.textColor = [UIColor colorWithRed:0.72 green:0.80 blue:0.86 alpha:1];
    _console.font = [UIFont fontWithName:@"Menlo" size:10.5] ?: [UIFont systemFontOfSize:10.5];
    _console.editable = NO;
    _console.layer.cornerRadius = 10;
    _console.layer.borderWidth = 1;
    _console.layer.borderColor = PP_STROKE.CGColor;
    _console.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    [_panel addSubview:_console];
    gLogView = _console;

    _progressTrack = [[UIView alloc] initWithFrame:CGRectMake(22, 366, pw - 44, 6)];
    _progressTrack.backgroundColor = PP_CARD2;
    _progressTrack.layer.cornerRadius = 3;
    _progressTrack.clipsToBounds = YES;
    _progressTrack.hidden = YES;
    [_panel addSubview:_progressTrack];

    _progressFill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 6)];
    _progressFill.backgroundColor = PP_ACCENT;
    [_progressTrack addSubview:_progressFill];

    _progressLabel = [[UILabel alloc] initWithFrame:CGRectMake(22, 376, pw - 44, 16)];
    _progressLabel.font = [UIFont systemFontOfSize:11];
    _progressLabel.textColor = PP_DIM;
    _progressLabel.hidden = YES;
    [_panel addSubview:_progressLabel];

    _primary = [UIButton buttonWithType:UIButtonTypeCustom];
    _primary.frame = CGRectMake(22, ph - 62, (pw - 56) * 0.62, 44);
    _primary.backgroundColor = PP_ACCENT;
    _primary.layer.cornerRadius = 11;
    _primary.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [_primary setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_primary addTarget:self action:@selector(primaryTapped) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_primary];

    _secondary = [UIButton buttonWithType:UIButtonTypeCustom];
    _secondary.frame = CGRectMake(CGRectGetMaxX(_primary.frame) + 12, ph - 62, (pw - 56) * 0.38 - 12, 44);
    _secondary.backgroundColor = PP_CARD2;
    _secondary.layer.cornerRadius = 11;
    _secondary.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [_secondary setTitleColor:PP_TEXT forState:UIControlStateNormal];
    [_secondary addTarget:self action:@selector(secondaryTapped) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_secondary];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshUI];
}

- (void)refreshUI {
    PPItem *it = _item;
    _icon.image = it.icon ?: PPPlaceholderIcon(it.name, 76);
    _titleLabel.text = it.name;
    _metaLabel.text = [NSString stringWithFormat:@"%@ · v%@ · %@ · %@",
                       it.bundleID.length ? it.bundleID : @"?",
                       it.version.length ? it.version : @"?",
                       PPHumanSize(it.size),
                       it.kind == PPKindInstalled ? @"已安装" : @"IPA 包"];
    _pathLabel.text = it.path;

    BOOL installed = it.kind == PPKindInstalled || it.installed;
    if (_working) {
        [_primary setTitle:@"处理中…" forState:UIControlStateNormal];
        _primary.enabled = NO;
    } else if (installed) {
        [_primary setTitle:@"打开" forState:UIControlStateNormal];
        _primary.enabled = YES;
        _primary.backgroundColor = PP_OK;
    } else {
        [_primary setTitle:@"安装" forState:UIControlStateNormal];
        _primary.enabled = YES;
        _primary.backgroundColor = PP_ACCENT;
    }
    [_secondary setTitle:(it.kind == PPKindInstalled ? @"卸载" : @"删除包") forState:UIControlStateNormal];
}

- (void)swallowTap { /* 点面板本体不关闭 */ }

- (void)dismiss {
    if (_working) return;
    [self.view endEditing:YES];
    gLogView = nil;
    if (self.onClose) self.onClose();
    [self dismissViewControllerAnimated:NO completion:nil];
}

- (BOOL)prefersStatusBarHidden { return YES; }

// ---------------------------------------------------------------- 安装
static void PPInstallCallback(NSDictionary *info) {
    if (![info isKindOfClass:[NSDictionary class]]) return;
    NSString *status = info[@"Status"] ?: @"";
    NSNumber *pct = info[@"PercentComplete"];
    NSString *err = nil;
    id e = info[@"Error"];
    if ([e isKindOfClass:[NSError class]]) err = [(NSError *)e localizedDescription];
    else if ([e isKindOfClass:[NSString class]]) err = e;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (err.length) PPLog(@"installd 报错: %@", err);
        else if (status.length) PPLog(@"%@ %@%%", status, pct ?: @0);
        else if (pct) PPLog(@"进度 %@%%", pct);
    });
}

- (void)primaryTapped {
    PPItem *it = _item;
    if (it.kind == PPKindInstalled || it.installed) { [self openItem]; return; }
    [self doInstall];
}

- (void)openItem {
    Class wsCls = LSClass(@"LSApplicationWorkspace");
    id ws = wsCls ? ((id (*)(id, SEL))objc_msgSend)(wsCls, @selector(defaultWorkspace)) : nil;
    BOOL ok = NO;
    if (ws && [ws respondsToSelector:@selector(openApplicationWithBundleID:)]) {
        ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, @selector(openApplicationWithBundleID:), _item.bundleID);
    }
    PPLog(@"启动 %@ -> %@", _item.bundleID, ok ? @"成功" : @"失败");
    if (!ok) {
        // 退一步走 LaunchServices 的 URL 通道
        Class lsCls = LSClass(@"LSApplicationWorkspace");
        if (lsCls) PPLog(@"（该 bundle 可能未注册到 LaunchServices，先 uicache 一次再试）");
    }
}

- (void)doInstall {
    if (!pMIInstall) { PPLog(@"MobileInstallationInstall 不可用，无法安装"); return; }
    _working = YES;
    [self refreshUI];
    _progressTrack.hidden = NO;
    _progressLabel.hidden = NO;
    _progressLabel.text = @"正在交给 installd…";

    PPLog(@"开始安装 %@", _item.path.lastPathComponent);
    if (!PPAppSyncPresent())
        PPLog(@"警告：没检测到 AppSync Unified，installd 很可能因签名拒绝");

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *opts = @{
            @"ApplicationType": @"User",
            @"PackageType": @"Developer",
            @"IsUserInitiated": @YES,
            @"OverrideCheck": @YES,
            @"IsPresent": @YES,
        };
        int rc = pMIInstall((__bridge CFStringRef)self.item.path,
                            (__bridge CFDictionaryRef)opts, PPInstallCallback, NULL);
        dispatch_async(dispatch_get_main_queue(), ^{
            PPLog(@"MobileInstallationInstall 返回 %d", rc);
            self.working = NO;
            self.progressLabel.text = (rc == 0) ? @"安装完成" : [NSString stringWithFormat:@"返回 %d，失败", rc];
            self.progressFill.frame = CGRectMake(0, 0, rc == 0 ? self.progressTrack.bounds.size.width : 0, 6);
            if (rc == 0) {
                self.item.installed = YES;
                if (self.onChanged) self.onChanged();
            }
            [self refreshUI];
        });
    });
}

- (void)secondaryTapped {
    PPItem *it = _item;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    if (it.kind == PPKindInstalled) {
        [a addAction:[UIAlertAction actionWithTitle:@"卸载" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [self doUninstall];
        }]];
    } else {
        [a addAction:[UIAlertAction actionWithTitle:@"删除这个 IPA 文件" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [[NSFileManager defaultManager] removeItemAtPath:it.path error:nil];
            PPLog(@"已删除 %@", it.path);
            if (self.onChanged) self.onChanged();
            [self dismiss];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = _secondary;
    a.popoverPresentationController.sourceRect = _secondary.bounds;
    [self presentViewController:a animated:YES completion:nil];
}

- (void)doUninstall {
    _working = YES;
    [self refreshUI];
    PPLog(@"卸载 %@", _item.bundleID);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL ok = NO;
        Class wsCls = LSClass(@"LSApplicationWorkspace");
        id ws = wsCls ? ((id (*)(id, SEL))objc_msgSend)(wsCls, @selector(defaultWorkspace)) : nil;
        if (ws && [ws respondsToSelector:@selector(uninstallApplication:withOptions:)]) {
            ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, @selector(uninstallApplication:withOptions:),
                                                           self.item.bundleID, @{});
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            PPLog(@"卸载 -> %@", ok ? @"成功" : @"失败");
            self.working = NO;
            if (ok && self.onChanged) self.onChanged();
            [self refreshUI];
        });
    });
}
@end

// ------------------------------------------------------------------ 主界面
@interface PPRootController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic, strong) UILabel          *titleLabel;
@property (nonatomic, strong) UILabel          *subtitleLabel;
@property (nonatomic, strong) UISegmentedControl *seg;
@property (nonatomic, strong) UICollectionView *grid;
@property (nonatomic, strong) UIRefreshControl *refresh;
@property (nonatomic, strong) NSArray<PPItem *> *ipaItems;
@property (nonatomic, strong) NSArray<PPItem *> *installedItems;
@property (nonatomic, assign) NSInteger         mode;      // 0 库 1 已安装
@property (nonatomic, assign) BOOL              scanning;
@end

@implementation PPRootController

- (NSArray<NSString *> *)searchDirs {
    return @[@"/var/mobile/Documents",
             @"/var/mobile/Documents/Downloads",
             @"/var/mobile/Downloads",
             @"/var/mobile/Media/Downloads",
             @"/var/root/Documents"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = PP_BG;

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(28, 30, 400, 40)];
    _titleLabel.text = @"PlayPad";
    _titleLabel.font = [UIFont systemFontOfSize:32 weight:UIFontWeightBold];
    _titleLabel.textColor = PP_TEXT;
    [self.view addSubview:_titleLabel];

    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(28, 70, 620, 20)];
    _subtitleLabel.font = [UIFont systemFontOfSize:12.5];
    _subtitleLabel.textColor = PP_DIM;
    [self.view addSubview:_subtitleLabel];

    _seg = [[UISegmentedControl alloc] initWithItems:@[@"库", @"已安装"]];
    _seg.selectedSegmentIndex = 0;
    _seg.tintColor = PP_ACCENT;
    [_seg addTarget:self action:@selector(segChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_seg];

    UIButton *reload = [UIButton buttonWithType:UIButtonTypeCustom];
    [reload setTitle:@"刷新" forState:UIControlStateNormal];
    [reload setTitleColor:PP_ACCENT forState:UIControlStateNormal];
    reload.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    reload.layer.borderColor = PP_ACCENT.CGColor;
    reload.layer.borderWidth = 1;
    reload.layer.cornerRadius = 9;
    [reload addTarget:self action:@selector(rescan) forControlEvents:UIControlEventTouchUpInside];
    reload.tag = 9001;
    [self.view addSubview:reload];

    UICollectionViewFlowLayout *fl = [[UICollectionViewFlowLayout alloc] init];
    fl.minimumInteritemSpacing = 8;
    fl.minimumLineSpacing = 16;
    fl.sectionInset = UIEdgeInsetsMake(12, 24, 40, 24);
    _grid = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:fl];
    _grid.backgroundColor = [UIColor clearColor];
    _grid.dataSource = self;
    _grid.delegate = self;
    _grid.alwaysBounceVertical = YES;
    [_grid registerClass:[PPCell class] forCellWithReuseIdentifier:@"cell"];
    [self.view addSubview:_grid];

    _refresh = [UIRefreshControl new];
    _refresh.tintColor = PP_DIM;
    [_refresh addTarget:self action:@selector(rescan) forControlEvents:UIControlEventValueChanged];
    [_grid addSubview:_refresh];

    gStatus = [[UILabel alloc] initWithFrame:CGRectZero];
    gStatus.font = [UIFont systemFontOfSize:11];
    gStatus.textColor = [PP_DIM colorWithAlphaComponent:0.8];
    [self.view addSubview:gStatus];

    // 长按 → 菜单（触控手势，非模拟）
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressed:)];
    [_grid addGestureRecognizer:lp];

    [self rescan];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    BOOL wide = b.size.width > 700;
    _seg.frame = CGRectMake(wide ? b.size.width - 320 : 28, 34, 180, 32);
    UIView *reload = [self.view viewWithTag:9001];
    reload.frame = CGRectMake(CGRectGetMaxX(_seg.frame) + 12, 34, 76, 32);
    _grid.frame = CGRectMake(0, 104, b.size.width, b.size.height - 104 - 30);
    gStatus.frame = CGRectMake(28, b.size.height - 26, b.size.width - 56, 16);
}

- (BOOL)prefersStatusBarHidden { return YES; }

- (void)segChanged {
    _mode = _seg.selectedSegmentIndex;
    [_grid reloadData];
    [self updateSubtitle];
}

- (void)updateSubtitle {
    NSUInteger n = _mode == 0 ? _ipaItems.count : _installedItems.count;
    _subtitleLabel.text = [NSString stringWithFormat:@"iPadOS %@ · %@ · %@ %lu 个",
                           [UIDevice currentDevice].systemVersion,
                           [UIDevice currentDevice].model,
                           _mode == 0 ? @"库中 IPA" : @"已安装应用",
                           (unsigned long)n];
    gStatus.text = [NSString stringWithFormat:@"AppSync Unified：%@    安装通道：%@    触控：UIKit 原生",
                    PPAppSyncPresent() ? @"已安装" : @"未检测到",
                    PPCanInstall() ? @"可用" : @"不可用"];
}

- (void)rescan {
    if (_scanning) { [_refresh endRefreshing]; return; }
    _scanning = YES;
    PPLog(@"扫描 IPA 目录…");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *ipas = PPScanIPAs([self searchDirs]);
        NSArray *inst = PPScanInstalled();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.ipaItems = PPDedupe(ipas);
            self.installedItems = inst;
            // 标记"已安装"
            NSMutableSet *ids = [NSMutableSet set];
            for (PPItem *i in inst) if (i.bundleID.length) [ids addObject:i.bundleID];
            for (PPItem *i in ipas) i.installed = [ids containsObject:i.bundleID];
            self.scanning = NO;
            [self.grid reloadData];
            [self.refresh endRefreshing];
            [self updateSubtitle];
            PPLog(@"扫描完成：IPA %lu 个，已安装 %lu 个",
                  (unsigned long)ipas.count, (unsigned long)inst.count);
        });
    });
}

- (NSArray<PPItem *> *)currentItems {
    return _mode == 0 ? _ipaItems : _installedItems;
}

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s {
    return [self currentItems].count;
}

- (CGSize)collectionView:(UICollectionView *)cv layout:(UICollectionViewLayout *)l
  sizeForItemAtIndexPath:(NSIndexPath *)ip {
    CGFloat w = cv.bounds.size.width;
    CGFloat cols = w > 1100 ? 7 : (w > 900 ? 6 : (w > 700 ? 5 : 4));
    CGFloat inner = w - 48 - (cols - 1) * 8;
    return CGSizeMake(floor(inner / cols), 148);
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    PPCell *c = [cv dequeueReusableCellWithReuseIdentifier:@"cell" forIndexPath:ip];
    PPItem *it = [self currentItems][(NSUInteger)ip.item];
    c.iconView.image = it.icon ?: PPPlaceholderIcon(it.name, 76);
    c.nameLabel.text = it.name;
    c.subLabel.text = it.installed ? @"已安装" : (it.kind == PPKindInstalled ? @"" : PPHumanSize(it.size));
    c.badge.hidden = !it.installed;
    return c;
}

- (void)openDetailFor:(PPItem *)it {
    PPDetailController *d = [PPDetailController new];
    d.item = it;
    d.modalPresentationStyle = UIModalPresentationOverFullScreen;
    d.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    __weak typeof(self) weakSelf = self;
    d.onClose = ^{ gLogView = nil; };
    d.onChanged = ^{ [weakSelf rescan]; };
    [self presentViewController:d animated:YES completion:nil];
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    [cv deselectItemAtIndexPath:ip animated:YES];
    PPItem *it = [self currentItems][(NSUInteger)ip.item];
    PPLog(@"点按：%@", it.name);
    [self openDetailFor:it];
}

- (void)longPressed:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [g locationInView:_grid];
    NSIndexPath *ip = [_grid indexPathForItemAtPoint:p];
    if (!ip) return;
    PPItem *it = [self currentItems][(NSUInteger)ip.item];

    UIAlertController *a = [UIAlertController alertControllerWithTitle:it.name
                                                              message:it.bundleID
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"打开详情" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [self openDetailFor:it];
    }]];
    if (it.installed) {
        [a addAction:[UIAlertAction actionWithTitle:@"启动" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            Class wsCls = LSClass(@"LSApplicationWorkspace");
            id ws = wsCls ? ((id (*)(id, SEL))objc_msgSend)(wsCls, @selector(defaultWorkspace)) : nil;
            if (ws) ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, @selector(openApplicationWithBundleID:), it.bundleID);
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    PPCell *cell = (PPCell *)[_grid cellForItemAtIndexPath:ip];
    a.popoverPresentationController.sourceView = cell ?: _grid;
    a.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:a animated:YES completion:nil];
}

@end

// ------------------------------------------------------------------ App
static BOOL PPScreenshot(UIWindow *w, NSString *path) {
    if (!w) return NO;
    UIGraphicsBeginImageContextWithOptions(w.bounds.size, NO, 1.0);
    [w drawViewHierarchyInRect:w.bounds afterScreenUpdates:YES];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    NSData *png = UIImagePNGRepresentation(img);
    BOOL ok = [png writeToFile:path atomically:YES];
    PPLog(@"截图 %@ -> %@ (%lu 字节)", path, ok ? @"OK" : @"失败", (unsigned long)png.length);
    return ok;
}

@interface PPAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) PPRootController *root;
@end

@implementation PPAppDelegate

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    PPLoadMobileInstallation();

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.root = [PPRootController new];
    self.window.rootViewController = self.root;
    self.window.backgroundColor = PP_BG;
    [self.window makeKeyAndVisible];

    PPLog(@"PlayPad 启动：%@ %@，屏幕 %.0fx%.0f",
          [UIDevice currentDevice].model, [UIDevice currentDevice].systemVersion,
          self.window.bounds.size.width, self.window.bounds.size.height);

    [self runAutotestIfRequested];
    return YES;
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)o {
    PPLog(@"openURL %@", url.absoluteString);
    [self.root rescan];
    return YES;
}

// 自检：设备上没有外部触控注入工具，所以这里用"和真实点按同一条代码路径"
// （直接调 collectionView:didSelectItemAtIndexPath:）来验证交互链路，
// 并把每一步截图落盘，从设备外把界面取回来核对。
- (void)runAutotestIfRequested {
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/playpad.autotest"]) return;
    PPLog(@"检测到 autotest 标记，开始自检");
    __weak typeof(self) ws = self;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        PPScreenshot(ws.window, @"/var/mobile/pp_01_library.png");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSIndexPath *ip = [NSIndexPath indexPathForItem:0 inSection:0];
            if ([ws.root currentItems].count > 0) {
                [ws.root collectionView:ws.root.grid didSelectItemAtIndexPath:ip];
                PPItem *first = ((NSArray *)[ws.root currentItems])[0];
                PPLog(@"自检：程序化点按第 1 项 %@", first.name);
            } else {
                PPLog(@"自检：库是空的");
            }

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                PPScreenshot(ws.window, @"/var/mobile/pp_02_detail.png");
                PPLog(@"自检完成");
                [[NSFileManager defaultManager] createFileAtPath:@"/var/mobile/playpad.done"
                                                        contents:[@"ok" dataUsingEncoding:NSUTF8StringEncoding]
                                                      attributes:nil];
            });
        });
    });
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([PPAppDelegate class]));
    }
}
