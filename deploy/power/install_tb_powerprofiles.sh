#!/bin/bash
# 安装 TB710FU 电源方案服务（在平板以 root 运行）
# TEST=1 会依次切换三档并打印实际频率，最后恢复原方案。
set -eu
export LC_ALL=C
SRC=/root/tb-powerprofiles-deploy
STATE=/var/lib/tb-powerprofiles/active
A() { runuser -u alarm -- env XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "$@"; }
PU=org.freedesktop.UPower.PowerProfiles
PP=/org/freedesktop/UPower/PowerProfiles

show() {
    echo "  CPU: $(for p in /sys/devices/system/cpu/cpufreq/policy*; do printf '%s=%s/%s ' \
        "$(basename "$p" | sed s/policy//)" "$(cat "$p/scaling_min_freq")" "$(cat "$p/scaling_max_freq")"; done)"
    echo "  GPU: min=$(cat /sys/class/devfreq/3d00000.gpu/min_freq) max=$(cat /sys/class/devfreq/3d00000.gpu/max_freq)"
    echo "  boost: $(systemctl is-active tb-gpu-boost.service 2>/dev/null || true)"
}
set_profile() {
    busctl --system set-property "$PU" "$PP" "$PU" ActiveProfile s "$1"
    sleep 1
    echo "切换到 $1："
    show
}

echo "=== 安装文件 ==="
install -m 755 "$SRC/tb-powerprofiles" /usr/local/bin/tb-powerprofiles
install -m 644 "$SRC/tb-powerprofiles.service" /etc/systemd/system/tb-powerprofiles.service
systemctl daemon-reload
echo "已安装 /usr/local/bin/tb-powerprofiles 与单元文件"

echo
echo "=== 让出 PPD 的 D-Bus 名字 ==="
systemctl disable --now power-profiles-daemon.service >/dev/null 2>&1 || true
systemctl mask power-profiles-daemon.service >/dev/null 2>&1 || true
echo "power-profiles-daemon: $(systemctl is-enabled power-profiles-daemon.service 2>&1 || true) / $(systemctl is-active power-profiles-daemon.service 2>&1 || true)"

echo
echo "=== 启动 tb-powerprofiles ==="
systemctl enable --now tb-powerprofiles.service
sleep 2
systemctl --no-pager status tb-powerprofiles.service | head -8
echo
echo "=== 上报的方案 ==="
busctl --system get-property "$PU" "$PP" "$PU" Profiles 2>&1
echo "当前：$(busctl --system get-property "$PU" "$PP" "$PU" ActiveProfile 2>&1)"
echo
echo "=== 服务日志 ==="
journalctl -u tb-powerprofiles.service -n 12 --no-pager

echo
echo "=== 重启 PowerDevil，让它重新读取 ==="
A systemctl --user restart plasma-powerdevil.service
sleep 3
A systemctl --user is-active plasma-powerdevil.service
echo -n "profileChoices: "
A busctl --user call org.kde.Solid.PowerManagement \
    /org/kde/Solid/PowerManagement/Actions/PowerProfile \
    org.kde.Solid.PowerManagement.Actions.PowerProfile profileChoices 2>&1

if [ "${TEST:-0}" = 1 ]; then
    echo
    echo "=== 实测三档 ==="
    PREV=$(cat "$STATE" 2>/dev/null || echo balanced)
    echo "原方案：$PREV"
    set_profile power-saver
    set_profile performance
    set_profile balanced
    set_profile "$PREV"
    echo
    echo "已恢复 $PREV"
fi
