// macPad 进程内 Mach-O 装载器（App 内嵌版，v3.31）
//
// v3.31：完整解析 LC_DYLD_CHAINED_FIXUPS（iOS 13.4 / macOS 11 起的新 rebase/bind
//        格式），arm64e 与 arm64 两种指针形态、IMPORT / IMPORT_ADDEND /
//        IMPORT_ADDEND64 三种导入表、单起点与多起点页都覆盖。
//        这是"让 13.0+ 的 IPA 能进内存"的关键一步：老 dyld 直接以
//        "missing LC_DYLD_INFO load command" 拒绝，我们自己解码。
//        next 的基准改成 page_size（iOS 16 的 __DATA 是 16KB 页，按 4KB 掩码会错位）。
// v3.29：数据指针自愈（EC=0x24/0x25 时把带标签的寄存器还原成裸地址再重试），
//        修好了 ps —— 它的 __TEXT,__const 里存着已签名的 __cstring 指针。
// v3.18：PAC 取指自愈（fault_handler 里 EC=0x20 的 far 带签名位时改 pc 重试）
//        + 装载末尾横扫可写段把残留签名指针剥成裸地址。
//        这两条让"braa -> br"中和策略闭环：指针是裸是签都不再致命。
//
// v3.11：跨世代 ptrauth ABI 中和（见下方 g_no_pac 注释）。
//        设备实测 macOS 11.2 的二进制是 ptrauth ABI v1（cpusubtype 0x80000002），
//        本机 iOS 12.2 是 ABI v0（0x00000002），两者的 __auth_stubs 授权约定
//        不兼容 —— 每个二进制都在第一个导入调用上 SIGTRAP。
//        v3.11 不再依赖签名正确，而是把 braa/blraa/retaa/ldraa 换成
//        等价的无授权指令，槽位里放裸地址。
//
// 从 Substitute 注入的 tweak 移植而来：现在由 MacPad.app 自己调用，
// 不再需要越狱注入。日志走 stderr，便于 fork 后由父进程经管道回收。
//
// 为什么不用 exec：
//   设备实测（dmesg + 24 个探针）证明，任何被 exec 的未签名二进制都会被
//   AMFI 以 Killed: 9 干掉；但 AMFI 对 platform 进程会 override library
//   validation，所以 Substitute 注入的 dylib 能活。
//   => 执行通道不是 exec，而是"在已活的进程里自己把 Mach-O 映射进来跑"。
//
// v3 新增（为了跑苹果真发的 macOS 二进制）：
//   * FAT 切片选择（Big Sur 的 /usr/bin/* 都是 x86_64 + arm64e 双切片）
//   * LC_MAIN (0x80000028) 入口
//   * __PAGEZERO 不参与映射（否则 span 直接 4GB）
//   * BIND_OPCODE_THREADED：ordinal 表 + arm64e chained pointer 走查
//     （DYLD_CHAINED_PTR_ARM64E 的 rebase / bind / auth 四种位型）
//   * 认证指针用 ptrauth 现场签名，否则 ldraa 会在 PAC 校验时崩

#include <mach-o/loader.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <mach/vm_region.h>
#include <mach/arm/thread_status.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <unistd.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <dirent.h>
#include <signal.h>
#include <pthread.h>
#include <fts.h>
#include <setjmp.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#ifndef LC_BUILD_VERSION
#define LC_BUILD_VERSION 0x32
#endif
#define LC_MAIN_CMD 0x80000028

#define REBASE_OPCODE_MASK                          0xF0
#define REBASE_OPCODE_SET_TYPE_IMM                  0x10
#define REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB   0x20
#define REBASE_OPCODE_ADD_ADDR_ULEB                 0x30
#define REBASE_OPCODE_ADD_ADDR_IMM_SCALED           0x40
#define REBASE_OPCODE_DO_REBASE_IMM_TIMES           0x50
#define REBASE_OPCODE_DO_REBASE_ULEB_TIMES          0x60
#define REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB       0x70
#define REBASE_OPCODE_DO_REBASE_ULEB_TIMES_SKIPPING_ULEB 0x80
#define REBASE_TYPE_POINTER                         1

#define BIND_OPCODE_MASK                            0xF0
#define BIND_OPCODE_DONE                            0x00
#define BIND_OPCODE_SET_DYLIB_ORDINAL_IMM           0x10
#define BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB          0x20
#define BIND_OPCODE_SET_DYLIB_SPECIAL_IMM           0x30
#define BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM   0x40
#define BIND_OPCODE_SET_TYPE_IMM                    0x50
#define BIND_OPCODE_SET_ADDEND_SLEB                 0x60
#define BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB     0x70
#define BIND_OPCODE_ADD_ADDR_ULEB                   0x80
#define BIND_OPCODE_DO_BIND                         0x90
#define BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB           0xA0
#define BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED     0xB0
#define BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB 0xC0
#define BIND_OPCODE_THREADED                        0xD0

#define MAX_SEGS 32
#define MAX_OPS  4000000
#define MAX_ORD  128

// arm64e chained pointer 位域（dyld_chained_fixups.h）
#define CH_NEXT(v)   ((uint32_t)(((v) >> 51) & 0x7FF))
#define CH_BIND(v)   ((int)(((v) >> 62) & 1))
#define CH_AUTH(v)   ((int)(((v) >> 63) & 1))

// 0 = 只输出苹果程序自己的 stdout/stderr；1 = 附带装载器诊断。
int g_macpad_verbose = 0;

// 1 = 只做 rebase/bind 不执行入口（分析 dylib 用）
static int g_bind_only = 0;
void macpad_report_missing(void);

// 依赖清单（LC_LOAD_DYLIB），bind-only 分析前先 dlopen 一遍
static char g_deps[24][512];
static int g_ndeps = 0;

static void P(const char *fmt, ...) {
    if (!g_macpad_verbose) return;
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0) {
        ssize_t w = write(2, buf, (size_t)n);
        (void)w;
    }
}

static const char *plat_name(uint32_t p) {
    switch (p) {
        case 1:  return "MACOS";
        case 2:  return "IOS";
        case 3:  return "TVOS";
        case 4:  return "WATCHOS";
        case 5:  return "BRIDGEOS";
        case 6:  return "MACCATALYST";
        case 7:  return "IOSSIMULATOR";
        default: return "UNKNOWN";
    }
}

static const char *ft_name(uint32_t ft) {
    switch (ft) {
        case MH_OBJECT:      return "MH_OBJECT";
        case MH_EXECUTE:     return "MH_EXECUTE";
        case MH_DYLIB:       return "MH_DYLIB";
        case MH_DYLINKER:    return "MH_DYLINKER";
        case MH_BUNDLE:      return "MH_BUNDLE";
        case MH_DSYM:        return "MH_DSYM";
        default:             return "MH_?";
    }
}

static sigjmp_buf g_jb;
static volatile sig_atomic_t g_jb_arm = 0;
static volatile sig_atomic_t g_in_handler = 0;
static volatile int g_fault_sig = 0;
static volatile uint64_t g_fault_pc = 0, g_fault_lr = 0, g_fault_far = 0;
static volatile uint64_t g_fault_sp = 0, g_fault_fp = 0;
static volatile uint64_t g_fault_pc_raw = 0, g_fault_far_raw = 0;
static volatile uint32_t g_fault_esr = 0;
static volatile uint64_t g_regs[29];

// 千万别用 __darwin_arm_thread_state64_get_pc() 这类宏。
//
// 它们在 arm64e 下会先做一次 autia，认证不过就执行 brk #0xc470，于是
// "信号处理器自己二次崩溃"，把真正的崩溃现场盖掉。而 ---- 直接读原始字段也不行：
// 本机的签名位能占到 bit32 以上（见 macpad_diag 的 sign(0x1000) 输出），
// 简单按低 48 位做掩码根本剥不干净。
//
// 正确做法是用 xpaci（ptrauth_strip）：它按架构约定的位宽验证并清除签名，
// 实测对 dlsym 返回值是无损的。万一某个值其实没签过名（xpaci 会把它变成毒指针），
// 用"结果看着不像用户态地址"来兜底。
static uint64_t sane_addr(uint64_t v) {
#if __has_feature(ptrauth_calls)
    uint64_t s = (uint64_t)(uintptr_t)ptrauth_strip((void *)(uintptr_t)v, ptrauth_key_asia);
    if (s >= 0x1000ULL && s < 0x0000800000000000ULL) return s;
#endif
    return v & 0x0000FFFFFFFFFFFFULL;
}

static int scrub_dirty_value(uint64_t dirty, uint64_t clean, uint64_t sp);
static uint64_t sign_pc_field(uint64_t pc);
static int scan_vm_dirty(uint64_t dirty, uint64_t clean);
static void *clean_ptr(void *p);
static void *sign_ptr(void *p, int key, uintptr_t disc);
static uint64_t untag33(uint64_t v);
static int plausible_addr(uint64_t v);

// 装载映像的可执行范围，给"PAC 取指自愈"判断用。
static uintptr_t g_img_lo = 0, g_img_hi = 0;
static int g_pac_fix_n = 0;
static uintptr_t g_pac_fix_last = 0;
static int g_data_fix_n = 0;        // 数据指针自愈次数

static void fault_handler(int sig, siginfo_t *si, void *uctx) {
    if (g_in_handler) _exit(92);
    g_in_handler = 1;
    g_fault_sig = sig;
    g_fault_far = si ? (uint64_t)si->si_addr : 0;
    if (uctx) {
        ucontext_t *uc = (ucontext_t *)uctx;
        // 连 uc_mcontext->__ss.__pc 这种成员都别直接点：arm64e 下 SDK 把它们换成了
        // 不透明字段（__opaque_pc 之类）。内核 ABI 的布局是固定的，就按偏移读：
        //   mcontext64 = __es(16B) + __ss，__ss = x[29], fp, lr, sp, pc, cpsr
        const uint64_t *ss = (const uint64_t *)((const uint8_t *)uc->uc_mcontext + 16);
        for (int i = 0; i < 29; i++) g_regs[i] = ss[i];
        g_fault_fp = sane_addr(ss[29]);
        g_fault_lr = sane_addr(ss[30]);
        g_fault_sp = sane_addr(ss[31]);
        g_fault_pc = sane_addr(ss[32]);
        g_fault_pc_raw = ss[32];
        g_fault_esr = *(const uint32_t *)((const uint8_t *)uc->uc_mcontext + 8);

        // ---- PAC 取指自愈 ----
        // 我们把 braa/blraa 换成了 br/blr，但源寄存器里可能仍旧是**已签名**的指针
        // （__auth_got 槽位、运行时 paciza 出来的回调……）。这种跳转的故障特征是
        // ESR.EC = 0x20（取指异常）且 far = pc | 签名位。
        uint32_t ec = (g_fault_esr >> 26) & 0x3F;
        if (ec == 0x20 && g_fault_far && g_fault_far != g_fault_pc && g_fault_pc &&
            g_pac_fix_n < 2000) {
            uintptr_t tgt = (uintptr_t)g_fault_pc;
            Dl_info di;
            memset(&di, 0, sizeof(di));
            int plausible = (tgt >= g_img_lo && tgt < g_img_hi) ||
                            (dladdr((void *)tgt, &di) && di.dli_fbase != NULL);
            if (plausible) {
                uint64_t *ssw = (uint64_t *)ss;
                g_pac_fix_last = tgt;
                g_pac_fix_n++;

                // 第一次：把现场彻底摊开。寄存器里到底有没有那个脏值，一眼就能看出来。
                if (g_pac_fix_n == 1) {
                    P("  === 故障现场 ===\n");
                    for (int i = 0; i < 29; i += 4)
                        P("    x%-2d=0x%016llx x%-2d=0x%016llx x%-2d=0x%016llx x%-2d=0x%016llx\n",
                          i, (unsigned long long)ssw[i], i+1, (unsigned long long)ssw[i+1],
                          i+2, (unsigned long long)ssw[i+2], i+3, (unsigned long long)ssw[i+3]);
                    P("    far=0x%llx pc=0x%llx lr=0x%llx sp=0x%llx fp=0x%llx\n",
                      (unsigned long long)g_fault_far, (unsigned long long)tgt,
                      (unsigned long long)g_fault_lr, (unsigned long long)g_fault_sp,
                      (unsigned long long)g_fault_fp);
                    int inr = 0;
                    for (int i = 0; i < 29; i++) {
                        uint64_t st = (uint64_t)(uintptr_t)clean_ptr((void *)(uintptr_t)ssw[i]);
                        if (st != ssw[i] && st == (uint64_t)tgt) { P("    >> 脏值在 x%d\n", i); inr++; }
                    }
                    if (!inr) P("    >> 29 个通用寄存器里没有等于目标裸地址的带签版本\n");
                }

                // 把寄存器里指向同一目标、但带签名的那些改干净
                {
                    int nr = 0;
                    for (int i = 0; i < 29; i++) {
                        uint64_t st = (uint64_t)(uintptr_t)clean_ptr((void *)(uintptr_t)ssw[i]);
                        if (st == ssw[i] || st != (uint64_t)tgt) continue;
                        ssw[i] = st; nr++;
                    }
                    if (nr && g_pac_fix_n <= 6)
                        P("  !! 清掉 %d 个带签寄存器\n", nr);
                }

                // 内存里也扫一遍：映像可写段 + 线程栈
                if (g_pac_fix_n <= 3)
                    scrub_dirty_value(g_fault_far, (uint64_t)tgt, g_fault_sp);
                // 再不行就扫全进程可写区（堆里的回调表常常在这儿）
                if (g_pac_fix_n <= 2) {
                    int hv = scan_vm_dirty(g_fault_far, (uint64_t)tgt);
                    P("  !! 全进程可写区扫描：%d 处命中\n", hv);
                }

                if (g_pac_fix_n <= 6 || (g_pac_fix_n % 500) == 0)
                    P("  .. 进度 #%d tgt=0x%llx sp=0x%llx lr=0x%llx x0=0x%llx\n",
                      g_pac_fix_n, (unsigned long long)tgt,
                      (unsigned long long)g_fault_sp, (unsigned long long)g_fault_lr,
                      (unsigned long long)ssw[0]);
                ssw[32] = sign_pc_field((uint64_t)tgt);
                if (g_pac_fix_n <= 6)
                    P("  !! PAC 取指自愈 #%d: far=0x%llx -> pc=0x%llx%s%s\n",
                      g_pac_fix_n, (unsigned long long)g_fault_far, (unsigned long long)tgt,
                      di.dli_fname ? " @" : "", di.dli_fname ? di.dli_fname : "");
                g_in_handler = 0;
                return;                                     // 恢复执行，重试干净地址
            }
        }

        // ---- 数据指针自愈（跨 ABI 的第二类伤害）----
        //
        // ps 的字符串常量池在 __TEXT,__const 里，里面存的是**已签名**的
        // "指向 __cstring 的指针"（苹果 arm64e 链接器给数据指针也打了签）。
        // ps 把它原样取出来当参数交给 _platform_strcmp，第一次解引用就
        // 数据中止：EC=0x24，far 就是那个带标签的值本身。
        //
        // 实测现场（macpadcli -v ps aux）：
        //   pc  = libsystem_platform _platform_strcmp
        //   esr = 0x92000004 (EC=0x24)
        //   far = 0x4dbc00104dc376c  ← 正好等于 x1
        //   把 x1 剥成 0x104dc376c 就是合法的 __cstring 地址
        //
        // 处理：找出值等于 far（或与 far 同源）的寄存器，就地还原成裸地址，
        // 然后不落 pc、直接返回，让内核重放这条 ldr。寄存器被改干净后同一
        // 条指令就成功了，所以不会像"改 pc"那样原地打转。
        if ((ec == 0x24 || ec == 0x25) && g_fault_far && g_data_fix_n < 200000) {
            uint64_t bare = untag33((uint64_t)g_fault_far);
            if (bare != (uint64_t)g_fault_far && plausible_addr(bare)) {
                uint64_t *ssw = (uint64_t *)ss;
                int fixed = 0;
                for (int i = 0; i < 29; i++) {
                    if (ssw[i] != (uint64_t)g_fault_far) continue;
                    ssw[i] = bare; fixed++;
                }
                // 没找到完全相等的：按"同源"退一步。字面池里的指针常常是
                // base+偏移存下来的，标签相同、低位相差不远，用 2MB 窗口判。
                if (!fixed) {
                    for (int i = 0; i < 29; i++) {
                        uint64_t b = untag33(ssw[i]);
                        if (b == ssw[i] || !plausible_addr(b)) continue;
                        uint64_t d = (b > bare) ? (b - bare) : (bare - b);
                        if (d < (1u << 21)) { ssw[i] = b; fixed++; }
                    }
                }
                if (fixed) {
                    g_data_fix_n++;
                    if (g_data_fix_n <= 4 || (g_data_fix_n % 2000) == 0)
                        P("  !! 数据指针自愈 #%d: far=0x%llx -> 0x%llx（%d 个寄存器）pc=0x%llx\n",
                          g_data_fix_n, (unsigned long long)g_fault_far,
                          (unsigned long long)bare, fixed,
                          (unsigned long long)g_fault_pc);
                    // 顺手把可写区里的同源脏值也抹掉，减少后续重复故障
                    if (g_data_fix_n <= 2)
                        scrub_dirty_value(g_fault_far, bare, g_fault_sp);
                    g_in_handler = 0;
                    return;                                 // 重试同一条指令
                }
            }
        }
    }
    g_in_handler = 0;
    if (g_jb_arm) { g_jb_arm = 0; siglongjmp(g_jb, 1); }
    _exit(91);
}

