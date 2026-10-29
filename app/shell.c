// app/shell.c — macPad 的会话壳（进程内 shell）
//
// macPad 原项目的"进入 macOS"是 chroot 到 /var/mnt/rootfs 再拉 launchd。
// 那条路需要完整的 macOS 根文件系统 + iPadOS 16 + Dopamine，本机（iOS 12.2、
// 没有 rootfs）走不了。这里搭的是它的**上层等价物**：
//
//   一个常驻的会话壳，每条命令都交给进程内装载器去跑真正的 macOS 二进制。
//   macOS 侧看到的 argv/envp/cwd/fd 全部由我们转交，所以 `ls` 就是苹果的 ls，
//   `sw_vers` 就会报 macOS 11.2 —— 只是没有 chroot，文件路径还是 iOS 的。
//
// 支持的语法（够日常用）：
//   cmd a b c          顺序执行
//   a ; b              顺序
//   a && b / a || b    短路
//   a | b | c          管道（用临时文件串，不占用线程）
//   > >> < 2>          重定向
//   $VAR ${VAR} $?     变量展开
//   '...'  "..."  \x   引用与转义
//
// 内置命令：cd pwd exit export unset set env help clear neofetch
// 其余全部落到 <bindir>/<cmd>.bin。

#include "shell.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int macpad_run(const char *path, int argc, char **argv, char **envp, int verbose);

// ---------------------------------------------------------------- 环境

#define ENV_MAX 64

static char  g_bindir[512] = "/Applications/MacPad.app/bin";
static char *g_env[ENV_MAX];
static int   g_env_n;
static int   g_last_rc;
static int   g_verbose;
static int   g_should_exit;
static int   g_exit_code;

static void env_init(void) {
    if (g_env_n) return;
    char buf[600];
    snprintf(buf, sizeof(buf), "PATH=%s", g_bindir);
    g_env[g_env_n++] = strdup(buf);
    g_env[g_env_n++] = strdup("HOME=/var/mobile");
    g_env[g_env_n++] = strdup("USER=root");
    g_env[g_env_n++] = strdup("LOGNAME=root");
    g_env[g_env_n++] = strdup("SHELL=/bin/sh");
    g_env[g_env_n++] = strdup("TERM=xterm-256color");
    g_env[g_env_n++] = strdup("LANG=en_US.UTF-8");
    g_env[g_env_n++] = strdup("PAGER=cat");
    g_env[g_env_n] = NULL;
}

static const char *env_get(const char *key) {
    size_t kl = strlen(key);
    for (int i = 0; i < g_env_n; i++) {
        if (strncmp(g_env[i], key, kl) == 0 && g_env[i][kl] == '=') return g_env[i] + kl + 1;
    }
    return NULL;
}

static void env_set(const char *kv) {
    const char *eq = strchr(kv, '=');
    if (!eq) return;
    size_t kl = (size_t)(eq - kv);
    for (int i = 0; i < g_env_n; i++) {
        if (strncmp(g_env[i], kv, kl) == 0 && g_env[i][kl] == '=') {
            free(g_env[i]);
            g_env[i] = strdup(kv);
            return;
        }
    }
    if (g_env_n < ENV_MAX - 2) {
        g_env[g_env_n++] = strdup(kv);
        g_env[g_env_n] = NULL;
    }
}

static void env_unset(const char *key) {
    size_t kl = strlen(key);
    for (int i = 0; i < g_env_n; i++) {
        if (strncmp(g_env[i], key, kl) == 0 && g_env[i][kl] == '=') {
            free(g_env[i]);
            memmove(&g_env[i], &g_env[i + 1], (size_t)(g_env_n - i) * sizeof(char *));
            g_env_n--;
            return;
        }
    }
}

// 交给苹果程序的 envp：在原环境上补一条 PWD
static char **env_build(char **store, int store_max) {
    int n = 0;
    char cwd[512];
    if (!getcwd(cwd, sizeof(cwd))) strcpy(cwd, "/");
    for (int i = 0; i < g_env_n && n < store_max - 3; i++) {
        if (strncmp(g_env[i], "PWD=", 4) == 0) continue;
        store[n++] = g_env[i];
    }
    static char pwdkv[600];
    snprintf(pwdkv, sizeof(pwdkv), "PWD=%s", cwd);
    store[n++] = pwdkv;
    store[n] = NULL;
    return store;
}

