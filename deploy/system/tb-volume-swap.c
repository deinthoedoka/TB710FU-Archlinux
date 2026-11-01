/*
 * tb-volume-swap - swap the TB710FU volume rocker key codes
 *
 * The board DTS wires the GPIO key to KEY_VOLUMEUP and the PMIC resin key to
 * KEY_VOLUMEDOWN, but the physical rocker is the other way round.  gpio-keys
 * does not emit scancodes, so the usual udev hwdb KEYBOARD_KEY remap has no
 * effect on it.  Grab both input devices and re-emit their events through a
 * uinput device with the two key codes exchanged.  The hall sensor switch
 * (SW_LID) from gpio-keys is forwarded unchanged.
 *
 * pmic_resin is registered later than gpio-keys on some boots, so retry the
 * scan for a while instead of grabbing only what exists at startup; otherwise
 * one rocker direction stays unswapped and both directions end up "down".
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define MAX_DEV 16
#define SCAN_ATTEMPTS 60

struct dev {
	int fd;
	char path[300];
	int kind; /* 1 = gpio-keys, 2 = pmic_resin */
};

static int match_name(int fd)
{
	char name[256] = { 0 };

	if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) < 0)
		return 0;
	if (strcmp(name, "gpio-keys") == 0)
		return 1;
	if (strcmp(name, "pmic_resin") == 0)
		return 2;
	return 0;
}

static int already_grabbed(struct dev *devs, int ndev, const char *path)
{
	int i;

	for (i = 0; i < ndev; i++) {
		if (strcmp(devs[i].path, path) == 0)
			return 1;
	}
	return 0;
}

static int grab_one(const char *path, int *kind_out)
{
	int fd, kind;

	fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0)
		return -1;
	kind = match_name(fd);
	if (!kind) {
		close(fd);
		return -1;
	}
	if (ioctl(fd, EVIOCGRAB, 1) < 0) {
		fprintf(stderr, "EVIOCGRAB %s: %s\n", path, strerror(errno));
		close(fd);
		return -1;
	}
	fprintf(stderr, "grabbed %s (%s)\n", path,
		kind == 1 ? "gpio-keys" : "pmic_resin");
	*kind_out = kind;
	return fd;
}

static int setup_uinput(void)
{
	struct uinput_setup setup = { 0 };
	int fd;

	fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "/dev/uinput: %s\n", strerror(errno));
		return -1;
	}

	ioctl(fd, UI_SET_EVBIT, EV_KEY);
	ioctl(fd, UI_SET_KEYBIT, KEY_VOLUMEUP);
	ioctl(fd, UI_SET_KEYBIT, KEY_VOLUMEDOWN);
	ioctl(fd, UI_SET_EVBIT, EV_SW);
	ioctl(fd, UI_SET_SWBIT, SW_LID);
	ioctl(fd, UI_SET_EVBIT, EV_SYN);

	setup.id.bustype = BUS_VIRTUAL;
	setup.id.vendor = 0x1b1c;
	setup.id.product = 0x0001;
	strncpy(setup.name, "TB710FU Volume Rocker", UINPUT_MAX_NAME_SIZE - 1);

	if (ioctl(fd, UI_DEV_SETUP, &setup) < 0 ||
	    ioctl(fd, UI_DEV_CREATE) < 0) {
		fprintf(stderr, "uinput setup: %s\n", strerror(errno));
		close(fd);
		return -1;
	}
	return fd;
}

int main(void)
{
	struct dev devs[MAX_DEV];
	struct pollfd pfd[MAX_DEV + 1];
	int ndev = 0, have_gpio = 0, have_resin = 0;
	int uifd, nfds, i, attempt;

	for (attempt = 1; attempt <= SCAN_ATTEMPTS; attempt++) {
		DIR *dir = opendir("/dev/input");
		struct dirent *de;

		if (dir) {
			while ((de = readdir(dir)) != NULL && ndev < MAX_DEV) {
				char path[300];
				int fd, kind;

				if (strncmp(de->d_name, "event", 5) != 0)
					continue;
				snprintf(path, sizeof(path), "/dev/input/%s",
					 de->d_name);
				if (already_grabbed(devs, ndev, path))
					continue;
				fd = grab_one(path, &kind);
				if (fd < 0)
					continue;
				devs[ndev].fd = fd;
				snprintf(devs[ndev].path, sizeof(devs[ndev].path),
					 "%s", path);
				devs[ndev].kind = kind;
				if (kind == 1)
					have_gpio = 1;
				else
					have_resin = 1;
				ndev++;
			}
			closedir(dir);
		}
		if (have_gpio && have_resin)
			break;
		sleep(1);
	}

	if (ndev == 0) {
		fprintf(stderr, "no volume key devices found\n");
		return 1;
	}
	if (!have_gpio || !have_resin)
		fprintf(stderr, "warning: gpio-keys=%d pmic_resin=%d after %ds\n",
			have_gpio, have_resin, attempt);

	uifd = setup_uinput();
	if (uifd < 0)
		return 1;

	for (i = 0; i < ndev; i++) {
		pfd[i].fd = devs[i].fd;
		pfd[i].events = POLLIN;
	}
	pfd[ndev].fd = uifd;
	pfd[ndev].events = 0;
	nfds = ndev + 1;

	for (;;) {
		struct input_event ev[64];
		int n, nread, j;

		n = poll(pfd, nfds, -1);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		for (i = 0; i < nfds; i++) {
			ssize_t len;

			if (!(pfd[i].revents & POLLIN))
				continue;
			len = read(pfd[i].fd, ev, sizeof(ev));
			if (len < 0) {
				if (errno == EAGAIN)
					continue;
				goto out;
			}
			nread = len / (int)sizeof(ev[0]);
			for (j = 0; j < nread; j++) {
				struct input_event e = ev[j];

				if (e.type == EV_KEY) {
					if (e.code == KEY_VOLUMEUP)
						e.code = KEY_VOLUMEDOWN;
					else if (e.code == KEY_VOLUMEDOWN)
						e.code = KEY_VOLUMEUP;
				} else if (e.type != EV_SW && e.type != EV_SYN) {
					continue;
				}
				if (write(uifd, &e, sizeof(e)) < 0)
					goto out;
			}
		}
	}
out:
	fprintf(stderr, "exiting: %s\n", strerror(errno));
	return 1;
}
