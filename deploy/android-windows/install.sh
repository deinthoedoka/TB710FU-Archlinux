#!/bin/sh
# Install the TB710FU Android window controls GNOME Shell extension.
set -eu

UUID=tb-android-windows@tb710fu
SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Accept both the repository layout (<root>/<uuid>/...) and a flat copy.
if [ -f "$SOURCE_DIR/$UUID/extension.js" ]; then
    FILE_DIR=$SOURCE_DIR/$UUID
else
    FILE_DIR=$SOURCE_DIR
fi
TARGET_DIR=/usr/share/gnome-shell/extensions/$UUID

install -d -m 755 "$TARGET_DIR"
install -Dm644 "$FILE_DIR/metadata.json" "$TARGET_DIR/metadata.json"
install -Dm644 "$FILE_DIR/extension.js" "$TARGET_DIR/extension.js"
install -Dm644 "$FILE_DIR/stylesheet.css" "$TARGET_DIR/stylesheet.css"

SHELL_USER=${SHELL_USER:-alarm}
RUNTIME_DIR=/run/user/$(id -u "$SHELL_USER")
if [ -d "$RUNTIME_DIR" ] && [ -S "$RUNTIME_DIR/bus" ]; then
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
            echo "enabled $UUID"
            ;;
    esac
    runuser -u "$SHELL_USER" -- env \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus" \
        gnome-extensions enable "$UUID" >/dev/null 2>&1 || true
fi

echo "installed $TARGET_DIR"
echo "if the extension does not appear, log out and back in (the shell scans extensions at startup)"
