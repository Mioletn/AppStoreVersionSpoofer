// i16_list.m —— iOS 14 的 UIListContentConfiguration
//
// iOS 14 把"cell 长什么样"从一堆散装属性（textLabel.text / detailTextLabel /
// imageView.image / 各种 offset）收敛成一个配置对象：
//
//     UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
//     c.text = @"标题";  c.secondaryText = @"副标题";
//     cell.contentConfiguration = c;
//
// 12.2 上 cell 本来就能排出完全一样的效果，只是没有这层对象。所以这里做两件事：
//   1. 一个纯数据的 UIListContentConfiguration，字段语义与 14 一致；
//   2. 给 UITableViewCell 补 contentConfiguration 的 setter，把配置落到
//      textLabel / detailTextLabel / imageView 上。
//
// 为什么标 approx 而不是 shim：iOS 14 的 contentConfiguration 参与 cell 的
// 自动布局（self-sizing、多行 accessory、contentMargin），12.2 的 textLabel
// 是固定 frame。文字和图片对得上，复杂布局对不齐 —— 这个差别说清楚，不粉饰。
//
// 注入到 iOS 14+ 的进程里时，系统已经有 contentConfiguration，class_addMethod
// 会失败并被我们忽略，系统的实现优先。

#import "i16.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// contentConfiguration 这个名字在 12.4 的头文件里不存在，@selector 直接写会警告。
#pragma clang diagnostic ignored "-Wundeclared-selector"

@interface UIListContentConfiguration : NSObject
@property (nonatomic, copy)   NSString *text;
@property (nonatomic, copy)   NSString *secondaryText;
@property (nonatomic, strong) UIImage  *image;

+ (instancetype)cellConfiguration;
+ (instancetype)subtitleCellConfiguration;
+ (instancetype)valueCellConfiguration;
@end

@implementation UIListContentConfiguration

+ (instancetype)cellConfiguration {
    return [self new];
}

+ (instancetype)subtitleCellConfiguration {
    UIListContentConfiguration *c = [self new];
    return c;
}

+ (instancetype)valueCellConfiguration {
    UIListContentConfiguration *c = [self new];
    return c;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<UIListContentConfiguration '%@' / '%@'%@>",
            self.text, self.secondaryText, self.image ? @" +image" : @""];
}

@end

// ---------------------------------------------------------------- cell 侧
// 用 KVC 取值，避免把两个类的头文件互相拽进来。
static void i16_cell_set_content_configuration(id self, SEL _cmd, id cfg) {
    UITableViewCell *cell = (UITableViewCell *)self;
    if (!cfg) {
        cell.textLabel.text = nil;
        cell.detailTextLabel.text = nil;
        cell.imageView.image = nil;
        return;
    }
    cell.textLabel.text = [cfg valueForKey:@"text"];
    cell.detailTextLabel.text = [cfg valueForKey:@"secondaryText"];
    cell.imageView.image = [cfg valueForKey:@"image"];
}

// getter 从 cell 当前状态反推一个配置对象 —— iOS 14 上这个属性是可读可写的，
// 读回来应该能反映 cell 现状。
static id i16_cell_get_content_configuration(id self, SEL _cmd) {
    UITableViewCell *cell = (UITableViewCell *)self;
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    c.text = cell.textLabel.text;
    c.secondaryText = cell.detailTextLabel.text;
    c.image = cell.imageView.image;
    return c;
}

void I16ListInstall(void) {
    static int done = 0;
    if (done) return;
    done = 1;

    Class cls = [UITableViewCell class];
    SEL setter = @selector(setContentConfiguration:);
    SEL getter = @selector(contentConfiguration);
    // 有就放手：iOS 14+ 的系统实现必须优先。
    if (!class_getInstanceMethod(cls, setter)) {
        class_addMethod(cls, setter, (IMP)i16_cell_set_content_configuration, "v@:@");
    }
    if (!class_getInstanceMethod(cls, getter)) {
        class_addMethod(cls, getter, (IMP)i16_cell_get_content_configuration, "@@:");
    }
}

NSString *I16ListDemo(void) {
    I16ListInstall();

    // 真造一个 cell，真写进去，再从 cell 读回来 —— 读回来的值才算数。
    UITableViewCell *cell =
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                               reuseIdentifier:@"i16demo"];

    UIListContentConfiguration *cfg = [UIListContentConfiguration subtitleCellConfiguration];
    cfg.text = @"标题";
    cfg.secondaryText = @"副标题";

    BOOL setterOK = [cell respondsToSelector:@selector(setContentConfiguration:)];
    if (!setterOK) return @"cell 没有 contentConfiguration，安装没生效";

    // 不能写 cell.contentConfiguration = cfg：12.4 的 UITableViewCell 没有这个属性，
    // 直接写是编译错误。走 msgSend，运行时才有意义。
    ((void (*)(id, SEL, id))objc_msgSend)(cell, @selector(setContentConfiguration:), cfg);

    NSString *back = cell.textLabel.text;
    NSString *back2 = cell.detailTextLabel.text;
    BOOL match = [back isEqualToString:@"标题"] && [back2 isEqualToString:@"副标题"];

    return [NSString stringWithFormat:
            @"写入配置后从 cell 读回：text=%@ secondary=%@ 一致=%d",
            back, back2, match];
}
