#!/bin/sh
# TB710FU phantom-key wake fix (2026-11-08) — no-reflash patch installer.
#
# Bug mitigated: the button board intermittently produces phantom keys.
# A phantom Volume-Up (gpio-keys, IRQ161 on SPMI GPIO) woke the tablet out
# of s2idle by itself; a phantom power key then lit the lock screen.  This
# patch disables gpio-keys device wakeup (Volume-Up + cover SW_LID) both at
# runtime and at every boot via a udev rule, so phantom Volume-Up can no
# longer wake the suspended tablet.  The PMIC power key keeps its wakeup
# flag, so real power-key wake is unaffected.  The cover daemon (GPIO66
# chardev) does not depend on gpio-keys wake either.
#
# It also installs tb-event-watch, a root service that records raw evdev
# events of the button devices, DPMS/bl_power transitions and the cover
# GPIO66 level to /root/event-watch/ (5 MB rotation) — evidence for the
# hardware repair (button board / flex cable).
#
# Baseline-agnostic: every target file is compared (cmp) first, only
# missing or differing files are replaced, and the replaced ones are backed
# up under /var/backups/tb710fu-phantomkey-fix/<timestamp>/ preserving
# paths.  Safe to re-run.
#
#   ./install.sh              install (needs root)
#   DRY_RUN=1 ./install.sh    print the actions without touching anything

set -eu

PKG_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FILES_DIR="$PKG_DIR/files"
BACKUP_ROOT=/var/backups/tb710fu-phantomkey-fix
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=$BACKUP_ROOT/$STAMP
GPIO_WAKE=/sys/devices/platform/gpio-keys/power/wakeup
DRY=${DRY_RUN:-0}

say() { printf '%s\n' "$*"; }

run() {
    if [ "$DRY" = "1" ]; then
        say "  [dry-run] $*"
    else
        "$@"
    fi
}

place() {
    pkg=$1; target=$2; mode=$3
    if [ -e "$target" ] && cmp -s "$pkg" "$target"; then
        say "  up-to-date: $target"
        return 0
    fi
    if [ -e "$target" ]; then
        run mkdir -p "$BACKUP_DIR$(dirname "$target")"
        run cp -a "$target" "$BACKUP_DIR$target"
        say "  backup: $target"
    fi
    run install -Dm"$mode" "$pkg" "$target"
    say "  installed: $target"
}

[ "$(id -u)" = 0 ] || { say "请用 root 运行（sudo -i 或 ssh root@）"; exit 1; }

say "== 1/4 校验补丁包完整性 =="
( cd "$PKG_DIR" && sha256sum -c SHA256SUMS --quiet ) && say "  SHA256SUMS 全部通过"

say "== 2/4 安装文件（仅替换有差异的） =="
place "$FILES_DIR/etc/udev/rules.d/70-tb-gpiokeys-nowake.rules" \
      /etc/udev/rules.d/70-tb-gpiokeys-nowake.rules 644
place "$FILES_DIR/usr/local/bin/tb-event-watch.py" \
      /usr/local/bin/tb-event-watch.py 755
place "$FILES_DIR/etc/systemd/system/tb-event-watch.service" \
      /etc/systemd/system/tb-event-watch.service 644

say "== 3/4 激活 =="
run udevadm control --reload-rules
# Runtime part of the udev rule: cut gpio-keys wakeup on the running system.
# (The rule itself handles every future boot; gpio-keys is a platform device,
# so there is no re-plug event to wait for.)
if [ -e "$GPIO_WAKE" ]; then
    CUR=$(cat "$GPIO_WAKE" 2>/dev/null || echo unknown)
    if [ "$CUR" != "disabled" ]; then
        run sh -c "echo disabled > $GPIO_WAKE"
        say "  gpio-keys wakeup: $CUR -> disabled"
    else
        say "  gpio-keys wakeup: already disabled"
    fi
else
    say "  警告: 未找到 $GPIO_WAKE（机型不符？udev 规则已装，运行时跳过）"
fi
run systemctl daemon-reload
if ! systemctl is-enabled --quiet tb-event-watch.service 2>/dev/null; then
    run systemctl enable tb-event-watch.service
fi
# restart (not start): a running unit must pick up the installed script.
run systemctl restart tb-event-watch.service

say "== 4/4 验证 =="
if python3 -c "import py_compile; py_compile.compile('/usr/local/bin/tb-event-watch.py', cfile='/tmp/.tb-event-watch.pyc', doraise=True)" 2>/dev/null; then
    say "  tb-event-watch 语法: OK"
else
    say "  错误: tb-event-watch.py 无法通过 python3 编译检查"
    exit 1
fi
rm -f /tmp/.tb-event-watch.pyc
if [ -e "$GPIO_WAKE" ]; then
    NOW=$(cat "$GPIO_WAKE")
    say "  gpio-keys wakeup: $NOW"
    [ "$NOW" = "disabled" ] || { say "  错误: gpio-keys wakeup 未变为 disabled"; exit 1; }
fi
say "  tb-event-watch: $(systemctl is-active tb-event-watch.service)"
# Show the udev rule is picked up for boot-time events (dry simulation).
if UTEST=$(udevadm test /sys/devices/platform/gpio-keys 2>&1 | grep -c "70-tb-gpiokeys-nowake.rules"); then
    [ "${UTEST:-0}" -gt 0 ] && say "  udev 规则: 已被 gpio-keys 事件命中（开机自动生效）" \
        || say "  注意: udev 模拟未命中规则（检查 /etc/udev/rules.d/70-tb-gpiokeys-nowake.rules）"
fi

say ""
say "完成。效果边界（说清楚）："
say "  挂起中的幽灵唤醒（音量加线路）-> 已切断，s2idle 不再被自己唤醒"
say "  电源键唤醒 -> 保留不变（pmic_pwrkey wakeup 仍为 enabled）"
say "  亮屏状态下幽灵电源键导致\"亮一下自灭\"-> 硬件问题，本补丁不处理（见 README）"
say "监控日志: journalctl -u tb-event-watch -f ；落盘文件 /root/event-watch/log-*.txt"
say "备份目录: $BACKUP_DIR （按原路径存放被替换的旧文件，复制回去即可回滚）"
