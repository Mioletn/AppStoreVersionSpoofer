// AppStoreVersionSpoofer — 设置面板控制器（修复版）
//
// 修复点：
//  - 原版用 system("killall -9 SpringBoard") 强制杀进程，既不优雅也有安全风险；
//    改为使用 notify_post("com.apple.springboard.reboot") 通知 SpringBoard 重启。
//  - 为避免偏好 bundle 链接私有 Preferences.framework 在部分 iOS 12 越狱环境下
//    导致 Settings 加载 bundle 时崩溃，这里用前向声明而非 #import 私有头文件；
//    运行时 Settings 自身已加载 Preferences.framework，PSListController 与方法
//    均可正常解析，无需在 bundle 内再链接该私有框架。

#import <Foundation/Foundation.h>
#import <notify.h>

@class UIViewController;

@interface PSListController : UIViewController
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface RootListController : PSListController
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
