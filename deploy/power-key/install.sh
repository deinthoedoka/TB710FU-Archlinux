#!/bin/sh
# Install the TB710FU power-key long-press handler and power menu.
set -eu

UUID=tb-power-menu@tb710fu
SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$SOURCE_DIR/$UUID/extension.js" ]; then
    FILE_DIR=$SOURCE_DIR/$UUID
else
    FILE_DIR=$SOURCE_DIR
fi
TARGET_DIR=/usr/share/gnome-shell/extensions/$UUID
SHELL_USER=${SHELL_USER:-alarm}
RUNTIME_DIR=/run/user/$(id -u "$SHELL_USER")

install -Dm755 "$SOURCE_DIR/tb-power-key" /usr/local/bin/tb-power-key
install -Dm644 "$SOURCE_DIR/tb-power-key.service" /usr/lib/systemd/user/tb-power-key.service
install -Dm644 "$SOURCE_DIR/70-tb-pwrkey-uaccess.rules" /etc/udev/rules.d/70-tb-pwrkey-uaccess.rules
udevadm control --reload-rules
udevadm trigger --subsystem-match=input --action=change

install -d -m 755 "$TARGET_DIR"
install -Dm644 "$FILE_DIR/metadata.json" "$TARGET_DIR/metadata.json"
install -Dm644 "$FILE_DIR/extension.js" "$TARGET_DIR/extension.js"
install -Dm644 "$FILE_DIR/stylesheet.css" "$TARGET_DIR/stylesheet.css"

if [ -d "$RUNTIME_DIR" ] && [ -S "$RUNTIME_DIR/bus" ]; then
    AS_USER="runuser -u $SHELL_USER -- env XDG_RUNTIME_DIR=$RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS=unix:path=$RUNTIME_DIR/bus"

    OLD=$($AS_USER gsettings get org.gnome.settings-daemon.plugins.power power-button-action)
    printf '%s\n' "$OLD" > /root/tb-power-button-action.before

    # gsd must not suspend on the press that starts a long press.
    $AS_USER gsettings set org.gnome.settings-daemon.plugins.power power-button-action nothing

    ENABLED=$($AS_USER gsettings get org.gnome.shell enabled-extensions)
    case "$ENABLED" in
        *"'$UUID'"*) ;;
        *)
            case "$ENABLED" in
                '@as []'|'[]') NEW="['$UUID']" ;;
                *) NEW=$(printf '%s' "$ENABLED" | sed "s/]$/, '$UUID']/") ;;
            esac
            $AS_USER gsettings set org.gnome.shell enabled-extensions "$NEW"
            ;;
    esac

    $AS_USER systemctl --user daemon-reload
    $AS_USER systemctl --user enable --now tb-power-key.service
fi

echo "installed $TARGET_DIR, daemon and udev rule"
echo "power-button-action was: $(cat /root/tb-power-button-action.before)"
echo "the shell extension loads at the next login; until then a long press uses the"
echo "gnome-session power-off dialog as a fallback"
echo "rollback: $AS_USER systemctl --user disable --now tb-power-key.service;"
echo "          gsettings set org.gnome.settings-daemon.plugins.power power-button-action $(cat /root/tb-power-button-action.before)"