typedef int (*entry_fn_t)(void);
// macOS 的 main(argc, argv, envp)：装载器得充当"内核"，把这三个交代清楚。
// 否则像 uname 这种会直接去读 argv[1]，拿到野指针。
typedef int (*entry3_fn_t)(int, char **, char **);

// 用裸 blr 调用入口，绕开编译器自作主张的授权。
//
// 踩过的坑：写成 ((entry3_fn_t)entry)(argc, argv, envp) 时，arm64e 目标下 clang
// 会给这个函数指针签名并生成一条带授权的间接分支。实测崩溃现场是
//     x16 = 0x20000100617f5c   （被签名过的入口）
//     x17 = 0x100617f5c        （入口裸地址）
//     [pc] = 0xd4388e00 = brk #0xc470
// 而 brk #0xc470 正是苹果的"PAC 校验失败"陷阱，lr 落在 libsystem_platform。
// 也就是说：我们连自己代码里的一次函数指针调用都过不了 ABI v0/v1 的校验。
// 那就不让编译器插手 —— 寄存器自己摆，blr 自己发。
__attribute__((noinline))
static int call_entry_raw(uint64_t fn, int argc, char **argv, char **envp) {
    register uint64_t x0 __asm("x0") = (uint64_t)(int64_t)argc;
    register uint64_t x1 __asm("x1") = (uint64_t)(uintptr_t)argv;
    register uint64_t x2 __asm("x2") = (uint64_t)(uintptr_t)envp;
    register uint64_t x9 __asm("x9") = fn;
    __asm__ __volatile__(
        "blr x9\n"
        : "+r"(x0)
        : "r"(x1), "r"(x2), "r"(x9)
        : "x3", "x4", "x5", "x6", "x7", "x8",
          "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17",
          "x30", "cc", "memory",
          "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7");
    return (int)x0;
}

// ---------------------------------------------------------------- PAC 签名
//
// 这里是整个移植最关键的一个判断：**要不要给跨镜像指针签名**。
//
// 苹果的 arm64e 有两个不兼容的 ptrauth ABI：
//   * ABI v0（iOS 12 ~ iOS 12.x，cpusubtype = 0x00000002）
//   * ABI v1（macOS 11 / iOS 13 起，cpusubtype = 0x80000002）
// 设备实测：macOS 11.2 的 /usr/bin/* 全是 0x80000002（ABI v1），
// 而本机运行时是 iOS 12.2（ABI v0）。两边对 __auth_stubs / __auth_got 里
// 那个 `braa x16, x17` 的授权约定不一致，按 v0 的规则签出来的值，
// 在硬件上过不了 v1 约定的校验 —— 表现为 EXC_BREAKPOINT -> SIGTRAP，
// 也就是我们之前看到的 `signal 5`，而且崩在每个二进制的第一个导入调用上
// （连 echo hello 都吐不出一个字）。
//
// 既然映像字节就在我们手里，正确做法不是去逆向 QARMA 的输入，
// 而是把授权环节整个摘掉：把 __TEXT 里的 braa/blraa/retaa 换成等价的
// br/blr/ret，槽位里放裸地址。语义完全等价，只是丢掉跨镜像的指针防篡改
// —— 而这本来就不是我们要保护的东西（这些二进制是苹果自己签的）。
// g_no_pac = 0 可以切回"老老实实签名"的旧行为，用于对比实验。
int g_no_pac = 1;

#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
// dlsym 返回的**已经是 dyld 按本进程约定签好名的指针**，千万别再签一次。
// 设备实测（macpadcli -d）：
//     sign(0x1000, IA, 0) = 0x0000438000001000   <- 签名落在 bit32..63，低 32 位是地址
//     dlsym(exit)         = 0x0040ae818f86d234
//     ptrauth_strip(上面) = 0x000000018f86d234   <- 无损，正是共享缓存里的真地址
// 之前一直崩，就是把 dlsym 的已签名值又拿去 sign 了一遍，把高位签名盖成垃圾。
static void *clean_ptr(void *p) {
    // 只有 dlsym 这类"由 dyld 签署"的指针才能这么剥；自己的函数地址没签过，
    // xpaci 会把它变成毒指针，所以这个函数只在 dlsym 分支里用。
    return ptrauth_strip(p, ptrauth_key_function_pointer);
}

// 从内存里读到的"可能带签"的值，还原成裸地址。
//
// 这里**不能**用 ptrauth_strip / xpaci：xpaci 的清位范围由 ABI 决定，对
// 0x2c0000102c0776c 这种值它会符号扩展出 0xffffff8102c0776c（非规范地址），
// 拿去解引用就是新的数据中止 —— 实测 ps 就这么二次崩的。
// 本机所有合法地址（映像 0x102cxxxxx、共享缓存 0x18f9xxxxx、栈 0x16dbxxxxx）
// 都落在低 33 位内，所以直接掩码，简单且不会造出怪物。
static uint64_t untag33(uint64_t v) { return v & 0x1FFFFFFFFull; }
static int plausible_addr(uint64_t v) { return v >= 0x100000000ull && v < 0x800000000ull; }

// ucontext 里的 __pc 在 arm64e 上是**签名字段**（SDK 因此把它藏成不透明字段）。
// 往里写裸地址，内核 sigreturn 时认证失败，会当这个字段没改过，于是原地重放
// 同一条故障指令 —— 实测就是这样死循环 200 万次的。必须按内核约定签好再写。
static uint64_t sign_pc_field(uint64_t pc) {
    return (uint64_t)(uintptr_t)ptrauth_sign_unauthenticated(
        (void *)(uintptr_t)pc, ptrauth_key_asia, 0);
}

static void *sign_ptr(void *p, int key, uintptr_t disc) {
    if (g_no_pac) return p;
    p = clean_ptr(p);                 // 先还原成裸地址，再按槽位约定重签
    switch (key) {
        case 0: return ptrauth_sign_unauthenticated(p, ptrauth_key_asia, disc);
        case 1: return ptrauth_sign_unauthenticated(p, ptrauth_key_asib, disc);
        case 2: return ptrauth_sign_unauthenticated(p, ptrauth_key_asda, disc);
        default: return ptrauth_sign_unauthenticated(p, ptrauth_key_asdb, disc);
    }
}
#else
static void *clean_ptr(void *p) { return p; }
static void *sign_ptr(void *p, int key, uintptr_t disc) { (void)key; (void)disc; return p; }
static uint64_t sign_pc_field(uint64_t pc) { return pc; }
#endif

// ---------------------------------------------------------------- ULEB/SLEB
static uint64_t read_uleb(const uint8_t **pp, const uint8_t *end) {
    uint64_t r = 0; int shift = 0;
    const uint8_t *p = *pp;
    while (p < end) {
        uint8_t b = *p++;
        if (shift < 64) r |= (uint64_t)(b & 0x7F) << shift;
        shift += 7;
        if (!(b & 0x80)) break;
    }
    *pp = p;
    return r;
}

static int64_t read_sleb(const uint8_t **pp, const uint8_t *end) {
    int64_t r = 0; int shift = 0; uint8_t b = 0;
    const uint8_t *p = *pp;
    while (p < end) {
        b = *p++;
        if (shift < 64) r |= (int64_t)(b & 0x7F) << shift;
        shift += 7;
        if (!(b & 0x80)) break;
    }
    if (shift < 64 && (b & 0x40)) r |= -((int64_t)1 << shift);
    *pp = p;
    return r;
}

// _exit / exit 拦截：苹果的二进制一旦调用，就说明它真的跑到了自己的代码路径上。
// 记下返回值并把控制流抢回装载器，这样后面的镜像还能继续测。
static int g_shim_exit = -1;

// 诊断开关：1 = 接管 _exit（用 siglongjmp 抢回控制流，方便一个进程里连跑多个镜像）
//           0 = 让它真的退出（子进程模型下更干净，退出码自然回传）
int g_hook_exit = 0;

static void macpad_exit_shim(int code) {
    g_shim_exit = code;
    P("  >>> 苹果的代码调用了 _exit(%d)\n", code);
    g_jb_arm = 0;
    siglongjmp(g_jb, 2);
}

// 缺失符号的替身：被当函数调用时安全返回；被当数据读取时也只是一段只读字节。
static void macpad_missing_sym(void) { }

// ---------------------------------------------------------------- 回调类 API 的拦截
//
// 这是跨世代 PAC 的"死角"：ls 把比较函数指针交给 libsystem_c 的 fts，
// libc 内部用 `braa x8, x?` 调它 —— 而且按 addrDiv=1 用**槽位自身地址**做
// modifier。那个地址在 libc 自己的栈帧里，我们既拿不到也预签不出来，
// 于是认证必然失败，CPU 把目标毒化成 "addr | bit61"，一跳就是取指异常。
//
// 实测证据（macpadcli -v ls / > file）：
//   x3 = x19 = 0x102fb0c84（干净的目标裸地址）
//   x17      = 0x1c04877b8（libc 算出来的 diversity）
//   far      = 0x20000102fb0c84 = 目标 | bit61
//   lr 位于 libsystem_c.dylib +0x5b4fc
// 我们自己的映像里已经没有一条 braa/blraa 了，所以毒化点只能在 libc 内部。
//
// 既然无法满足它的认证约定，就把回调拿掉：fts_open 传 NULL 比较器，
// fts 就不排序、也不回调。代价是目录项按文件系统原始顺序输出（不排序），
// 换来的是整条 fts 通路彻底不碰跨 ABI 的 PAC。
static void *mp_call3(void *fn, void *a, void *b, void *c);
static void *g_real_fts_open;
static void *mp_fts_open(char *const *argv, int options,
                         int (*compar)(const FTSENT **, const FTSENT **)) {
    (void)compar;
    // dlsym 返回的是**已按本进程约定签名**的指针。以前这里是
    // typedef 强转后直接调用，编译器生成的 braa 恰好能认证成功；
    // 改成裸 blr 之后就成了"跳到带签地址"，取指异常 far=code|bit61，崩在
    // fts_open 的 pacibsp 上。所以必须先用 clean_ptr 剥回裸地址。
    if (!g_real_fts_open) g_real_fts_open = clean_ptr(dlsym(RTLD_DEFAULT, "fts_open"));
    if (!g_real_fts_open) return NULL;
    P("  shim fts_open: 丢弃比较器（跨 ABI 的 PAC 回调必崩），改由 fts 原序返回\n");
    return mp_call3(g_real_fts_open, (void *)argv, (void *)(uintptr_t)(intptr_t)options, NULL);
}

// ---- 排序 / 查找：自己实现，绕开 libc 内部的授权回调 ----
//
// ps 的崩溃由 dladdr 直接点名：lr 位于 libsystem_c + 0x59130 = bsearch。
// 和 fts 是同一个病根 —— 苹果 arm64e 的 C 函数指针默认按"地址多样性"签名，
// modifier 就是指针槽位自身的地址，那个地址在 libc 的栈帧里，装载器无从预签。
// 于是我们自己实现这几个通用算法，回调一律用裸 blr 发出（不认证、不签名）。
// 算法本身与 libc 语义等价，只是丢了防篡改（这些二进制是苹果自己签的，不需要）。

