/*
 * libtb-refreshcap.so - software refresh-rate cap for the TB710FU panel.
 *
 * The DSI panel has a single 3200x2000@120Hz KMS mode. Switching to a real
 * 60Hz mode powers the panel down/up and garbles the image, but the compositor
 * frame clock can simply be told that the output refreshes at 60Hz: mutter then
 * schedules one frame every 16.6ms while KMS keeps scanning the 120Hz mode.
 * That is the "lock the maximum to 60Hz" mode the Android-style UI offers.
 *
 * Mutter 51 forwards each presentation through
 *   clutter_stage_view_notify_presented(view, frame_info)
 * which calls clutter_stage_presented() and then
 * clutter_frame_clock_notify_presented(clock, frame_info); the latter copies
 * frame_info->refresh_rate into the frame clock.  Both entry points are hooked:
 * the stage view function is the cross-library call from libmutter (guaranteed
 * to be interposable), the frame clock function is kept as a fallback for
 * direct callers.  Editing the struct in place changes the compositor cadence
 * without touching KMS.
 *
 * The mode is read from ~/.config/tb-display-mode (or $XDG_CONFIG_HOME); "60"
 * enables the cap and anything else leaves the native 120Hz behaviour.  The
 * file is re-read at most twice per second.
 *
 * Build (aarch64 cross toolchain):
 *   aarch64-linux-gnu-gcc -shared -fPIC -O2 -o libtb-refreshcap.so \
 *       libtb-refreshcap.c -ldl
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* Mirror of ClutterFrameInfo (clutter/clutter/clutter-stage.h, mutter 51).
 * Keep the layout assertions; an ABI change must not silently corrupt the
 * frame info. */
typedef struct {
    int64_t global_frame_counter;
    int64_t view_frame_counter;
    int64_t presentation_time;
    float refresh_rate;
    int flags;
    unsigned int sequence;
    int64_t kms_ready_time_us;
} ClutterFrameInfo;

_Static_assert(offsetof(ClutterFrameInfo, refresh_rate) == 24,
               "ClutterFrameInfo.refresh_rate moved");
_Static_assert(sizeof(ClutterFrameInfo) == 48,
               "ClutterFrameInfo size changed");

typedef void (*NotifyPresentedFn)(void *object, ClutterFrameInfo *frame_info);

static NotifyPresentedFn real_frame_clock_notify;
static NotifyPresentedFn real_stage_view_notify;

#define CAP_HZ 60.0f
#define MODE_CHECK_INTERVAL_NS (500 * 1000 * 1000LL)
#define CONFIG_NAME ".config/tb-display-mode"
#define LOG_PREFIX "[tb-refreshcap] "

static int cap_hz_env; /* TB_REFRESHCAP_FORCE, for testing */
static int cap_active;
static int logged_applied;
static int log_enabled;
static int observed_count;
static float last_observed_rate;
static int64_t last_check_ns;

static int is_shell_process(void)
{
    char comm[64];
    int fd;
    ssize_t size;
    char *newline;

    fd = open("/proc/self/comm", O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 0;
    size = read(fd, comm, sizeof comm - 1);
    close(fd);
    if (size <= 0)
        return 0;
    comm[size] = '\0';
    newline = strchr(comm, '\n');
    if (newline)
        *newline = '\0';
    return strcmp(comm, "gnome-shell") == 0;
}

static void log_line(const char *text)
{
    if (log_enabled)
        dprintf(2, "%s%s\n", LOG_PREFIX, text);
}

static void write_marker(void)
{
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    char path[512];
    int fd;

    if (!runtime)
        return;
    snprintf(path, sizeof path, "%s/tb-refreshcap-loaded", runtime);
    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0)
        return;
    dprintf(fd, "%ld\n", (long)getpid());
    close(fd);
}

__attribute__((constructor))
static void refreshcap_init(void)
{
    const char *force = getenv("TB_REFRESHCAP_FORCE");
    int shell;

    if (force)
        cap_hz_env = atoi(force);
    shell = is_shell_process();
    log_enabled = shell || (getenv("TB_REFRESHCAP_VERBOSE") != NULL);
    if (shell) {
        write_marker();
        /* Do not leak the preload into every app the shell spawns. */
        unsetenv("LD_PRELOAD");
    }
    if (log_enabled) {
        char line[96];
        snprintf(line, sizeof line, "loaded pid=%ld force=%d",
                 (long)getpid(), cap_hz_env);
        log_line(line);
    }
}