// ---------------------------------------------------------------- 词法

enum { T_WORD = 0, T_PIPE, T_SEMI, T_AND, T_OR, T_OUT, T_OUTA, T_IN, T_ERR, T_BG };

typedef struct { int kind; char *text; } token_t;

#define TOK_MAX 256

static void tok_free(token_t *t, int n) {
    for (int i = 0; i < n; i++) free(t[i].text);
}

// 变量展开：把 $NAME / ${NAME} / $? 写进 dst
static void expand_var(const char **pp, char *dst, size_t cap) {
    const char *p = *pp;
    char name[128];
    size_t nl = 0;
    if (*p == '{') {
        p++;
        while (*p && *p != '}' && nl < sizeof(name) - 1) name[nl++] = *p++;
        if (*p == '}') p++;
    } else if (*p == '?') {
        p++;
        name[nl++] = '?';
        name[nl] = '\0';
    } else {
        while ((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
               (*p >= '0' && *p <= '9') || *p == '_') {
            if (nl < sizeof(name) - 1) name[nl++] = *p;
            p++;
        }
    }
    name[nl] = '\0';
    const char *val = NULL;
    if (nl == 1 && name[0] == '?') {
        static char rcbuf[24];
        snprintf(rcbuf, sizeof(rcbuf), "%d", g_last_rc);
        val = rcbuf;
    } else if (nl) {
        val = env_get(name);
    }
    if (val) {
        size_t vl = strlen(val);
        size_t dl = strlen(dst);
        if (dl + vl < cap) memcpy(dst + dl, val, vl + 1);
    }
    *pp = p;
}

static int is_op_char(char c) {
    return c == '|' || c == ';' || c == '&' || c == '>' || c == '<';
}

// 返回 token 数；-1 表示语法错（引号没闭合）
static int tokenize(char *s, token_t *out, int max) {
    int n = 0;
    char w[1024];
    size_t wl = 0;
    int in_word = 0;

    while (*s) {
        while (*s == ' ' || *s == '\t') s++;
        if (!*s) break;
        if (*s == '#' && !in_word) break;              // 注释

        if (!in_word && *s == '2' && s[1] == '>') {     // 2>
            if (n < max) { out[n].kind = T_ERR; out[n].text = NULL; n++; }
            s += 2;
            continue;
        }
        if (is_op_char(*s)) {
            int kind;
            if (*s == '|' && s[1] == '|') { kind = T_OR; s += 2; }
            else if (*s == '&' && s[1] == '&') { kind = T_AND; s += 2; }
            else if (*s == '|') { kind = T_PIPE; s += 1; }
            else if (*s == ';') { kind = T_SEMI; s += 1; }
            else if (*s == '&') { kind = T_BG; s += 1; }
            else if (*s == '>' && s[1] == '>') { kind = T_OUTA; s += 2; }
            else if (*s == '>') { kind = T_OUT; s += 1; }
            else { kind = T_IN; s += 1; }
            if (n < max) { out[n].kind = kind; out[n].text = NULL; n++; }
            in_word = 0;
            continue;
        }

        // 普通字符：累积成词
        in_word = 1;
        wl = 0;
        w[0] = '\0';
        while (*s && *s != ' ' && *s != '\t' && !is_op_char(*s) &&
               !(*s == '2' && s[1] == '>')) {
            if (*s == '\'') {                            // 单引号：原样
                s++;
                while (*s && *s != '\'') {
                    if (wl + 1 < sizeof(w)) w[wl++] = *s;
                    s++;
                }
                if (*s == '\'') s++;
                else { tok_free(out, n); return -1; }
            } else if (*s == '"') {                      // 双引号：允许 $var 与 \"
                s++;
                while (*s && *s != '"') {
                    if (*s == '\\' && (s[1] == '"' || s[1] == '\\' || s[1] == '$')) {
                        s++;
                        if (wl + 1 < sizeof(w)) w[wl++] = *s;
                        s++;
                    } else if (*s == '$') {
                        w[wl] = '\0';
                        const char *pv = s;
                        expand_var(&pv, w, sizeof(w));
                        wl = strlen(w);
                        s = (char *)pv;
                    } else {
                        if (wl + 1 < sizeof(w)) w[wl++] = *s;
                        s++;
                    }
                }
                if (*s == '"') s++;
                else { tok_free(out, n); return -1; }
            } else if (*s == '\\') {                     // 转义
                s++;
                if (*s) {
                    if (wl + 1 < sizeof(w)) w[wl++] = *s;
                    s++;
                }
            } else if (*s == '$') {                      // 变量
                w[wl] = '\0';
                const char *pv = s;
                expand_var(&pv, w, sizeof(w));
                wl = strlen(w);
                s = (char *)pv;
            } else {
                if (wl + 1 < sizeof(w)) w[wl++] = *s;
                s++;
            }
        }
        w[wl] = '\0';
        if (n < max) { out[n].kind = T_WORD; out[n].text = strdup(w); n++; }
        in_word = 0;
    }
    return n;
}

// ---------------------------------------------------------------- 执行

typedef struct {
    char *argv[64];
    int   argc;
    char *in;
    char *out;
    int   append;
    char *err;
} stage_t;

static void stage_reset(stage_t *st) {
    memset(st, 0, sizeof(*st));
}

static int open_out(const char *path, int append) {
    int flags = O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC);
    return open(path, flags, 0644);
}