__attribute__((noinline))
static int mp_call_cmp2(int (*fn)(const void *, const void *), const void *a, const void *b) {
    register uint64_t x0 __asm("x0") = (uint64_t)(uintptr_t)a;
    register uint64_t x1 __asm("x1") = (uint64_t)(uintptr_t)b;
    register uint64_t x9 __asm("x9") = (uint64_t)(uintptr_t)fn;
    __asm__ __volatile__(
        "blr x9\n"
        : "+r"(x0)
        : "r"(x1), "r"(x9)
        : "x2", "x3", "x4", "x5", "x6", "x7", "x8",
          "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17",
          "x30", "cc", "memory", "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7");
    return (int)x0;
}

__attribute__((noinline))
static int mp_call_cmp3(int (*fn)(const void *, const void *, void *),
                        const void *a, const void *b, void *ctx) {
    register uint64_t x0 __asm("x0") = (uint64_t)(uintptr_t)a;
    register uint64_t x1 __asm("x1") = (uint64_t)(uintptr_t)b;
    register uint64_t x2 __asm("x2") = (uint64_t)(uintptr_t)ctx;
    register uint64_t x9 __asm("x9") = (uint64_t)(uintptr_t)fn;
    __asm__ __volatile__(
        "blr x9\n"
        : "+r"(x0)
        : "r"(x1), "r"(x2), "r"(x9)
        : "x3", "x4", "x5", "x6", "x7", "x8",
          "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17",
          "x30", "cc", "memory", "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7");
    return (int)x0;
}

static void mp_bcopy(uint8_t *dst, const uint8_t *src, size_t n) {
    for (size_t i = 0; i < n; i++) dst[i] = src[i];
}

// 堆排序：原地、O(n log n)、不需要额外数组，只借一个元素大小的中转缓冲。
static void mp_sift(uint8_t *base, size_t start, size_t end, size_t sz,
                    int (*cmp)(const void *, const void *), uint8_t *tmp) {
    size_t root = start;
    while (root * 2 + 1 <= end) {
        size_t child = root * 2 + 1;
        if (child + 1 <= end &&
            mp_call_cmp2(cmp, base + child * sz, base + (child + 1) * sz) < 0)
            child++;
        if (mp_call_cmp2(cmp, base + root * sz, base + child * sz) < 0) {
            mp_bcopy(tmp, base + root * sz, sz);
            mp_bcopy(base + root * sz, base + child * sz, sz);
            mp_bcopy(base + child * sz, tmp, sz);
            root = child;
        } else {
            return;
        }
    }
}

static void mp_qsort(void *b, size_t n, size_t sz, int (*cmp)(const void *, const void *)) {
    if (!b || n < 2 || !sz || !cmp) return;
    uint8_t *base = (uint8_t *)b;
    uint8_t *tmp = (uint8_t *)malloc(sz);
    if (!tmp) return;
    for (size_t start = (n - 2) / 2 + 1; start-- > 0; )
        mp_sift(base, start, n - 1, sz, cmp, tmp);
    for (size_t end = n - 1; end > 0; end--) {
        mp_bcopy(tmp, base, sz);
        mp_bcopy(base, base + end * sz, sz);
        mp_bcopy(base + end * sz, tmp, sz);
        mp_sift(base, 0, end - 1, sz, cmp, tmp);
    }
    free(tmp);
}

static void *mp_bsearch(const void *key, const void *b, size_t n, size_t sz,
                        int (*cmp)(const void *, const void *)) {
    if (!b || !sz || !cmp) return NULL;
    const uint8_t *base = (const uint8_t *)b;
    size_t lo = 0, hi = n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        int c = mp_call_cmp2(cmp, key, base + mid * sz);
        if (c == 0) return (void *)(uintptr_t)(base + mid * sz);
        if (c < 0) hi = mid; else lo = mid + 1;
    }
    return NULL;
}

// ---- qsort_r / mergesort 的 ctx 版本：qsort_r 的 ctx 版本需要 3 参回调 ----
typedef struct { int (*fn)(const void *, const void *, void *); void *ctx; uint8_t *tmp; size_t sz; } mp_ctx_t;
static mp_ctx_t *g_mp_sortctx;

static int mp_ctx_thunk(const void *a, const void *b) {
    return mp_call_cmp3(g_mp_sortctx->fn, a, b, g_mp_sortctx->ctx);
}
static void mp_qsort_r(void *b, size_t n, size_t sz,
                       void *ctx, int (*fn)(const void *, const void *, void *)) {
    if (!b || n < 2 || !sz || !fn) return;
    mp_ctx_t c = { fn, ctx, NULL, sz };
    mp_ctx_t *save = g_mp_sortctx;
    g_mp_sortctx = &c;
    mp_qsort(b, n, sz, mp_ctx_thunk);
    g_mp_sortctx = save;
}

// ---- 数据指针去标签：字符串族函数 ----
//
// ps 崩在 _platform_strcmp 的数据中止，far = 0x050a4001050ab76c，
// 低 33 位正好落在 __TEXT,__cstring 里 —— 也就是说参数是个**合法的字符串指针，
// 只是高位被签了名**。字符串本来不该带 PAC，但跨世代 ABI 下 __TEXT,__const /
// 链式 fixup 里的数据指针会被按"认证指针"处理，于是拿到手的就是个带标签的值。
// 对这些纯数据函数，参数进来先 xpaci 一下：干净的指针过 xpaci 是恒等运算，
// 带标签的则被还原 —— 无副作用。
static const char *sanea(const char *p) {
    if (!p) return p;
    uint64_t v = (uint64_t)(uintptr_t)p;
    if ((v >> 33) == 0) return p;
    uint64_t t = (uint64_t)(uintptr_t)clean_ptr((void *)(uintptr_t)v);
    if (t && (t >> 33) == 0) {
        static int n;
        if (g_macpad_verbose && n < 20) {
            P("  去标签指针 0x%016llx -> 0x%llx\n", (unsigned long long)v,
              (unsigned long long)t);
            n++;
        }
        return (const char *)(uintptr_t)t;
    }
    return p;
}

static int  mp_strcmp(const char *a, const char *b)      { return strcmp(sanea(a), sanea(b)); }
static int  mp_strncmp(const char *a, const char *b, size_t n) { return strncmp(sanea(a), sanea(b), n); }
static int  mp_strcasecmp(const char *a, const char *b)  { return strcasecmp(sanea(a), sanea(b)); }
static int  mp_strncasecmp(const char *a, const char *b, size_t n) { return strncasecmp(sanea(a), sanea(b), n); }
static char *mp_strstr(const char *a, const char *b)     { return strstr(sanea(a), sanea(b)); }
static size_t mp_strlcpy(char *d, const char *s, size_t n) { return strlcpy(d, sanea(s), n); }
static size_t mp_strlcat(char *d, const char *s, size_t n) { return strlcat(d, sanea(s), n); }

// 裸 blr 调 3 参函数：避免把 void* 强转成函数指针时又生成一次授权分支。
__attribute__((noinline))
static void *mp_call3(void *fn, void *a, void *b, void *c) {
    register uint64_t x0 __asm("x0") = (uint64_t)(uintptr_t)a;
    register uint64_t x1 __asm("x1") = (uint64_t)(uintptr_t)b;
    register uint64_t x2 __asm("x2") = (uint64_t)(uintptr_t)c;
    register uint64_t x9 __asm("x9") = (uint64_t)(uintptr_t)fn;
    __asm__ __volatile__(
        "blr x9\n"
        : "+r"(x0)
        : "r"(x1), "r"(x2), "r"(x9)
        : "x3", "x4", "x5", "x6", "x7", "x8",
          "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17",
          "x30", "cc", "memory", "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7");
    return (void *)(uintptr_t)x0;
}

static void *shim_lookup(const char *sym) {
    if (!sym || !sym[0]) return (void *)&macpad_missing_sym;
    const char *name = sym;
    if (name[0] == '_') name++;
    if ((strcmp(name, "exit") == 0 || strcmp(name, "_exit") == 0) && g_hook_exit) {
        P("  shim 拦截 %s -> 本地钩子 @%p\n", sym, (void *)&macpad_exit_shim);
        return (void *)&macpad_exit_shim;
    }
    if (strcmp(name, "fts_open") == 0) return (void *)&mp_fts_open;
    if (strcmp(name, "qsort") == 0)    return (void *)&mp_qsort;
    if (strcmp(name, "qsort_r") == 0)  return (void *)&mp_qsort_r;
    if (strcmp(name, "bsearch") == 0)  return (void *)&mp_bsearch;
    // 字符串族**不要**拦。试过（v3.24）：把 strcmp/strncmp/... 换成先剥标签的版本，
    // 想修 ps 那个"字符串指针带标签"的数据中止，结果 ls 反而被拖进 PAC 自愈死循环
    // （目标落在 libsystem_c 内部，同一处反复 200 万次），而 ps 也没修好。
    // 净收益为负，撤掉。原始症状留在 v3.24 的日志里备查。
    void *p = dlsym(RTLD_DEFAULT, name);
    if (!p && name != sym) p = dlsym(RTLD_DEFAULT, sym);
    if (!p && name[0] == '_') p = dlsym(RTLD_DEFAULT, name + 1);   // ___stdoutp 这类
    if (!p) {
        P("  shim 替身 %s（本机 libSystem 没有这个符号）\n", sym);
        return (void *)&macpad_missing_sym;
    }
    // dlsym 给的是已签名指针，先剥回裸地址；后面要不要重签由槽位决定。
    return clean_ptr(p);
}

struct sect {
    char seg[17], name[17];
    uint64_t addr, size;
    uint32_t offset, flags;
};
static struct sect g_sects[80];
static int g_nsect;

// 就地抓脏值：把内存里所有等于 dirty 的 8 字节槽位换成 clean。
//
// 为什么必须这么干：只把故障现场的 pc 改干净是治标。ls 把排序回调交给
// libsystem_c 的 qsort/fts，那个函数指针存在 ls 自己的全局表里；libc 每次比较
// 都重新取一次、重新 blr 一次，所以源头不改就会在同一个地址上无限循环
// （实测原地打转 200 万次）。
//
// 扫描面：本映像的所有可写 section + 当前线程栈。命中就打一行，顺便把脏值
// 到底躺在哪儿也交代清楚。
static uint64_t g_page_low_vm = 0;   // 映像最低 vmaddr（map_and_run 里设置）
static int scrub_dirty_value(uint64_t dirty, uint64_t clean, uint64_t sp) {
    if (!dirty || dirty == clean || !g_img_lo || !g_page_low_vm) return 0;
    int hits = 0;
    uint8_t *base = (uint8_t *)(uintptr_t)g_img_lo;

    for (int si = 0; si < g_nsect; si++) {
        struct sect *sc = &g_sects[si];
        if (strcmp(sc->seg, "__DATA") && strcmp(sc->seg, "__DATA_CONST") &&
            strcmp(sc->seg, "__DATA_DIRTY")) continue;
        if (!sc->size || sc->addr < g_page_low_vm) continue;
        uint64_t *w = (uint64_t *)(base + (sc->addr - g_page_low_vm));
        uint64_t n = sc->size / 8;
        for (uint64_t k = 0; k < n; k++) {
            if (w[k] != dirty) continue;
            w[k] = clean;
            hits++;
            if (hits <= 6)
                P("  !! 脏值命中 %s/%s+0x%llx (0x%llx -> 0x%llx)\n", sc->seg, sc->name,
                  (unsigned long long)(k * 8), (unsigned long long)dirty,
                  (unsigned long long)clean);
        }
    }

    // 线程栈：从 sp 往上扫到栈顶（回调指针常常是自动变量）
    {
        void *top = pthread_get_stackaddr_np(pthread_self());
        size_t sz = pthread_get_stacksize_np(pthread_self());
        uint8_t *lo = (uint8_t *)top - sz;
        uint64_t *w = (uint64_t *)((sp > (uint64_t)(uintptr_t)lo ? (uint8_t *)(uintptr_t)sp : lo));
        uint8_t *endp = (uint8_t *)top;
        int sth = 0;
        for (; (uint8_t *)(w + 1) <= endp; w++) {
            if (*w != dirty) continue;
            *w = clean;
            hits++; sth++;
        }
        if (sth) P("  !! 脏值命中 栈 ×%d\n", sth);
    }
    if (!hits) P("  !! 脏值 0x%llx 在映像可写段与线程栈里都没找到（源头不在我们这儿）\n",
                 (unsigned long long)dirty);
    return hits;
}

// 兜底：把整个进程的可写映射扫一遍（堆里的回调表通常不在本映像的数据段里）。
// 只在故障后的头两次调用，预算 512MB，避免拖垮一次比较只要几十微秒的程序。
static int scan_vm_dirty(uint64_t dirty, uint64_t clean) {
    if (!dirty || dirty == clean) return 0;
    int hits = 0;
    uint64_t budget = 512ull * 1024 * 1024;
    // 注意：iPhoneOS 12.4 SDK 的 <mach/mach_vm.h> 是个空壳（直接 #error unsupported），
    // 所以这里用老的 vm_region_64，参数是 vm_address_t/vm_size_t，够用。
    vm_address_t addr = 0;
    vm_size_t size = 0;
    while (budget) {
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64,
                         (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) break;
        if (size == 0) break;
        if ((info.protection & VM_PROT_WRITE) && size <= 64u * 1024 * 1024) {
            uint64_t *w = (uint64_t *)(uintptr_t)addr;
            uint64_t n = (uint64_t)size / 8;
            for (uint64_t k = 0; k < n; k++)
                if (w[k] == dirty) { w[k] = clean; hits++; }
            budget = ((uint64_t)size < budget) ? budget - (uint64_t)size : 0;
        }
        addr += size;
    }
    return hits;
}

struct img {
    const uint8_t *file;
    size_t fsz;
    struct segment_command_64 *segs[MAX_SEGS];
    uint32_t nsegs;
    uint64_t low_vm, high_vm, page_low, slide;
    uint8_t *base;
    int has_dyld_info;
    struct dyld_info_command *di;
};

