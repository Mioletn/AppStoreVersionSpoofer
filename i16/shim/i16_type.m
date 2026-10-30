// i16_type.m —— iOS 14 的 UTType，映射回 12.2 就有的 UTI
//
// iOS 14 把"文件类型"从字符串（UTI）升级成一个类型对象：UTType。
// 好处是能表达"我需要一张图片，具体格式随意"（conformsTo 语义）。
// 12.2 上这套能力其实一直都在 —— 就是 MobileCoreServices 的 UTI 函数，
// 只是没有面向对象的门面。
//
// 所以这里不是"重新实现"，是"给已有能力套上 14 的门面"：
//   UTType.identifier  ←→  UTI 字符串
//   -conformsToType:   ←→  UTTypeConformsTo()
// 真实的一致性判断交给系统，不自己编表。
//
// 两个踩过的坑，都在编译期：
//   1. 这套精简 iPhoneOS12.4.sdk 的 MobileCoreServices 没把 UTCoreTypes 带进来，
//      kUTTypeItem 这一类常量全部 undeclared。它们本来就是公开的 UTI 字符串，
//      直接写字面量即可，不依赖 SDK 裁到什么程度。
//   2. UTTypeConformsTo 同理没声明，但符号在设备上确实有（MobileCoreServices 导出），
//      所以自己 extern 一下，链接期由 -framework MobileCoreServices 解析。

#import "i16.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>

extern Boolean UTTypeConformsTo(CFStringRef inUTI, CFStringRef inConformsToUTI);

@interface UTType : NSObject
// 13+ 里是 readonly；这里必须可写，因为值要由 +typeWithIdentifier: 填。
// 对外仍然当 readonly 用 —— 头文件只暴露我们想暴露的部分。
@property (nonatomic, copy) NSString *identifier;
+ (instancetype)typeWithIdentifier:(NSString *)identifier;

+ (UTType *)item;
+ (UTType *)data;
+ (UTType *)image;
+ (UTType *)png;
+ (UTType *)jpeg;
+ (UTType *)gif;
+ (UTType *)movie;
+ (UTType *)audio;
+ (UTType *)text;
+ (UTType *)plainText;
+ (UTType *)html;
+ (UTType *)json;
+ (UTType *)pdf;
+ (UTType *)zip;
+ (UTType *)folder;
+ (UTType *)url;
+ (UTType *)fileURL;

- (BOOL)conformsToType:(UTType *)other;
- (BOOL)isEqual:(id)object;
@end

@implementation UTType

+ (instancetype)typeWithIdentifier:(NSString *)identifier {
    if (!identifier) return nil;
    UTType *t = [self new];
    t.identifier = identifier;
    return t;
}

// 统一入口。字符串就是 UTI 本身，不经过 kUTType* 常量。
static UTType *i16_ut(NSString *uti) {
    if (!uti) return nil;
    return [UTType typeWithIdentifier:uti];
}

+ (UTType *)item      { return i16_ut(@"public.item"); }
+ (UTType *)data      { return i16_ut(@"public.data"); }
+ (UTType *)image     { return i16_ut(@"public.image"); }
+ (UTType *)png       { return i16_ut(@"public.png"); }
+ (UTType *)jpeg      { return i16_ut(@"public.jpeg"); }
+ (UTType *)gif       { return i16_ut(@"com.compuserve.gif"); }
+ (UTType *)movie     { return i16_ut(@"public.movie"); }
+ (UTType *)audio     { return i16_ut(@"public.audio"); }
+ (UTType *)text      { return i16_ut(@"public.text"); }
+ (UTType *)plainText { return i16_ut(@"public.plain-text"); }
+ (UTType *)html      { return i16_ut(@"public.html"); }
+ (UTType *)json      { return i16_ut(@"public.json"); }
+ (UTType *)pdf       { return i16_ut(@"com.adobe.pdf"); }
+ (UTType *)zip       { return i16_ut(@"public.zip-archive"); }
+ (UTType *)folder    { return i16_ut(@"public.folder"); }
+ (UTType *)url       { return i16_ut(@"public.url"); }
+ (UTType *)fileURL   { return i16_ut(@"public.file-url"); }

- (BOOL)conformsToType:(UTType *)other {
    if (!other || !other.identifier || !self.identifier) return NO;
    // 13+ 上 identifier 相同即视为同一类型；conformsTo 也把自身算进去。
    if ([self.identifier isEqualToString:other.identifier]) return YES;
    return UTTypeConformsTo((__bridge CFStringRef)self.identifier,
                            (__bridge CFStringRef)other.identifier) ? YES : NO;
}

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[UTType class]]) return NO;
    return [self.identifier isEqualToString:((UTType *)object).identifier];
}

- (NSUInteger)hash { return self.identifier.hash; }

- (NSString *)description {
    return [NSString stringWithFormat:@"<UTType %@>", self.identifier];
}

@end

void I16TypeInstall(void) {
    // 同样是"类在加载时已注册"，无安装步骤。
}

NSString *I16TypeDemo(void) {
    UTType *png   = [UTType png];
    UTType *image = [UTType image];
    UTType *text  = [UTType plainText];

    BOOL pngIsImage = [png conformsToType:image];
    BOOL pngIsText  = [png conformsToType:text];
    BOOL textIsText = [text conformsToType:text];

    return [NSString stringWithFormat:
            @"png→image=%d  png→text=%d  text→text=%d  png.identifier=%@",
            pngIsImage, pngIsText, textIsText, png.identifier];
}
