#!/bin/bash
# clean-rootfs.sh - turn a copy of the live TB710FU Arch + GNOME system into a
# distributable first-boot image.  Run as root INSIDE the image chroot (the
# tablet can run it natively; no qemu).
#
# The caller has already:
#   * rsynced the live root into the image with the personal-data excludes
#   * copied /home/alarm/.local/share/Steam (games/account data excluded)
#   * copied boot_arch.img / boot_zui.img / boot_single.img to /boot/tbboot
#   * copied tb-install-run and tb-installer.service into place
set -euo pipefail

export LANG=C
export LC_ALL=C
export HOME=/root

say() { echo "== $*"; }

say "remove applications and build-only packages"
# linux-firmware is a dependency of linux-aarch64 in some trees; keep it explicit.
pacman -D --asexplicit linux-firmware diffutils kmod file findutils gawk grep gzip sed tar coreutils util-linux systemd >/dev/null 2>&1 || true
pkgs="
linux-latest linux-aarch64
linuxqq wechat-bin
libreoffice-fresh-zh-cn libreoffice-fresh
mpv
cmake gcc make meson ninja rust go fakeroot pkgconf intltool
extra-cmake-modules gobject-introspection nlohmann-json
dart
"
for p in $pkgs; do
  pacman -Qq "$p" >/dev/null 2>&1 || continue
  pacman -Rns --noconfirm "$p" || echo "   kept $p (required by something else)"
done
for p in $(pacman -Qq | grep '^vlc' || true); do
  pacman -Rns --noconfirm "$p" || echo "   kept $p"
done
# Second pass: the first pacman loop can lose a transaction to a hook/post-transaction
# failure.  These are pure build tools and are safe to retry.
for p in cmake gcc make meson ninja rust go fakeroot pkgconf intltool \
         extra-cmake-modules gobject-introspection nlohmann-json patch lsof strace bc; do
  pacman -Qq "$p" >/dev/null 2>&1 || continue
  pacman -Rns --noconfirm "$p" >/dev/null 2>&1 || true
done

# Do NOT mass-remove orphans: Shelly and the port binaries were installed by hand, so
# pacman does not know their runtime libraries are still needed.  Leftovers are small.
pacman -Qtdq 2>/dev/null | sed "s/^/   orphan (kept): /" || true

say "remove documentation and non-zh/en locales"
rm -rf /usr/share/doc /usr/share/man /usr/share/gtk-doc /usr/share/help
find /usr/share/locale -mindepth 1 -maxdepth 1 \
  ! -name 'zh*' ! -name 'en*' ! -name 'locale.alias' -exec rm -rf {} + 2>/dev/null || true

