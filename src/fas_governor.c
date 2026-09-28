// SPDX-License-Identifier: GPL-2.0-only
/*
 * UCLAMP Auto Profiler - Hardware Frame Aware Scheduling (FAS) Governor
 * Ultra-low latency user-space bridge for /dev/encore_fas on ARM64 Linux.
 */

#include <linux/types.h>
#include <linux/ioctl.h>
#include <elf.h>
#include "../include/encore_fas_uapi.h"

#define FAS_DEV_PATH "/dev/encore_fas"
#define LIBGUI_PATH "/system/lib64/libgui.so"
#define PID_FILE_PATH "/data/adb/uclamp_profiler/fas_governor.pid"
#define STATE_FILE_PATH "/data/adb/uclamp_profiler/fas_state.json"
#define UCLAMP_TOP_APP "/dev/cpuset/top-app/uclamp.min"

#define DEFAULT_FALLBACK_OFFSET 0x111e24ULL

/* Minimal direct syscall wrappers for standalone zero-dependency ARM64 binary */
static inline long sys1(long n, long a1) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a1;
    __asm__ volatile("svc #0" : "=r"(x0) : "r"(x8), "r"(x0) : "memory");
    return x0;
}

static inline long sys2(long n, long a1, long a2) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a1;
    register long x1 __asm__("x1") = a2;
    __asm__ volatile("svc #0" : "=r"(x0) : "r"(x8), "r"(x0), "r"(x1) : "memory");
    return x0;
}

static inline long sys3(long n, long a1, long a2, long a3) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a1;
    register long x1 __asm__("x1") = a2;
    register long x2 __asm__("x2") = a3;
    __asm__ volatile("svc #0" : "=r"(x0) : "r"(x8), "r"(x0), "r"(x1), "r"(x2) : "memory");
    return x0;
}

static inline long sys4(long n, long a1, long a2, long a3, long a4) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a1;
    register long x1 __asm__("x1") = a2;
    register long x2 __asm__("x2") = a3;
    register long x3 __asm__("x3") = a4;
    __asm__ volatile("svc #0" : "=r"(x0) : "r"(x8), "r"(x0), "r"(x1), "r"(x2), "r"(x3) : "memory");
    return x0;
}

static inline long sys6(long n, long a1, long a2, long a3, long a4, long a5, long a6) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a1;
    register long x1 __asm__("x1") = a2;
    register long x2 __asm__("x2") = a3;
    register long x3 __asm__("x3") = a4;
    register long x4 __asm__("x4") = a5;
    register long x5 __asm__("x5") = a6;
    __asm__ volatile("svc #0" : "=r"(x0) : "r"(x8), "r"(x0), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory");
    return x0;
}

#define SYS_GETPID       172
#define SYS_OPENAT       56
#define SYS_CLOSE        57
#define SYS_READ         63
#define SYS_WRITE        64
#define SYS_LSEEK        62
#define SYS_IOCTL        29
#define SYS_PPOLL        73
#define SYS_KILL         129
#define SYS_RT_SIGACTION 134
#define SYS_CLOCK_GETTIME 113
#define SYS_UNLINKAT     35
#define SYS_MMAP         222
#define SYS_MUNMAP       215
#define SYS_FSTAT        80
#define SYS_EXIT         93
#define SYS_NANOSLEEP    101

#define O_RDONLY    00
#define O_WRONLY    01
#define O_RDWR      02
#define O_CREAT   0100
#define O_TRUNC  01000
#define O_NONBLOCK 04000
#define AT_FDCWD  -100

#define PROT_READ   0x1
#define MAP_PRIVATE 0x02
#define MAP_FAILED  ((void *)-1)

#define POLLIN      0x0001
#define POLLPRI     0x0002
#define POLLERR     0x0008
#define POLLHUP     0x0010

struct timespec {
    long tv_sec;
    long tv_nsec;
};

struct pollfd {
    int fd;
    short events;
    short revents;
};

