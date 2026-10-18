// AppStoreVersionSpoofer — 设置面板控制器（修复版）
//
// 修复点：
//  - 原版用 system("killall -9 SpringBoard") 强制杀进程，既不优雅也有安全风险；
//    改为使用 notify_post("com.apple.springboard.reboot") 通知 SpringBoard 重启。
//  - 源码用前向声明 + 类扩展属性（而非 #import 私有头文件，SDK 不含其公开头），
//    同时在 Makefile 中以 PRIVATE_FRAMEWORKS 链接 Preferences.framework 的链接桩；
//    运行时 Settings 自身已加载该框架，符号在宿主进程内解析，不会引起重复加载或闪退。

#import <Foundation/Foundation.h>
#import <notify.h>

@class UIViewController;

@interface PSListController : UIViewController
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface RootListController : PSListController
@end

// 类扩展中声明 specifiers 属性，让编译器为本类合成 _specifiers 实例变量，
// 从而免依赖私有头文件即可编译（运行时由真实 PSListController 提供方法实现）。
@interface RootListController ()
@property (nonatomic, retain) NSArray *specifiers;
@end

@implementation RootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// 通过 notify 通知 SpringBoard 安全重启，取代 system("killall -9")
- (void)respring:(id)sender {
    notify_post("com.apple.springboard.reboot");
}

@end
