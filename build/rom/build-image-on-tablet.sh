#!/bin/bash
# build-image-on-tablet.sh - build the clean, first-boot Arch rootfs image ON the
# TB710FU itself (native aarch64, no qemu, no NBD).  Run as root on the tablet.
#
# It never writes the UFS: the whole build happens in a 22 GiB sparse file under
# /root/rom-build, mounted through a loop device.
#
# Inputs (put them in /root/rom-stage):
#   boot/boot_arch.img boot/boot_zui.img boot/boot_single.img
#   tb-install-run tb-installer.service clean-rootfs.sh
#   steam.desktop tb-als-toggle.desktop tb-als-toggle.png
#
# Output: /root/rom-build/arch-root.img (ext4 LABEL=arch-root)
set -euo pipefail

IMG=${IMG:-/root/rom-build/arch-root.img}
SIZE=${SIZE:-22G}
MNT=${MNT:-/mnt/build}
STAGE=${STAGE:-/root/rom-stage}
LIVE_HOME=/home/alarm

say() { echo "== $*"; }
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
for f in "$STAGE"/boot/boot_arch.img "$STAGE"/boot/boot_zui.img \
         "$STAGE"/boot/boot_single.img "$STAGE"/clean-rootfs.sh \
         "$STAGE"/tb-install-run "$STAGE"/tb-installer.service; do
  [ -f "$f" ] || { echo "missing staging file: $f"; exit 1; }
done

say "detach a previous build image"
for l in $(losetup -j "$IMG" 2>/dev/null | cut -d: -f1); do
  umount "$MNT" 2>/dev/null || true
  losetup -d "$l" 2>/dev/null || true
done
umount "$MNT" 2>/dev/null || true
rm -f "$IMG"
mkdir -p "$(dirname "$IMG")" "$MNT"

say "create $SIZE ext4 image"
truncate -s "$SIZE" "$IMG"
mkfs.ext4 -q -F -L arch-root "$IMG"
LOOP=$(losetup -f --show "$IMG")
mount -o noatime "$LOOP" "$MNT"

