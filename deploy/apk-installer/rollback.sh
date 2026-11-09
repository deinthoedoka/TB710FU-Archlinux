#!/bin/sh
# Remove the APK installer and restore the pre-deployment MIME configuration.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

rm -f /usr/local/bin/droidloom-apk-installer \
      /usr/share/applications/org.droidloom.ApkInstaller.desktop \
      /usr/share/icons/hicolor/scalable/apps/droidloom-apk-installer.svg \
      /usr/share/icons/hicolor/128x128/apps/droidloom-apk-installer.png

update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true

if [ -f "$here/mimeapps.list" ]; then
    install -o alarm -g alarm -m 644 "$here/mimeapps.list" /home/alarm/.config/mimeapps.list
fi

echo "APK installer removed; MIME association restored."
