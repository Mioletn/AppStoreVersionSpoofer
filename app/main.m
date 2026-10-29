// macPad — 在 iOS 12.2 / A12X 上运行 macOS 11 的用户态二进制
//
// 思路：不走 exec（AMFI 会杀掉未签名二进制），而是在本进程 fork 出的子进程里
// 自己把 Mach-O 映射进来、自己修指针、自己跳进去。详见 loader.c 顶部注释。
//
// 每个命令都在独立子进程里跑，所以：
//   * 苹果程序的 _exit() 不会带走 App
//   * 程序之间的堆/stdio/locale 状态互不污染
//   * 崩溃只影响那一条命令

#import <UIKit/UIKit.h>
#import <sys/wait.h>
#import <unistd.h>
#import <fcntl.h>
#import <signal.h>

int macpad_run(const char *path, int argc, char **argv, char **envp, int verbose);
const char *macpad_host(void);

// ------------------------------------------------------------------ 配色
#define C_BG        [UIColor colorWithRed:0.043 green:0.055 blue:0.078 alpha:1.0]
#define C_PANEL     [UIColor colorWithRed:0.078 green:0.094 blue:0.125 alpha:1.0]
#define C_STROKE    [UIColor colorWithRed:0.16  green:0.19  blue:0.24  alpha:1.0]
#define C_TEXT      [UIColor colorWithRed:0.85  green:0.89  blue:0.94  alpha:1.0]
#define C_DIM       [UIColor colorWithRed:0.45  green:0.51  blue:0.58  alpha:1.0]
#define C_ACCENT    [UIColor colorWithRed:0.36  green:0.85  blue:0.62  alpha:1.0]
#define C_WARN      [UIColor colorWithRed:0.98  green:0.65  blue:0.30  alpha:1.0]

// 控制台内容同时落一份到磁盘：既是给用户的日志，也方便远程排查
// （GUI 里的输出人不在设备旁就看不到）。
// 多路径尝试：/var/mobile 在无沙盒下可写，但万一 entitlement 没被内核接受，
// App 会被关进自己的容器，那时只有 NSTemporaryDirectory() 能落盘。
static NSString *g_logPath = nil;

static NSString *pick_log_path(void) {
    NSArray *cands = @[@"/var/mobile/macpad_app.log",
                       @"/tmp/macpad_app.log",
                       [NSTemporaryDirectory() stringByAppendingPathComponent:@"macpad_app.log"]];
    for (NSString *p in cands) {
        FILE *f = fopen(p.fileSystemRepresentation, "a");
        if (f) { fclose(f); return p; }
    }
    return nil;
}

static void macpad_log_file(NSString *text) {
    if (text.length == 0) return;
    if (!g_logPath) g_logPath = pick_log_path();
    // NSLog 无论如何都发一份，走系统日志（syslog）能远程抓
    NSLog(@"[macpad] %@", [text stringByTrimmingCharactersInSet:
                           [NSCharacterSet newlineCharacterSet]]);
    if (!g_logPath) return;
    FILE *f = fopen(g_logPath.fileSystemRepresentation, "a");
    if (!f) return;
    fputs(text.UTF8String, f);
    fclose(f);
}

@interface MacPadViewController : UIViewController <UITextFieldDelegate, UIScrollViewDelegate>
@property (nonatomic, strong) UITextView   *console;
@property (nonatomic, strong) UITextField  *input;
@property (nonatomic, strong) UILabel      *status;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSMutableAttributedString *log;
@property (nonatomic, strong) NSArray<NSString *> *commands;
@property (nonatomic, assign) BOOL verbose;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, strong) NSArray<NSString *> *queue;   // 自检队列
@property (nonatomic, assign) NSInteger qidx;
@end

@implementation MacPadViewController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = C_BG;
    self.log = [NSMutableAttributedString new];
    // 装载器已经稳定，默认只留苹果程序自己的输出；需要看装载过程就敲 verbose on
    self.verbose = NO;
    self.busy = NO;

    [self buildUI];
    [self scanCommands];
    [self printBanner];
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

