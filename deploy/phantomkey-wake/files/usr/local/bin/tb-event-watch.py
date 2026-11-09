#!/usr/bin/env python3
"""TB710FU phantom-key watcher.

Background: spontaneous screen-on without any key press. Journal shows
phantom KEY_POWER (pmic_pwrkey, event1) bursts co-occurring with the
gpio-keys Volume-Up line (IRQ161, SPMI GPIO) waking the device from
s2idle.  Suspected intermittent short on the button board / key lines.

This daemon records every raw evdev event of the button devices, plus
DPMS/backlight transitions and the cover-sensor GPIO66 level, with
timestamps, so the next phantom burst can be correlated exactly.

Log: /root/event-watch/log-<start>.txt (rotated at 5 MB).
"""
import os
import select
import struct
import time

# EVIOCGNAME(256) = _IOC(_IOC_READ, 'E', 0x06, 256)
IOC_READ = 2
def ioc_read(nr, size, typ=0x45):
    return (IOC_READ << 30) | (size << 16) | (typ << 8) | nr

EVIOCGNAME = ioc_read(0x06, 256)
def eviocgbit(ev, size):
    return ioc_read(0x20 + ev, size)

# aarch64 input_event: timeval(16) + type(2) + code(2) + value(4)
EVENT = struct.Struct("llHHi")
EV_SZ = EVENT.size

WATCH = {"/dev/input/event0": "gpio-keys(volup/lid)",
         "/dev/input/event1": "pmic_pwrkey",
         "/dev/input/event2": "pmic_resin"}

KEY_NAMES = {116: "KEY_POWER", 115: "KEY_VOLUMEUP", 114: "KEY_VOLUMEDOWN",
             143: "KEY_WAKEUP"}
SW_NAMES = {0: "SW_LID", 1: "SW_TABLET_MODE"}
TYPE_NAMES = {0: "SYN", 1: "KEY", 2: "REL", 3: "ABS", 4: "MSC", 5: "SW",
              15: "SW", 17: "LED", 20: "REP"}

BL_POWER = "/sys/class/backlight/sy7758-backlight/bl_power"
DPMS_GLOB = "/sys/class/drm/card*-DSI-1/dpms"
GPIO_DEBUG = "/sys/kernel/debug/gpio"

log = None
log_path = None
log_size = 0


def write(line):
    global log, log_path, log_size
    data = (line + "\n").encode()
    if log is None or log_size > 5 * 1024 * 1024:
        if log:
            log.close()
        log_path = "/root/event-watch/log-%s.txt" % time.strftime("%Y%m%d-%H%M%S")
        os.makedirs("/root/event-watch", exist_ok=True)
        log = open(log_path, "wb", buffering=0)
        log_size = 0
    log.write(data)
    log_size += len(data)


def decode_name(typ, code, value):
    base = TYPE_NAMES.get(typ, "T%d" % typ)
    if base == "KEY":
        return "%s(%d)%s" % (base, code, KEY_NAMES.get(code, ""))
    if base == "SW":
        return "%s(%d)%s" % (base, code, SW_NAMES.get(code, ""))
    return "%s(%d)" % (base, code)


def read_line_level():
    """Cover hall sensor GPIO66 level from debugfs (0=closed,1=open)."""
    try:
        with open(GPIO_DEBUG) as fh:
            for line in fh:
                if " gpio-66 " in line:
                    return "high" if " high " in line else "low"
    except OSError:
        pass
    return "?"


def state_snapshot():
    dpms = bl = "?"
    try:
        import glob as _g
        d = _g.glob(DPMS_GLOB)
        if d:
            dpms = open(d[0]).read().strip()
    except OSError:
        pass
    try:
        bl = open(BL_POWER).read().strip()
    except OSError:
        pass
    return dpms, bl


def main():
    os.makedirs("/root/event-watch", exist_ok=True)
    write("=== phantom-key watch started %s ===" % time.strftime("%F %T"))
    for path, desc in WATCH.items():
        write("  watch %s (%s)" % (path, desc))

    fds = {}
    for path in WATCH:
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
            buf = bytearray(256)
            n = __import__("fcntl").ioctl(fd, EVIOCGNAME, buf, True)
            name = buf[:n].decode(errors="replace").rstrip("\x00")
            write("  opened %s name=%s" % (path, name))
            fds[fd] = path
        except OSError as e:
            write("  ! cannot open %s: %s" % (path, e))
    poll = select.poll()
    for fd in fds:
        poll.register(fd, select.POLLIN)

    last_dpms = last_bl = last_level = None
    last_poll = 0.0

    while True:
        events = poll.poll(500)
        now = time.time()
        if now - last_poll >= 2.0:
            last_poll = now
            dpms, bl = state_snapshot()
            if dpms != last_dpms:
                write("%s DPMS %s -> %s" % (time.strftime("%F %T.%f")[:-3],
                                            last_dpms, dpms))
                last_dpms = dpms
            if bl != last_bl:
                write("%s BL_POWER %s -> %s" % (time.strftime("%F %T.%f")[:-3],
                                                last_bl, bl))
                last_bl = bl
            level = read_line_level()
            if level != last_level:
                write("%s GPIO66(cover) %s -> %s" % (time.strftime("%F %T.%f")[:-3],
                                                     last_level, level))
                last_level = level
        for fd, _mask in events:
            path = fds[fd]
            data = os.read(fd, 256 * EV_SZ)
            for off in range(0, len(data) - EV_SZ + 1, EV_SZ):
                sec, usec, typ, code, value = EVENT.unpack_from(data, off)
                if typ == 0:
                    continue
                write("%s [%s] %s value=%d" % (
                    time.strftime("%F %T.%f")[:-3], path,
                    decode_name(typ, code, value), value))


if __name__ == "__main__":
    main()