static const char *base_name(const char *p) {
    const char *b = strrchr(p, '/');
    return b ? b + 1 : p;
}

// 找可执行：带 / 就直用，否则按 PATH 里找 <dir>/<cmd>.bin 或 <dir>/<cmd>
static int resolve_cmd(const char *cmd, char *out, size_t cap) {
    if (strchr(cmd, '/')) {
        snprintf(out, cap, "%s", cmd);
        return access(out, R_OK) == 0;
    }
    const char *path = env_get("PATH");
    char dirs[1024];
    snprintf(dirs, sizeof(dirs), "%s", path ? path : g_bindir);
    char *save = NULL;
    for (char *d = strtok_r(dirs, ":", &save); d; d = strtok_r(NULL, ":", &save)) {
        snprintf(out, cap, "%s/%s.bin", d, cmd);
        if (access(out, R_OK) == 0) return 1;
        snprintf(out, cap, "%s/%s", d, cmd);
        if (access(out, R_OK) == 0) return 1;
    }
    return 0;
}

// 把 argv[0] 换成干净命令名（很多程序拿它当 getprogname）
static const char *clean_name(const char *path, char *buf, size_t cap) {
    const char *b = base_name(path);
    snprintf(buf, cap, "%s", b);
    size_t l = strlen(buf);
    if (l > 4 && strcmp(buf + l - 4, ".bin") == 0) buf[l - 4] = '\0';
    return buf;
}

static int run_bin(const char *path, int argc, char **argv) {
    char nb[128];
    const char *nm = clean_name(path, nb, sizeof(nb));
    char **av = (char **)calloc((size_t)argc + 2, sizeof(char *));
    if (!av) return 1;
    av[0] = (char *)nm;
    for (int i = 1; i < argc; i++) av[i] = argv[i];
    av[argc] = NULL;

    char *store[ENV_MAX + 4];
    char **envp = env_build(store, ENV_MAX + 4);

    fflush(NULL);
    int rc = macpad_run(path, argc, av, envp, g_verbose);
    fflush(NULL);
    free(av);
    return rc < 0 ? 127 : (rc & 0xFF);
}

// ---- 内置命令 ----

