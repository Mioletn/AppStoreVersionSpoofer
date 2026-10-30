// sfprobe v4 —— 在设备上渲染 i16symbols.pdf，出一张对照图
//
// 前三轮已经把 car 那条路走死了（v1 名字通/取图 nil，v2 扫 90 组参数全 nil，
// v3 私有入口直接断言崩溃），结论与证据都写在 shim/i16_symbol.m 的注释里。
// 现在要验证的是新素材形态：
//
//   i16symbols.pdf   一页一个符号，页尺寸 = 符号固有尺寸
//   i16symbols.json  名字 -> 页码 + 尺寸
//   渲染只需要 CoreGraphics：CGPDFPage + CGBitmapContext
//
// 为什么要跑在设备上而不是本地看一眼就算：
//   PDF 是我自己写的（build_symbols.py 里手写的对象表与内容流），
//   PC 上的 PDF 库读得通不代表 12.2 的 CoreGraphics 读得通。
//   交叉验证一遍，才知道这个文件是「合法 PDF」还是「恰好被某一家的解析器容忍」。
//   同时把渲染出的 PNG 拉回来看 —— 形状对了才算数，尺寸对不代表画面对。

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <stdio.h>
#import <stdarg.h>
#import <unistd.h>

static void L(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    printf("%s\n", [s UTF8String]);
    fflush(stdout);
}

// 和 shim 里同一套画法：按固有宽高比算目标尺寸，铺满画布，黑色透明底。
static CGImageRef render(CGPDFDocumentRef doc, CGPDFPageRef page, CGFloat pt, double scale) {
    CGRect box = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
    if (box.size.width < 1 || box.size.height < 1) return NULL;
    CGFloat h = pt, w = pt * (box.size.width / box.size.height);
    size_t pw = (size_t)lround(w * scale), ph = (size_t)lround(h * scale);
    if (pw < 1 || ph < 1) return NULL;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, pw, ph, 8, pw * 4, cs,
                                             kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGContextScaleCTM(ctx, pw / box.size.width, ph / box.size.height);
    CGContextTranslateCTM(ctx, -box.origin.x, -box.origin.y);
    CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
    CGContextDrawPDFPage(ctx, page);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return img;
}

int main(int argc, char **argv) {
    NSString *dir = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"/Library/i16";
    NSString *pdfPath = [dir stringByAppendingPathComponent:@"i16symbols.pdf"];
    NSString *idxPath = [dir stringByAppendingPathComponent:@"i16symbols.json"];

    L(@"sfprobe v4 · uid=%u · %@", (unsigned)getuid(),
      [[NSProcessInfo processInfo] operatingSystemVersionString]);
    L(@"资源目录 = %@", dir);

    NSData *jd = [NSData dataWithContentsOfFile:idxPath];
    NSDictionary *idx = jd ? [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil] : nil;
    NSArray *names = idx[@"names"];
    L(@"索引：%@", names ? [NSString stringWithFormat:@"%lu 个名字", (unsigned long)names.count]
                        : @"读不出来");
    if (!names.count) return 1;

    NSURL *url = [NSURL fileURLWithPath:pdfPath];
    CGPDFDocumentRef doc = CGPDFDocumentCreateWithURL((__bridge CFURLRef)url);
    if (!doc) { L(@"[x] CGPDFDocument 打不开 %@", pdfPath); return 1; }
    size_t pages = CGPDFDocumentGetNumberOfPages(doc);
    L(@"PDF：%zu 页，文件 %.1f MB", pages, [[NSFileManager defaultManager]
        attributesOfItemAtPath:pdfPath error:nil].fileSize / 1048576.0);
    if (pages != names.count) L(@"  !! 页数与名字数不一致，索引会错位");

    // ---- 单点验证：尺寸能不能跟着变
    L(@"\n== 单符号多尺寸 ==");
    NSInteger ok = 0;
    NSString *first = @"heart.fill";
    if (![names containsObject:first]) first = names[0];
    NSUInteger pageNo = [names indexOfObject:first] + 1;
    CGPDFPageRef pg = CGPDFDocumentGetPage(doc, pageNo);
    for (CGFloat pt = 11; pt <= 88; pt *= 2) {
        // 无级缩放：同一个页，不同目标点高，像素尺寸应当线性增长
        CGImageRef c = render(doc, pg, pt, 2.0);
        if (c) {
            L(@"  %-12@ %2.0fpt -> %zux%zu px", first, pt, CGImageGetWidth(c), CGImageGetHeight(c));
            CGImageRelease(c);
            ok++;
        } else {
            L(@"  %-12@ %2.0fpt -> NULL", first, pt);
        }
    }

    // ---- 出一张对照图：挑不同年代的符号，按 8 个一行铺开
    NSArray *pick = @[@"heart.fill", @"gear", @"trash", @"square.and.arrow.up",
                      @"magnifyingglass", @"play.fill", @"person.crop.circle",
                      @"airpods", @"bell", @"camera", @"envelope", @"calendar"];
    CGFloat cell = 96, pad = 8, pt = 64;
    size_t side = (size_t)(cell * pick.count + pad * 2);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef sheet = CGBitmapContextCreate(NULL, side, (size_t)cell + (size_t)pad * 2,
                                              8, side * 4, cs,
                                              kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    CGContextSetRGBFillColor(sheet, 0.11, 0.11, 0.13, 1);
    CGContextFillRect(sheet, CGRectMake(0, 0, side, cell + pad * 2));

    NSInteger drawn = 0;
    for (NSUInteger i = 0; i < pick.count; i++) {
        CGRect r = CGRectMake(pad + cell * i, pad, cell, cell);
        CGContextSetRGBFillColor(sheet, 1, 1, 1, 1);
        CGContextFillRect(sheet, r);
        NSUInteger n = [names indexOfObject:pick[i]];
        if (n == NSNotFound) { L(@"  缺 %@", pick[i]); continue; }
        CGPDFPageRef p = CGPDFDocumentGetPage(doc, n + 1);
        if (!p) { L(@"  页 %lu 取不到（%@）", (unsigned long)n + 1, pick[i]); continue; }
        CGImageRef c = render(doc, p, pt, 1.0);
        if (!c) { L(@"  渲染失败 %@", pick[i]); continue; }
        CGContextDrawImage(sheet, CGRectInset(r, 10, 10), c);
        CGImageRelease(c);
        drawn++;
    }

    CGImageRef sheetImg = CGBitmapContextCreateImage(sheet);
    CGContextRelease(sheet);
    NSURL *out = [NSURL fileURLWithPath:@"/var/mobile/sf_sheet.png"];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)out,
                                                               CFSTR("public.png"), 1, NULL);
    BOOL wrote = NO;
    if (dst) {
        CGImageDestinationAddImage(dst, sheetImg, NULL);
        wrote = CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
    CGImageRelease(sheetImg);
    CGPDFDocumentRelease(doc);

    L(@"\n== 结论 ==");
    L(@"  多尺寸渲染 %ld/5 · 对照图画出 %ld/%lu · PNG %@",
      (long)ok, (long)drawn, (unsigned long)pick.count, wrote ? @"已写入 /var/mobile/sf_sheet.png" : @"写失败");
    return 0;
}