- (void)buildUI {
    CGFloat top = 0;
    if (@available(iOS 11.0, *)) {
        top = self.view.safeAreaInsets.top;
    } else {
        top = 20;
    }

    // 标题
    UILabel *title = [UILabel new];
    title.text = @"macPad";
    title.font = [UIFont fontWithName:@"Menlo-Bold" size:22] ?: [UIFont boldSystemFontOfSize:22];
    title.textColor = C_ACCENT;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    UILabel *sub = [UILabel new];
    sub.text = [NSString stringWithFormat:@"macOS 11.2 用户态 · 宿主 %s",
                macpad_host()];
    sub.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    sub.textColor = C_DIM;
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sub];

    // 控制台
    self.console = [UITextView new];
    self.console.backgroundColor = C_PANEL;
    self.console.textColor = C_TEXT;
    self.console.font = [UIFont fontWithName:@"Menlo" size:11.5] ?: [UIFont systemFontOfSize:11.5];
    self.console.editable = NO;
    self.console.scrollEnabled = YES;
    self.console.layer.cornerRadius = 8;
    self.console.layer.borderWidth = 1;
    self.console.layer.borderColor = C_STROKE.CGColor;
    self.console.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
    self.console.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.console];

    // 输入行
    UIView *bar = [UIView new];
    bar.backgroundColor = C_PANEL;
    bar.layer.cornerRadius = 8;
    bar.layer.borderWidth = 1;
    bar.layer.borderColor = C_STROKE.CGColor;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bar];

    UILabel *prompt = [UILabel new];
    prompt.text = @"$";
    prompt.font = [UIFont fontWithName:@"Menlo-Bold" size:14] ?: [UIFont boldSystemFontOfSize:14];
    prompt.textColor = C_ACCENT;
    prompt.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:prompt];

    self.input = [UITextField new];
    self.input.font = [UIFont fontWithName:@"Menlo" size:13] ?: [UIFont systemFontOfSize:13];
    self.input.textColor = C_TEXT;
    self.input.tintColor = C_ACCENT;
    self.input.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.input.autocorrectionType = UITextAutocorrectionTypeNo;
    self.input.spellCheckingType = UITextSpellCheckingTypeNo;
    self.input.returnKeyType = UIReturnKeyGo;
    self.input.delegate = self;
    self.input.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:@"ls /var/mobile" attributes:@{NSForegroundColorAttributeName: C_DIM}];
    self.input.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:self.input];

    self.spinner = [[UIActivityIndicatorView alloc]
                    initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    self.spinner.color = C_ACCENT;
    self.spinner.hidesWhenStopped = YES;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:self.spinner];

    // 状态行
    self.status = [UILabel new];
    self.status.font = [UIFont fontWithName:@"Menlo" size:9.5] ?: [UIFont systemFontOfSize:9.5];
    self.status.textColor = C_DIM;
    self.status.text = @"就绪 · 输入 help 查看命令";
    self.status.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.status];

    NSDictionary *views = @{@"title": title, @"sub": sub, @"console": self.console,
                            @"bar": bar, @"status": self.status};
    NSDictionary *metrics = @{@"top": @(top + 8)};

    [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:
        @"V:|-(top)-[title(26)]-[sub(14)]-8-[console]-8-[bar(40)]-4-[status(12)]-8-|"
        options:0 metrics:metrics views:views]];
    [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:
        @"H:|-12-[title]-12-|" options:0 metrics:nil views:views]];
    [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:
        @"H:|-12-[sub]-12-|" options:0 metrics:nil views:views]];
    [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:
        @"H:|-12-[console]-12-|" options:0 metrics:nil views:views]];
    [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:
        @"H:|-12-[bar]-12-|" options:0 metrics:nil views:views]];
    [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:
        @"H:|-14-[status]-14-|" options:0 metrics:nil views:views]];

    [bar addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:
        @"H:|-12-[prompt(14)]-8-[input]-8-[spinner(20)]-10-|"
        options:0 metrics:nil views:@{@"prompt": prompt, @"input": self.input,
                                      @"spinner": self.spinner}]];
    [bar addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:
        @"V:|-[input]-|" options:0 metrics:nil views:@{@"input": self.input}]];
    [bar addConstraint:[NSLayoutConstraint constraintWithItem:prompt attribute:NSLayoutAttributeCenterY
        relatedBy:NSLayoutRelationEqual toItem:bar attribute:NSLayoutAttributeCenterY multiplier:1 constant:0]];
    [bar addConstraint:[NSLayoutConstraint constraintWithItem:self.spinner attribute:NSLayoutAttributeCenterY
        relatedBy:NSLayoutRelationEqual toItem:bar attribute:NSLayoutAttributeCenterY multiplier:1 constant:0]];
}

#pragma mark - 控制台文本

