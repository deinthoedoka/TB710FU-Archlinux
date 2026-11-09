#!/bin/sh
# Install the TB710FU background-service trim and VM/IO tuning.
set -eu

SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SHELL_USER=${SHELL_USER:-alarm}
RUNTIME_DIR=/run/user/$(id -u "$SHELL_USER")

install -Dm755 "$SOURCE_DIR/tb-background-trim" /usr/local/bin/tb-background-trim

install -Dm644 "$SOURCE_DIR/tb-background-trim.service" \
    /etc/systemd/user/tb-background-trim.service
install -Dm644 "$SOURCE_DIR/tb-background-trim.timer" \
    /etc/systemd/user/tb-background-trim.timer
install -Dm644 "$SOURCE_DIR/slice.d/50-tb-background.conf" \
    /etc/systemd/user/background.slice.d/50-tb-background.conf
for unit in gnome-software localsearch-3 evolution-addressbook-factory \
            evolution-calendar-factory evolution-source-registry; do
    install -Dm644 "$SOURCE_DIR/dropins/$unit.service.d/50-tb-background.conf" \
        "/etc/systemd/user/$unit.service.d/50-tb-background.conf"
done

install -Dm644 "$SOURCE_DIR/91-tb-performance.conf" /etc/sysctl.d/91-tb-performance.conf
sysctl --system >/dev/null

# The debug watcher called "loginctl list-sessions" every second, which kept
# systemd-logind busy and wrote a 1 Hz log for 30 minutes after every boot.
systemctl disable --now tb-display-watch.service >/dev/null 2>&1 || true
rm -f /run/tb-display-watch.log

# Global enable: the timer is active for every future login, including the
# first login of the packaged image.
systemctl --global enable tb-background-trim.timer >/dev/null 2>&1 || true

if [ -d "$RUNTIME_DIR" ] && [ -S "$RUNTIME_DIR/bus" ]; then
    AS_USER="runuser -u $SHELL_USER -- env XDG_RUNTIME_DIR=$RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS=unix:path=$RUNTIME_DIR/bus"
    $AS_USER systemctl --user daemon-reload
    $AS_USER systemctl --user enable --now tb-background-trim.timer >/dev/null 2>&1 || true
fi

echo "installed background trim; timer runs 90s after login"
echo "sysctl: vm.vfs_cache_pressure=$(sysctl -n vm.vfs_cache_pressure) dirty_ratio=$(sysctl -n vm.dirty_ratio)"
echo "disable/remove the old debug watcher: systemctl disable --now tb-display-watch.service"