static int cd_builtin(int argc, char **argv) {
    const char *tgt = argc > 1 ? argv[1] : env_get("HOME");
    if (!tgt || !*tgt) tgt = "/";
    char buf[1024];
    if (strcmp(tgt, "-") == 0) {
        const char *old = env_get("OLDPWD");
        if (!old) { fprintf(stderr, "cd: OLDPWD 未设置\n"); return 1; }
        tgt = old;
    }
    if (tgt[0] == '~') {                       // 只支持 ~ 与 ~/
        const char *home = env_get("HOME");
        snprintf(buf, sizeof(buf), "%s%s", home ? home : "/", tgt[1] == '/' ? tgt + 1 : "");
        tgt = buf;
    }
    char old[512];
    if (!getcwd(old, sizeof(old))) strcpy(old, "/");
    if (chdir(tgt) != 0) {
        fprintf(stderr, "cd: %s: %s\n", tgt, strerror(errno));
        return 1;
    }
    char kv[600];
    snprintf(kv, sizeof(kv), "OLDPWD=%s", old);
    env_set(kv);
    char now[512];
    if (getcwd(now, sizeof(now))) {
        snprintf(kv, sizeof(kv), "PWD=%s", now);
        env_set(kv);
    }
    return 0;
}

static int help_builtin(void) {
    printf("内置: cd pwd exit export unset set env help clear neofetch\n");
    printf("外部程序（真正的 macOS 二进制）:\n  ");
    DIR *d = opendir(g_bindir);
    int col = 0;
    if (d) {
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
            size_t l = strlen(e->d_name);
            if (l <= 4 || strcmp(e->d_name + l - 4, ".bin") != 0) continue;
            printf("%.*s  ", (int)(l - 4), e->d_name);
            if (++col % 6 == 0) printf("\n  ");
        }
        closedir(d);
    }
    printf("\n");
    return 0;
}

static int neofetch_builtin(void) {
    char host[128] = "iPad";
    FILE *f = fopen("/var/mobile/.macpad_host", "r");
    if (f) { if (fgets(host, sizeof(host), f)) { char *nl = strchr(host, '\n'); if (nl) *nl = 0; } fclose(f); }
    char kb[32] = "11.2.3";
    f = fopen("/var/mobile/.macpad_macos", "r");
    if (f) { if (fgets(kb, sizeof(kb), f)) { char *nl = strchr(kb, '\n'); if (nl) *nl = 0; } fclose(f); }

    printf("       .:'          %s@%s\n", env_get("USER") ? env_get("USER") : "root", host);
    printf("    __ :'__          ------------------\n");
    printf(" .'`  `-'  ``.       OS: macOS %s (userspace, in-process)\n", kb);
    printf(":          .-'       Host: iPad (iOS 12.2, Darwin 18.5.0)\n");
    printf(":         :          Kernel: xnu-4903.252.2 (iOS)\n");
    printf(" :         `-;       Shell: macpad-sh\n");
    printf("  `.__.-.__.'        Terminal: macPad\n");
    printf("                     Note: 无 chroot，文件系统仍是 iOS 的\n");
    return 0;
}

static int is_builtin(const char *c) {
    static const char *b[] = { "cd", "pwd", "exit", "export", "unset", "set", "env",
                               "help", "clear", "neofetch", NULL };
    for (int i = 0; b[i]; i++) if (strcmp(c, b[i]) == 0) return 1;
    return 0;
}

static int run_builtin(int argc, char **argv) {
    const char *c = argv[0];
    if (strcmp(c, "cd") == 0) return cd_builtin(argc, argv);
    if (strcmp(c, "pwd") == 0) { char b[512]; printf("%s\n", getcwd(b, sizeof(b)) ? b : "?"); return 0; }
    if (strcmp(c, "exit") == 0) {
        g_should_exit = 1;
        g_exit_code = argc > 1 ? atoi(argv[1]) : 0;
        return g_exit_code;
    }
    if (strcmp(c, "export") == 0) {
        for (int i = 1; i < argc; i++) {
            if (strchr(argv[i], '=')) env_set(argv[i]);
            else { const char *v = env_get(argv[i]); if (v) { char kv[600]; snprintf(kv, sizeof(kv), "%s=%s", argv[i], v); env_set(kv); } }
        }
        return 0;
    }
    if (strcmp(c, "unset") == 0) { for (int i = 1; i < argc; i++) env_unset(argv[i]); return 0; }
    if (strcmp(c, "set") == 0 || strcmp(c, "env") == 0) {
        for (int i = 0; i < g_env_n; i++) printf("%s\n", g_env[i]);
        return 0;
    }
    if (strcmp(c, "help") == 0) return help_builtin();
    if (strcmp(c, "clear") == 0) { printf("\033[H\033[2J"); return 0; }
    if (strcmp(c, "neofetch") == 0) return neofetch_builtin();
    return 127;
}