struct kernel_sigaction {
    void (*sa_handler)(int);
    unsigned long sa_flags;
    void (*sa_restorer)(void);
    unsigned long sa_mask;
};

/* Standard memory & string primitives */
void *memset(void *s, int c, unsigned long n) {
    unsigned char *p = s;
    while (n--) *p++ = (unsigned char)c;
    return s;
}

void *memcpy(void *dst, const void *src, unsigned long n) {
    char *d = dst;
    const char *s = src;
    while (n--) *d++ = *s++;
    return dst;
}

int memcmp(const void *s1, const void *s2, unsigned long n) {
    const unsigned char *p1 = s1, *p2 = s2;
    while (n--) {
        if (*p1 != *p2) return *p1 - *p2;
        p1++; p2++;
    }
    return 0;
}

unsigned long strlen(const char *s) {
    unsigned long len = 0;
    while (s[len]) len++;
    return len;
}

static int str_len(const char *s) {
    return (int)strlen(s);
}

static void print_out(const char *s) {
    sys3(SYS_WRITE, 1, (long)s, str_len(s));
}

static void str_copy(char *dst, const char *src) {
    while (*src) *dst++ = *src++;
    *dst = '\0';
}

static int str_equal(const char *a, const char *b) {
    while (*a && *b) {
        if (*a != *b) return 0;
        a++; b++;
    }
    return (*a == *b);
}

static int str_starts_with(const char *str, const char *prefix) {
    while (*prefix) {
        if (*str != *prefix) return 0;
        str++; prefix++;
    }
    return 1;
}

static long parse_long(const char *s) {
    long val = 0;
    while (*s >= '0' && *s <= '9') {
        val = val * 10 + (*s - '0');
        s++;
    }
    return val;
}

static int int_to_str(long val, char *buf) {
    char tmp[32];
    int ti = 0, bi = 0;
    if (val == 0) {
        buf[0] = '0'; buf[1] = '\0';
        return 1;
    }
    if (val < 0) {
        buf[bi++] = '-';
        val = -val;
    }
    while (val > 0) {
        tmp[ti++] = '0' + (val % 10);
        val /= 10;
    }
    while (ti > 0) {
        buf[bi++] = tmp[--ti];
    }
    buf[bi] = '\0';
    return bi;
}

