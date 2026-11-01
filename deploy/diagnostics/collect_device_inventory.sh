#!/bin/bash
# collect_device_inventory.sh - read-only dump of what this tablet runs, used to build the
# public port repo. Prints no secrets: no connection profiles, no keys, no user files.
set -u

echo "===== identity ====="
uname -a
sed -n '1,4p' /etc/os-release
echo "hostname: $(hostname)"
echo "cmdline: $(cat /proc/cmdline)"
echo
echo "===== kernel module tree ====="
ls /lib/modules/$(uname -r)/
find /lib/modules/$(uname -r) -name '*.ko*' | grep -E 'updates|extra|tb' || true
echo
echo "===== pacman explicit ====="
pacman -Qqe | sort
echo
echo "===== pacman foreign ====="
pacman -Qqm | sort
echo
echo "===== pacman total ====="
pacman -Qq | wc -l
echo
echo "===== flatpak ====="
flatpak list --app --columns=application,origin 2>/dev/null || true
flatpak remotes 2>/dev/null || true
echo
echo "===== system services enabled ====="
systemctl list-unit-files --state=enabled --no-pager --no-legend 2>/dev/null | awk '{print $1}' | sort
echo
echo "===== user services enabled (alarm) ====="
sudo -u alarm XDG_RUNTIME_DIR=/run/user/1000 systemctl --user list-unit-files --state=enabled --no-pager --no-legend 2>/dev/null | awk '{print $1}' | sort || true
echo
echo "===== /etc/systemd/system ====="
ls -1 /etc/systemd/system/*.service /etc/systemd/system/*.timer 2>/dev/null
echo
echo "===== /usr/local/bin ====="
ls -1 /usr/local/bin
echo
echo "===== /usr/local/sbin ====="
ls -1 /usr/local/sbin 2>/dev/null
echo
echo "===== modprobe.d ====="
for f in /etc/modprobe.d/*.conf; do echo "--- $f"; cat "$f"; done 2>/dev/null
echo
echo "===== udev rules ====="
ls -1 /etc/udev/rules.d 2>/dev/null
echo
echo "===== sysctl.d ====="
ls -1 /etc/sysctl.d 2>/dev/null
echo
echo "===== tmpfiles.d ====="
ls -1 /etc/tmpfiles.d 2>/dev/null
echo
echo "===== polkit rules ====="
ls -1 /etc/polkit-1/rules.d 2>/dev/null
echo
echo "===== /etc/xdg/autostart ====="
ls -1 /etc/xdg/autostart 2>/dev/null
echo
echo "===== /etc/fonts ====="
ls -1 /etc/fonts 2>/dev/null
echo
echo "===== firmware top level ====="
ls -1 /usr/lib/firmware | head -60
echo "--- adsp/cdsp"
ls -l /usr/lib/firmware/qcom/sm8650/*adsp* /usr/lib/firmware/qcom/sm8650/*cdsp* 2>/dev/null | head
echo
echo "===== sessions ====="
ls -1 /usr/share/wayland-sessions /usr/share/xsessions 2>/dev/null
echo
echo "===== alarm config names ====="
ls -1 /home/alarm/.config 2>/dev/null | head -100
echo "--- autostart"
ls -1 /home/alarm/.config/autostart 2>/dev/null
echo "--- local/share"
ls -1 /home/alarm/.local/share 2>/dev/null
echo "--- local/bin"
ls -1 /home/alarm/.local/bin 2>/dev/null
echo
echo "===== plasmalogin config ====="
ls -1 /var/lib/plasmalogin/.config 2>/dev/null
echo
echo "===== /etc/hosts extra ====="
grep -v -E '^(#|127\.|::1|$)' /etc/hosts
echo
echo "===== pacman.conf options ====="
grep -E '^(IgnorePkg|DisableSandbox|HoldPkg|Color|ParallelDownloads)' /etc/pacman.conf
echo
echo "===== profile.d tb/steam refs ====="
grep -rn 'tb-\|s302\|steam\|fex' /etc/profile.d/ 2>/dev/null | head
echo
echo "===== user ====="
id alarm
echo
echo "===== disk ====="
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS | head -40
echo
echo "===== state ====="
systemctl is-system-running 2>/dev/null || true
systemctl --failed --no-pager --no-legend
echo
echo "===== done ====="