// ---------------------------------------------------------------- chained 走查
static int walk_chain(struct img *im, int segidx, uint64_t off,
                      char **ord, int ord_n, int *out_bind, int *out_rebase) {
    *out_bind = 0; *out_rebase = 0;
    if (segidx < 0 || (uint32_t)segidx >= im->nsegs) return -1;
    struct segment_command_64 *sg = im->segs[segidx];
    uint8_t *segbase = im->base + (sg->vmaddr - im->page_low);
    int guard = 0;

    while (guard++ < 200000) {
        if (off + 8 > sg->vmsize) break;
        uint64_t *slot = (uint64_t *)(segbase + off);
        uint64_t v = *slot;
        int is_bind = CH_BIND(v);
        int is_auth = CH_AUTH(v);
        uint64_t val = 0;

        if (is_bind) {
            uint32_t ordn = (uint32_t)(v & 0xFFFF);
            const char *sym = (ordn < (uint32_t)ord_n) ? ord[ordn] : NULL;
            void *p = shim_lookup(sym);
            if (!p) {
                P("      ! ord=%u (%s) 未找到\n", ordn, sym ? sym : "?");
            }
            if (is_auth && p) {
                uint16_t disc = (uint16_t)((v >> 32) & 0xFFFF);
                int addrDiv = (int)((v >> 48) & 1);
                int key = (int)((v >> 49) & 3);
                // __auth_got 的取用形式是 `ldr x16,[x17]; braa x16,x17`，
                // 判别子就是槽位自身地址（addrDiv=1）
                p = sign_ptr(p, key, addrDiv ? (uintptr_t)slot : (uintptr_t)disc);
            }
            val = (uint64_t)p;
            (*out_bind)++;
        } else {
            if (is_auth) {
                uint32_t target = (uint32_t)(v & 0xFFFFFFFF);
                uint16_t disc = (uint16_t)((v >> 32) & 0xFFFF);
                int addrDiv = (int)((v >> 48) & 1);
                int key = (int)((v >> 49) & 3);
                val = (uint64_t)sign_ptr((void *)((uintptr_t)im->base + target), key,
                                         addrDiv ? (uintptr_t)slot : (uintptr_t)disc);
            } else {
                uint64_t target = v & 0x7FFFFFFFFFFULL;              // 43 位
                uint64_t high8 = (v >> 43) & 0xFF;
                uint64_t runtime;
                if (target >= im->page_low)
                    runtime = target + im->slide;                    // 绝对 vmaddr
                else
                    runtime = (uint64_t)im->base + target;           // 相对基址
                val = (runtime & 0x00FFFFFFFFFFFFFFULL) | (high8 << 56);
            }
            (*out_rebase)++;
        }
        *slot = val;

        uint32_t next = CH_NEXT(v);
        if (next == 0) break;
        off = (off & ~0xFFFULL) + (uint64_t)next * 4;
    }
    return 0;
}

// ---------------------------------------------------------------- 链式 fixups（完整解析）
//
// iOS 13.4 / macOS 11 起，链接器不再输出 LC_DYLD_INFO_ONLY 的操作码流，而是把所有
// rebase/bind 信息**编码进指针本身**，索引表放在 LC_DYLD_CHAINED_FIXUPS 指的那块
// blob 里。老 dyld（iOS 12 的 dyld2）不认这个格式，直接报
//     DYLD, missing LC_DYLD_INFO load command
// 但对我们这种"自己做 dyld"的装载器反而是好事：信息全在数据里，不用逆向操作码流。
//
// 结构（dyld_chained_fixups.h）：
//   dyld_chained_fixups_header   { version, starts_offset, imports_offset,
//                                  symbols_offset, imports_count,
//                                  imports_format, symbols_format }
//   dyld_chained_starts_in_image { seg_count, seg_info_offset[] }
//   dyld_chained_starts_in_segment { size, page_size, pointer_format,
//                                    segment_offset, max_valid_pointer,
//                                    page_count, page_start[] }
//
// 一个槽位的位域（以 DYLD_CHAINED_PTR_64 为例）：
//   bit63 = isBind，bit51..62 = next（单位 4 字节，相对**本页起始**），
//   低 36 位 = target（rebase）或 24 位 ordinal + 8 位 addend（bind）。
//
// 关键细节：next 的基准是 page_size，不是固定 4KB。iOS 16 的 __DATA 用 16KB 页，
// 按 0x1000 掩码会把下一页的链算错位（这正是之前手写走查对不上的原因）。
#define LC_DYLD_CHAINED_FIXUPS_CMD 0x80000034

#define CH_PTR_ARM64E            1
#define CH_PTR_64                2
#define CH_PTR_32                3
#define CH_PTR_64_OFFSET         6
#define CH_PTR_ARM64E_KERNEL     7
#define CH_PTR_ARM64E_USERLAND   9
#define CH_PTR_ARM64E_FIRMWARE   10
#define CH_PTR_ARM64E_USERLAND24 12

#define CH_START_NONE  0xFFFF
#define CH_START_MULTI 0x8000

static uint16_t rd16(const uint8_t *p) { uint16_t v; memcpy(&v, p, 2); return v; }
static uint32_t rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t rd64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }

// 缺失符号清单：跑完之后一次性报出来，这就是"这台机器到底缺哪些框架"的答案。
#define MAX_MISS 128
static char g_miss[MAX_MISS][96];
static int  g_miss_n;
static void note_missing(const char *nm) {
    for (int i = 0; i < g_miss_n; i++) if (!strcmp(g_miss[i], nm)) return;
    if (g_miss_n < MAX_MISS) snprintf(g_miss[g_miss_n++], 96, "%s", nm);
}
static void report_missing(void) {
    if (!g_miss_n) return;
    P("  缺失符号 %d 个（调用会落到空桩）:\n", g_miss_n);
    for (int i = 0; i < g_miss_n; i++) P("    - %s\n", g_miss[i]);
}

// 对外暴露，给 cli 用（-l 模式分析 dylib 时打印完整清单）
void macpad_report_missing(void) {
    if (!g_miss_n) { P("  缺失符号：无（这台机器上全都有）\n"); return; }
    P("\n  缺失符号 %d 个（本机 libSystem 没有，运行到就会崩）:\n", g_miss_n);
    for (int i = 0; i < g_miss_n; i++) P("    - %s\n", g_miss[i]);
}

struct chinfo {
    const uint8_t *blob;
    uint32_t blobsz;
    const uint8_t *imports;
    const uint8_t *symbols;
    uint32_t imp_count, imp_fmt;
};

static void ch_symbol(const struct chinfo *ci, uint32_t name_off, char *out, size_t len) {
    out[0] = 0;
    if (!ci->symbols || !ci->blobsz) return;
    if ((uint32_t)(ci->symbols - ci->blob) + name_off >= ci->blobsz) return;
    const uint8_t *p = ci->symbols + name_off;
    const uint8_t *end = ci->blob + ci->blobsz;
    size_t n = 0;
    while (p + n < end && p[n] && n < len - 1) n++;
    memcpy(out, p, n);
    out[n] = 0;
}

// imports_format: 1=IMPORT(4B) 2=IMPORT_ADDEND(8B) 3=IMPORT_ADDEND64(16B)
static int ch_import(const struct chinfo *ci, uint32_t idx, char *name, size_t nlen,
                     int64_t *addend) {
    *addend = 0; name[0] = 0;
    if (idx >= ci->imp_count) return -1;
    if (ci->imp_fmt == 1) {
        uint32_t v = rd32(ci->imports + (size_t)idx * 4);
        ch_symbol(ci, v >> 9, name, nlen);
    } else if (ci->imp_fmt == 2) {
        uint32_t v = rd32(ci->imports + (size_t)idx * 8);
        *addend = (int32_t)rd32(ci->imports + (size_t)idx * 8 + 4);
        ch_symbol(ci, v >> 9, name, nlen);
    } else if (ci->imp_fmt == 3) {
        const uint8_t *e = ci->imports + (size_t)idx * 16;
        uint64_t v = rd64(e);
        *addend = (int64_t)rd64(e + 8);
        ch_symbol(ci, (uint32_t)(v >> 32), name, nlen);
    } else {
        return -1;
    }
    return name[0] ? 0 : -1;
}

// rebase 的 target 语义随格式而变：
//   PTR_64          —— 绝对 vmaddr（老式，可能在 4GB 内任意位置）
//   PTR_64_OFFSET   —— 相对 mach_header 的偏移
//   ARM64E 家族     —— 用户态（1/9/10/12）是偏移，内核态（7）是 vmaddr
// 这里统一用"落在本镜像 vm 区间就按 vmaddr，否则按偏移"的判据兜底，
// 两种语义都能落对，且对合法值不会误判（区间外的小值必然是偏移）。
static uint64_t ch_rebase_target(struct img *im, uint64_t t, uint16_t fmt) {
    int is_off = (fmt == CH_PTR_64_OFFSET || fmt == CH_PTR_ARM64E ||
                  fmt == CH_PTR_ARM64E_USERLAND || fmt == CH_PTR_ARM64E_FIRMWARE ||
                  fmt == CH_PTR_ARM64E_USERLAND24);
    if (is_off) return (uint64_t)(uintptr_t)im->base + t;
    if (t >= im->page_low && t < im->high_vm) return t + im->slide;
    return (uint64_t)(uintptr_t)im->base + t;
}

// 走一条链。
//
// next 是**相对当前槽位**的增量（单位 4 字节），不是"页内绝对偏移"——
// 这一点踩过一次坑：按 `(off & ~page_mask) + next*4` 算，槽位在 0x8 时
// 会永远原地打转（0x8 & ~0x3fff = 0，加回来又是 0x8），整条链只修前 3 个就断了。
// 正确写法就是 `off += next * 4`。
static void ch_walk_chain(struct img *im, const struct chinfo *ci, uint8_t *segbase,
                          uint64_t vmsize, uint64_t off, uint16_t fmt, uint16_t page_size,
                          int *bind_ok, int *bind_fail, int *rebase_n) {
    int guard = 0;
    (void)page_size;
    while (guard++ < 200000) {
        if (off + 8 > vmsize) break;
        uint64_t *slot = (uint64_t *)(segbase + off);
        uint64_t v = *slot;
        uint64_t next = 0;

        if (fmt == CH_PTR_64 || fmt == CH_PTR_64_OFFSET) {
            int isb = (int)((v >> 63) & 1);
            next = (v >> 51) & 0xFFF;
            if (isb) {
                uint32_t ord = (uint32_t)(v & 0xFFFFFF);
                int add = (int)(int8_t)((v >> 24) & 0xFF);
                char nm[256]; int64_t ia = 0;
                if (ch_import(ci, ord, nm, sizeof(nm), &ia) != 0) {
                    *slot = 0; (*bind_fail)++;
                    if (g_macpad_verbose) P("    ! ordinal %u 越界\n", ord);
                } else {
                    void *p = shim_lookup(nm);
                    int64_t a = (int64_t)add + ia;
                    *slot = (uint64_t)(uintptr_t)p + (uint64_t)a;
                    if (p == (void *)&macpad_missing_sym) { (*bind_fail)++; note_missing(nm); }
                    else (*bind_ok)++;
                }
            } else {
                uint64_t t = v & 0xFFFFFFFFFULL;         // 36 位
                uint64_t h8 = (v >> 36) & 0xFF;
                uint64_t rt = ch_rebase_target(im, t, fmt);
                *slot = (rt & 0x00FFFFFFFFFFFFFFULL) | (h8 << 56);
                (*rebase_n)++;
            }
        } else if (fmt == CH_PTR_ARM64E || fmt == CH_PTR_ARM64E_USERLAND ||
                   fmt == CH_PTR_ARM64E_USERLAND24 || fmt == CH_PTR_ARM64E_KERNEL ||
                   fmt == CH_PTR_ARM64E_FIRMWARE) {
            int isb = (int)((v >> 62) & 1);
            int isa = (int)((v >> 63) & 1);
            next = (v >> 51) & 0x7FF;
            if (isb) {
                uint32_t ord = (uint32_t)(v & 0xFFFF);
                int64_t add = 0;
                if (!isa) {                                  // 非认证 bind 带 19 位有符号 addend
                    add = (int64_t)((v >> 32) & 0x7FFFF);
                    if (add & 0x40000) add -= 0x80000;
                }
                char nm[256]; int64_t ia = 0;
                if (ch_import(ci, ord, nm, sizeof(nm), &ia) != 0) {
                    *slot = 0; (*bind_fail)++;
                } else {
                    void *p = shim_lookup(nm);
                    *slot = (uint64_t)(uintptr_t)p + (uint64_t)(add + ia);
                    if (p == (void *)&macpad_missing_sym) { (*bind_fail)++; note_missing(nm); }
                    else (*bind_ok)++;
                }
            } else {
                uint64_t t, h8 = 0;
                if (isa) { t = v & 0xFFFFFFFFULL; }          // 认证 rebase：32 位偏移
                else { t = v & 0x7FFFFFFFFFFULL; h8 = (v >> 43) & 0xFF; }
                uint64_t rt = ch_rebase_target(im, t, fmt);
                *slot = (rt & 0x00FFFFFFFFFFFFFFULL) | (h8 << 56);
                (*rebase_n)++;
            }
        } else {
            if (g_macpad_verbose && guard == 1)
                P("    链式: 不支持的 pointer_format=%u，跳过本段\n", fmt);
            return;
        }

        if (!next) break;
        off += (uint64_t)next * 4;
    }
}

