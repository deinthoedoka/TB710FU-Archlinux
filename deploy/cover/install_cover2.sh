#!/bin/bash
set -e
install -o root -g root -m 755 /tmp/tb-cover-daemon /usr/local/bin/tb-cover-daemon
install -o root -g root -m 644 /tmp/tb-cover-daemon.service /etc/systemd/system/tb-cover-daemon.service
rm -f /tmp/tb-cover-daemon /tmp/tb-cover-daemon.service
pkill -f gpio_hall_test.py 2>/dev/null || true
pkill -f watch_cover_focus.py 2>/dev/null || true
systemctl daemon-reload
systemctl restart tb-cover-daemon.service
sleep 2
echo "=== 服务状态 ==="
systemctl is-active tb-cover-daemon.service
echo
echo "=== 日志 ==="
journalctl -u tb-cover-daemon.service --no-pager -n 10 | tail -10
echo
echo "=== GPIO66 现在归谁 ==="
grep -E '^ *gpio66 ' /sys/kernel/debug/gpio
