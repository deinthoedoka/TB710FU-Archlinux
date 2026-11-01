#!/bin/bash
set -e
install -o root -g root -m 755 /tmp/tb-gpu-boost /usr/local/bin/tb-gpu-boost
install -o root -g root -m 644 /tmp/tb-gpu-boost.service /etc/systemd/system/tb-gpu-boost.service
rm -f /tmp/tb-gpu-boost /tmp/tb-gpu-boost.service
systemctl daemon-reload
systemctl enable tb-gpu-boost.service >/dev/null 2>&1 || true
systemctl restart tb-gpu-boost.service
sleep 2
echo "=== 服务状态 ==="
systemctl is-active tb-gpu-boost.service
echo
echo "=== 日志 ==="
journalctl -u tb-gpu-boost.service --no-pager -n 12 | tail -12
echo
echo "=== GPU 现状 ==="
G=/sys/class/devfreq/3d00000.gpu
echo "  governor=$(cat $G/governor)  polling=$(cat $G/polling_interval) ms"
echo "  min=$(cat $G/min_freq)  cur=$(cat $G/cur_freq)"