say "remove dev/build leftovers and non-base apps"
rm -rf /usr/local/zig-aarch64-linux-0.17.0 /usr/local/zig
rm -f  /usr/local/bin/zig
rm -rf /usr/local/obs /usr/local/obs-ffmpeg-mux /usr/local/bin/obs /usr/local/bin/obs-ffmpeg-mux
rm -rf /usr/local/lib/obs* /usr/local/share/obs /usr/local/share/metainfo
rm -f /usr/local/bin/gnome-control-center /usr/local/lib/tb-about-gpu.so /usr/local/lib/tb-cpuinfo.so
rm -f /usr/local/bin/hexagonrpcd-v /usr/local/bin/tb-als-daemon \
       /usr/local/bin/tb-als-daemon.kde.bak-* /usr/local/sbin/*.bak-*
rm -rf /usr/src/*
rm -rf /opt/*
rm -rf /var/lib/flatpak /var/lib/Steamcommunity_302
rm -rf /etc/systemd/system/s302-1000.service /etc/systemd/system/s302-1000.service.d
rm -f  /etc/systemd/system/multi-user.target.wants/s302-1000.service
rm -rf /home/alarm/.local/share/Steamcommunity_302

say "clear personal/runtime state"
rm -rf /var/lib/bluetooth/* /var/lib/NetworkManager/* /var/lib/upower/* \
       /var/lib/AccountsService/* /var/lib/colord/* /var/lib/geoclue/* \
       /var/lib/gdm/* /var/lib/localsearch/* /var/lib/localsearch3/* \
       /var/lib/tracker3/* /var/lib/PackageKit/* /var/lib/gnome-remote-desktop/* \
       /var/lib/systemd/coredump/* /var/lib/systemd/rfkill/* \
       /var/lib/tb-powerprofiles/* 2>/dev/null || true
# rm -rf .../* leaves dotfiles behind; gdm keeps .config/monitors.xml and a
# .migrated-dyn-users marker there.
find /var/lib/gdm -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
find /var/lib/droidloom/users -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
rm -rf /var/lib/droidloom/users/*
mkdir -p /var/lib/droidloom/users
rm -rf /var/log/* /var/cache/* /var/tmp/* /tmp/* 2>/dev/null || true
mkdir -p /var/log /var/cache/pacman/pkg /var/tmp /tmp
chmod 1777 /var/tmp /tmp
rm -f /var/lib/systemd/random-seed
rm -rf /etc/NetworkManager/system-connections/*
rm -f /etc/ssh/ssh_host_*
rm -f /etc/machine-id
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
[ -d /var/lib/dbus ] && ln -sfn /etc/machine-id /var/lib/dbus/machine-id
rm -rf /root/*
rm -f /etc/systemd/user/tb-als.service
rm -f /etc/systemd/user/graphical-session.target.wants/tb-als.service
rm -f /etc/systemd/user/tb-als.service.kde.bak-*

say "hostname, hosts, fstab, locale"
echo tb710fu > /etc/hostname
grep -q steamloopback.host /etc/hosts || echo '127.0.0.1 steamloopback.host' >> /etc/hosts
printf 'LABEL=arch-root  /  ext4  rw,noatime  0 1\n' > /etc/fstab
# The GNOME session uses the Chinese locale on this port; keep it.
grep -q '^LANG=zh_CN.UTF-8' /etc/locale.conf 2>/dev/null || echo 'LANG=zh_CN.UTF-8' > /etc/locale.conf

say "pacman: keep the custom kernel out, allow pacman 7 on a kernel without Landlock"
if ! grep -q '^IgnorePkg .*linux-aarch64' /etc/pacman.conf; then
  printf '\n# TB710FU: the kernel comes from boot_a (kShimC), not pacman.\nIgnorePkg = linux-aarch64 linux-latest linux-api-headers\n' >> /etc/pacman.conf
fi
if ! grep -q '^DisableSandbox$' /etc/pacman.conf; then
  sed -i '0,/^\[options\]/s//[options]\nDisableSandbox/' /etc/pacman.conf
fi

say "reset passwords (documented default: tb710fu; change after first login)"
echo 'root:tb710fu' | chpasswd
echo 'alarm:tb710fu' | chpasswd
usermod -aG wheel,video,audio alarm 2>/dev/null || usermod -aG wheel,video alarm

say "GNOME system defaults (extensions, power button, idle)"
install -d -m 755 /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/00-tb-power <<'EOF'
[org/gnome/desktop/session]
idle-delay=uint32 300
[org/gnome/desktop/screensaver]
lock-enabled=true
lock-delay=uint32 0
[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
power-button-action='nothing'
[org/gnome/shell]
favorite-apps=['firefox.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Settings.desktop', 'org.gnome.Console.desktop', 'com.shellyorg.shelly.desktop', 'steam.desktop']
[org/gnome/desktop/interface]
show-battery-percentage=true
EOF
cat > /etc/dconf/db/local.d/10-tb-shell <<'EOF'
[org/gnome/shell]
enabled-extensions=['tb-als@tb710fu', 'tb-rotate-anim@tb710fu', 'tb-android-windows@tb710fu', 'tb-display-mode@tb710fu', 'tb-power-menu@tb710fu']
EOF
dconf update

say "fresh alarm home"
install -d -m 700 /root
install -d -m 755 /opt /boot/tbboot
install -d -m 755 /var/lib/droidloom/users/1000
install -d -m 700 /var/lib/droidloom/users/1000/data
rm -rf /home/alarm
install -d -o alarm -g alarm -m 700 /home/alarm
cp -a /etc/skel/.bash_logout /etc/skel/.bash_profile /etc/skel/.bashrc /home/alarm/ 2>/dev/null || true
install -d -o alarm -g alarm -m 755 \
  /home/alarm/.config /home/alarm/.local/share /home/alarm/.local/state \
  /home/alarm/.cache /home/alarm/.ssh \
  /home/alarm/下载 /home/alarm/文档 /home/alarm/图片 /home/alarm/音乐 \
  /home/alarm/视频 /home/alarm/桌面 /home/alarm/模板 /home/alarm/公共 /home/alarm/项目
install -d -o alarm -g alarm -m 755 \
  /home/alarm/.config/systemd/user/graphical-session.target.wants \
  /home/alarm/.local/share/applications
# tb-power-key and tb-background-trim are enabled system-wide (/etc/systemd/user),
# so a fresh home does not need per-user symlinks.
printf 'adaptive\n' > /home/alarm/.config/tb-display-mode
# The built-in panel is 3200x2000; GNOME must start at scale 2 or the first
# login looks like a phone UI on a 14" screen.  This is the panel's own EDID
# identity, not user data.
cat > /home/alarm/.config/monitors.xml <<'EOF'
<monitors version="2">
  <configuration>
    <layoutmode>logical</layoutmode>
    <logicalmonitor>
      <x>0</x>
      <y>0</y>
      <scale>2</scale>
      <primary>yes</primary>
      <monitor>
        <monitorspec>
          <connector>DSI-1</connector>
          <vendor>LEN</vendor>
          <product>unknown</product>
          <serial>unknown</serial>
        </monitorspec>
        <mode>
          <width>3200</width>
          <height>2000</height>
          <rate>120.000</rate>
        </mode>
      </monitor>
    </logicalmonitor>
  </configuration>
  <configuration>
    <layoutmode>physical</layoutmode>
    <logicalmonitor>
      <x>0</x>
      <y>0</y>
      <scale>2</scale>
      <primary>yes</primary>
      <monitor>
        <monitorspec>
          <connector>DSI-1</connector>
          <vendor>LEN</vendor>
          <product>unknown</product>
          <serial>unknown</serial>
        </monitorspec>
        <mode>
          <width>3200</width>
          <height>2000</height>
          <rate>120.000</rate>
        </mode>
      </monitor>
    </logicalmonitor>
  </configuration>
  <configuration>
    <layoutmode>logical</layoutmode>
    <logicalmonitor>
      <x>0</x>
      <y>0</y>
      <scale>2</scale>
      <primary>yes</primary>
      <monitor>
        <monitorspec>
          <connector>DSI-1</connector>
          <vendor>unknown</vendor>
          <product>unknown</product>
          <serial>unknown</serial>
        </monitorspec>
        <mode>
          <width>3200</width>
          <height>2000</height>
          <rate>120.000</rate>
        </mode>
      </monitor>
    </logicalmonitor>
  </configuration>
</monitors>
EOF

cat > /home/alarm/.config/mimeapps.list <<'EOF'
[Default Applications]
application/vnd.android.package-archive=org.droidloom.ApkInstaller.desktop
text/html=firefox.desktop
inode/directory=org.gnome.Nautilus.desktop
EOF
chown -R alarm:alarm /home/alarm/.config /home/alarm/.local /home/alarm/.cache /home/alarm/.ssh
chmod 600 /home/alarm/.config/monitors.xml /home/alarm/.config/tb-display-mode
chown alarm:alarm /home/alarm/.bash_logout /home/alarm/.bash_profile /home/alarm/.bashrc 2>/dev/null || true

say "enable first-boot units"
systemctl enable tb-installer.service >/dev/null 2>&1 || true
# SSH stays off by default; the default password is public.  The key generator
# stays enabled so the user only needs "systemctl enable --now sshd" later.
systemctl enable sshdgenkeys.service >/dev/null 2>&1 || true
systemctl disable sshd.service >/dev/null 2>&1 || true
# The installed system does not need the USB-NCM debug gadget (the installer
# initramfs has its own copy); keep the units, just do not start them.
systemctl disable tb-usb-ncm-watch.service tb-usb-ncm.service >/dev/null 2>&1 || true
# Not used by this image (normal /home/alarm).
systemctl disable systemd-homed.service systemd-homed-activate.service >/dev/null 2>&1 || true
# The 1 Hz debug watcher (loginctl every second) must not ship.
systemctl disable tb-display-watch.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/multi-user.target.wants/tb-display-watch.service \
      /etc/systemd/system/tb-display-watch.service

# Global user services: power key, background trim.  tb-als is the GNOME shell
# extension now; the old /usr/local/bin/tb-als-daemon unit was removed above.
systemctl --global enable tb-power-key.service tb-background-trim.timer >/dev/null 2>&1 || true
systemctl --global disable tb-als.service >/dev/null 2>&1 || true

say "installer script and boot variants must be executable/verifiable"
chmod 0755 /usr/local/sbin/tb-install-run
for v in arch zui single; do
  if [ -f /boot/tbboot/boot_$v.img ]; then
    (cd /boot/tbboot && sha256sum boot_$v.img > boot_$v.img.sha256)
  fi
done

say "sanity checks"
[ -x /usr/local/sbin/tb-install-run ] || { echo "missing installer"; exit 1; }
[ -f /boot/tbboot/boot_arch.img ] || { echo "missing boot_arch"; exit 1; }
[ -f /boot/tbboot/boot_single.img ] || { echo "missing boot_single"; exit 1; }
[ -f /etc/systemd/system/tb-installer.service ] || { echo "missing unit"; exit 1; }
[ -x /usr/bin/gnome-shell ] || { echo "missing GNOME Shell"; exit 1; }
[ -x /usr/bin/gnome-control-center ] || { echo "missing GNOME Settings"; exit 1; }
[ -x /usr/bin/gdm ] || { echo "missing gdm"; exit 1; }
[ -x /usr/bin/firefox ] || { echo "missing Firefox"; exit 1; }
[ -x /usr/bin/nautilus ] || { echo "missing Nautilus"; exit 1; }
[ -x /usr/bin/shelly-ui ] || { echo "missing Shelly"; exit 1; }
[ -x /usr/bin/droidloomd ] || { echo "missing droidloom"; exit 1; }
[ -x /usr/bin/droidloom-wayland ] || { echo "missing droidloom-wayland"; exit 1; }
[ -x /usr/local/bin/tb-power-key ] || { echo "missing power-key daemon"; exit 1; }
[ -f /usr/local/lib/libtb-refreshcap.so ] || { echo "missing refresh shim"; exit 1; }
[ -f /etc/systemd/user/org.gnome.Shell@user.service.d/tb-refreshcap.conf ] || {
  echo "missing refresh drop-in"; exit 1; }
[ -f /etc/udev/rules.d/70-tb-pwrkey-uaccess.rules ] || { echo "missing pwrkey rule"; exit 1; }
[ -d /usr/share/gnome-shell/extensions/tb-power-menu@tb710fu ] || { echo "missing power menu"; exit 1; }
[ -d /usr/share/gnome-shell/extensions/tb-display-mode@tb710fu ] || { echo "missing refresh tile"; exit 1; }
[ -d /usr/share/gnome-shell/extensions/tb-android-windows@tb710fu ] || { echo "missing Android windows"; exit 1; }
[ -d /usr/share/gnome-shell/extensions/tb-als@tb710fu ] || { echo "missing ALS extension"; exit 1; }
[ -d /usr/share/gnome-shell/extensions/tb-rotate-anim@tb710fu ] || { echo "missing rotation extension"; exit 1; }
[ -x /usr/local/bin/tb-background-trim ] || { echo "missing background trim"; exit 1; }
[ -f /etc/sysctl.d/91-tb-performance.conf ] || { echo "missing VM tuning"; exit 1; }
[ -f /etc/dconf/db/local.d/00-tb-power ] || { echo "missing dconf defaults"; exit 1; }
[ ! -e /etc/ssh/ssh_host_ed25519_key ] || { echo "ssh host key leaked"; exit 1; }
[ ! -d /home/alarm/.mozilla ] || { echo "Firefox profile leaked"; exit 1; }
[ ! -e /home/alarm/.ssh/id_ed25519 ] || { echo "user SSH key leaked"; exit 1; }
grep -q '^LABEL=arch-root' /etc/fstab || { echo "bad fstab"; exit 1; }

say "normalize world-writable directories (the live /usr was 777)"
find / -xdev -type d -perm -0002 ! -path /tmp ! -path /var/tmp -exec chmod go-w {} + 2>/dev/null || true
chmod 1777 /tmp /var/tmp
ln -sfn /proc/self/mounts /etc/mtab
ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
rm -rf /var/log/*

say "clean"
sync
echo "CLEAN-OK"
