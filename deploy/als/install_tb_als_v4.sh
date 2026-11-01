#!/bin/bash
# 安装亮度学习版（在平板上以 root 运行）。
# TEST=1 会等过 8 秒学习预热后，模拟一次手动调亮并检查是否学习。
set -eu
export LC_ALL=C
SRC=/root/tb-als-deploy
PROFILE=/home/alarm/.config/tb-als-profile.json
BC=/org/kde/Solid/PowerManagement/Actions/BrightnessControl
BI=org.kde.Solid.PowerManagement.Actions.BrightnessControl
A() { runuser -u alarm -- env XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "$@"; }
get_b() { A busctl --user call org.kde.Solid.PowerManagement "$BC" "$BI" brightness 2>/dev/null | awk '{print $2}' || true; }
set_b() { A busctl --user call org.kde.Solid.PowerManagement "$BC" "$BI" setBrightness i "$1"; }

echo "=== 安装守护与 CLI ==="
install -m 755 "$SRC/tb-als-daemon.py" /usr/local/bin/tb-als-daemon
install -m 755 "$SRC/tb-als" /usr/local/bin/tb-als
bash -n /usr/local/bin/tb-als && echo "shell 语法 OK"
/usr/local/bin/tb-als-daemon --simulate | tail -4
if [ -f "$PROFILE" ]; then
    chown alarm:alarm "$PROFILE"
fi

echo "=== 安装单元与菜单项 ==="
install -d /etc/systemd/user
install -m 644 "$SRC/tb-als.service" /etc/systemd/user/tb-als.service
install -m 644 "$SRC/tb-als-greeter.service" /etc/systemd/system/tb-als-greeter.service
install -d -o alarm -g alarm /home/alarm/.local/share/applications
install -m 644 -o alarm -g alarm "$SRC/tb-als-toggle.desktop" \
    /home/alarm/.local/share/applications/tb-als-toggle.desktop
mkdir -p /etc/systemd/user/plasma-workspace.target.wants
ln -sfn /etc/systemd/user/tb-als.service \
    /etc/systemd/user/plasma-workspace.target.wants/tb-als.service
systemctl daemon-reload
systemctl enable tb-als-greeter.service >/dev/null 2>&1 || true

echo
echo "=== 重启服务 ==="
systemctl restart tb-als-greeter.service
A systemctl --user daemon-reload
A systemctl --user restart tb-als.service
sleep 2
echo "user: $(A systemctl --user is-active tb-als.service)"
echo "greeter: $(systemctl is-active tb-als-greeter.service)"
A /usr/local/bin/tb-als status || true

if [ "${TEST:-0}" = 1 ]; then
    echo
    echo "=== 学习功能实测（等待 10 秒预热）==="
    sleep 10
    if [ -f "$PROFILE" ]; then
        cp "$PROFILE" /tmp/tb-als-profile.bak
    else
        rm -f /tmp/tb-als-profile.bak
    fi
    CUR=$(get_b)
    if [ -z "$CUR" ]; then
        echo "读不到当前亮度，跳过实测"
    elif [ "$CUR" -lt 8500 ]; then
        TESTVAL=$((CUR + 1500))
    else
        TESTVAL=$((CUR - 1500))
    fi
    if [ -n "${TESTVAL:-}" ]; then
        echo "当前 $CUR，模拟手动调到 $TESTVAL"
        A busctl --user call org.kde.screensaver /ScreenSaver \
            org.freedesktop.ScreenSaver SimulateUserActivity >/dev/null 2>&1 || true
        set_b "$TESTVAL"
        sleep 3
        NOW=$(get_b)
        echo "3 秒后亮度: $NOW（应保持 $TESTVAL，而不是回落到曲线值）"
        A journalctl --user-unit=tb-als.service --since '-20 s' --no-pager | tail -8
        if A journalctl --user-unit=tb-als.service --since '-20 s' --no-pager | grep -q '已学习'; then
            echo "学习：OK"
        else
            echo "学习：未触发（看上面的日志）"
        fi
        if [ -f /tmp/tb-als-profile.bak ]; then
            mv /tmp/tb-als-profile.bak "$PROFILE"
            chown alarm:alarm "$PROFILE"
        else
            rm -f "$PROFILE"
        fi
        A systemctl --user restart tb-als.service
        sleep 3
        echo "已恢复测试前的学习数据"
    fi
fi