// 跑一个 stage：重定向 → 内置或装载
static int run_stage(stage_t *st, int in_fd, int out_fd, int err_fd, int is_last) {
    (void)is_last;
    if (st->argc == 0) return 0;

    int save0 = -1, save1 = -1, save2 = -1;

    int want_in = st->in ? open(st->in, O_RDONLY) : in_fd;
    if (st->in && want_in < 0) { fprintf(stderr, "macpad: %s: %s\n", st->in, strerror(errno)); return 1; }
    int want_out = st->out ? open_out(st->out, st->append) : out_fd;
    if (st->out && want_out < 0) { fprintf(stderr, "macpad: %s: %s\n", st->out, strerror(errno)); return 1; }
    int want_err = st->err ? open_out(st->err, 0) : err_fd;

    fflush(NULL);
    if (want_in >= 0) { save0 = dup(0); dup2(want_in, 0); }
    if (want_out >= 0) { save1 = dup(1); dup2(want_out, 1); }
    if (want_err >= 0) { save2 = dup(2); dup2(want_err, 2); }

    int rc;
    if (is_builtin(st->argv[0])) {
        rc = run_builtin(st->argc, st->argv);
    } else {
        char path[1024];
        if (!resolve_cmd(st->argv[0], path, sizeof(path))) {
            fprintf(stderr, "macpad: %s: 找不到这个 macOS 程序（用 help 看有哪些）\n", st->argv[0]);
            rc = 127;
        } else {
            rc = run_bin(path, st->argc, st->argv);
        }
    }

    fflush(NULL);
    if (save2 >= 0) { dup2(save2, 2); close(save2); }
    if (save1 >= 0) { dup2(save1, 1); close(save1); }
    if (save0 >= 0) { dup2(save0, 0); close(save0); }
    if (st->in && want_in >= 0) close(want_in);
    if (st->out && want_out >= 0) close(want_out);
    if (st->err && want_err >= 0) close(want_err);
    return rc;
}

static char g_tmpname[8][64];
static int  g_ntmp;

static int make_tmp(void) {
    const char *base = getenv("TMPDIR");
    if (!base) base = "/tmp";
    snprintf(g_tmpname[g_ntmp], sizeof(g_tmpname[0]), "%s/.mpsh_%d_%d", base, (int)getpid(), g_ntmp);
    int fd = open(g_tmpname[g_ntmp], O_RDWR | O_CREAT | O_TRUNC, 0600);
    g_ntmp++;
    return fd;
}

static void drop_tmp(void) {
    for (int i = 0; i < g_ntmp; i++) { unlink(g_tmpname[i]); }
    g_ntmp = 0;
}

// 执行一条管道
static int run_pipeline(stage_t *st, int n) {
    int rc = 0;
    int in_fd = -1;
    g_ntmp = 0;
    for (int i = 0; i < n; i++) {
        int out_fd = -1;
        int tmp = -1;
        if (i < n - 1) {
            if (g_ntmp >= 8) break;
            tmp = make_tmp();
            out_fd = tmp;
        }
        rc = run_stage(&st[i], in_fd, out_fd, -1, i == n - 1);
        if (tmp >= 0) {
            lseek(tmp, 0, SEEK_SET);
            if (in_fd >= 0) close(in_fd);
            in_fd = tmp;
        }
        if (g_should_exit) break;
    }
    if (in_fd >= 0) close(in_fd);
    drop_tmp();
    return rc;
}

// ---------------------------------------------------------------- 对外

void mpshell_set_bindir(const char *dir) {
    if (!dir || !*dir) return;
    snprintf(g_bindir, sizeof(g_bindir), "%s", dir);
    env_init();
    char kv[600];
    snprintf(kv, sizeof(kv), "PATH=%s", g_bindir);
    env_set(kv);
}

