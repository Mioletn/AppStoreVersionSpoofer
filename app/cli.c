// macpad-cli — 命令行版的 macPad 装载器
//
// 和 App 里的装载器是同一份 loader.c，区别只是：
//   * 没有 UIKit，不经过 SpringBoard，可以直接从 SSH 跑起来
//   * 直接在当前进程里装载，退出码就是苹果程序自己的退出码
//
// 用法：
//   macpad-cli ls /var/mobile
//   macpad-cli uname -a
//   macpad-cli -v ls -l /var/mobile        # -v 打印装载诊断
//   macpad-cli -f /path/to/prog.bin a b c  # -f 显式指定文件

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libgen.h>

#include "shell.h"

int macpad_run(const char *path, int argc, char **argv, char **envp, int verbose);
extern int g_no_pac;
extern int g_macpad_verbose;
void macpad_diag(void);

#define BIN_DIR "/Applications/MacPad.app/bin"

static void usage(const char *prog) {
    fprintf(stderr,
            "macpad-cli — 在当前 iOS 进程里装载并运行 macOS Mach-O\n"
            "\n"
            "用法:\n"
            "  %s [-v] [-P] <命令> [参数...]\n"
            "  %s [-v] [-P] -f <文件路径> [参数...]\n"
            "\n"
            "  -v   打印装载诊断\n"
            "  -P   保留 PAC 签名（默认已改为中和授权指令：macOS 11 是 ptrauth ABI v1，\n"
            "       本机 iOS 12 是 ABI v0，两边约定不兼容）\n"
            "  -d   指针取证（dlsym 返回值长什么样）后退出\n"
            "  -f   直接指定二进制文件（否则在 %s/<命令>.bin 里找）\n"
            "\n"
            "例:\n"
            "  %s ls /var/mobile\n"
            "  %s -v uname -a\n"
            "  %s sh                 # 进入会话（可 cd / 管道 / 重定向）\n",
            prog, prog, BIN_DIR, prog, prog, prog);
}

int main(int argc, char **argv) {
    int verbose = 0;
    int i = 1;

    while (i < argc && argv[i][0] == '-' && argv[i][1] != '\0') {
        if (strcmp(argv[i], "-v") == 0) { verbose = 1; i++; }
        else if (strcmp(argv[i], "-P") == 0) { g_no_pac = 0; i++; }
        else if (strcmp(argv[i], "-d") == 0) { g_macpad_verbose = 1; macpad_diag(); return 0; }
        else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage(argv[0]); return 0;
        }
        else break;
    }
    if (i >= argc) { usage(argv[0]); return 2; }

    // 进会话：macpadcli sh
    // 这是"进入 macOS"的入口——之后每条命令都由进程内装载器跑真正的
    // macOS 二进制，argv/envp/cwd/fd 全部按 POSIX 语义转交。
    if (strcmp(argv[i], "sh") == 0 || strcmp(argv[i], "shell") == 0) {
        mpshell_set_bindir(BIN_DIR);
        return mpshell_run(verbose) & 0xFF;
    }

    char path[1024];
    int prog_arg_index;

    if (strcmp(argv[i], "-f") == 0) {
        i++;
        if (i >= argc) { usage(argv[0]); return 2; }
        snprintf(path, sizeof(path), "%s", argv[i]);
        prog_arg_index = i;          // argv[i] 就是程序路径，直接当 argv[0]
    } else {
        const char *cmd = argv[i];
        // 允许直接给路径
        if (strchr(cmd, '/')) {
            snprintf(path, sizeof(path), "%s", cmd);
        } else {
            snprintf(path, sizeof(path), "%s/%s.bin", BIN_DIR, cmd);
        }
        prog_arg_index = i;
    }

    if (access(path, R_OK) != 0) {
        fprintf(stderr, "macpad-cli: 找不到 %s\n", path);
        fprintf(stderr, "提示：内嵌程序在 %s/ 下，文件名形如 ls.bin\n", BIN_DIR);
        return 2;
    }

    // 交给苹果程序的 argv：用命令名（不含 .bin）当 argv[0]，其余原样透传
    int sub_argc = argc - prog_arg_index;
    char **sub_argv = (char **)calloc((size_t)sub_argc + 1, sizeof(char *));
    if (!sub_argv) return 2;
    for (int k = 0; k < sub_argc; k++) {
        sub_argv[k] = argv[prog_arg_index + k];
    }
    sub_argv[sub_argc] = NULL;

    // argv[0] 换成干净的命令名：很多程序会拿它当 getprogname() 用
    {
        static char namebuf[128];
        const char *base = strrchr(path, '/');
        base = base ? base + 1 : path;
        snprintf(namebuf, sizeof(namebuf), "%s", base);
        char *dot = strrchr(namebuf, '.');
        if (dot && strcmp(dot, ".bin") == 0) *dot = '\0';
        sub_argv[0] = namebuf;
    }

    char *envp[] = {
        (char *)"PATH=/usr/bin:/bin:/usr/sbin:/sbin",
        (char *)"HOME=/var/mobile",
        (char *)"TERM=xterm-256color",
        (char *)"LANG=en_US.UTF-8",
        NULL
    };

    fflush(NULL);
    int rc = macpad_run(path, sub_argc, sub_argv, envp, verbose);

    // 苹果程序通常自己 _exit 了，走不到这里；能到这里说明是正常 return
    fflush(NULL);
    free(sub_argv);
    return rc < 0 ? 1 : (rc & 0xFF);
}
