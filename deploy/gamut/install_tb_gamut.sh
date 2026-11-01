#!/bin/bash
# 安装色域切换（在平板以 root 运行）
# TEST=1 会把当前状态切到准确色域再显示状态（默认已经是准确就只显示）。
set -eu
export LC_ALL=C
SRC=/root/tb-gamut-deploy
PPID_DESK=$(pgrep -u alarm -x plasmashell | head -1)
WAY=$(tr '\0' '\n' < "/proc/$PPID_DESK/environ" 2>/dev/null | sed -n 's/^WAYLAND_DISPLAY=//p')
XA=$(tr '\0' '\n' < "/proc/$PPID_DESK/environ" 2>/dev/null | sed -n 's/^XAUTHORITY=//p')
A() { runuser -u alarm -- env XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    WAYLAND_DISPLAY="${WAY:-wayland-1}" DISPLAY=:0 XAUTHORITY="$XA" "$@"; }

echo "=== 安装 CLI 与 ICC ==="
install -m 755 "$SRC/tb-gamut" /usr/local/bin/tb-gamut
bash -n /usr/local/bin/tb-gamut && echo "shell 语法 OK"
mkdir -p /usr/share/color/icc/tb710fu
python3 -I "$SRC/make_p3_icc.py" /usr/share/color/icc/tb710fu/DisplayP3.icc
chmod 644 /usr/share/color/icc/tb710fu/DisplayP3.icc

echo
echo "=== 安装应用菜单项 ==="
install -d -o alarm -g alarm /home/alarm/.local/share/applications
install -m 644 -o alarm -g alarm "$SRC/tb-gamut-toggle.desktop" \
    /home/alarm/.local/share/applications/tb-gamut-toggle.desktop
A kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
echo "已安装 色域切换（准确 / 鲜艳）"

echo
echo "=== 当前状态 ==="
A /usr/local/bin/tb-gamut status || true

if [ "${TEST:-0}" = 1 ]; then
    echo
    echo "=== 切到准确色域 ==="
    A /usr/local/bin/tb-gamut accurate || true
    sleep 1
    A /usr/local/bin/tb-gamut status || true
fi