cleanup() {
  for d in run dev sys proc; do umount "$MNT/$d" 2>/dev/null || true; done
  umount "$MNT" 2>/dev/null || true
  losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

say "copy the live root (personal data and build-only trees excluded)"
rsync -aHAXx --numeric-ids --stats \
  --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run \
  --exclude=/tmp --exclude=/var/tmp --exclude=/mnt --exclude=/media \
  --exclude=/home/alarm --exclude=/root --exclude=/opt \
  --exclude=/var/cache --exclude=/var/log \
  --exclude=/var/lib/droidloom/users --exclude=/var/lib/flatpak \
  --exclude=/var/lib/NetworkManager --exclude=/var/lib/bluetooth \
  --exclude=/var/lib/upower --exclude=/var/lib/AccountsService \
  --exclude=/var/lib/colord --exclude=/var/lib/geoclue \
  --exclude=/var/lib/Steamcommunity_302 \
  --exclude=/var/lib/systemd/random-seed \
  --exclude=/etc/ssh/ssh_host_\* --exclude=/etc/machine-id \
  --exclude=/boot/Image --exclude=/boot/Image.gz \
  --exclude=/boot/initramfs-linux.img --exclude=/boot/dtbs --exclude=/boot/tbboot \
  --exclude=/usr/lib/libreoffice --exclude=/usr/lib/vlc \
  --exclude=/usr/share/doc --exclude=/usr/share/man \
  --exclude=/usr/local/zig-aarch64-linux-0.17.0 \
  --exclude=/usr/local/obs --exclude=/usr/local/obs-ffmpeg-mux \
  --exclude=/usr/local/lib/obs\* --exclude=/usr/local/share/obs \
  --exclude='*.bak-*' --exclude='*.official-*' --exclude='__pycache__' \
  / "$MNT/"

say "install the installer and final boot images"
install -Dm755 "$STAGE/tb-install-run" "$MNT/usr/local/sbin/tb-install-run"
install -Dm644 "$STAGE/tb-installer.service" "$MNT/etc/systemd/system/tb-installer.service"
install -d "$MNT/boot/tbboot"
for v in arch zui single; do
  install -m644 "$STAGE/boot/boot_$v.img" "$MNT/boot/tbboot/boot_$v.img"
  (cd "$MNT/boot/tbboot" && sha256sum "boot_$v.img" > "boot_$v.img.sha256")
done
# tbboot: also allow selecting the single-system image
sed -i 's/for v in zui arch; do/for v in zui arch single; do/; s/zui|arch) install_variant/zui|arch|single) install_variant/; s/\[zui|arch|status\]/[zui|arch|single|status]/' \
  "$MNT/usr/local/sbin/tbboot"

say "run the chroot cleanup"
install -d -m 700 "$MNT/root"
install -d -m 755 "$MNT/proc" "$MNT/sys" "$MNT/dev" "$MNT/run" "$MNT/tmp" "$MNT/var/tmp"
cp "$STAGE/clean-rootfs.sh" "$MNT/root/clean-rootfs.sh"
mount --bind /proc "$MNT/proc"
mount --bind /sys "$MNT/sys"
mount --bind /dev "$MNT/dev"
mount --bind /run "$MNT/run"
chroot "$MNT" /bin/bash /root/clean-rootfs.sh
rm -f "$MNT/root/clean-rootfs.sh"

say "copy the Steam client tree (games/account data excluded)"
install -d -o 1000 -g 1000 "$MNT/home/alarm/.local/share/Steam"
rsync -aHAX --numeric-ids \
  --exclude=steamapps --exclude=appcache --exclude=config \
  --exclude=logs --exclude=userdata --exclude=dumps --exclude=depotcache \
  --exclude='ssfn*' --exclude=steam.token --exclude=registry.vdf \
  --exclude='*.vdf' \
  "$LIVE_HOME/.local/share/Steam/" "$MNT/home/alarm/.local/share/Steam/"
install -d -o 1000 -g 1000 "$MNT/home/alarm/.local/share/Steam/steamapps"

say "Steam / ALS desktop entries"
if [ -f "$STAGE/steam.desktop" ]; then
  install -Dm644 "$STAGE/steam.desktop" "$MNT/usr/share/applications/steam.desktop"
fi
if [ -f "$STAGE/tb-als-toggle.desktop" ]; then
  install -Dm644 "$STAGE/tb-als-toggle.desktop" "$MNT/usr/share/applications/tb-als-toggle.desktop"
fi
if [ -f "$STAGE/tb-als-toggle.png" ]; then
  install -Dm644 "$STAGE/tb-als-toggle.png" "$MNT/usr/local/share/icons/tb-als-toggle.png"
fi
install -d -o 1000 -g 1000 "$MNT/home/alarm/.steam"
for pair in \
  "root:/home/alarm/.local/share/Steam" \
  "steam:/home/alarm/.local/share/Steam" \
  "bin32:/home/alarm/.local/share/Steam/ubuntu12_32" \
  "bin64:/home/alarm/.local/share/Steam/ubuntu12_64" \
  "bin:/home/alarm/.local/share/Steam/ubuntu12_32" \
  "sdk32:/home/alarm/.local/share/Steam/linux32" \
  "sdk64:/home/alarm/.local/share/Steam/linux64" \
  "sdkarm64:/home/alarm/.local/share/Steam/linuxarm64"; do
  name=${pair%%:*}; target=${pair#*:}
  ln -sfn "$target" "$MNT/home/alarm/.steam/$name"
  chown -h 1000:1000 "$MNT/home/alarm/.steam/$name"
done
chown -R 1000:1000 "$MNT/home/alarm/.local/share/Steam" "$MNT/home/alarm/.steam"

say "final sanity checks"
[ -x "$MNT/usr/local/sbin/tb-install-run" ] || { echo "installer missing"; exit 1; }
[ -f "$MNT/boot/tbboot/boot_arch.img" ] || { echo "boot_arch missing"; exit 1; }
[ -f "$MNT/boot/tbboot/boot_single.img" ] || { echo "boot_single missing"; exit 1; }
[ -x "$MNT/usr/bin/gnome-shell" ] || { echo "GNOME Shell missing"; exit 1; }
[ -x "$MNT/usr/bin/gnome-control-center" ] || { echo "GNOME Settings missing"; exit 1; }
[ -x "$MNT/usr/bin/gdm" ] || { echo "gdm missing"; exit 1; }
[ -x "$MNT/usr/bin/droidloomd" ] || { echo "droidloom missing"; exit 1; }
[ -x "$MNT/usr/bin/shelly-ui" ] || { echo "Shelly missing"; exit 1; }
[ -x "$MNT/usr/local/bin/tb-power-key" ] || { echo "power-key daemon missing"; exit 1; }
[ -f "$MNT/usr/local/lib/libtb-refreshcap.so" ] || { echo "refresh shim missing"; exit 1; }
[ -x "$MNT/usr/local/bin/tb-background-trim" ] || { echo "background trim missing"; exit 1; }
[ -d "$MNT/usr/share/gnome-shell/extensions/tb-power-menu@tb710fu" ] || { echo "power menu extension missing"; exit 1; }
[ -d "$MNT/usr/share/gnome-shell/extensions/tb-display-mode@tb710fu" ] || { echo "refresh tile missing"; exit 1; }
[ -d "$MNT/home/alarm/.local/share/Steam" ] || { echo "Steam missing"; exit 1; }
[ -s "$MNT/home/alarm/.config/mimeapps.list" ] || { echo "mimeapps missing"; exit 1; }
[ ! -e "$MNT/etc/ssh/ssh_host_ed25519_key" ] || { echo "ssh host key leaked"; exit 1; }
[ ! -d "$MNT/home/alarm/.mozilla" ] || { echo "Firefox profile leaked"; exit 1; }
[ ! -e "$MNT/home/alarm/.ssh/id_ed25519" ] || { echo "user SSH key leaked"; exit 1; }
grep -q '^LABEL=arch-root' "$MNT/etc/fstab" || { echo "bad fstab"; exit 1; }

sync
umount "$MNT/run" "$MNT/dev" "$MNT/sys" "$MNT/proc" 2>/dev/null || true
umount "$MNT"
losetup -d "$LOOP"
trap - EXIT
sync
echo
echo "IMAGE-OK $IMG"
du -sh "$IMG"
df -h "$IMG"
sha256sum "$IMG"
