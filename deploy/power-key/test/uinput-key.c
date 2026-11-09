/* Test helper: create a virtual keyboard that presses KEY_POWER for N ms. */
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static void emit(int fd, int type, int code, int value)
{
    struct input_event event = {0};
    event.type = type;
    event.code = code;
    event.value = value;
    if (write(fd, &event, sizeof event) < 0)
        perror("write");
}

int main(int argc, char **argv)
{
    int hold_ms = argc > 1 ? atoi(argv[1]) : 200;
    int delay_ms = argc > 2 ? atoi(argv[2]) : 1500;
    int fd;
    struct uinput_setup setup = {0};

    fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        perror("open /dev/uinput");
        return 1;
    }
    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0 ||
        ioctl(fd, UI_SET_KEYBIT, KEY_POWER) < 0) {
        perror("uinput ioctl");
        return 1;
    }
    strncpy(setup.name, "tb-power-test", UINPUT_MAX_NAME_SIZE - 1);
    setup.id.bustype = BUS_VIRTUAL;
    setup.id.vendor = 0x1;
    setup.id.product = 0x1;
    if (ioctl(fd, UI_DEV_SETUP, &setup) < 0 ||
        ioctl(fd, UI_DEV_CREATE) < 0) {
        perror("UI_DEV_CREATE");
        return 1;
    }
    usleep(delay_ms * 1000);
    emit(fd, EV_KEY, KEY_POWER, 1);
    emit(fd, EV_SYN, SYN_REPORT, 0);
    usleep(hold_ms * 1000);
    emit(fd, EV_KEY, KEY_POWER, 0);
    emit(fd, EV_SYN, SYN_REPORT, 0);
    usleep(200 * 1000);
    ioctl(fd, UI_DEV_DESTROY);
    close(fd);
    return 0;
}