static long get_time_ms(void) {
    struct timespec ts;
    sys2(SYS_CLOCK_GETTIME, 1 /* CLOCK_MONOTONIC */, (long)&ts);
    return ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void sleep_ms(long ms) {
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (ms % 1000) * 1000000;
    sys2(SYS_NANOSLEEP, (long)&ts, 0);
}

/* ELF Symbol Offset Resolver */
static const char *const kCandidateSymbols[] = {
    "_ZN7android7Surface16hook_queueBufferEP13ANativeWindowP19ANativeWindowBufferi",
    "_ZN7android7Surface11queueBufferERKNS_2spINS_13GraphicBufferEEERKNS1_INS_5FenceEEEPNS_24SurfaceQueueBufferOutputE",
    "_ZN7android7Surface11queueBufferEP19ANativeWindowBufferi",
    "_ZN7android7Surface11queueBufferEP19ANativeWindowBufferiPNS_24SurfaceQueueBufferOutputE",
};

static __u64 resolve_libgui_offset(const char *lib_path) {
    long fd = sys4(SYS_OPENAT, AT_FDCWD, (long)lib_path, O_RDONLY, 0);
    if (fd < 0) return DEFAULT_FALLBACK_OFFSET;

    // Direct lseek to get file size
    long size = sys3(SYS_LSEEK, fd, 0, 2 /* SEEK_END */);
    sys3(SYS_LSEEK, fd, 0, 0 /* SEEK_SET */);
    if (size < (long)sizeof(Elf64_Ehdr)) {
        sys1(SYS_CLOSE, fd);
        return DEFAULT_FALLBACK_OFFSET;
    }

    void *base = (void *)sys6(SYS_MMAP, 0, size, PROT_READ, MAP_PRIVATE, fd, 0);
    sys1(SYS_CLOSE, fd);
    if (base == MAP_FAILED) return DEFAULT_FALLBACK_OFFSET;

    const Elf64_Ehdr *eh = (const Elf64_Ehdr *)base;
    if (eh->e_ident[0] != 0x7f || eh->e_ident[1] != 'E' || eh->e_ident[2] != 'L' || eh->e_ident[3] != 'F') {
        sys2(SYS_MUNMAP, (long)base, size);
        return DEFAULT_FALLBACK_OFFSET;
    }

    const Elf64_Shdr *sh = (const Elf64_Shdr *)((const char *)base + eh->e_shoff);
    const Elf64_Phdr *ph = (const Elf64_Phdr *)((const char *)base + eh->e_phoff);

    __u64 target_vaddr = 0;

    // Search symbol tables
    for (int i = 0; i < eh->e_shnum; i++) {
        if (sh[i].sh_type == SHT_DYNSYM || sh[i].sh_type == SHT_SYMTAB) {
            const Elf64_Shdr *symtab = &sh[i];
            const Elf64_Shdr *strtab = &sh[symtab->sh_link];
            const Elf64_Sym *syms = (const Elf64_Sym *)((const char *)base + symtab->sh_offset);
            const char *strs = (const char *)base + strtab->sh_offset;
            int nsyms = symtab->sh_size / sizeof(Elf64_Sym);

            for (int s = 0; s < 4; s++) {
                const char *cand = kCandidateSymbols[s];
                for (int j = 0; j < nsyms; j++) {
                    if (ELF64_ST_TYPE(syms[j].st_info) == STT_FUNC && syms[j].st_value != 0) {
                        const char *name = strs + syms[j].st_name;
                        if (str_equal(name, cand)) {
                            target_vaddr = syms[j].st_value;
                            break;
                        }
                    }
                }
                if (target_vaddr != 0) break;
            }
        }
        if (target_vaddr != 0) break;
    }

    __u64 final_offset = DEFAULT_FALLBACK_OFFSET;
    if (target_vaddr != 0) {
        // Map Virtual Address to File Offset using PT_LOAD headers
        for (int p = 0; p < eh->e_phnum; p++) {
            if (ph[p].p_type == PT_LOAD) {
                if (target_vaddr >= ph[p].p_vaddr && target_vaddr < ph[p].p_vaddr + ph[p].p_filesz) {
                    final_offset = ph[p].p_offset + (target_vaddr - ph[p].p_vaddr);
                    break;
                }
            }
        }
    }

    sys2(SYS_MUNMAP, (long)base, size);
    return final_offset;
}

/* Global state */
static volatile int g_running = 1;
static int g_fas_fd = -1;
static int g_uclamp_fd = -1;
static int g_ctx_id = -1;

static void sig_handler(int sig) {
    (void)sig;
    g_running = 0;
}

static void set_uclamp(int val) {
    if (g_uclamp_fd < 0) return;
    char buf[16];
    int len = int_to_str(val, buf);
    sys3(SYS_LSEEK, g_uclamp_fd, 0, 0);
    sys3(SYS_WRITE, g_uclamp_fd, (long)buf, len);
}

static void update_state_file(int active, int pid, const char *pkg, int target_fps,
                              const char *event_name, int uclamp_val, int janks) {
    long fd = sys4(SYS_OPENAT, AT_FDCWD, (long)STATE_FILE_PATH, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;

    char buf[512];
    char tmp[32];
    buf[0] = '\0';

    #define APPEND(s) { const char *_p = (s); while (*_p) { buf[bi++] = *_p++; } }
    int bi = 0;
    APPEND("{\n  \"active\": ");
    APPEND(active ? "true" : "false");
    APPEND(",\n  \"pid\": ");
    int_to_str(pid, tmp); APPEND(tmp);
    APPEND(",\n  \"pkg\": \""); APPEND(pkg); APPEND("\"");
    APPEND(",\n  \"target_fps\": ");
    int_to_str(target_fps, tmp); APPEND(tmp);
    APPEND(",\n  \"last_event\": \""); APPEND(event_name); APPEND("\"");
    APPEND(",\n  \"uclamp_boost\": ");
    int_to_str(uclamp_val, tmp); APPEND(tmp);
    APPEND(",\n  \"jank_count\": ");
    int_to_str(janks, tmp); APPEND(tmp);
    APPEND("\n}\n");
    buf[bi] = '\0';

    sys3(SYS_WRITE, fd, (long)buf, bi);
    sys1(SYS_CLOSE, fd);
}

static void cmd_stop(void) {
    long fd = sys4(SYS_OPENAT, AT_FDCWD, (long)PID_FILE_PATH, O_RDONLY, 0);
    if (fd >= 0) {
        char buf[32];
        long n = sys3(SYS_READ, fd, (long)buf, 31);
        sys1(SYS_CLOSE, fd);
        if (n > 0) {
            buf[n] = '\0';
            long pid = parse_long(buf);
            if (pid > 0) {
                sys2(SYS_KILL, pid, 15 /* SIGTERM */);
                sleep_ms(100);
            }
        }
    }
    sys2(SYS_UNLINKAT, AT_FDCWD, (long)PID_FILE_PATH);
    update_state_file(0, 0, "", 0, "STOPPED", 0, 0);
    print_out("[✓] FAS Governor stopped\n");
}

static int cmd_start(int target_pid, int target_fps, const char *pkg_name) {
    // 1. Check & stop any previous governor instance
    cmd_stop();

    // 2. Open /dev/encore_fas
    g_fas_fd = sys4(SYS_OPENAT, AT_FDCWD, (long)FAS_DEV_PATH, O_RDWR | O_NONBLOCK, 0);
    if (g_fas_fd < 0) {
        print_out("[-] Error: Cannot open /dev/encore_fas\n");
        return 1;
    }

    // 3. Resolve Surface::queueBuffer offset in libgui.so
    __u64 offset = resolve_libgui_offset(LIBGUI_PATH);

    // 4. Register listener with kernel
    struct fas_register_args reg;
    char *p = (char *)&reg;
    for (int i = 0; i < sizeof(reg); i++) p[i] = 0;

    reg.pid = target_pid;
    reg.offset = offset;
    str_copy(reg.path, LIBGUI_PATH);
    if (target_fps == 30) {
        reg.cfg.count = 1;
        reg.cfg.fps[0] = 30;
        reg.cfg.vsync_ns = 1000000000U / 30;
    } else if (target_fps == 60) {
        reg.cfg.count = 1;
        reg.cfg.fps[0] = 60;
        reg.cfg.vsync_ns = 1000000000U / 60;
    } else {
        // Auto multi-rate mode: kernel tracks both 60 FPS and 30 FPS cadences automatically!
        reg.cfg.count = 2;
        reg.cfg.fps[0] = 60;
        reg.cfg.fps[1] = 30;
        reg.cfg.vsync_ns = 1000000000U / 60;
    }

    long ret = sys3(SYS_IOCTL, g_fas_fd, FAS_IOC_REGISTER, (long)&reg);
    if (ret != 0) {
        print_out("[-] Error: FAS_IOC_REGISTER failed (kernel returned error)\n");
        sys1(SYS_CLOSE, g_fas_fd);
        return 2;
    }
    g_ctx_id = reg.ctx_id;

    // 5. Open UCLAMP top-app node
    g_uclamp_fd = sys4(SYS_OPENAT, AT_FDCWD, (long)UCLAMP_TOP_APP, O_WRONLY, 0);

    // 6. Save PID file
    long pid_fd = sys4(SYS_OPENAT, AT_FDCWD, (long)PID_FILE_PATH, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (pid_fd >= 0) {
        char pbuf[32];
        int mypid = sys1(SYS_GETPID, 0);
        int plen = int_to_str(mypid, pbuf);
        sys3(SYS_WRITE, pid_fd, (long)pbuf, plen);
        sys1(SYS_CLOSE, pid_fd);
    }

    // 7. Setup signal handling
    struct kernel_sigaction sa;
    sa.sa_handler = sig_handler;
    sa.sa_flags = 0;
    sa.sa_restorer = 0;
    sa.sa_mask = 0;
    sys4(SYS_RT_SIGACTION, 15 /* SIGTERM */, (long)&sa, 0, 8);
    sys4(SYS_RT_SIGACTION, 2 /* SIGINT */, (long)&sa, 0, 8);
    sys4(SYS_RT_SIGACTION, 1 /* SIGHUP */, (long)&sa, 0, 8);

    print_out("[✓] FAS Governor attached to PID ");
    char num_buf[32];
    int_to_str(target_pid, num_buf); print_out(num_buf);
    print_out(" (Target: ");
    int_to_str(reg.cfg.fps[0], num_buf); print_out(num_buf);
    if (reg.cfg.count > 1) {
        print_out("/");
        int_to_str(reg.cfg.fps[1], num_buf); print_out(num_buf);
    }
    print_out(" FPS)\n");

    // Dynamic scheduling variables
    int baseline_uclamp = 25;
    int current_uclamp = 25;
    long boost_expire_ms = 0;
    int jank_counter = 0;
    const char *last_event_str = "HEALTHY";
    int active_fps = reg.cfg.fps[0];

    // Set initial smooth baseline
    set_uclamp(baseline_uclamp);
    update_state_file(1, target_pid, pkg_name, active_fps, "ATTACHED", baseline_uclamp, 0);

    // 8. Event loop
    struct pollfd pfd;
    pfd.fd = g_fas_fd;
    pfd.events = POLLIN;

    struct fas_event events[8];
    long last_status_update = get_time_ms();

    while (g_running) {
        // Poll with 50ms timeout for responsive boost decay
        struct timespec tmo = {.tv_sec = 0, .tv_nsec = 50000000};
        int pr = sys4(SYS_PPOLL, (long)&pfd, 1, (long)&tmo, 0);

        long now = get_time_ms();

        if (pr > 0 && (pfd.revents & POLLIN)) {
            long nread = sys3(SYS_READ, g_fas_fd, (long)events, sizeof(events));
            if (nread > 0) {
                int count = nread / sizeof(struct fas_event);
                for (int i = 0; i < count; i++) {
                    struct fas_event *ev = &events[i];
                    if (ev->ctx_id != g_ctx_id) continue;

                    switch (ev->type) {
                        case FAS_EVENT_BOOST_SOFT:
                            last_event_str = "BOOST_SOFT";
                            jank_counter++;
                            current_uclamp = 60;
                            set_uclamp(current_uclamp);
                            boost_expire_ms = now + 150;
                            break;

                        case FAS_EVENT_BOOST_HARD:
                        case FAS_EVENT_BIG_JANK:
                            last_event_str = "HARD_JANK";
                            jank_counter += 2;
                            current_uclamp = 85;
                            set_uclamp(current_uclamp);
                            boost_expire_ms = now + 250;
                            break;

                        case FAS_EVENT_SMALL_JANK:
                            last_event_str = "SMALL_JANK";
                            jank_counter++;
                            if (current_uclamp < 45) {
                                current_uclamp = 45;
                                set_uclamp(current_uclamp);
                            }
                            boost_expire_ms = now + 100;
                            break;

                        case FAS_EVENT_DEGRADED:
                            last_event_str = "DEGRADED";
                            baseline_uclamp = 50;
                            current_uclamp = 50;
                            set_uclamp(current_uclamp);
                            break;

                        case FAS_EVENT_RECOVERED:
                            last_event_str = "RECOVERED";
                            baseline_uclamp = 25;
                            current_uclamp = 25;
                            set_uclamp(current_uclamp);
                            boost_expire_ms = 0;
                            break;

                        case FAS_EVENT_PAUSED:
                            last_event_str = "PAUSED";
                            // Loading screen / inactive: drop uclamp to 0!
                            current_uclamp = 0;
                            set_uclamp(0);
                            boost_expire_ms = 0;
                            break;

                        case FAS_EVENT_RESUMED:
                            last_event_str = "RESUMED";
                            baseline_uclamp = 25;
                            current_uclamp = 25;
                            set_uclamp(current_uclamp);
                            break;

                        case FAS_EVENT_RATE_SWITCH:
                            last_event_str = "RATE_SWITCH";
                            if (ev->fps > 0) active_fps = (int)ev->fps;
                            break;

                        default:
                            break;
                    }
                }
            }
        }

        // Check boost expiration
        if (boost_expire_ms > 0 && now >= boost_expire_ms) {
            current_uclamp = baseline_uclamp;
            set_uclamp(current_uclamp);
            boost_expire_ms = 0;
            last_event_str = "HEALTHY";
        }

        // Update state file every 1s or on state change
        if (now - last_status_update >= 1000) {
            // Check if game process is still alive
            if (sys2(SYS_KILL, target_pid, 0) != 0) {
                // Game process died
                break;
            }
            update_state_file(1, target_pid, pkg_name, active_fps,
                              last_event_str, current_uclamp, jank_counter);
            last_status_update = now;
        }
    }

    // Teardown
    if (g_ctx_id >= 0) {
        struct fas_remove_args rem;
        rem.ctx_id = g_ctx_id;
        sys3(SYS_IOCTL, g_fas_fd, FAS_IOC_REMOVE, (long)&rem);
    }
    if (g_fas_fd >= 0) sys1(SYS_CLOSE, g_fas_fd);
    if (g_uclamp_fd >= 0) sys1(SYS_CLOSE, g_uclamp_fd);
    sys2(SYS_UNLINKAT, AT_FDCWD, (long)PID_FILE_PATH);
    update_state_file(0, 0, "", 0, "TERMINATED", 0, 0);

    return 0;
}

int main_entry(int argc, char **argv) {
    if (argc < 2) {
        print_out("Usage: fas_governor start <pid> [fps] [pkg] | stop | status\n");
        return 1;
    }

    const char *cmd = argv[1];
    if (str_equal(cmd, "stop")) {
        cmd_stop();
        return 0;
    } else if (str_equal(cmd, "status")) {
        long fd = sys4(SYS_OPENAT, AT_FDCWD, (long)STATE_FILE_PATH, O_RDONLY, 0);
        if (fd >= 0) {
            char buf[512];
            long n = sys3(SYS_READ, fd, (long)buf, 511);
            sys1(SYS_CLOSE, fd);
            if (n > 0) {
                buf[n] = '\0';
                print_out(buf);
                return 0;
            }
        }
        print_out("{\"active\": false}\n");
        return 0;
    } else if (str_equal(cmd, "start") && argc >= 3) {
        int pid = (int)parse_long(argv[2]);
        int fps = (argc >= 4) ? (int)parse_long(argv[3]) : 60;
        const char *pkg = (argc >= 5) ? argv[4] : "game";
        return cmd_start(pid, fps, pkg);
    } else {
        print_out("Usage: fas_governor start <pid> [fps] [pkg] | stop | status\n");
        return 1;
    }
}

__attribute__((naked)) void _start(void) {
    __asm__ volatile(
        "ldr x0, [sp]\n"       // x0 = argc
        "add x1, sp, #8\n"     // x1 = argv
        "bl main_entry\n"      // call main_entry(argc, argv)
        "mov x8, #93\n"        // sys_exit
        "svc #0\n"
    );
}