static int apply_chained_fixups(struct img *im, uint32_t dataoff, uint32_t datasize,
                                int *out_bind, int *out_rebase, int *out_fail) {
    *out_bind = *out_rebase = *out_fail = 0;
    if (!datasize || (size_t)dataoff + datasize > im->fsz) return -1;

    struct chinfo ci;
    ci.blob = im->file + dataoff;
    ci.blobsz = datasize;
    const uint8_t *h = ci.blob;
    uint32_t starts_off  = rd32(h + 4);
    uint32_t imports_off = rd32(h + 8);
    uint32_t symbols_off = rd32(h + 12);
    uint32_t imp_count   = rd32(h + 16);
    uint32_t imp_fmt     = rd32(h + 20);
    uint32_t sym_fmt     = rd32(h + 24);
    if (starts_off >= datasize) return -1;
    if (sym_fmt != 0) { P("  链式: 符号区为压缩格式(%u)，不支持\n", sym_fmt); return -1; }
    if (imports_off >= datasize || symbols_off >= datasize) return -1;
    ci.imports = ci.blob + imports_off;
    ci.symbols = ci.blob + symbols_off;
    ci.imp_count = imp_count;
    ci.imp_fmt = imp_fmt;

    const uint8_t *sii = ci.blob + starts_off;
    uint32_t seg_count = rd32(sii);
    P("  链式 fixups: v%u，%u 段，%u 个导入（fmt=%u）\n",
      rd32(h), seg_count, imp_count, imp_fmt);
    if (seg_count > 64) seg_count = 64;

    for (uint32_t si = 0; si < seg_count; si++) {
        if ((size_t)starts_off + 4 + (size_t)(si + 1) * 4 > datasize) break;
        uint32_t sio = rd32(sii + 4 + si * 4);
        if (!sio) continue;
        if ((size_t)starts_off + sio + 22 > datasize) continue;
        const uint8_t *sc = sii + sio;
        uint16_t page_size = rd16(sc + 4);
        uint16_t fmt       = rd16(sc + 6);
        uint16_t page_cnt  = rd16(sc + 20);
        if (!page_size) page_size = 0x1000;
        if (si >= im->nsegs) continue;
        struct segment_command_64 *sg = im->segs[si];
        if (sg->vmaddr < im->page_low) continue;                 // __PAGEZERO
        uint8_t *segbase = im->base + (sg->vmaddr - im->page_low);

        int b0 = *out_bind, r0 = *out_rebase, f0 = *out_fail;
        for (uint16_t pi = 0; pi < page_cnt; pi++) {
            if ((size_t)sio + 22 + (size_t)(pi + 1) * 2 > datasize) break;
            uint16_t start = rd16(sc + 22 + pi * 2);
            if (start == CH_START_NONE) continue;
            if (start & CH_START_MULTI) {
                // 溢出表：page_start[] 之后的一段 u16 列表，0x8000 结束
                uint32_t k = start & ~CH_START_MULTI;
                uint32_t maxk = (uint32_t)page_cnt + 512;
                while (k * 2 + 22 + sio < datasize && k < maxk) {
                    uint16_t s2 = rd16(sc + 22 + k * 2);
                    if (s2 == CH_START_MULTI) break;
                    ch_walk_chain(im, &ci, segbase, sg->vmsize,
                                  (uint64_t)pi * page_size + s2, fmt, page_size,
                                  out_bind, out_fail, out_rebase);
                    k++;
                }
            } else {
                ch_walk_chain(im, &ci, segbase, sg->vmsize,
                              (uint64_t)pi * page_size + start, fmt, page_size,
                              out_bind, out_fail, out_rebase);
            }
        }
        char sn[17];
        memcpy(sn, sg->segname, 16); sn[16] = 0;
        P("  %-16s 链式: 绑定 %d（缺 %d），重基 %d，页 %u×0x%x fmt=%u\n",
          sn, *out_bind - b0, *out_fail - f0, *out_rebase - r0, page_cnt, page_size, fmt);
    }
    return (*out_bind + *out_rebase) ? 0 : -1;
}

// ---------------------------------------------------------------- rebase（经典）
static void apply_rebase(struct img *im, int *out_count) {
    *out_count = 0;
    if (!im->has_dyld_info || !im->di->rebase_off || !im->di->rebase_size) return;
    if ((size_t)im->di->rebase_off + im->di->rebase_size > im->fsz) return;

    const uint8_t *p = im->file + im->di->rebase_off;
    const uint8_t *end = p + im->di->rebase_size;
    uint8_t type = 0; int seg = -1; uint64_t off = 0; int count = 0;

    while (p < end) {
        uint8_t b = *p++;
        uint8_t op = b & REBASE_OPCODE_MASK, imm = b & 0x0F;
        if (op == 0x00) break;
        switch (op) {
            case REBASE_OPCODE_SET_TYPE_IMM: type = imm; break;
            case REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
                seg = imm; off = read_uleb(&p, end); break;
            case REBASE_OPCODE_ADD_ADDR_ULEB: off += read_uleb(&p, end); break;
            case REBASE_OPCODE_ADD_ADDR_IMM_SCALED: off += (uint64_t)imm * 8; break;
            case REBASE_OPCODE_DO_REBASE_IMM_TIMES:
            case REBASE_OPCODE_DO_REBASE_ULEB_TIMES:
            case REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB:
            case REBASE_OPCODE_DO_REBASE_ULEB_TIMES_SKIPPING_ULEB: {
                uint64_t times = (op == REBASE_OPCODE_DO_REBASE_IMM_TIMES) ? imm
                                                                          : read_uleb(&p, end);
                uint64_t skip = 0;
                if (op == REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB ||
                    op == REBASE_OPCODE_DO_REBASE_ULEB_TIMES_SKIPPING_ULEB)
                    skip = read_uleb(&p, end);
                for (uint64_t i = 0; i < times && count < MAX_OPS; i++) {
                    if (seg < 0 || (uint32_t)seg >= im->nsegs) break;
                    struct segment_command_64 *sg = im->segs[seg];
                    if (off + 8 > sg->vmsize) break;
                    if (type == REBASE_TYPE_POINTER) {
                        uint64_t *slot = (uint64_t *)(im->base + (sg->vmaddr - im->page_low) + off);
                        *slot += im->slide;
                        count++;
                    }
                    off += 8 + skip;
                }
                break;
            }
            default: return;
        }
    }
    *out_count = count;
}

// ---------------------------------------------------------------- bind（经典 + threaded）
struct bindstat { int ok, fail, chains, chbind, chrebase; };

static void linear_bind_pointers(struct img *im, char **ord, int ord_n,
                                 int *out_bind, int *out_rebase);

static void apply_bind(struct img *im, uint32_t off_field, uint32_t size_field,
                       const char *label, struct bindstat *st) {
    memset(st, 0, sizeof(*st));
    if (!im->has_dyld_info || !off_field || !size_field) return;
    if ((size_t)off_field + size_field > im->fsz) { P("  %s 越界\n", label); return; }

    const uint8_t *p = im->file + off_field;
    const uint8_t *end = p + size_field;
    char *ord[MAX_ORD];
    int ord_n = 0;
    char sym[256]; sym[0] = 0;
    int seg = -1;
    uint64_t seg_off = 0;
    int reported = 0;

    while (p < end) {
        uint8_t b = *p++;
        uint8_t op = b & BIND_OPCODE_MASK, imm = b & 0x0F;
        switch (op) {
            case BIND_OPCODE_DONE:
                continue;
            case BIND_OPCODE_SET_DYLIB_ORDINAL_IMM:
            case BIND_OPCODE_SET_DYLIB_SPECIAL_IMM:
                break;
            case BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB:
                read_uleb(&p, end);
                break;
            case BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM: {
                size_t n = 0;
                while (p < end && *p && n < sizeof(sym) - 1) sym[n++] = (char)*p++;
                sym[n] = 0;
                if (p < end) p++;
                if (ord_n < MAX_ORD) {
                    ord[ord_n] = strdup(sym);
                    ord_n++;
                }
                break;
            }
            case BIND_OPCODE_SET_TYPE_IMM:
                break;
            case BIND_OPCODE_SET_ADDEND_SLEB:
                read_sleb(&p, end);
                break;
            case BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
                seg = imm; seg_off = read_uleb(&p, end);
                break;
            case BIND_OPCODE_ADD_ADDR_ULEB:
                seg_off += read_uleb(&p, end);
                break;
            case BIND_OPCODE_DO_BIND:
            case BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB:
            case BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED:
            case BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB: {
                uint64_t times = 1, skip = 0;
                if (op == BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB) {
                    times = read_uleb(&p, end); skip = read_uleb(&p, end);
                } else if (op == BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB) {
                    skip = read_uleb(&p, end);
                } else if (op == BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED) {
                    skip = (uint64_t)imm * 8;
                }
                if (seg < 0 || (uint32_t)seg >= im->nsegs) break;
                for (uint64_t i = 0; i < times; i++) {
                    struct segment_command_64 *sg = im->segs[seg];
                    if (seg_off + 8 > sg->vmsize) break;
                    uint64_t *slot = (uint64_t *)(im->base + (sg->vmaddr - im->page_low) + seg_off);
                    void *a = shim_lookup(sym);
                    if (a && a != (void *)&macpad_missing_sym) {
                        *slot = (uint64_t)a; st->ok++;
                    } else {
                        // 空桩：记进缺失清单，运行到才会崩，但清单先给出来
                        *slot = (uint64_t)(a ? a : 0);
                        st->fail++;
                        note_missing(sym);
                        if (reported++ < 8) P("    ! 本机没有 %s\n", sym);
                    }
                    seg_off += 8 + skip;
                }
                break;
            }
            case BIND_OPCODE_THREADED: {
                if (imm == 0) {
                    uint64_t cap = read_uleb(&p, end);
                    P("  %s: threaded ordinal 表容量 %llu\n", label, (unsigned long long)cap);
                } else {
                    // 顺序数组优先：macOS 11 的 __auth_got/__got 就是这个形态。
                    // 链走查的 next 单位在这批二进制里对不上（会写错 4 字节），
                    // 只在顺序扫不到东西时才当兜底。
                    int lb = 0, lrb = 0;
                    linear_bind_pointers(im, ord, ord_n, &lb, &lrb);
                    int cb = 0, crb = 0;
                    if (lb + lrb == 0)
                        walk_chain(im, seg, seg_off, ord, ord_n, &cb, &crb);
                    st->chains++;
                    st->chbind += cb + lb;
                    st->chrebase += crb + lrb;
                    P("  %s: seg=%d off=0x%llx -> 绑定 %d, 重基 %d\n",
                      label, seg, (unsigned long long)seg_off, cb + lb, crb + lrb);
                }
                break;
            }
            default:
                P("  %s 未知操作码 0x%02x\n", label, b);
                return;
        }
    }
    P("  %s 汇总: 经典绑定 %d (失败 %d), 链 %d 条\n", label, st->ok, st->fail, st->chains);
}

// ---------------------------------------------------------------- FAT 切片
static const uint8_t *pick_slice(const uint8_t *file, size_t fsz, size_t *out_sz,
                                 char *why, size_t whylen) {
    uint32_t be = 0;
    if (fsz >= 8) be = ((uint32_t)file[0] << 24) | ((uint32_t)file[1] << 16) |
                       ((uint32_t)file[2] << 8) | file[3];
    if (be != 0xCAFEBABE && be != 0xCAFEBABF) {
        *out_sz = fsz;
        return file;                     // 单切片
    }
    uint32_t n = ((uint32_t)file[4] << 24) | ((uint32_t)file[5] << 16) |
                 ((uint32_t)file[6] << 8) | file[7];
    snprintf(why, whylen, "FAT, %u slices", n);
    const uint8_t *fallback = NULL; size_t fallback_sz = 0;
    for (uint32_t i = 0; i < n && 8 + (size_t)(i + 1) * 20 <= fsz; i++) {
        const uint8_t *e = file + 8 + i * 20;
        uint32_t ct   = ((uint32_t)e[0] << 24) | ((uint32_t)e[1] << 16) | ((uint32_t)e[2] << 8) | e[3];
        uint32_t csu  = ((uint32_t)e[4] << 24) | ((uint32_t)e[5] << 16) | ((uint32_t)e[6] << 8) | e[7];
        uint32_t off  = ((uint32_t)e[8] << 24) | ((uint32_t)e[9] << 16) | ((uint32_t)e[10] << 8) | e[11];
        uint32_t size = ((uint32_t)e[12] << 24) | ((uint32_t)e[13] << 16) | ((uint32_t)e[14] << 8) | e[15];
        if (ct != 0x0100000C || off + (size_t)size > fsz) continue;
        P("  FAT slice[%u]: arm64 subtype=0x%x off=%u size=%u\n", i, csu & 0xFF, off, size);
        if ((csu & 0xFF) == 2) { *out_sz = size; return file + off; }   // 优先 arm64e
        if (!fallback) { fallback = file + off; fallback_sz = size; }
    }
    if (fallback) { *out_sz = fallback_sz; return fallback; }
    *out_sz = 0;
    return NULL;
}

// threaded 时代（macOS 11）的 __auth_got / __got 不是按 next 串起来的链，
// 而是一段**顺序数组**：低 16 位是 ordinal，bit62=bind，bit63=auth。
// 按 section 边界逐 8 字节解码，比猜 next 步进可靠。
static int g_dbg = 0;

// 哪些 section 里装的是"需要修复的指针"。
// __const 要按段区分：__DATA_CONST,__const 是可写段里的指针数组（ps 的字符串表就在这儿），
// 而 __TEXT,__const 是只读常量池，碰不得（mprotect 后是 r-x，写了会直接崩）。
static int is_ptr_section(const char *seg, const char *n) {
    if (!strcmp(n, "__auth_got") || !strcmp(n, "__got") ||
        !strcmp(n, "__la_symbol_ptr") || !strcmp(n, "__auth_ptr") ||
        !strcmp(n, "__nl_symbol_ptr") || !strcmp(n, "__thread_ptrs"))
        return 1;
    if (!strcmp(n, "__const"))
        return !strcmp(seg, "__DATA_CONST") || !strcmp(seg, "__DATA");
    return 0;
}