- (void)append:(NSString *)text color:(UIColor *)color {
    if (!text) return;
    if (![text hasSuffix:@"\n"]) text = [text stringByAppendingString:@"\n"];
    NSDictionary *attrs = @{
        NSFontAttributeName: [UIFont fontWithName:@"Menlo" size:11.5] ?: [UIFont systemFontOfSize:11.5],
        NSForegroundColorAttributeName: color ?: C_TEXT
    };
    [self.log appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attrs]];
    self.console.attributedText = self.log;
    macpad_log_file(text);

    // 滚到底
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.console.text.length > 0) {
            NSRange r = NSMakeRange(self.console.text.length - 1, 1);
            [self.console scrollRangeToVisible:r];
        }
    });
}

- (void)printBanner {
    [self append:@"macPad · 在 iOS 上直接跑 macOS 11 的二进制" color:C_ACCENT];
    [self append:@"不走 exec、不签名：把 Mach-O 映射进子进程再跳进去。" color:C_DIM];
    [self append:@"" color:C_DIM];
    [self append:@"先试这几个：" color:C_DIM];
    [self append:@"  ls -l /var/mobile" color:C_DIM];
    [self append:@"  cat /etc/hosts" color:C_DIM];
    [self append:@"  uname -a" color:C_DIM];
    [self append:@"  echo hello from macOS" color:C_DIM];
    [self append:@"" color:C_DIM];
}

// 自检：把一组命令串起来跑，跑完结果都落在 /var/mobile/macpad_app.log
- (void)runSelfTests:(NSArray<NSString *> *)cmds {
    self.queue = cmds;
    self.qidx = 0;
    if (cmds.count) [self execute:cmds[0]];
}

#pragma mark - 命令表

- (void)scanCommands {
    NSMutableArray *list = [NSMutableArray array];
    NSString *binDir = [[NSBundle mainBundle] pathForResource:@"bin" ofType:nil];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:binDir error:nil];
    for (NSString *f in files) {
        if ([f hasSuffix:@".bin"]) {
            [list addObject:[f stringByDeletingPathExtension]];
        }
    }
    self.commands = [list sortedArrayUsingSelector:@selector(compare:)];
}

- (NSString *)binPathFor:(NSString *)cmd {
    NSString *p = [[NSBundle mainBundle] pathForResource:cmd ofType:@"bin" inDirectory:@"bin"];
    if (p && [[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    return nil;
}

#pragma mark - 执行

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    NSString *line = [textField.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceCharacterSet]];
    textField.text = @"";
    if (line.length == 0) return NO;
    [self execute:line];
    return NO;
}

- (void)execute:(NSString *)line {
    if (self.busy) return;

    [self append:[NSString stringWithFormat:@"$ %@", line] color:C_ACCENT];

    // 内建命令
    if ([line isEqualToString:@"help"]) {
        [self append:[NSString stringWithFormat:@"可用程序：%@",
                      [self.commands componentsJoinedByString:@"  "]] color:C_TEXT];
        [self append:@"内建：help / clear / verbose on|off" color:C_DIM];
        [self append:@"注意：每个命令都在独立子进程里跑，崩溃不会影响 App。" color:C_DIM];
        return;
    }
    if ([line isEqualToString:@"clear"]) {
        self.log = [NSMutableAttributedString new];
        self.console.attributedText = self.log;
        return;
    }
    if ([line hasPrefix:@"verbose"]) {
        self.verbose = [line containsString:@"on"];
        [self append:self.verbose ? @"装载诊断：开（会多出装载过程日志）"
                                 : @"装载诊断：关" color:C_WARN];
        return;
    }

    // 拆参数
    NSMutableArray<NSString *> *parts = [[line componentsSeparatedByString:@" "] mutableCopy];
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    for (NSString *p in parts) {
        if (p.length) [args addObject:p];
    }
    if (args.count == 0) return;

    NSString *cmd = args[0];
    NSString *binPath = [self binPathFor:cmd];
    if (!binPath) {
        [self append:[NSString stringWithFormat:@"macpad: 没有 %@ 这个程序", cmd] color:C_WARN];
        [self append:[NSString stringWithFormat:@"可用：%@",
                      [self.commands componentsJoinedByString:@" "]] color:C_DIM];
        return;
    }

    self.busy = YES;
    [self.spinner startAnimating];
    self.status.text = [NSString stringWithFormat:@"运行 %@ …", cmd];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int rc = -999;
        NSString *out = [MacPadViewController runBinary:binPath
                                                   args:args
                                                verbose:weakSelf.verbose
                                                     rc:&rc];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self2 = weakSelf;
            if (!self2) return;
            [self2 append:out color:C_TEXT];
            [self2 append:[NSString stringWithFormat:@"[退出码 %d]", rc] color:C_DIM];
            self2.busy = NO;
            [self2.spinner stopAnimating];
            self2.status.text = @"就绪";

            // 自检队列：一条跑完接着下一条
            if (self2.queue && self2.qidx + 1 < (NSInteger)self2.queue.count) {
                self2.qidx++;
                NSString *next = self2.queue[self2.qidx];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ [self2 execute:next]; });
            }
        });
    });
}