// 执行一行；返回最后一条命令的退出码
int mpshell_exec_line(const char *line, int verbose) {
    if (!g_env_n) env_init();
    g_verbose = verbose;
    g_should_exit = 0;

    char buf[4096];
    snprintf(buf, sizeof(buf), "%s", line);

    token_t tok[TOK_MAX];
    int n = tokenize(buf, tok, TOK_MAX);
    if (n < 0) {
        fprintf(stderr, "macpad: 引号没闭合\n");
        g_last_rc = 2;
        return 2;
    }

    stage_t st[8];
    int nst = 0;
    stage_reset(&st[0]);
    nst = 1;

    int i = 0;
    int rc = 0;
    int skip_next = 0;          // && / || 短路

    while (i < n) {
        token_t *t = &tok[i];
        if (t->kind == T_WORD) {
            if (st[nst - 1].argc < 62) st[nst - 1].argv[st[nst - 1].argc++] = t->text;
            i++;
            continue;
        }
        if (t->kind == T_PIPE) {
            if (nst < 8) { stage_reset(&st[nst]); nst++; }
            i++;
            continue;
        }
        if (t->kind == T_IN || t->kind == T_OUT || t->kind == T_OUTA || t->kind == T_ERR) {
            if (i + 1 < n && tok[i + 1].kind == T_WORD) {
                stage_t *cur = &st[nst - 1];
                if (t->kind == T_IN) cur->in = tok[i + 1].text;
                else if (t->kind == T_OUT) cur->out = tok[i + 1].text;
                else if (t->kind == T_OUTA) { cur->out = tok[i + 1].text; cur->append = 1; }
                else cur->err = tok[i + 1].text;
                i += 2;
            } else { i++; }
            continue;
        }
        if (t->kind == T_BG) { i++; continue; }

        // 分隔符：先把已攒的管道跑掉
        if (!skip_next) rc = run_pipeline(st, nst);
        g_last_rc = rc;
        if (g_should_exit) return rc;

        if (t->kind == T_AND) skip_next = (rc != 0);
        else if (t->kind == T_OR) skip_next = (rc == 0);
        else skip_next = 0;

        stage_reset(&st[0]);
        nst = 1;
        i++;
    }

    if (!skip_next) rc = run_pipeline(st, nst);
    g_last_rc = rc;
    tok_free(tok, n);
    return rc;
}

static void print_prompt(void) {
    char cwd[512];
    if (!getcwd(cwd, sizeof(cwd))) strcpy(cwd, "/");
    const char *home = env_get("HOME");
    char shown[600];
    if (home && strncmp(cwd, home, strlen(home)) == 0) {
        snprintf(shown, sizeof(shown), "~%s", cwd + strlen(home));
    } else {
        snprintf(shown, sizeof(shown), "%s", cwd);
    }
    printf("root@ipad:%s# ", shown);
    fflush(stdout);
}

int mpshell_run(int verbose) {
    if (!g_env_n) env_init();
    g_verbose = verbose;

    printf("\033[1mmacPad 1.0\033[0m · macOS 11.2 userspace（进程内装载，无 chroot）\n");
    printf("可用命令用 \033[1mhelp\033[0m 看，退出用 \033[1mexit\033[0m。\n\n");

    char line[4096];
    size_t ll = 0;
    int tty = isatty(0);

    for (;;) {
        if (tty) print_prompt();
        ll = 0;
        for (;;) {
            char c;
            ssize_t r = read(0, &c, 1);
            if (r <= 0) {
                if (ll == 0) {
                    if (tty) printf("\n");
                    return g_last_rc;
                }
                break;
            }
            if (c == '\r') continue;
            if (c == '\n') break;
            if (c == 4) {                         // Ctrl-D
                if (ll == 0) { if (tty) printf("\n"); return g_last_rc; }
                continue;
            }
            if (c == 127 || c == 8) {             // 退格
                if (ll > 0) { ll--; if (tty) printf("\b \b"); }
                continue;
            }
            if (ll + 1 < sizeof(line)) line[ll++] = c;
        }
        line[ll] = '\0';
        if (!ll) continue;
        if (!tty) printf("%s\n", line);           // 非终端时回显，日志才看得懂

        mpshell_exec_line(line, verbose);
        if (g_should_exit) return g_exit_code;
    }
}