static void linear_bind_pointers(struct img *im, char **ord, int ord_n,
                                 int *out_bind, int *out_rebase) {
    *out_bind = 0; *out_rebase = 0;
    for (int si = 0; si < g_nsect; si++) {
        struct sect *sc = &g_sects[si];
        if (!is_ptr_section(sc->seg, sc->name)) continue;
        if (sc->addr < im->page_low || sc->addr + sc->size > im->high_vm) continue;
        uint64_t n = sc->size / 8;
        int did = 0;
        for (uint64_t k = 0; k < n; k++) {
            uint64_t *slot = (uint64_t *)(im->base + (sc->addr - im->page_low) + k * 8);
            uint64_t v = *slot;
            int is_bind = CH_BIND(v);
            int is_auth = CH_AUTH(v);
            if (is_bind) {
                uint32_t ordn = (uint32_t)(v & 0xFFFF);
                if (ordn >= (uint32_t)ord_n) {
                    if (g_dbg < 8) { P("      跳过 %s+0x%llx: 值 0x%016llx ordinal=%u 超表\n",
                        sc->name, (unsigned long long)(k*8), (unsigned long long)v, ordn); g_dbg++; }
                    continue;
                }
                const char *sym = ord[ordn];
                void *p = shim_lookup(sym);
                if (!p) { P("      ! ord=%u (%s) 未找到\n", ordn, sym ? sym : "?"); continue; }
                uint64_t raw_slot = v;
                if (is_auth) {
                    uint16_t disc = (uint16_t)((v >> 32) & 0xFFFF);
                    int addrDiv = (int)((v >> 48) & 1);
                    int key = (int)((v >> 49) & 3);
                    uintptr_t modifier = addrDiv ? (uintptr_t)slot : (uintptr_t)disc;
                    void *signed_p = sign_ptr(p, key, modifier);
                    if (g_macpad_verbose && g_dbg < 20) {
                        P("      %-22s ord=%-3u key=%d addrDiv=%d modifier=0x%llx\n"
                          "        slot=0x%016llx sym=%p signed=%p\n",
                          sym ? sym : "?", ordn, key, addrDiv,
                          (unsigned long long)modifier,
                          (unsigned long long)raw_slot, p, signed_p);
                        g_dbg++;
                    }
                    p = signed_p;
                }
                *slot = (uint64_t)p;
                (*out_bind)++;
                did++;
            } else if (v) {
                // 认证指针与非认证指针的 target 宽度不同：
                //   __auth_ptr/__auth_got : target = 低 32 位（镜像内偏移），另带 key/diversity
                //   __got/__ptr           : target = 低 43 位（可能是绝对 vmaddr），另带 high8
                // 所以范围检查只能放在非认证分支里；对认证指针做 page_low 比较会把它们全滤掉。
                uint64_t runtime;
                if (is_auth) {
                    uint32_t target = (uint32_t)(v & 0xFFFFFFFF);
                    uint16_t disc = (uint16_t)((v >> 32) & 0xFFFF);
                    int addrDiv = (int)((v >> 48) & 1);
                    int key = (int)((v >> 49) & 3);
                    runtime = (uint64_t)sign_ptr((void *)((uintptr_t)im->base + target), key,
                                                 addrDiv ? (uintptr_t)slot : (uintptr_t)disc);
                } else {
                    uint64_t target = v & 0x7FFFFFFFFFFULL;             // 43 位
                    uint64_t high8 = (v >> 43) & 0xFF;
                    uint64_t span = im->high_vm - im->page_low;
                    if (target >= im->page_low && target <= im->high_vm)
                        runtime = target + im->slide;                   // 绝对 vmaddr
                    else if (target < span)
                        runtime = (uint64_t)im->base + target;          // 相对基址
                    else {
                        if (g_dbg < 8) { P("      跳过 %s+0x%llx: 值 0x%016llx 无法定位\n",
                            sc->name, (unsigned long long)(k*8), (unsigned long long)v); g_dbg++; }
                        continue;
                    }
                    runtime = (runtime & 0x00FFFFFFFFFFFFFFULL) | (high8 << 56);
                }
                *slot = runtime;
                (*out_rebase)++;
                did++;
            }
        }
        if (did)
            P("  线性绑定 %s/%s: %d 个槽位（%llu 个 8 字节）\n",
              sc->seg, sc->name, did, (unsigned long long)n);
    }
}

// 兜底：__DATA/__DATA_CONST 里存在既不挂在 threaded 链上、也没有 classic rebase 记录的
// 裸指针槽位（ps 的 __DATA,__data +0xf20..+0xf30 就是三个指向 __cstring 的字符串指针）。
// dyld 在 macOS 上会修好它们，但两条正式通路都覆盖不到，所以这里补一遍扫描：
// 只认 "auth=0、bind=0、低 43 位恰好落在本镜像 vm 区间" 的值——这种形态几乎只可能是指针，
// 而且改完的值是 base+offset（远在 vm 区间之外），天然幂等，重复扫不会二次修改。
static int sweep_orphan_rebases(struct img *im) {
    int fixed_n = 0;
    for (int si = 0; si < g_nsect; si++) {
        struct sect *sc = &g_sects[si];
        if (strcmp(sc->seg, "__DATA_CONST") && strcmp(sc->seg, "__DATA")) continue;
        if (sc->addr < im->page_low || sc->addr + sc->size > im->high_vm) continue;
        uint64_t n = sc->size / 8;
        for (uint64_t k = 0; k < n; k++) {
            uint64_t *slot = (uint64_t *)(im->base + (sc->addr - im->page_low) + k * 8);
            uint64_t v = *slot;
            if (!v) continue;
            if (v >> 62) continue;                       // auth / bind：已由正式通路处理
            uint64_t target = v & 0x7FFFFFFFFFFULL;      // 低 43 位
            if (target < im->page_low || target > im->high_vm) continue;
            *slot = (uint64_t)im->base + (target - im->page_low);
            fixed_n++;
            P("  兜底重基 %s+0x%llx: 0x%llx -> 0x%llx\n", sc->name,
              (unsigned long long)(k * 8), (unsigned long long)v,
              (unsigned long long)*slot);
        }
    }
    return fixed_n;
}

// 把 __DATA*/指针槽位里残留的"已签名指针"统一剥成裸地址。
//
// 背景：我们把 braa/blraa 中和成了 br/blr，等于放弃"跳转前认证"这一环。
// 于是槽位里到底放签名值还是裸值，必须二选一并全程一致 —— 我们选裸值。
// 但 __auth_got / __auth_ptr 的填充来源不止一处（threded bind、经典 bind、
// 顺序数组 rebase），任何一个漏掉都会在 br 时跳到 far=pc|签名位。
// 所以装载末尾再横扫一遍，只认形态严格的才改：
//   高位(bit33 以上)非零  →  ptrauth_strip 后高位干净  →  落点确实是已映射镜像
// 三条同时满足才动手。对本来就干净的指针 xpaci 是恒等，天然幂等。
static int strip_pac_slots(struct img *im) {
    int n = 0;
    uint64_t lo = (uint64_t)(uintptr_t)im->base;
    uint64_t hi = lo + (im->high_vm - im->page_low);
    for (int si = 0; si < g_nsect; si++) {
        struct sect *sc = &g_sects[si];
        // 只碰 __DATA*。曾经试过把 __TEXT,__const 也纳进来（想修 ps 的
        // "字符串指针带标签"），结果 __TEXT 里的字面池被改坏，ls 直接挂死
        // （rc=124 超时）—— __TEXT 里的东西不能按"指针"猜，撤掉。
        if (strcmp(sc->seg, "__DATA") && strcmp(sc->seg, "__DATA_CONST") &&
            strcmp(sc->seg, "__DATA_DIRTY")) continue;
        if (sc->addr < im->page_low || sc->addr + sc->size > im->high_vm) continue;
        uint64_t cnt = sc->size / 8;
        for (uint64_t k = 0; k < cnt; k++) {
            uint64_t *slot = (uint64_t *)(im->base + (sc->addr - im->page_low) + k * 8);
            uint64_t v = *slot;
            if (!v || (v >> 33) == 0) continue;
            uint64_t s = (uint64_t)(uintptr_t)clean_ptr((void *)(uintptr_t)v);
            if (s == v || !s || (s >> 33)) continue;
            if (!((s >= lo && s < hi))) {
                Dl_info di;
                memset(&di, 0, sizeof(di));
                if (!dladdr((void *)(uintptr_t)s, &di) || !di.dli_fbase) continue;
            }
            *slot = s;
            n++;
            if (g_macpad_verbose && n <= 24)
                P("  剥签 %s/%s+0x%llx: 0x%llx -> 0x%llx\n", sc->seg, sc->name,
                  (unsigned long long)(k * 8), (unsigned long long)v, (unsigned long long)s);
        }
    }
    return n;
}

// 修"链式授权 rebase"槽位（ps 崩溃的真正根因）。
//
// macOS 11 arm64e 镜像用 LC_DYLD_CHAINED_FIXUPS，且可执行段 __DATA,__data 从
// __DATA_CONST,__auth_got 链出 74 个定值指针。它们不是绑定，也不是 classic
// rebase，而是 chained 格式里的 REBASE + auth：
//
//   bit63=1  bit62=0  next=...  key=...  addrDiv=1  diversity=...  target=低 32 位偏移
//
// dyld 的修法是 raw = base + (target << addrDiv)（32 位偏移模型，Apple 的
// dyld3 对 4GB 内镜像默认走这个）。我们的 chained 通路当时只认 bit62=1 的
// bind 槽，于是这些槽原样留成 0x8030000000003f80 —— 读出来是 far 指针，
// ps 据此算出来的 x8=0x8030000000004490，第一下 blraa 就崩在
// 0x1010044933（远指针当函数地址跳）。ps 的符号表/参数表全在这条链上，
// 所以它比 ls/dd 更早死。
//
// 只认三重形态：auth=1、bind=0、低 32 位偏移落在本镜像 vm 跨度内。
// 签名指针（来自 dlsym 等）低位是真实地址 0x0100xxxx，不会落进"小偏移"区间；
// 改完是 base+offset 的裸地址，天然幂等，重复扫不会二次修改。
static int fix_chained_auth_rebases(struct img *im) {
    int n = 0;
    uint64_t span = im->high_vm - im->page_low;
    for (int si = 0; si < g_nsect; si++) {
        struct sect *sc = &g_sects[si];
        if (strcmp(sc->seg, "__DATA") && strcmp(sc->seg, "__DATA_CONST") &&
            strcmp(sc->seg, "__DATA_DIRTY")) continue;
        if (sc->addr < im->page_low || sc->addr + sc->size > im->high_vm) continue;
        uint64_t cnt = sc->size / 8;
        for (uint64_t k = 0; k < cnt; k++) {
            uint64_t *slot = (uint64_t *)(im->base + (sc->addr - im->page_low) + k * 8);
            uint64_t v = *slot;
            if (!(v >> 63)) continue;             // 不是 auth
            if ((v >> 62) & 1) continue;          // 是 bind（另一条通路已处理）
            uint64_t target = v & 0xFFFFFFFFULL;
            if (!target || target >= span) continue;
            uint64_t raw = (uint64_t)(uintptr_t)im->base + target;
            *slot = raw;
            n++;
            if (g_macpad_verbose && n <= 12)
                P("  链式授权 rebase %s/%s+0x%llx: 0x%llx -> 0x%llx\n", sc->seg, sc->name,
                  (unsigned long long)(k * 8), (unsigned long long)v, (unsigned long long)raw);
        }
    }
    return n;
}

// ---------------------------------------------------------------- 中和跨镜像授权指令
//
// 把 __TEXT 里"跨镜像"的授权指令换成等价的无授权指令：
//
//   braa  Xn, Xm   (0xD71F0800 | Rn<<5 | Rm)  ->  br   Xn   (0xD61F0000 | Rn<<5)
//   blraa Xn, Xm   (0xD73F0800 | Rn<<5 | Rm)  ->  blr  Xn   (0xD63F0000 | Rn<<5)
//   braaz/blraaz   (0xD61F/0xD63F, Rm=11111)  ->  br   /blr
//   ldraa Xt,[Xn,#imm]                        ->  ldr  Xt,[Xn,#byteoff]
//   paciza/pacizb/pacdza/pacdzb  Xd           ->  nop
//   autiza/autizb/autdza/autdzb  Xd           ->  nop
//   xpaci/xpacd                  Xd           ->  nop
//
// 为什么要连"零修饰符签名"一起 nop：
//   ls 会把比较函数交给 qsort 之类的 libc 回调。arm64e 下它先 paciza 把函数指针
//   签好再传出去，而本机 iOS 12 的 libc 收到后是裸 blr —— 一跳就落到非规范地址，
//   ESR 报 EC=0x20 取指异常（实测 ls/ps 在 stdout 不是终端时必崩）。
//   签名和验证两边一起摘掉，指针全程保持裸地址，跨 ABI 才自洽。
//
// **绝对不要碰 paciasp/pacibsp 和 retaa/retab**。
// 它们是函数内自洽的一对：入口 pacibsp 用 SP 签 LR，出口 retab 用同一个 SP 验证再返回。
// 中间 LR 一直带签名，从栈上 ldp 回来也还是带签名。曾经把 retab 换成 ret，
// 等于跳过 autib，ret 拿着带签名的 LR 就跳走了（pc == lr，far 是被签过的 pc）。
#define IS_BRAA(v)   (((v) & 0xFFFFFC00u) == 0xD71F0800u)
#define IS_BRAAB(v)  (((v) & 0xFFFFFC00u) == 0xD71F0C00u)
#define IS_BLRAA(v)  (((v) & 0xFFFFFC00u) == 0xD73F0800u)
#define IS_BLRAAB(v) (((v) & 0xFFFFFC00u) == 0xD73F0C00u)
#define IS_LDRAA(v)  (((v) & 0xFFE00C00u) == 0xF8200400u)
// 零修饰符（Z 形）的签名 / 验证 / 去签名：只带一个 Rd，其余全固定。
// 掩码去掉 Rd(bit4..0) 和 A/B 钥匙位(bit10)，正好把这 10 种形态全部区分开。
static int is_zero_modifier_pac(uint32_t v) {
    uint32_t k = v & 0xFFFFFBE0u;
    return k == 0xDAC123E0u || k == 0xDAC127E0u ||     // paciza / pacizb
           k == 0xDAC12BE0u || k == 0xDAC12FE0u ||     // pacdza / pacdzb
           k == 0xDAC133E0u || k == 0xDAC137E0u ||     // autiza / autizb
           k == 0xDAC13BE0u || k == 0xDAC13FE0u ||     // autdza / autdzb
           k == 0xDAC143E0u || k == 0xDAC147E0u;       // xpaci  / xpacd
}
#define IS_BRAAZ(v)  (((v) & 0xFFFFFC1Fu) == 0xD61F081Fu)
#define IS_BRABZ(v)  (((v) & 0xFFFFFC1Fu) == 0xD61F0C1Fu)
#define IS_BLRAAZ(v) (((v) & 0xFFFFFC1Fu) == 0xD63F081Fu)
#define IS_BLRABZ(v) (((v) & 0xFFFFFC1Fu) == 0xD63F0C1Fu)
#define INSN_NOP     0xD503201Fu

static int is_code_section(const struct sect *sc) {
    return (sc->flags & 0x80000400u) != 0;      // S_ATTR_PURE_INSTRUCTIONS
}

