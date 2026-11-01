#!/bin/bash
# Read-only dump of the device configs that are not yet in the repo. No secrets:
# no Wi-Fi profiles, no keys, no user files.
set -u
for f in \
  /etc/systemd/system/tb-ufs-pm.service \
  /etc/systemd/system/tb-display-watch.service \
  /etc/systemd/system/tb-als-greeter.service \
  /etc/systemd/system/tb-cover-daemon.service \
  /etc/systemd/system/tb-gpu-boost.service \
  /etc/systemd/system/tb-powerprofiles.service \
  /etc/systemd/system/tb-volume-swap.service \
  /etc/systemd/system/hexagonrpcd-adsp-sensorspd.service \
  /etc/systemd/system/s302-1000.service \
  /etc/systemd/system/power-profiles-daemon.service \
  /etc/udev/rules.d/90-tb-backlight.rules \
  /etc/udev/rules.d/10-fastrpc.rules \
  /etc/modprobe.d/qcom-battmgr-current.conf \
  /etc/fonts/local.conf \
  /etc/tmpfiles.d/tb-mem-sleep.conf \
  /etc/systemd/logind.conf.d/tb710fu-keys.conf \
  /etc/systemd/sleep.conf.d/tb710fu-s2idle.conf \
  /etc/NetworkManager/conf.d/90-tb710fu-usb0.conf
do
  echo "===== $f"
  if [ -e "$f" ]; then cat "$f"; else echo "(missing)"; fi
  echo
done

echo "===== /usr/local/sbin listing"
ls -la /usr/local/sbin
echo
echo "===== ufs related"
grep -rln 'ufs' /usr/local/sbin /etc/systemd/system 2>/dev/null
echo
echo "===== hexagonrpcd"
ls -la /usr/local/bin/hexagonrpcd* 2>/dev/null
file /usr/local/bin/hexagonrpcd 2>/dev/null
echo
echo "===== s302"
ls -la /opt/s302 /opt/s302-* 2>/dev/null | head -20
echo
echo "===== plasmalogin kwinoutput"
cat /var/lib/plasmalogin/.config/kwinoutputconfig.json 2>/dev/null
echo
echo "===== alarm kwinoutput"
cat /home/alarm/.config/kwinoutputconfig.json 2>/dev/null
