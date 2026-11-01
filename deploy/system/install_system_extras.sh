#!/bin/bash
# Install the system-level fixes that came after the rootfs payload: modprobe quirks,
# udev rules, the UFS runtime-PM unit, volume-key swap and the CJK font preference.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

echo "== modprobe / udev / fonts"
install -Dm644 "$D/qcom-battmgr-current.conf" /etc/modprobe.d/qcom-battmgr-current.conf
install -Dm644 "$D/10-fastrpc.rules" /etc/udev/rules.d/10-fastrpc.rules
install -Dm644 "$D/90-tb-backlight.rules" /etc/udev/rules.d/90-tb-backlight.rules
install -Dm644 "$D/local.conf" /etc/fonts/local.conf

echo "== units"
install -Dm644 "$D/tb-ufs-pm.service" /etc/systemd/system/tb-ufs-pm.service
install -Dm644 "$D/tb-volume-swap.service" /etc/systemd/system/tb-volume-swap.service

if command -v cc >/dev/null 2>&1; then
  cc -O2 -Wall -o /usr/local/sbin/tb-volume-swap "$D/tb-volume-swap.c"
  chmod 0755 /usr/local/sbin/tb-volume-swap
else
  echo "!! cc not found - install gcc, then re-run this script for the volume-key swap"
fi

systemctl daemon-reload
systemctl enable --now tb-ufs-pm.service
if [ -x /usr/local/sbin/tb-volume-swap ]; then
  systemctl enable --now tb-volume-swap.service
fi
udevadm control --reload || true
fc-cache -f >/dev/null 2>&1 || true
echo "done - the qcom_battmgr option applies on the next module load (or reboot)"
