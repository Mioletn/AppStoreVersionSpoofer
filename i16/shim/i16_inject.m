// i16_inject.m —— i16shim.dylib 被注入到别的进程时的自举
//
// 这个文件只在 dylib 里编（app 自己不需要）。它做一件事：
// 发现自己运行在一个"别人"的进程里，就把 i16 的全部能力在那个进程里跑一遍，
// 把结果写到 /var/mobile/i16_inject_<bundleid>.txt。
//
// 为什么值得这么做：面板上写"已实现"，只能证明在 i16 自己的进程里可用。
// 真正要回答的问题是 —— 把这些 API 塞进一个第三方的、2019 年编译的 App 进程里，
// 它们还成不成立？UIColor 的 metaclass 加方法在别的进程里会不会被系统覆盖？
// UTTypeConformsTo 在那个进程的链接上下文里解不解析得开？
// 答案要跑出来，不能推断。

#import "i16.h"
#import <UIKit/UIKit.h>

__attribute__((constructor))
static void i16_shim_bootstrap(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    // i16 自己的面板不需要这条通路，它会从界面里跑。
    if (!bid || [bid isEqualToString:@"com.i16.panel"]) return;

    // constructor 执行时 UIKit 还没进入可用状态（创建 cell / 取 window 会出问题），
    // 所以挂到主队列延后执行 —— 那时 runloop 已经转起来，第一帧也画完了。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @autoreleasepool {
            NSString *report = I16RunSelfTest();
            NSString *path = [NSString stringWithFormat:
                              @"/var/mobile/i16_inject_%@.txt", bid];
            NSError *err = nil;
            BOOL ok = [report writeToFile:path
                               atomically:YES
                                 encoding:NSUTF8StringEncoding
                                    error:&err];
            NSLog(@"[i16shim] injected into %@ -> %@ ok=%d err=%@",
                  bid, path, ok, err);
        }
    });
}
