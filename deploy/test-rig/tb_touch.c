// SPDX-License-Identifier: GPL-2.0
// Minimal multitouch injector for the Denial/TB710FU test rig.
// Commands on stdin:
//   down SLOT X Y      (X 0..1599, Y 0..999 logical)
//   move SLOT X Y
//   up SLOT
//   sleep MS
//   tap X Y [MS]
// Slots are tracked; BTN_TOUCH follows the number of active contacts.

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_SLOTS 10
#define MAX_X 1599
#define MAX_Y 999

static int fd = -1;
static int active[MAX_SLOTS];
static int next_tracking = 1;
static int active_count;

static void die(const char *what)
{
    perror(what);
    exit(1);
}

static void emit(int type, int code, int value)
{
    struct input_event ev = {
        .type = type,
        .code = code,
        .value = value,
    };
    if (write(fd, &ev, sizeof(ev)) != sizeof(ev))
        die("write input_event");
}

static void syn(void)
{
    emit(EV_SYN, SYN_REPORT, 0);
}

static int clamp(int v, int lo, int hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

static void emit_abs(int slot, int x, int y)
{
    emit(EV_ABS, ABS_MT_SLOT, slot);
    emit(EV_ABS, ABS_MT_POSITION_X, clamp(x, 0, MAX_X));
    emit(EV_ABS, ABS_MT_POSITION_Y, clamp(y, 0, MAX_Y));
    // Legacy axes keep libinput's pointer emulation consistent.
    emit(EV_ABS, ABS_X, clamp(x, 0, MAX_X));
    emit(EV_ABS, ABS_Y, clamp(y, 0, MAX_Y));
}

static void down(int slot, int x, int y)
{
    if (slot < 0 || slot >= MAX_SLOTS)
        return;
    if (!active[slot]) {
        active[slot] = 1;
        active_count++;
    }
    emit(EV_ABS, ABS_MT_SLOT, slot);
    emit(EV_ABS, ABS_MT_TRACKING_ID, next_tracking++);
    emit_abs(slot, x, y);
    if (active_count == 1)
        emit(EV_KEY, BTN_TOUCH, 1);
    syn();
}

static void move(int slot, int x, int y)
{
    if (slot < 0 || slot >= MAX_SLOTS || !active[slot])
        return;
    emit_abs(slot, x, y);
    syn();
}

static void up(int slot)
{
    if (slot < 0 || slot >= MAX_SLOTS || !active[slot])
        return;
    emit(EV_ABS, ABS_MT_SLOT, slot);
    emit(EV_ABS, ABS_MT_TRACKING_ID, -1);
    active[slot] = 0;
    if (active_count > 0)
        active_count--;
    if (active_count == 0)
        emit(EV_KEY, BTN_TOUCH, 0);
    syn();
}

static void sleep_ms(int ms)
{
    usleep(ms * 1000);
}

static int setup(void)
{
    struct uinput_setup setup = { 0 };
    struct uinput_abs_setup abs = { 0 };

    fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0)
        die("open /dev/uinput");

    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_EVBIT, EV_ABS);
    ioctl(fd, UI_SET_EVBIT, EV_SYN);
    ioctl(fd, UI_SET_KEYBIT, BTN_TOUCH);
    ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT);

    memset(&abs, 0, sizeof(abs));
    abs.absinfo = (struct input_absinfo){ .minimum = 0, .maximum = MAX_X, .fuzz = 0, .flat = 0, .resolution = 0 };
    abs.code = ABS_X;
    ioctl(fd, UI_ABS_SETUP, &abs);
    abs.absinfo = (struct input_absinfo){ .minimum = 0, .maximum = MAX_Y, .fuzz = 0, .flat = 0, .resolution = 0 };
    abs.code = ABS_Y;
    ioctl(fd, UI_ABS_SETUP, &abs);
    abs.absinfo = (struct input_absinfo){ .minimum = 0, .maximum = MAX_SLOTS - 1, .fuzz = 0, .flat = 0, .resolution = 0 };
    abs.code = ABS_MT_SLOT;
    ioctl(fd, UI_ABS_SETUP, &abs);
    abs.absinfo = (struct input_absinfo){ .minimum = 0, .maximum = 65535, .fuzz = 0, .flat = 0, .resolution = 0 };
    abs.code = ABS_MT_TRACKING_ID;
    ioctl(fd, UI_ABS_SETUP, &abs);
    abs.absinfo = (struct input_absinfo){ .minimum = 0, .maximum = MAX_X, .fuzz = 0, .flat = 0, .resolution = 0 };
    abs.code = ABS_MT_POSITION_X;
    ioctl(fd, UI_ABS_SETUP, &abs);
    abs.absinfo = (struct input_absinfo){ .minimum = 0, .maximum = MAX_Y, .fuzz = 0, .flat = 0, .resolution = 0 };
    abs.code = ABS_MT_POSITION_Y;
    ioctl(fd, UI_ABS_SETUP, &abs);

    snprintf(setup.name, UINPUT_MAX_NAME_SIZE, "tb-touch-inject");
    setup.id.bustype = BUS_VIRTUAL;
    setup.id.vendor = 0x1;
    setup.id.product = 0x1;
    setup.id.version = 1;
    if (ioctl(fd, UI_DEV_SETUP, &setup) < 0)
        die("UI_DEV_SETUP");
    if (ioctl(fd, UI_DEV_CREATE) < 0)
        die("UI_DEV_CREATE");
    sleep_ms(1600);
    return 0;
}

int main(void)
{
    char line[256];

    setup();
    while (fgets(line, sizeof(line), stdin)) {
        char cmd[32];
        int a = 0, b = 0, c = 0;

        if (line[0] == '#' || line[0] == '\n')
            continue;
        int n = sscanf(line, "%31s %d %d %d", cmd, &a, &b, &c);
        if (n < 1)
            continue;
        if (!strcmp(cmd, "down") && n >= 4) {
            down(a, b, c);
        } else if (!strcmp(cmd, "move") && n >= 4) {
            move(a, b, c);
        } else if (!strcmp(cmd, "up") && n >= 2) {
            up(a);
        } else if (!strcmp(cmd, "sleep") && n >= 2) {
            sleep_ms(a);
        } else if (!strcmp(cmd, "tap") && n >= 3) {
            down(0, a, b);
            sleep_ms(n >= 4 ? c : 120);
            up(0);
        } else {
            fprintf(stderr, "bad command: %s", line);
        }
        fflush(stdout);
    }
    // Lift anything left down.
    for (int i = 0; i < MAX_SLOTS; i++)
        if (active[i])
            up(i);
    ioctl(fd, UI_DEV_DESTROY);
    close(fd);
    return 0;
}
