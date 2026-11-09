#!/bin/sh
# Install the Droidloom APK installer on the tablet (run as root).
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
applications=/usr/share/applications
icons=/usr/share/icons/hicolor

install -Dm755 "$here/droidloom-apk-installer.py" /usr/local/bin/droidloom-apk-installer
install -Dm644 "$here/org.droidloom.ApkInstaller.desktop" "$applications/org.droidloom.ApkInstaller.desktop"
install -Dm644 "$here/droidloom-apk-installer.svg" "$icons/scalable/apps/droidloom-apk-installer.svg"
install -Dm644 "$here/droidloom-apk-installer-128.png" "$icons/128x128/apps/droidloom-apk-installer.png"

update-desktop-database "$applications" >/dev/null 2>&1 || true
gtk-update-icon-cache -f -t "$icons" >/dev/null 2>&1 || true

# The desktop session user must own the MIME association.
desktop_user=${DROIDLOOM_USER:-alarm}
if id "$desktop_user" >/dev/null 2>&1; then
    runuser -u "$desktop_user" -- \
        xdg-mime default org.droidloom.ApkInstaller.desktop \
        application/vnd.android.package-archive || true
fi

echo "APK installer installed."
echo "Try: xdg-mime query default application/vnd.android.package-archive"
