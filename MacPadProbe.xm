// macPad Stage-0 ABI probe (Substitute-injected tweak)
// Runs inside the filtered process at load time and writes a report to disk.
// This bypasses the AMFI gate that kills standalone unsigned executables:
// Substitute injects us as a dylib and AMFI overrides library validation for
// platform processes (verified in dmesg on this device).

#import <Foundation/Foundation.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <errno.h>
#include <signal.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdlib.h>

static int g_fd = -1;

static void P(const char *fmt, ...) {
    if (g_fd < 0) return;
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0) {
        ssize_t w = write(g_fd, buf, (size_t)n);
        (void)w;
    }
}

static sigjmp_buf g_jb;
static volatile sig_atomic_t g_jb_ok = 0;

static void on_fault(int sig) {
    (void)sig;
    if (g_jb_ok) siglongjmp(g_jb, 1);
    _exit(90);
}

__attribute__((constructor))
static void macpad_probe(void) {
    const char *paths[] = {
        "/var/mobile/macpad_report.txt",
        "/tmp/macpad_report.txt",
        "/var/tmp/macpad_report.txt"
    };
    for (int i = 0; i < 3 && g_fd < 0; i++) {
        g_fd = open(paths[i], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    }
    if (g_fd < 0) return;

    P("MACPAD-PROBE v1\n");

    struct utsname u;
    memset(&u, 0, sizeof(u));
    if (uname(&u) == 0) {
        P("uname: %s %s %s\n", u.sysname, u.release, u.machine);
    }

    const char *pn = getprogname();
    P("process: %s\n", pn ? pn : "?");
    P("pid=%d uid=%d euid=%d\n", getpid(), getuid(), geteuid());

#if defined(__arm64e__)
    P("dylib-slice: arm64e\n");
#else
    P("dylib-slice: arm64\n");
#endif

    /* getentropy (syscall 500): available since 10.12 / Darwin 16 */
    unsigned char eb[16];
    memset(eb, 0, sizeof(eb));
    errno = 0;
    long r = syscall(500, eb, (size_t)16);
    P("getentropy(500): ret=%ld errno=%d\n", r, errno);

    /* clonefileat (syscall 462): Darwin 19+ only; on Darwin 18 expect ENOSYS=78 */
    errno = 0;
    long r2 = syscall(462, -100, "/mp-a", -100, "/mp-b", 0);
    P("clonefileat(462): ret=%ld errno=%d (ENOSYS=78)\n", r2, errno);

    /* ulock_wake (syscall 516): Darwin 17+ */
    errno = 0;
    int dummy = 0;
    long r3 = syscall(516, (uint32_t)1, (void *)&dummy, (uint64_t)0);
    P("ulock_wake(516): ret=%ld errno=%d\n", r3, errno);

    /* terminate_with_payload (520): Darwin 19+. Do NOT call: it would kill us. */
    P("terminate_with_payload(520): skipped (kills process)\n");

    /* commpage read, guarded */
    struct sigaction sa, old1, old2;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_fault;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &old1);
    sigaction(SIGBUS, &sa, &old2);

    if (sigsetjmp(g_jb, 1) == 0) {
        g_jb_ok = 1;
        volatile uint64_t *cp = (volatile uint64_t *)(uintptr_t)0x0000000FFFFFC000ULL;
        uint64_t a = cp[0];
        uint64_t b = cp[1];
        P("commpage[0]=0x%016llx\n", (unsigned long long)a);
        P("commpage[1]=0x%016llx\n", (unsigned long long)b);
        g_jb_ok = 0;
    } else {
        P("commpage: FAULT (SIGSEGV/SIGBUS)\n");
        g_jb_ok = 0;
    }
    sigaction(SIGSEGV, &old1, NULL);
    sigaction(SIGBUS, &old2, NULL);

    P("MACPAD-PROBE-DONE\n");
    close(g_fd);
    g_fd = -1;
}
