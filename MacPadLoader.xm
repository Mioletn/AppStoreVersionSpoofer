// macPad Stage-0/2 Mach-O in-process loader  (v3)
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

#import <Foundation/Foundation.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
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

static int g_fd = -1;

static void P(const char *fmt, ...) {
    if (g_fd < 0) return;
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0) {
        ssize_t w = write(g_fd, buf, (size_t)n);
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
static volatile int g_fault_sig = 0;
static volatile uint64_t g_fault_pc = 0, g_fault_lr = 0, g_fault_far = 0;

static void fault_handler(int sig, siginfo_t *si, void *uctx) {
    g_fault_sig = sig;
    g_fault_far = si ? (uint64_t)si->si_addr : 0;
    if (uctx) {
        ucontext_t *uc = (ucontext_t *)uctx;
        // arm64e 下 pc/lr 是不透明的 ptrauth 字段，必须用官方取值宏
        g_fault_pc = (uint64_t)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
        g_fault_lr = (uint64_t)__darwin_arm_thread_state64_get_lr(uc->uc_mcontext->__ss);
    }
    if (g_jb_arm) { g_jb_arm = 0; siglongjmp(g_jb, 1); }
    _exit(91);
}

typedef int (*entry_fn_t)(void);
// macOS 的 main(argc, argv, envp)：装载器得充当"内核"，把这三个交代清楚。
// 否则像 uname 这种会直接去读 argv[1]，拿到野指针。
typedef int (*entry3_fn_t)(int, char **, char **);

// ---------------------------------------------------------------- PAC 签名
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
static void *sign_ptr(void *p, int key, uintptr_t disc) {
    switch (key) {
        case 0: return ptrauth_sign_unauthenticated(p, ptrauth_key_asia, disc);
        case 1: return ptrauth_sign_unauthenticated(p, ptrauth_key_asib, disc);
        case 2: return ptrauth_sign_unauthenticated(p, ptrauth_key_asda, disc);
        default: return ptrauth_sign_unauthenticated(p, ptrauth_key_asdb, disc);
    }
}
#else
static void *sign_ptr(void *p, int key, uintptr_t disc) { (void)key; (void)disc; return p; }
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

static void macpad_exit_shim(int code) {
    g_shim_exit = code;
    P("  >>> 苹果的代码调用了 _exit(%d)\n", code);
    g_jb_arm = 0;
    siglongjmp(g_jb, 2);
}

// 缺失符号的替身：被当函数调用时安全返回；被当数据读取时也只是一段只读字节。
static void macpad_missing_sym(void) { }

static void *shim_lookup(const char *sym) {
    if (!sym || !sym[0]) return (void *)&macpad_missing_sym;
    const char *name = sym;
    if (name[0] == '_') name++;
    if (strcmp(name, "exit") == 0 || strcmp(name, "_exit") == 0) {
        P("  shim 拦截 %s -> 本地钩子（不真的退出进程）\n", sym);
        return (void *)&macpad_exit_shim;
    }
    void *p = dlsym(RTLD_DEFAULT, name);
    if (!p && name != sym) p = dlsym(RTLD_DEFAULT, sym);
    if (!p && name[0] == '_') p = dlsym(RTLD_DEFAULT, name + 1);   // ___stdoutp 这类
    if (!p) {
        P("  shim 替身 %s（本机 libSystem 没有这个符号）\n", sym);
        return (void *)&macpad_missing_sym;
    }
    return p;
}

struct sect {
    char seg[17], name[17];
    uint64_t addr, size;
    uint32_t offset, flags;
};
static struct sect g_sects[80];
static int g_nsect;

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
                    if (a) { *slot = (uint64_t)a; st->ok++; }
                    else {
                        *slot = 0; st->fail++;
                        if (reported++ < 8) P("    ! 未能绑定 %s\n", sym);
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
                if (is_auth) {
                    uint16_t disc = (uint16_t)((v >> 32) & 0xFFFF);
                    int addrDiv = (int)((v >> 48) & 1);
                    int key = (int)((v >> 49) & 3);
                    p = sign_ptr(p, key, addrDiv ? (uintptr_t)slot : (uintptr_t)disc);
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

// ---------------------------------------------------------------- 主流程
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
            case LC_LOAD_DYLIB:
            case LC_LOAD_WEAK_DYLIB:
            case LC_REEXPORT_DYLIB: {
                struct dylib_command *dc = (struct dylib_command *)lc;
                P("  LOAD_DYLIB %s\n", (const char *)lc + dc->dylib.name.offset);
                break;
            }
            default: break;
        }
        cur += lc->cmdsize;
    }

    if (!nsegs) { P("  没有可映射的段\n"); goto out; }
    if (!have_entry) { P("  没有入口（dylib 不在此轮目标内）\n"); goto out; }
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

    if (di) {
        int nrebase = 0;
        apply_rebase(&im, &nrebase);
        if (nrebase) P("  经典 rebase: %d\n", nrebase);
        struct bindstat bs;
        if (di->bind_size) apply_bind(&im, di->bind_off, di->bind_size, "bind", &bs);
        if (di->lazy_bind_size) apply_bind(&im, di->lazy_bind_off, di->lazy_bind_size, "lazy", &bs);
        if (di->weak_bind_size) apply_bind(&im, di->weak_bind_off, di->weak_bind_size, "weak", &bs);
    }

    {
        int swept = sweep_orphan_rebases(&im);
        if (swept) P("  兜底扫描共修复 %d 个孤儿指针\n", swept);
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

    {
        uint64_t entry = entry_vm + slide;
        P("  entry(file)=0x%llx entry(runtime)=0x%llx\n",
          (unsigned long long)entry_vm, (unsigned long long)entry);

        struct sigaction sa, o1, o2, o3;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = fault_handler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_NODEFER | SA_SIGINFO;
        sigaction(SIGSEGV, &sa, &o1);
        sigaction(SIGBUS, &sa, &o2);
        sigaction(SIGILL, &sa, &o3);

        g_fault_sig = 0;
        g_shim_exit = -1;
        int jmp = sigsetjmp(g_jb, 1);
        if (jmp == 0) {
            g_jb_arm = 1;
            static char arg0[64], arg1[64];
            snprintf(arg0, sizeof(arg0), "%s", "uname");
            snprintf(arg1, sizeof(arg1), "%s", "-a");
            char *argv[3] = { arg0, arg1, NULL };
            char *envp[2] = { NULL };
            int rv = ((entry3_fn_t)entry)(2, argv, envp);
            g_jb_arm = 0;
            P("  >>> 返回 %d (0x%x)\n", rv, rv);
            rc = rv;
        } else if (jmp == 2) {
            P("  >>> 执行成功：苹果二进制走完了自己的入口，调用 _exit(%d)\n", g_shim_exit);
            rc = 1000 + g_shim_exit;
        } else {
            P("  >>> 崩溃: signal %d (%s)\n", g_fault_sig, strsignal(g_fault_sig));
            P("      pc=0x%llx (镜像+0x%llx) lr=0x%llx (镜像+0x%llx) far=0x%llx\n",
              (unsigned long long)g_fault_pc,
              (unsigned long long)(g_fault_pc >= (uint64_t)img ? g_fault_pc - (uint64_t)img : 0),
              (unsigned long long)g_fault_lr,
              (unsigned long long)(g_fault_lr >= (uint64_t)img ? g_fault_lr - (uint64_t)img : 0),
              (unsigned long long)g_fault_far);
            rc = -1000 - g_fault_sig;
        }
        sigaction(SIGSEGV, &o1, NULL);
        sigaction(SIGBUS, &o2, NULL);
        sigaction(SIGILL, &o3, NULL);
    }

out:
    if (img) munmap(img, span);
    if (raw && raw != MAP_FAILED) munmap(raw, raw_sz);
    if (fd >= 0) close(fd);
    return rc;
}

__attribute__((constructor))
static void macpad_loader(void) {
    const char *report_paths[] = {
        "/var/mobile/macpad_loader.txt",
        "/tmp/macpad_loader.txt",
        "/var/tmp/macpad_loader.txt"
    };
    for (int i = 0; i < 3 && g_fd < 0; i++)
        g_fd = open(report_paths[i], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (g_fd < 0) return;

    P("MACPAD-LOADER v3\n");
    struct utsname u;
    memset(&u, 0, sizeof(u));
    if (uname(&u) == 0)
        P("host: %s %s (%s)\n  %s\n", u.sysname, u.release, u.machine, u.version);
    P("process: %s pid=%d uid=%d\n", getprogname(), getpid(), getuid());

    // 先跑自造的 demo（回归），再跑苹果真二进制
    const char *dir = "/Library/MacPadLoader/bin";
    DIR *d = opendir(dir);
    if (d) {
        struct dirent *e;
        static char paths[24][256];
        int n = 0;
        while ((e = readdir(d)) != NULL && n < 24) {
            if (e->d_name[0] == '.') continue;
            size_t len = strlen(e->d_name);
            if (len < 5 || strcmp(e->d_name + len - 4, ".bin") != 0) continue;
            snprintf(paths[n], sizeof(paths[n]), "%s/%s", dir, e->d_name);
            n++;
        }
        closedir(d);
        for (int i = 0; i < n; i++) map_and_run(paths[i]);
    } else {
        P("打不开 %s: %s\n", dir, strerror(errno));
    }

    P("\nMACPAD-LOADER-DONE\n");
    close(g_fd);
    g_fd = -1;
}
