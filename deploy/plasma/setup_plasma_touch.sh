#!/bin/bash
# Install the Plasma first-login touch-scaling helper (runs on the tablet as root).
set -e
install -o root  -g root  -m 755 /tmp/tb-plasma-touch-defaults /usr/local/bin/tb-plasma-touch-defaults
install -d -o alarm -g alarm -m 755 /home/alarm/.config/autostart
install -o alarm -g alarm -m 644 /tmp/tb-plasma-touch-defaults.desktop \
    /home/alarm/.config/autostart/tb-plasma-touch-defaults.desktop
rm -f /tmp/tb-plasma-touch-defaults /tmp/tb-plasma-touch-defaults.desktop
echo "=== 安装结果 ==="
ls -l /usr/local/bin/tb-plasma-touch-defaults \
      /home/alarm/.config/autostart/tb-plasma-touch-defaults.desktop
echo
echo "=== 当前缩放（内屏） ==="
runuser -u alarm -- env XDG_RUNTIME_DIR=/run/user/1000 kscreen-doctor -o 2>/dev/null \
    | grep -A3 -E '^Output: .*DSI' | head -8 || true