static int parse_cap(const char *home, int *cap)
{
    const char *config_home = getenv("XDG_CONFIG_HOME");
    char path[512];
    char buffer[64];
    int fd;
    ssize_t size;

    if (config_home && config_home[0] == '/')
        snprintf(path, sizeof path, "%s/tb-display-mode", config_home);
    else if (home)
        snprintf(path, sizeof path, "%s/%s", home, CONFIG_NAME);
    else
        return 0;
    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 0;
    size = read(fd, buffer, sizeof buffer - 1);
    close(fd);
    if (size <= 0)
        return 0;
    buffer[size] = '\0';
    if (strncmp(buffer, "60", 2) == 0) {
        *cap = 60;
        return 1;
    }
    return 0;
}

static int refresh_cap_hz(void)
{
    struct timespec now;
    int cap = 0;
    int enabled;

    if (cap_hz_env > 0) {
        if (!cap_active) {
            char line[64];
            snprintf(line, sizeof line, "forced cap %dHz", cap_hz_env);
            log_line(line);
        }
        cap_active = 1;
        return cap_hz_env;
    }

    clock_gettime(CLOCK_MONOTONIC, &now);
    {
        int64_t now_ns = (int64_t)now.tv_sec * 1000000000LL + now.tv_nsec;
        if (now_ns - last_check_ns < MODE_CHECK_INTERVAL_NS)
            return cap_active ? (int)CAP_HZ : 0;
        last_check_ns = now_ns;
    }

    enabled = parse_cap(getenv("HOME"), &cap);
    if (enabled != cap_active) {
        char line[64];
        snprintf(line, sizeof line, "cap %s",
                 enabled ? "enabled (60Hz)" : "disabled (adaptive)");
        log_line(line);
        logged_applied = 0;
    }
    cap_active = enabled;
    return enabled ? (int)CAP_HZ : 0;
}

static void apply_cap(ClutterFrameInfo *frame_info)
{
    int cap = refresh_cap_hz();

    if (!frame_info)
        return;

    if (cap > 0 && frame_info->refresh_rate > (float)cap + 0.5f) {
        if (!logged_applied) {
            char line[96];
            snprintf(line, sizeof line, "applied cap: %.2fHz -> %dHz",
                     frame_info->refresh_rate, cap);
            log_line(line);
            logged_applied = 1;
        }
        frame_info->refresh_rate = (float)cap;
        last_observed_rate = (float)cap;
        observed_count++;
    } else if (frame_info->refresh_rate > 1.0f) {
        if (observed_count < 3 ||
            frame_info->refresh_rate != last_observed_rate) {
            char line[96];
            snprintf(line, sizeof line, "observed %.2fHz",
                     frame_info->refresh_rate);
            log_line(line);
            last_observed_rate = frame_info->refresh_rate;
            observed_count++;
        }
    }
}

/* Cross-library entry point used by meta-stage-view.c. */
void clutter_stage_view_notify_presented(void *stage_view,
                                         ClutterFrameInfo *frame_info)
{
    if (!real_stage_view_notify)
        real_stage_view_notify = (NotifyPresentedFn)dlsym(
            RTLD_NEXT, "clutter_stage_view_notify_presented");

    apply_cap(frame_info);

    if (real_stage_view_notify)
        real_stage_view_notify(stage_view, frame_info);
}

/* Fallback for callers that reach the frame clock directly. */
void clutter_frame_clock_notify_presented(void *frame_clock,
                                          ClutterFrameInfo *frame_info)
{
    if (!real_frame_clock_notify)
        real_frame_clock_notify = (NotifyPresentedFn)dlsym(
            RTLD_NEXT, "clutter_frame_clock_notify_presented");

    apply_cap(frame_info);

    if (real_frame_clock_notify)
        real_frame_clock_notify(frame_clock, frame_info);
}
