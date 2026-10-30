// i16_menu.m —— iOS 13/14 的 UIAction / UIMenu，在 12.2 上落地
//
// 这两个类型是 iOS 13 引入的"声明式菜单"。UIKit 用它做长按菜单、下拉按钮、
// 导航栏溢出菜单。12.2 上完全没有，所以任何用它们构建界面的 App 一碰就崩。
//
// 补法分两层，必须分清：
//   · 数据层（这里做的）：UIAction / UIMenu 当作纯数据容器，完整可用。
//     构造、嵌套、取 children、触发 handler —— 语义和 13 一致。
//   · 呈现层（这里只做到近似）：13 用 UIContextMenuInteraction 弹浮层，
//     12 上弹不了那种浮层。这里降到 UIAlertController（actionSheet），
//     项数、顺序、handler 都对，外观不一样。
//
// 所以这一项在面板上标 approx，不标 shim —— 数据结构是真的，呈现是近似的。

#import "i16.h"
#import <UIKit/UIKit.h>

// ---------------------------------------------------------------- UIAction
// 12.2 的 UIKit 里没有这两个名字，这里定义不会和系统冲突。
// 反过来，注入到 iOS 13+ 的进程里时，系统的那份已经注册，我们的定义会被忽略
// （类名在 objc 运行时里先到先得），这正好是想要的行为。
@interface UIAction : NSObject
@property (nonatomic, copy)   NSString *title;
@property (nonatomic, copy)   UIImage  *image;
@property (nonatomic, copy)   NSString *identifier;
@property (nonatomic, assign, getter=isDisabled) BOOL disabled;
@property (nonatomic, copy)   void (^handler)(UIAction *action);
+ (instancetype)actionWithTitle:(NSString *)title
                          image:(UIImage *)image
                     identifier:(NSString *)identifier
                        handler:(void (^)(UIAction *action))handler;
@end

@implementation UIAction
+ (instancetype)actionWithTitle:(NSString *)title
                          image:(UIImage *)image
                     identifier:(NSString *)identifier
                        handler:(void (^)(UIAction *))handler {
    UIAction *a = [self new];
    a.title = title;
    a.image = image;
    a.identifier = identifier;
    a.handler = handler;
    return a;
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<UIAction %@ '%@'%@>",
            self.identifier, self.title, self.disabled ? @" disabled" : @""];
}
@end

// ---------------------------------------------------------------- UIMenu
@interface UIMenu : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray  *children;
+ (instancetype)menuWithTitle:(NSString *)title children:(NSArray *)children;
+ (instancetype)menuWithTitle:(NSString *)title
                        image:(UIImage *)image
                   identifier:(NSString *)identifier
                      options:(NSUInteger)options
                     children:(NSArray *)children;
@end

@implementation UIMenu
+ (instancetype)menuWithTitle:(NSString *)title children:(NSArray *)children {
    return [self menuWithTitle:title image:nil identifier:nil options:0
                      children:children];
}
+ (instancetype)menuWithTitle:(NSString *)title
                        image:(UIImage *)image
                   identifier:(NSString *)identifier
                      options:(NSUInteger)options
                     children:(NSArray *)children {
    UIMenu *m = [self new];
    m.title = title;
    m.children = children ?: @[];
    return m;
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<UIMenu '%@' %lu 项>",
            self.title, (unsigned long)self.children.count];
}
@end

// ---------------------------------------------------------------- 呈现层降级
// 把一个 UIMenu 摊平成 UIAlertController。嵌套的菜单只取第一层 ——
// actionSheet 没有子菜单概念，拍平会把层级压掉，所以宁可只取一层并说明。
static UIAlertController *i16_alert_from_menu(UIMenu *menu,
                                              UIViewController *host) {
    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:menu.title
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    for (id child in menu.children) {
        if (![child isKindOfClass:[UIAction class]]) continue;   // 子菜单跳过
        UIAction *a = child;
        if (a.disabled) continue;
        [ac addAction:[UIAlertAction actionWithTitle:a.title
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *_) {
            if (a.handler) a.handler(a);
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
    if (!host) return ac;

    // iPad 上 actionSheet 必须有 popover 锚点，否则直接抛异常。
    ac.popoverPresentationController.sourceView = host.view;
    ac.popoverPresentationController.sourceRect =
        CGRectMake(host.view.bounds.size.width / 2,
                   host.view.bounds.size.height / 2, 1, 1);
    [host presentViewController:ac animated:YES completion:nil];
    return ac;
}

void I16MenuInstall(void) {
    // 数据层不需要安装步骤：类在加载时就已经注册。
    // 这个函数存在是为了让调用方不必区分"哪些模块需要 install"。
}

NSString *I16MenuDemo(void) {
    UIAction *a1 = [UIAction actionWithTitle:@"复制" image:nil
                                  identifier:@"copy" handler:^(UIAction *a) {}];
    UIAction *a2 = [UIAction actionWithTitle:@"分享" image:nil
                                  identifier:@"share" handler:^(UIAction *a) {}];
    UIAction *a3 = [UIAction actionWithTitle:@"删除" image:nil
                                  identifier:@"delete" handler:^(UIAction *a) {}];
    a3.disabled = YES;

    UIMenu *sub = [UIMenu menuWithTitle:@"更多" children:@[a2]];
    UIMenu *root = [UIMenu menuWithTitle:@"操作" children:@[a1, sub, a3]];

    // 转一次 actionSheet，确认呈现层这条路是通的（不真的弹）。
    UIAlertController *ac = i16_alert_from_menu(root, nil);
    NSUInteger actions = ac.actions.count;   // 2 个可用 + 取消，子菜单被跳过

    return [NSString stringWithFormat:
            @"UIAction 构造 %lu 个，UIMenu 两层嵌套，降级成 actionSheet 后 %lu 个可用项（子菜单不摊平）",
            (unsigned long)3, (unsigned long)actions];
}