// fork 一个子进程，把 stdout/stderr 接到管道上，让子进程去跑 macOS 二进制。
+ (NSString *)runBinary:(NSString *)binPath
                   args:(NSArray<NSString *> *)args
                verbose:(BOOL)verbose
                     rc:(int *)outRC {
    int fds[2];
    if (pipe(fds) != 0) {
        *outRC = -1;
        return [NSString stringWithFormat:@"pipe() 失败: %s", strerror(errno)];
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(fds[0]);
        close(fds[1]);
        *outRC = -1;
        return [NSString stringWithFormat:
                @"fork() 失败: %s\n\nApp 需要 platform-application 权限。\n"
                @"确认已安装到 /Applications 并带 entitlement 重签。", strerror(errno)];
    }

    if (pid == 0) {
        // ---- 子进程：只做 async-signal-safe 的事，绝不碰 UIKit ----
        close(fds[0]);
        dup2(fds[1], STDOUT_FILENO);
        dup2(fds[1], STDERR_FILENO);
        close(fds[1]);

        // stdin 指向 /dev/null：像 cat 这种不带参数就闷头读 stdin 的程序
        // 会立刻拿到 EOF，而不是把整个 UI 线程拖死。
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) { dup2(devnull, STDIN_FILENO); close(devnull); }

        // 苹果程序被 SIGPIPE 打断时不至于死得莫名其妙
        signal(SIGPIPE, SIG_IGN);

        int argc = (int)args.count;
        char **argv = (char **)calloc((size_t)argc + 1, sizeof(char *));
        for (int i = 0; i < argc; i++) {
            argv[i] = strdup([args[i] UTF8String]);
        }
        argv[argc] = NULL;

        char *envp[] = {
            (char *)"PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            (char *)"HOME=/var/mobile",
            (char *)"TERM=xterm-256color",
            (char *)"LANG=en_US.UTF-8",
            NULL
        };

        int rc = macpad_run([binPath fileSystemRepresentation], argc, argv, envp,
                            verbose ? 1 : 0);
        fflush(NULL);
        _exit(rc < 0 ? 1 : (rc & 0xFF));
    }

    // ---- 父进程：先读完管道（避免管道满导致子进程阻塞），再回收 ----
    close(fds[1]);
    NSMutableData *data = [NSMutableData data];
    char buf[8192];
    ssize_t n;
    while ((n = read(fds[0], buf, sizeof(buf))) > 0) {
        [data appendBytes:buf length:(NSUInteger)n];
    }
    close(fds[0]);

    int status = 0;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status))      *outRC = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) *outRC = -WTERMSIG(status);
    else                         *outRC = -1;

    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return s ?: @"";
}

@end

#pragma mark - AppDelegate

// UIApplicationMain 的第 4 个参数是 delegate 类名。
// 传一个 UIViewController 子类进去，UIKit 会把它当 AppDelegate 实例化，
// 然后因为它没有 window 属性而 abort()（崩溃堆栈落在 GraphicsServices）。
// 所以必须有一个真正的 UIResponder<UIApplicationDelegate>。
@interface MacPadAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation MacPadAppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    for (NSString *p in @[@"/var/mobile/macpad_app.log", @"/tmp/macpad_app.log"]) {
        [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
    }
    NSLog(@"[macpad] didFinishLaunching, log target=%@", g_logPath ?: pick_log_path());

    MacPadViewController *vc = [MacPadViewController new];
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = C_BG;
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    // 启动后自动跑一轮自检：由简到繁，一次就能看出装载器走到了哪一步。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [vc runSelfTests:@[
            @"true",
            @"echo hello-from-macos",
            @"uname -a",
            @"ls -l /var/mobile",
            @"cat /etc/hosts",
            @"date",
        ]];
    });
    return YES;
}

@end

#pragma mark - App 入口

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass([MacPadAppDelegate class]));
    }
}
