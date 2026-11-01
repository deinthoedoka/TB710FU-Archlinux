#!/bin/bash
set -eu
export LC_ALL=C
A() { runuser -u alarm -- env XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "$@"; }

cat > /home/alarm/.local/share/applications/tb-als-toggle.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=自动亮度
Name[zh_CN]=自动亮度
GenericName=自动亮度开关
Comment=点击切换：根据环境光自动调节屏幕亮度
Exec=/usr/local/bin/tb-als toggle
Icon=video-display-brightness
Terminal=false
Categories=Settings;
Keywords=自动亮度;亮度;als;brightness;
X-KDE-StartupNotify=false
EOF
chown alarm:alarm /home/alarm/.local/share/applications/tb-als-toggle.desktop
chmod 644 /home/alarm/.local/share/applications/tb-als-toggle.desktop
echo "=== 校验 ==="
desktop-file-validate /home/alarm/.local/share/applications/tb-als-toggle.desktop && echo "desktop OK"
echo "=== 刷新应用菜单 ==="
A kbuildsycoca6 --noincremental 2>&1 | tail -3 || true
echo
echo "=== 服务与当前状态 ==="
A systemctl --user is-enabled tb-als.service
A systemctl --user is-active tb-als.service
A /usr/local/bin/tb-als status
