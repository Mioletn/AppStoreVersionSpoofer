// AppStoreVersionSpoofer — 设置面板控制器（修复版）
//
// 修复点：
//  - 原版用 system("killall -9 SpringBoard") 强制杀进程，既不优雅也有安全风险；
//    改为使用 notify_post("com.apple.springboard.reboot") 通知 SpringBoard 重启。
//  - 增加头部说明组，符合 HIG「为操作提供上下文」的要求。

#import <Preferences/Preferences.h>
#import <notify.h>

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