static int patch_auth_sections(struct img *im) {
    int n_br = 0, n_ldr = 0, n_z = 0;
    for (int si = 0; si < g_nsect; si++) {
        struct sect *sc = &g_sects[si];
        if (!is_code_section(sc)) continue;
        if (sc->addr < im->page_low || sc->addr + sc->size > im->high_vm) continue;
        uint32_t *w = (uint32_t *)(im->base + (sc->addr - im->page_low));
        uint64_t cnt = sc->size / 4;
        int did = 0;
        for (uint64_t k = 0; k < cnt; k++) {
            uint32_t v = w[k];
            uint32_t rn = (v >> 5) & 0x1F;
            if (IS_BRAA(v) || IS_BRAAB(v)) {
                w[k] = 0xD61F0000u | (rn << 5);          // br Xn
                n_br++; did++;
            } else if (IS_BLRAA(v) || IS_BLRAAB(v)) {
                w[k] = 0xD63F0000u | (rn << 5);          // blr Xn
                n_br++; did++;
            } else if (IS_BRAAZ(v) || IS_BRABZ(v)) {
                w[k] = 0xD61F0000u | (rn << 5);          // braaz -> br
                n_br++; did++;
            } else if (IS_BLRAAZ(v) || IS_BLRABZ(v)) {
                w[k] = 0xD63F0000u | (rn << 5);          // blraaz -> blr
                n_br++; did++;
            } else if (is_zero_modifier_pac(v)) {
                w[k] = INSN_NOP;                         // 签名/验证/去签名 一律 nop
                n_z++; did++;
            } else if (IS_LDRAA(v)) {
                int32_t imm9 = (int32_t)((v >> 12) & 0x1FF);
                if (imm9 & 0x100) imm9 -= 0x200;
                int32_t byteoff = imm9 * 8;              // LDRA 的 imm9 以 8 为单位
                if (byteoff >= -256 && byteoff <= 255) {
                    uint32_t rt = v & 0x1F;
                    w[k] = 0xF8400000u | (((uint32_t)byteoff & 0x1FF) << 12) |
                           (rn << 5) | rt;               // ldr Xt, [Xn, #simm9]
                    n_ldr++; did++;
                }
            }
        }
        if (did)
            P("  去授权 %s/%s: %d 条（分支 %d，零修饰符 %d，ldr %d）\n",
              sc->seg, sc->name, did, n_br, n_z, n_ldr);
    }
    return n_br + n_z + n_ldr;
}

// ---------------------------------------------------------------- 主流程
// 由 macpad_run() 设置，map_and_run 里调用入口时使用。
static int    g_argc = 0;
static char **g_argv = NULL;
static char **g_envp = NULL;

static int map_and_run(const char *path) {
    int rc = -1;
    uint8_t *raw = NULL;
    size_t raw_sz = 0;
    const uint8_t *slice = NULL;
    size_t slice_sz = 0;
    uint8_t *img = NULL;
    size_t span = 0;
    uint64_t low_vm = 0, high_vm = 0, slide = 0, entry_vm = 0;
    int have_entry = 0;
    int fd = -1;
    struct segment_command_64 *segs[MAX_SEGS];
    uint32_t nsegs = 0;
    const uint8_t *cur = NULL, *cmds_end = NULL;
    struct dyld_info_command *di = NULL;
    struct linkedit_data_command *chfix = NULL;
    struct mach_header_64 *mh = NULL;
    struct img im;
    uint64_t page_low = 0;

    memset(&im, 0, sizeof(im));
    g_nsect = 0;
    P("\n=== %s ===\n", path);

    fd = open(path, O_RDONLY);
    if (fd < 0) { P("  open: FAIL errno=%d\n", errno); return -1; }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 64) { P("  fstat: FAIL\n"); close(fd); return -1; }
    raw_sz = (size_t)st.st_size;
    raw = (uint8_t *)mmap(NULL, raw_sz, PROT_READ, MAP_PRIVATE, fd, 0);
    if (raw == MAP_FAILED) { P("  mmap: FAIL errno=%d\n", errno); close(fd); return -1; }
    P("  file: %zu bytes\n", raw_sz);

    {
        char why[64] = "thin";
        slice = pick_slice(raw, raw_sz, &slice_sz, why, sizeof(why));
        if (!slice) { P("  没有可用 arm64 切片\n"); goto out; }
        P("  %s -> 使用切片 %zu bytes\n", why, slice_sz);
    }

    mh = (struct mach_header_64 *)slice;
    if (mh->magic != MH_MAGIC_64) { P("  magic 0x%08x 不是 64 位 Mach-O\n", mh->magic); goto out; }
    P("  header: cputype=0x%x cpusubtype=0x%x filetype=%s ncmds=%d\n",
      mh->cputype, mh->cpusubtype, ft_name(mh->filetype), mh->ncmds);

    cur = slice + sizeof(struct mach_header_64);
    cmds_end = cur + mh->sizeofcmds;
    for (uint32_t i = 0; i < mh->ncmds && cur + 8 <= cmds_end; i++) {
        struct load_command *lc = (struct load_command *)cur;
        if (lc->cmdsize < 8 || cur + lc->cmdsize > cmds_end) break;
        switch (lc->cmd) {
            case LC_SEGMENT_64: {
                struct segment_command_64 *sg = (struct segment_command_64 *)lc;
                char name[17];
                memcpy(name, sg->segname, 16); name[16] = 0;
                {
                    const uint8_t *sp = (const uint8_t *)lc + sizeof(struct segment_command_64);
                    for (uint32_t k = 0; k < sg->nsects && k < 16; k++, sp += sizeof(struct section_64)) {
                        const struct section_64 *sc = (const struct section_64 *)sp;
                        if (g_nsect >= 80) break;
                        char sn[17];
                        memcpy(sn, sc->sectname, 16); sn[16] = 0;
                        strncpy(g_sects[g_nsect].seg, name, 16); g_sects[g_nsect].seg[16] = 0;
                        strncpy(g_sects[g_nsect].name, sn, 16); g_sects[g_nsect].name[16] = 0;
                        g_sects[g_nsect].addr = sc->addr;
                        g_sects[g_nsect].size = sc->size;
                        g_sects[g_nsect].offset = sc->offset;
                        g_sects[g_nsect].flags = sc->flags;
                        g_nsect++;
                    }
                }
                int is_pz = (strcmp(name, "__PAGEZERO") == 0);
                if (nsegs < MAX_SEGS) segs[nsegs++] = sg;   // 保留下标，和 dyld 对齐
                if (is_pz) {
                    P("  SEG %-16s 不映射（vsize=0x%llx 只是地址保护）\n",
                      name, (unsigned long long)sg->vmsize);
                    break;
                }
                P("  SEG %-16s vm=0x%-11llx vsize=0x%-8llx off=0x%-6llx fsize=0x%-6llx prot=%d\n",
                  name, (unsigned long long)sg->vmaddr, (unsigned long long)sg->vmsize,
                  (unsigned long long)sg->fileoff, (unsigned long long)sg->filesize, sg->initprot);
                if (sg->vmsize) {
                    if (!low_vm || sg->vmaddr < low_vm) low_vm = sg->vmaddr;
                    if (sg->vmaddr + sg->vmsize > high_vm) high_vm = sg->vmaddr + sg->vmsize;
                }
                break;
            }
            case LC_UNIXTHREAD: {
                uint32_t *p = (uint32_t *)((uint8_t *)lc + 8);
                if (p[0] == 6 && p[1] >= 68) {
                    entry_vm = ((uint64_t *)(p + 2))[32];
                    have_entry = 1;
                }
                break;
            }
            case LC_MAIN_CMD: {
                struct entry_point_command *ep = (struct entry_point_command *)lc;
                entry_vm = ep->entryoff;            // 相对 __TEXT 起点，稍后加 low_vm
                have_entry = 2;
                P("  LC_MAIN entryoff=0x%llx\n", (unsigned long long)ep->entryoff);
                break;
            }
            case LC_BUILD_VERSION: {
                uint32_t *p = (uint32_t *)((uint8_t *)lc + 8);
                P("  LC_BUILD_VERSION platform=%u (%s) minos=0x%06x sdk=0x%06x\n",
                  p[0], plat_name(p[0]), p[1], p[2]);
                break;
            }
            case LC_VERSION_MIN_MACOSX:
            case LC_VERSION_MIN_IPHONEOS: {
                uint32_t *p = (uint32_t *)((uint8_t *)lc + 8);
                P("  LC_VERSION_MIN version=0x%06x sdk=0x%06x\n", p[0], p[1]);
                break;
            }
            case LC_DYLD_INFO:
            case LC_DYLD_INFO_ONLY: {
                di = (struct dyld_info_command *)lc;
                P("  LC_DYLD_INFO_ONLY rebase=%u/%u bind=%u/%u lazy=%u/%u weak=%u/%u\n",
                  di->rebase_off, di->rebase_size, di->bind_off, di->bind_size,
                  di->lazy_bind_off, di->lazy_bind_size,
                  di->weak_bind_off, di->weak_bind_size);
                break;
            }
            case LC_DYLD_CHAINED_FIXUPS_CMD: {
                chfix = (struct linkedit_data_command *)lc;
                P("  LC_DYLD_CHAINED_FIXUPS dataoff=%u datasize=%u（iOS 13.4+ 新格式）\n",
                  chfix->dataoff, chfix->datasize);
                break;
            }
            case LC_LOAD_DYLIB:
            case LC_LOAD_WEAK_DYLIB:
            case LC_REEXPORT_DYLIB: {
                struct dylib_command *dc = (struct dylib_command *)lc;
                const char *dn = (const char *)lc + dc->dylib.name.offset;
                P("  LOAD_DYLIB %s\n", dn);
                // 记下来给 bind-only 分析用：先把依赖装进进程，否则 Foundation /
                // Security 的符号会被判成"本机缺失"（其实只是没加载）。
                if (g_ndeps < 24) snprintf(g_deps[g_ndeps++], 512, "%s", dn);
                break;
            }
            default: break;
        }
        cur += lc->cmdsize;
    }

    if (!nsegs) { P("  没有可映射的段\n"); goto out; }
    // dylib 没有 LC_MAIN/LC_UNIXTHREAD。以前直接放弃，现在改成"只绑定不执行"：
    // 把 rebase/bind 全跑一遍，报出缺哪些符号 —— 这就是"这个 App 能不能在
    // 12.2 上跑"的判定依据，比一次次拉起看崩溃日志快得多。
    {
        int is_dylib = (mh->filetype == MH_DYLIB);
        if (!have_entry && !is_dylib) { P("  没有入口（不是可执行文件）\n"); goto out; }
        if (is_dylib) {
            g_bind_only = 1;
            P("  这是一个 dylib：只做 rebase/bind，不跳入口\n");
            // 先把它依赖的系统框架装进本进程，否则绑定阶段会把 Foundation /
            // Security 里的符号全判成"本机没有"，清单就不准了。
            for (int d = 0; d < g_ndeps; d++) {
                if (g_deps[d][0] != '/') continue;
                void *h = dlopen(g_deps[d], RTLD_LAZY | RTLD_GLOBAL);
                P("  预载 %-70s %s\n", g_deps[d], h ? "ok" : dlerror());
            }
        }
    }
    if (have_entry == 2) entry_vm += low_vm;

    page_low = low_vm & ~0xFFFULL;
    span = (size_t)(((high_vm + 0xFFF) & ~0xFFFULL) - page_low);
    P("  镜像: vm 0x%llx..0x%llx span=0x%zx\n",
      (unsigned long long)page_low, (unsigned long long)high_vm, span);

    img = (uint8_t *)mmap(NULL, span, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (img == MAP_FAILED) { P("  mmap(anon): FAIL errno=%d\n", errno); img = NULL; goto out; }
    slide = (uint64_t)img - page_low;
    P("  base=%p slide=0x%llx\n", img, (unsigned long long)(int64_t)slide);

    for (uint32_t i = 0; i < nsegs; i++) {
        struct segment_command_64 *sg = segs[i];
        if (!sg->filesize) continue;
        if (sg->vmaddr < page_low) continue;              // __PAGEZERO
        if (sg->fileoff + sg->filesize > slice_sz) { P("  段 %u 越界\n", i); continue; }
        memcpy(img + (sg->vmaddr - page_low), slice + sg->fileoff, (size_t)sg->filesize);
    }

    im.file = slice; im.fsz = slice_sz; im.nsegs = nsegs;
    for (uint32_t i = 0; i < nsegs; i++) im.segs[i] = segs[i];
    im.low_vm = low_vm; im.high_vm = high_vm; im.page_low = page_low;
    im.slide = slide; im.base = img;
    im.has_dyld_info = (di != NULL); im.di = di;

    // 两条通路互斥：新格式（链式）解析成功就不再跑启发式修复，
    // 否则启发式会把已经修正的槽位当成"脏值"再改一遍。
    int chained_ok = 0;
    if (chfix) {
        int cb = 0, crb = 0, cf = 0;
        if (apply_chained_fixups(&im, chfix->dataoff, chfix->datasize, &cb, &crb, &cf) == 0) {
            chained_ok = 1;
            P("  链式 fixups 应用完成：绑定 %d（缺 %d），重基 %d\n", cb, cf, crb);
        } else {
            P("  链式 fixups 解析失败，回退启发式\n");
        }
    }

    if (di) {
        int nrebase = 0;
        apply_rebase(&im, &nrebase);
        if (nrebase) P("  经典 rebase: %d\n", nrebase);
        struct bindstat bs;
        if (di->bind_size) apply_bind(&im, di->bind_off, di->bind_size, "bind", &bs);
        if (di->lazy_bind_size) apply_bind(&im, di->lazy_bind_off, di->lazy_bind_size, "lazy", &bs);
        if (di->weak_bind_size) apply_bind(&im, di->weak_bind_off, di->weak_bind_size, "weak", &bs);
    }

    if (!chained_ok) {
        int swept = sweep_orphan_rebases(&im);
        if (swept) P("  兜底扫描共修复 %d 个孤儿指针\n", swept);
        // 可写段里残留的签名指针统一剥成裸值（与 br/blr 中和配套）
        int ch = fix_chained_auth_rebases(&im);
        if (ch) P("  链式授权 rebase：修复 %d 个定值指针槽\n", ch);
    }
    {
        int st = strip_pac_slots(&im);
        P("  剥签扫描：%d 个残留签名指针被还原为裸地址\n", st);
    }
    report_missing();

    // 给"PAC 取指自愈"用：记录映像的可执行区间
    g_img_lo = (uintptr_t)img;
    g_img_hi = (uintptr_t)img + (high_vm - page_low);
    g_page_low_vm = page_low;

    // 必须在 __TEXT 被 mprotect 成 r-x 之前改字节
    if (g_no_pac) {
        int np = patch_auth_sections(&im);
        P("  去授权：共改写 %d 条授权指令（跨 ABI 中和）\n", np);
    }

    for (uint32_t i = 0; i < nsegs; i++) {
        struct segment_command_64 *sg = segs[i];
        if (!sg->vmsize || sg->vmaddr < page_low) continue;
        int prot = 0;
        if (sg->initprot & VM_PROT_READ) prot |= PROT_READ;
        if (sg->initprot & VM_PROT_WRITE) prot |= PROT_WRITE;
        if (sg->initprot & VM_PROT_EXECUTE) prot |= PROT_EXEC;
        if (!prot) prot = PROT_READ;
        char name[17];
        memcpy(name, sg->segname, 16); name[16] = 0;
        uint64_t start = (sg->vmaddr & ~0xFFFULL);
        uint64_t stop = ((sg->vmaddr + sg->vmsize + 0xFFF) & ~0xFFFULL);
        int r = mprotect(img + (start - page_low), (size_t)(stop - start), prot);
        P("  mprotect %-16s %s%s%s -> %s\n", name,
          (prot & PROT_READ) ? "r" : "-", (prot & PROT_WRITE) ? "w" : "-",
          (prot & PROT_EXEC) ? "x" : "-", r == 0 ? "ok" : "FAIL");
        if (r != 0 && (prot & PROT_EXEC)) { P("    !! 无执行权限 errno=%d\n", errno); goto out; }
    }

    if (g_bind_only) {
        macpad_report_missing();
        return 0;
    }

    {
        uint64_t entry = entry_vm + slide;
        P("  entry(file)=0x%llx entry(runtime)=0x%llx\n",
          (unsigned long long)entry_vm, (unsigned long long)entry);

        // SIGTRAP 也要接：arm64e 上 braa/ldraa 的 PAC 校验失败会走
        // EXC_BREAKPOINT -> SIGTRAP，而不是 SEGV。不接就只能看到"退出码 -5"。
        struct sigaction sa, o1, o2, o3, o4, o5;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = fault_handler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_NODEFER | SA_SIGINFO;
        sigaction(SIGSEGV, &sa, &o1);
        sigaction(SIGBUS, &sa, &o2);
        sigaction(SIGILL, &sa, &o3);
        sigaction(SIGTRAP, &sa, &o4);
        sigaction(SIGABRT, &sa, &o5);

        g_fault_sig = 0;
        g_pac_fix_n = 0;
        g_data_fix_n = 0;
        g_shim_exit = -1;
        int jmp = sigsetjmp(g_jb, 1);
        if (jmp == 0) {
            g_jb_arm = 1;
            // 用调用方给的 argv/envp。缺省时补一份最小可用的，
            // 因为很多程序（uname、ls）会直接读 argv[1] 或 envp。
            static char *def_argv[2];
            static char *def_envp[2];
            int argc = g_argc;
            char **argv = g_argv;
            char **envp = g_envp;
            if (!argv) {
                def_argv[0] = (char *)path;
                def_argv[1] = NULL;
                argc = 1; argv = def_argv;
            }
            if (!envp) {
                def_envp[0] = (char *)"PATH=/usr/bin:/bin:/usr/sbin:/sbin";
                def_envp[1] = NULL;
                envp = def_envp;
            }
            int rv = call_entry_raw(entry, argc, argv, envp);
            g_jb_arm = 0;
            P("  >>> 返回 %d (0x%x)（PAC 取指自愈 %d 次，数据指针自愈 %d 次）\n",
              rv, rv, g_pac_fix_n, g_data_fix_n);
            rc = rv;
        } else if (jmp == 2) {
            P("  >>> 执行成功：苹果二进制走完了自己的入口，调用 _exit(%d)（PAC 自愈 %d 次）\n",
              g_shim_exit, g_pac_fix_n);
            rc = 1000 + g_shim_exit;
        } else {
            P("  >>> 崩溃: signal %d (%s)\n", g_fault_sig, strsignal(g_fault_sig));
            P("      pc=0x%llx (镜像+0x%llx) lr=0x%llx (镜像+0x%llx) far=0x%llx\n",
              (unsigned long long)g_fault_pc,
              (unsigned long long)(g_fault_pc >= (uint64_t)img ? g_fault_pc - (uint64_t)img : 0),
              (unsigned long long)g_fault_lr,
              (unsigned long long)(g_fault_lr >= (uint64_t)img ? g_fault_lr - (uint64_t)img : 0),
              (unsigned long long)g_fault_far);
            P("      pc_raw=0x%016llx esr=0x%08x (EC=0x%02x)\n",
              (unsigned long long)g_fault_pc_raw, (unsigned)g_fault_esr,
              (unsigned)(g_fault_esr >> 26));
            P("      x0=0x%llx x1=0x%llx x2=0x%llx x3=0x%llx\n",
              (unsigned long long)g_regs[0], (unsigned long long)g_regs[1],
              (unsigned long long)g_regs[2], (unsigned long long)g_regs[3]);
            P("      x8=0x%llx x16=0x%llx x17=0x%llx fp=0x%llx sp=0x%llx\n",
              (unsigned long long)g_regs[8], (unsigned long long)g_regs[16],
              (unsigned long long)g_regs[17], (unsigned long long)g_fault_fp,
              (unsigned long long)g_fault_sp);
            // dladdr 能查到共享缓存里的符号，直接告诉我们崩在哪个函数
            {
                Dl_info d1, d2;
                memset(&d1, 0, sizeof(d1)); memset(&d2, 0, sizeof(d2));
                if (dladdr((void *)(uintptr_t)g_fault_pc, &d1) && d1.dli_fname)
                    P("      pc 位于 %s (+0x%llx) %s\n", d1.dli_fname,
                      (unsigned long long)(g_fault_pc - (uint64_t)(uintptr_t)d1.dli_fbase),
                      d1.dli_sname ? d1.dli_sname : "");
                if (dladdr((void *)(uintptr_t)g_fault_lr, &d2) && d2.dli_fname)
                    P("      lr 位于 %s (+0x%llx) %s\n", d2.dli_fname,
                      (unsigned long long)(g_fault_lr - (uint64_t)(uintptr_t)d2.dli_fbase),
                      d2.dli_sname ? d2.dli_sname : "");
                // 崩溃点那条指令本身：是 brk 就说明是显式陷阱，不是野跳转
                vm_offset_t word = 0; vm_size_t got = 0;
                if (vm_read_overwrite(mach_task_self(), (vm_address_t)g_fault_pc,
                                      4, (vm_address_t)&word, &got) == KERN_SUCCESS && got == 4)
                    P("      [pc] = 0x%08x\n", (unsigned)word);
            }
            // 帧指针回溯：苹果的二进制都带 frame pointer，一路 fp[1] 就是返回地址，
            // 能直接看出是从哪条调用链上崩的（比只看 pc 有用得多）。
            {
                uint64_t fp = g_fault_fp;
                P("      回溯:\n");
                for (int i = 0; i < 10 && fp; i++) {
                    uint64_t pair[2] = {0, 0};
                    vm_size_t n2 = 0;
                    if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp,
                                          sizeof(pair), (vm_address_t)pair, &n2) != KERN_SUCCESS
                        || n2 != sizeof(pair)) break;
                    uint64_t ra = sane_addr(pair[1]);
                    Dl_info d3;
                    memset(&d3, 0, sizeof(d3));
                    if (dladdr((void *)(uintptr_t)ra, &d3) && d3.dli_fname)
                        P("        #%d 0x%llx %s (+0x%llx) %s\n", i, (unsigned long long)ra,
                          d3.dli_fname,
                          (unsigned long long)(ra - (uint64_t)(uintptr_t)d3.dli_fbase),
                          d3.dli_sname ? d3.dli_sname : "");
                    else
                        P("        #%d 0x%llx\n", i, (unsigned long long)ra);
                    fp = sane_addr(pair[0]);
                    if (fp <= g_fault_sp) break;
                }
            }
            rc = -1000 - g_fault_sig;
        }
        sigaction(SIGSEGV, &o1, NULL);
        sigaction(SIGBUS, &o2, NULL);
        sigaction(SIGILL, &o3, NULL);
        sigaction(SIGTRAP, &o4, NULL);
        sigaction(SIGABRT, &o5, NULL);
    }

