// main.m —— App 壳
//
// 界面在 ui16.m。这里只做三件事：起窗口、接 URL scheme、把自检结果落盘。
//
// URL scheme：
//   i16://selftest   全量自检，写 /var/mobile/i16_selftest.txt
//   i16://shot       把首页和详情页各截一张图，写 /var/mobile/i16_home.png
//                    /var/mobile/i16_detail.png
//
// 为什么要有 shot：设备上没有可用的触摸注入工具，也没有 screencapture。
// 界面这种东西，「布局参数都对」不等于「看起来对」—— 得拿到像素。

#import <UIKit/UIKit.h>
#import "i16.h"
#import "ui16.h"

// 实现在 app/inapp_probe.m。声明放这里而不是新建头文件：只有一个调用点。
FOUNDATION_EXPORT NSString *I16InAppProbe(void);

@interface I16AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation I16AppDelegate

- (BOOL)application:(UIApplication *)app
        didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.rootViewController = I16UIRoot();
    [self.window makeKeyAndVisible];
    return YES;
}

- (BOOL)application:(UIApplication *)app
            openURL:(NSURL *)url
            options:(NSDictionary *)options {
    NSString *host = url.host;

    if ([host isEqualToString:@"selftest"]) {
        // 等窗口稳定再跑，否则 alert 会挂在还没上屏的 VC 上。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self runSelfTest];
        });
        return YES;
    }

    if ([host isEqualToString:@"streamtest"]) {
        // 采集要在 App 进程里跑：这里才有真正的图形上下文。
        // 放后台队列，别把主线程卡住。
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *r = I16InAppProbe();
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *ac =
                    [UIAlertController alertControllerWithTitle:@"采集探针完成"
                                                        message:r
                                                 preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                                       style:UIAlertActionStyleCancel
                                                     handler:nil]];
                [self.window.rootViewController presentViewController:ac animated:YES completion:nil];
            });
        });
        return YES;
    }

    if ([host isEqualToString:@"shot"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            I16UISnapshotAll(@"/var/mobile");
        });
        return YES;
    }

    return NO;
}

- (void)runSelfTest {
    NSString *report = I16RunSelfTest();
    NSString *path = @"/var/mobile/i16_selftest.txt";

    NSError *err = nil;
    BOOL ok = [report writeToFile:path
                       atomically:YES
                         encoding:NSUTF8StringEncoding
                            error:&err];
    NSLog(@"[i16] selftest -> %@ ok=%d err=%@\n%@", path, ok, err, report);

    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:
            (ok ? @"自检完成，已写入 i16_selftest.txt" : @"自检完成，但写文件失败")
                                            message:report
                                     preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
    [self.window.rootViewController presentViewController:ac animated:YES completion:nil];
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, @"I16AppDelegate");
    }
}
