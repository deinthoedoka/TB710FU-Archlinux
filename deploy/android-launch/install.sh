#!/bin/sh
# TB710FU: make Android launch per app icon and shut down again when the last
# app exits. Run as root on the tablet (or through deploy/run_on.sh).
#
# Idempotent. Does not enable droidloom.service: the runtime stays on demand.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
desktop_user=${SHELL_USER:-alarm}
runtime_dir=/run/user/$(id -u "$desktop_user")
applications=/usr/share/applications
user_applications=$(runuser -u "$desktop_user" -- sh -c 'echo "${XDG_DATA_HOME:-$HOME/.local/share}/applications"')

# Cold launch is handled inside droidloomctl itself (runtime/droidloom-supervisor/
# src/bin/droidloomctl.rs), so the generated desktop entries keep upstream's
# `Exec=/usr/bin/droidloomctl launch …`. A launcher that still holds an older
# command line works too; nothing here depends on GNOME noticing a rewrite.
install -Dm755 "$here/tb-droidloom-idle" /usr/local/bin/tb-droidloom-idle
install -Dm644 "$here/tb-droidloom-idle.service" /usr/lib/systemd/user/tb-droidloom-idle.service

python3 -c 'import py_compile,sys; py_compile.compile(sys.argv[1], cfile="/tmp/tb-droidloom-idle.pyc", doraise=True)' \
    /usr/local/bin/tb-droidloom-idle

# The shipped "Android (Droidloom)" entry runs `droidloomctl start` and leaves
# Android resident forever. Shadow it with Hidden=true so the icon disappears
# (GLib reports NoDisplay entries as visible; Hidden drops the entry outright);
# the app icons now start the runtime themselves.
if [ -f "$applications/dev.denial.Droidloom.desktop" ]; then
    install -d -m 700 -o "$desktop_user" -g "$desktop_user" "$user_applications"
    sed '/^NoDisplay=/d; /^Hidden=/d; s/^\[Desktop Entry\]/[Desktop Entry]\nHidden=true/' \
        "$applications/dev.denial.Droidloom.desktop" > \
        "$user_applications/dev.denial.Droidloom.desktop.tmp"
    chown "$desktop_user":"$desktop_user" "$user_applications/dev.denial.Droidloom.desktop.tmp"
    mv "$user_applications/dev.denial.Droidloom.desktop.tmp" \
        "$user_applications/dev.denial.Droidloom.desktop"
fi

if [ -d "$runtime_dir" ] && [ -S "$runtime_dir/bus" ]; then
    AS_USER="runuser -u $desktop_user -- env XDG_RUNTIME_DIR=$runtime_dir
        DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime_dir/bus"
    $AS_USER systemctl --user daemon-reload
    $AS_USER systemctl --user enable --now tb-droidloom-idle.service
    # adb's fork-server is a transient unit that outlived its purpose.
    $AS_USER systemctl --user stop droidloom-adb-server.service 2>/dev/null || true
else
    echo "no live session for $desktop_user; enable later with:"
    echo "  systemctl --user enable --now tb-droidloom-idle.service"
fi

echo "Installed. Android now starts on an app click and stops 120s after the last task exits."
echo "Check: systemctl --user status tb-droidloom-idle.service"
