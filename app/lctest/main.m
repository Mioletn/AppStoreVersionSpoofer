// lctest — 用**系统 dyld**加载一个 iOS 13+ 的 dylib，看它到底缺什么
//
// 为什么不能只用 macpadcli 判断：
//   macpadcli 是进程内装载器，它用 dlsym(RTLD_DEFAULT) 找符号。它自己只链了
//   libSystem，所以 Foundation 的私有符号（__NSDictionary0__struct 之类）一律
//   查不到，被误判成"缺失"。
//   真正决定成败的是**系统 dyld**：它按 load command 里的 ordinal 去对应
//   镜像的导出表里找，能拿到那些私有符号。
//
// 所以这个探针只做一件事：dlopen 目标 dylib，把 dyld 的原话打出来。
// 成功就意味着 ObjC 类注册、Swift 运行时初始化、initializer 全由系统办妥了。
//
// 用法：lctest <dylib 路径> [要找的符号 ...]

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "用法: lctest <dylib> [sym ...]\n");
            return 2;
        }
        const char *path = argv[1];
        printf("=== lctest %s ===\n", path);
        printf("  系统版本: %s\n", [[[UIDevice currentDevice] systemVersion] UTF8String]);

        // RTLD_NOW：立刻解析所有符号。用 RTLD_LAZY 会把问题推迟到调用时才炸，
        // 那样看不出到底缺什么。
        void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
        if (!h) {
            printf("  ✗ dlopen 失败\n  dyld 说: %s\n", dlerror());
            return 1;
        }
        printf("  ✓ dlopen 成功\n");

        // 报一下这个镜像里有几个 ObjC 类 —— 能数出来说明类已经注册进来了
        unsigned int n = 0;
        const char **names = objc_copyClassNamesForImage(path, &n);
        printf("  ObjC 类: %u 个\n", n);
        for (unsigned int i = 0; i < n && i < 12; i++) printf("     - %s\n", names[i]);
        if (names) free(names);

        for (int i = 2; i < argc; i++) {
            void *s = dlsym(h, argv[i]);
            printf("  dlsym(%s) = %p\n", argv[i], s);
        }
        printf("=== 结论：这个镜像在 iOS %s 上可以加载 ===\n",
               [[[UIDevice currentDevice] systemVersion] UTF8String]);
        return 0;
    }
}