out:
    if (img) munmap(img, span);
    if (raw && raw != MAP_FAILED) munmap(raw, raw_sz);
    if (fd >= 0) close(fd);
    return rc;
}

// 对外入口：装载并运行一个 macOS Mach-O。
//   path  : 可执行文件路径（fat/thin 都行，自动选 arm64 切片）
//   argc/argv/envp : 交给镜像 main() 的参数；传 NULL 用最小默认值
//   verbose: 1 打印装载全过程到 stderr
// 返回：镜像自己的退出码；装载失败返回负数。
int macpad_run(const char *path, int argc, char **argv, char **envp, int verbose) {
    g_macpad_verbose = verbose;
    // 无条件吐一行：能区分"子进程根本没起来"和"起来了但装载器崩了"。
    // 顺带把 ptrauth 的编译期状态报出来 —— 这是 arm64/arm64e 最容易踩的坑。
    {
        char m[320];
#if __has_feature(ptrauth_calls)
        const char *pac = "on";
#else
        const char *pac = "OFF(no-op!)";
#endif
        int n = snprintf(m, sizeof(m),
                         "macpad[%d]: run %s (argc=%d) ptrauth=%s arch=%s\n",
                         (int)getpid(), path, argc, pac,
#if defined(__arm64e__)
                         "arm64e"
#else
                         "arm64"
#endif
                         );
        if (n > 0) { ssize_t w = write(2, m, (size_t)n); (void)w; }
    }
    g_argc = argc;
    g_argv = argv;
    g_envp = envp;
    int rc = map_and_run(path);
    g_argv = NULL;
    g_envp = NULL;
    g_argc = 0;
    return rc;
}

const char *macpad_host(void) {
    static char buf[256];
    struct utsname u;
    memset(&u, 0, sizeof(u));
    if (uname(&u) != 0) return "unknown";
    snprintf(buf, sizeof(buf), "%s %s (%s)", u.sysname, u.release, u.machine);
    return buf;
}

// ---------------------------------------------------------------- 指针取证
// 用来回答一个问题：dlsym / 本进程里拿到的符号地址，到底是不是一个"干净"的地址？
// arm64e 的签名位放在哪几位，取决于内核给这个进程配置的 VA 宽度 —— 这个函数把
// 原始值、几种可能的去签名结果、以及 dladdr 能否解析，一次性打出来。
static void show_ptr(const char *label, void *p) {
    uint64_t v = (uint64_t)(uintptr_t)p;
    P("  %-18s raw = 0x%016llx\n", label, (unsigned long long)v);
    uint64_t cands[3] = { v, v & 0xFFFFFFFFULL, v & 0x0000FFFFFFFFFFFFULL };
    const char *names[3] = { "as-is", "低32位", "低48位" };
    for (int i = 0; i < 3; i++) {
        Dl_info di;
        memset(&di, 0, sizeof(di));
        int ok = dladdr((void *)(uintptr_t)cands[i], &di) != 0 && di.dli_fname != NULL;
        if (ok)
            P("      %s 0x%llx -> %s +0x%llx %s\n", names[i],
              (unsigned long long)cands[i], di.dli_fname,
              (unsigned long long)(cands[i] - (uint64_t)(uintptr_t)di.dli_fbase),
              di.dli_sname ? di.dli_sname : "");
        else
            P("      %s 0x%llx -> 无法解析\n", names[i], (unsigned long long)cands[i]);
    }
}

void macpad_diag(void) {
    P("=== 指针取证 ===\n");
    P("  sizeof(void*)=%d __has_feature(ptrauth_calls)=%d\n",
      (int)sizeof(void *),
#if __has_feature(ptrauth_calls)
      1
#else
      0
#endif
      );
#if __has_feature(ptrauth_calls)
    // 最关键的一条：对 0 签名，得到的就是"纯签名位"，一眼看出 PAC 占哪几位。
    // 这决定了去签名时该保留多少位地址、以及 dlsym 的返回值能不能无损还原。
    {
        // 用 0x1000 而不是 NULL：clang 把"签空指针"当错误（-Wptrauth-null-pointers）。
        // 0x1000 只占 bit12，其余位全是签名，同样能看出签名位落在哪儿。
        uint64_t z  = (uint64_t)(uintptr_t)ptrauth_sign_unauthenticated((void *)(uintptr_t)0x1000,
                                        ptrauth_key_asia, (uintptr_t)0);
        uint64_t one = (uint64_t)(uintptr_t)ptrauth_sign_unauthenticated((void *)(uintptr_t)1,
                                        ptrauth_key_asia, (uintptr_t)0);
        uint64_t k   = 0x000000018f86d234ULL;
        uint64_t sk  = (uint64_t)(uintptr_t)ptrauth_sign_unauthenticated((void *)(uintptr_t)k,
                                        ptrauth_key_asia, (uintptr_t)0);
        uint64_t bk  = (uint64_t)(uintptr_t)ptrauth_strip((void *)(uintptr_t)sk,
                                        ptrauth_key_function_pointer);
        P("  sign(0x1000,IA,0) = 0x%016llx   <- 纯签名位\n", (unsigned long long)z);
        P("  sign(1,IA,0)      = 0x%016llx\n", (unsigned long long)one);
        P("  sign(0x18f86d234) = 0x%016llx\n", (unsigned long long)sk);
        P("  strip(上一行)     = 0x%016llx  %s\n", (unsigned long long)bk,
          bk == k ? "无损" : "!! 有损");
        {
            void *d = dlsym(RTLD_DEFAULT, "exit");
            uint64_t sd = (uint64_t)(uintptr_t)ptrauth_strip(d, ptrauth_key_function_pointer);
            P("  dlsym(exit)       = 0x%016llx\n", (unsigned long long)(uintptr_t)d);
            P("  strip(dlsym exit) = 0x%016llx\n", (unsigned long long)sd);
        }
    }
#endif
    show_ptr("dlsym(exit)", dlsym(RTLD_DEFAULT, "exit"));
    show_ptr("dlsym(malloc)", dlsym(RTLD_DEFAULT, "malloc"));
    show_ptr("dlsym(getpid)", dlsym(RTLD_DEFAULT, "getpid"));
    // 我们自己代码里直接取地址：这个值由 dyld 通过 __auth_got 提供，
    // 如果它也"脏"，说明整个进程的指针签名约定都跟我们想象的不一样。
    {
        void *fp = (void *)(uintptr_t)&exit;
        show_ptr("&exit", fp);
    }
    {
        // 把已加载镜像的头地址列一下：共享缓存里的镜像（libSystem 等）都集中在
        // 同一个基址附近，一眼就能看出这个进程的地址空间到底长什么样。
        uint32_t n = _dyld_image_count();
        P("  已加载镜像 %u 个（前 8 个）\n", n);
        for (uint32_t i = 0; i < n && i < 8; i++) {
            const struct mach_header *h = _dyld_get_image_header(i);
            const char *nm = _dyld_get_image_name(i);
            P("    %2u %p %s\n", i, (const void *)h, nm ? nm : "(null)");
        }
    }
}
