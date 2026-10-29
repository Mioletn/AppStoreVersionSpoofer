// pptrace — 崩在 pc=0 的时候，把真凶打出来
//
// 为什么需要它：iOS 12.2 的崩溃报告在「跳空」这种故障上信息太少 ——
// pc=0、lr 落在 libdyld 的桩区，看不出是谁调的。而 libdyld.dylib 在
// 12.2 上只存在于 dyld 共享缓存里，磁盘上没有文件，没法反汇编。
//
// 所以由一个 constructor 接管信号，把寄存器、lr/pc 的落点（库名+偏移）、
// 以及栈回溯直接写到 stderr。用环境变量 PPTRACE=1 开启，默认完全不生效。
//
// 顺带提供 pp_note()，让 ios12stub 里的补丁函数能报告"我被调到了"，
// 这样能区分"符号没接上"和"接上了但语义不对"。

#import <Foundation/Foundation.h>
#import <signal.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <dlfcn.h>
#import <sys/ucontext.h>

static char g_b[3072];
static int  g_n;

static void pc_(char c) { if (g_n < (int)sizeof(g_b) - 1) g_b[g_n++] = c; }

static void ps_(const char *s) { while (*s) pc_(*s++); }

static void px_(uint64_t v) {
    static const char *H = "0123456789abcdef";
    char t[18];
    int k = 0;
    ps_("0x");
    if (!v) { pc_('0'); return; }
    while (v) { t[k++] = H[v & 15]; v >>= 4; }
    while (k) pc_(t[--k]);
}

static void pd_(long v) {
    char t[12];
    int k = 0;
    if (v < 0) { pc_('-'); v = -v; }
    if (!v) { pc_('0'); return; }
    while (v) { t[k++] = (char)('0' + v % 10); v /= 10; }
    while (k) pc_(t[--k]);
}

static void fl_(void) {
    if (g_n) { ssize_t r = write(2, g_b, (size_t)g_n); (void)r; g_n = 0; }
}

// ---------------------------------------------------------------- 对外接口
// 桩函数命中时喊一声，用于判定"补丁到底有没有被调用"。
void pp_note(const char *what) {
    ps_("[hit] ");
    ps_(what);
    pc_('\n');
    fl_();
}

// ---------------------------------------------------------------- 地址归属
static void pp_where(uint64_t a) {
    Dl_info di;
    if (a && dladdr((void *)(uintptr_t)a, &di) && di.dli_fname) {
        const char *nm = di.dli_fname;
        const char *b = strrchr(nm, '/');
        ps_(b ? b + 1 : nm);
        ps_(" + ");
        px_(a - (uint64_t)(uintptr_t)di.dli_fbase);
        if (di.dli_sname) {
            ps_("  ");
            ps_(di.dli_sname);
        }
    } else {
        px_(a);
    }
    pc_('\n');
}

// ---------------------------------------------------------------- 信号处理
static void pp_handler(int sig, siginfo_t *si, void *uctx) {
    ucontext_t *uc = (ucontext_t *)uctx;
    // 按偏移读，绕开 __darwin_arm_thread_state64_get_pc 的 autia
    const uint64_t *ss = (const uint64_t *)((const uint8_t *)uc->uc_mcontext + 16);

    ps_("\n===== PPTRACE sig ");
    pd_(sig);
    ps_(" =====\n");

    ps_("fault ");
    px_((uint64_t)(uintptr_t)si->si_addr);
    pc_('\n');

    static const char *rn[29] = {
        "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7",
        "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15",
        "x16", "x17", "x18", "x19", "x20", "x21", "x22", "x23",
        "x24", "x25", "x26", "x27", "x28"
    };
    for (int i = 0; i < 29; i++) {
        ps_(rn[i]);
        pc_('=');
        px_(ss[i]);
        pc_(' ');
        if (i % 4 == 3) pc_('\n');
    }
    ps_("fp="); px_(ss[29]);
    ps_(" lr="); px_(ss[30]);
    ps_(" sp="); px_(ss[31]);
    ps_(" pc="); px_(ss[32]);
    pc_('\n');

    ps_("--- pc 落点 ---\n");
    pp_where(ss[32]);
    ps_("--- lr 落点 ---\n");
    pp_where(ss[30]);

    ps_("--- 栈回溯 ---\n");
    uint64_t fp0 = ss[29], sp = ss[31];
    for (int i = 0; i < 20; i++) {
        if (!fp0 || fp0 <= sp || fp0 > sp + 0x20000) break;
        uint64_t *fr = (uint64_t *)(uintptr_t)fp0;
        uint64_t ret = fr[1], nfp = fr[0];
        ps_("  #");
        pd_(i);
        ps_(" ");
        pp_where(ret);
        if (nfp <= fp0) break;
        fp0 = nfp;
    }
    ps_("===== end =====\n");
    fl_();

    signal(sig, SIG_DFL);
    raise(sig);
}

__attribute__((constructor))
static void pp_init(void) {
    if (!getenv("PPTRACE")) return;

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = pp_handler;
    sa.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigemptyset(&sa.sa_mask);

    const int sg[4] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT };
    for (int i = 0; i < 4; i++) sigaction(sg[i], &sa, NULL);

    ps_("[pptrace] armed pid=");
    pd_((long)getpid());
    pc_('\n');
    fl_();
}
