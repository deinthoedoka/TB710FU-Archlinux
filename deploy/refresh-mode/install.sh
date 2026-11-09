#!/bin/sh
# Install the TB710FU software refresh-rate cap.
set -eu

UUID=tb-display-mode@tb710fu
SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$SOURCE_DIR/$UUID/extension.js" ]; then
    FILE_DIR=$SOURCE_DIR/$UUID
else
    FILE_DIR=$SOURCE_DIR
fi
TARGET_DIR=/usr/share/gnome-shell/extensions/$UUID
SHELL_USER=${SHELL_USER:-alarm}
RUNTIME_DIR=/run/user/$(id -u "$SHELL_USER")

install -Dm755 "$SOURCE_DIR/libtb-refreshcap.so" /usr/local/lib/libtb-refreshcap.so
install -d -m 755 /etc/systemd/user/org.gnome.Shell@user.service.d
cat > /etc/systemd/user/org.gnome.Shell@user.service.d/tb-refreshcap.conf <<'EOF'
[Service]
Environment=LD_PRELOAD=/usr/local/lib/libtb-refreshcap.so
EOF

install -d -m 755 "$TARGET_DIR"
install -Dm644 "$FILE_DIR/metadata.json" "$TARGET_DIR/metadata.json"
install -Dm644 "$FILE_DIR/extension.js" "$TARGET_DIR/extension.js"

if [ -d "$RUNTIME_DIR" ] && [ -S "$RUNTIME_DIR/bus" ]; then
    runuser -u "$SHELL_USER" -- env \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus" \
        systemctl --user daemon-reload
    ENABLED=$(runuser -u "$SHELL_USER" -- env \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus" \
        gsettings get org.gnome.shell enabled-extensions)
    case "$ENABLED" in
        *"'$UUID'"*) ;;
        *)
            case "$ENABLED" in
                '@as []'|'[]') NEW="['$UUID']" ;;
                *) NEW=$(printf '%s' "$ENABLED" | sed "s/]$/, '$UUID']/") ;;
            esac
            runuser -u "$SHELL_USER" -- env \
                XDG_RUNTIME_DIR="$RUNTIME_DIR" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus" \
                gsettings set org.gnome.shell enabled-extensions "$NEW"
            ;;
    esac
fi

echo "installed $TARGET_DIR and $TARGET_DIR drop-in"
echo "log out and back in (or reboot): the preload is applied when org.gnome.Shell@user.service starts"
echo "then use Quick Settings -> 刷新率 to switch between 自适应 and 60Hz"
