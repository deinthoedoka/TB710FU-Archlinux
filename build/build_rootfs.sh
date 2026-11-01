#!/bin/bash
# build_rootfs.sh - build the TB710FU Arch Linux disk image used for the NBD dry run.
#
# Run as root inside a Linux build host (WSL2 Ubuntu is fine). Output is a raw
# disk image laid out like the SteamOS-ARM-Port one, because the initramfs mounts
# partition 2 of the NBD disk (nbd-client -b 512 -> MBR with 512-byte sectors):
#
#   p1  4 MiB   unused (exists so that the root is partition 2)
#   p2  rest    ext4, label arch-root, Arch Linux aarch64 + the TB710FU payload
#
# Inputs (environment):
#   OUT        output directory            (default $HOME/tb710fu/out)
#   SIZE       image size                  (default 12G)
#   BASE_TARBALL  ArchLinuxARM-aarch64 tarball (downloaded if missing)
#   MODULES_TAR   modules-7.2.6-tb710fu.tar
#   FWDIR         firmware tree (/usr/lib/firmware layout)
#   SSH_PUBKEY    key for root and the alarm user
#   BOOTDIR       dir with boot_zui.img / boot_arch.img (optional, enables tbboot)
#
# The aarch64 pacman runs under qemu-user-static (binfmt). Check with:
#   ls /proc/sys/fs/binfmt_misc/ | grep -i qemu-aarch64
set -euo pipefail
OUT=${OUT:-$HOME/tb710fu/out}
SIZE=${SIZE:-12G}
MOD=${MODULES_TAR:?set MODULES_TAR to modules-7.2.6-tb710fu.tar}
FW=${FWDIR:?set FWDIR to the firmware tree}
REPO=$(cd "$(dirname "$0")" && pwd)
IMG=$OUT/arch-nbd.img
MNT=$OUT/mnt
# staged copy first (work/fetch_deps.ps1 downloads it from the tuna mirror and hashes it)
SRCWIN=${SRCWIN:-$ARCH_ROOT/../sources}
BASE=${BASE_TARBALL:-$OUT/ArchLinuxARM-aarch64-latest.tar.gz}
MIRROR=${MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/\$arch/\$repo}

mkdir -p "$OUT" "$MNT"
if [ ! -f "$BASE" ] && [ -f "$SRCWIN/ArchLinuxARM-aarch64.tar.gz" ]; then
  cp "$SRCWIN/ArchLinuxARM-aarch64.tar.gz" "$BASE"
  LINE=$(tr -d '\r' < "$SRCWIN/deps.sha256" 2>/dev/null | grep -m1 '  ArchLinuxARM-aarch64\.tar\.gz$' || true)
  if [ -n "$LINE" ]; then
    WANT=${LINE%% *}
    GOT=$(sha256sum "$BASE" | cut -d' ' -f1)
    [ "$WANT" = "$GOT" ] || {
      echo "!! staged ArchLinuxARM tarball does not match deps.sha256 ($GOT != $WANT)"; exit 1; }
    echo "   ArchLinuxARM tarball sha256 verified"
  fi
fi
[ -f "$BASE" ] || curl -fL -o "$BASE" https://archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || {
  echo "!! qemu-aarch64 binfmt not registered. In Ubuntu: apt install qemu-user-binfmt" >&2
  exit 1
}

echo "== disk image $IMG ($SIZE), MBR with p1=4MiB, p2=root"
rm -f "$IMG"; truncate -s "$SIZE" "$IMG"
# dos (MBR) table: nbd-client reads it with -b 512, and nbdroot.sh mounts /dev/nbd0p2.
# Be explicit: `4MiB,2MiB` + `,` made sfdisk put p2 in the 1 MiB..4 MiB gap (3 MiB) and then
# the ext4 ran out of space during the base tarball extraction.
sfdisk "$IMG" <<EOF
label: dos
unit: sectors
start=2048, size=8192, type=83
start=10240, type=83
EOF
LOOP=$(losetup -f --show -P "$IMG")
mkfs.ext4 -q -F -L arch-root "${LOOP}p2"
mount -o noatime "${LOOP}p2" "$MNT"
# pacman-key leaves a gpg-agent behind that keeps /dev busy; on the way out kill whatever still
# holds the mount, then detach the loop. Kept inline (a function here somehow ended up "command
# not found" at the cleanup step) and in single quotes so $MNT/$LOOP resolve when it runs.
trap 'umount -R "$MNT" 2>/dev/null || { fuser -km -m "$MNT" 2>/dev/null; sleep 1; umount -R "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null; }; losetup -d "$LOOP" 2>/dev/null' EXIT

echo "== unpack Arch Linux ARM base"
tar xpf "$BASE" --xattrs -C "$MNT"

# Some directories come out world-writable in the image (seen: /usr, /usr/lib, /etc - pacman
# then warns "filesystem: 777 package: 755"). Nothing in this tree is writable by anyone but
# root, so normalize and report what was changed.
CHANGED=$(find "$MNT" -xdev -type d -perm -0002 2>/dev/null | tee /tmp/worldwritable.txt | wc -l)
if [ "$CHANGED" -gt 0 ]; then
  echo "   $CHANGED world-writable dirs after extraction, fixing (first 5:)"
  head -5 /tmp/worldwritable.txt | sed 's/^/     /'
  find "$MNT" -xdev -type d -perm -0002 -exec chmod go-w {} + 2>/dev/null || true
fi

echo "== chroot plumbing"
# these have to exist inside the image first - they come from the base tarball
mkdir -p "$MNT/proc" "$MNT/sys" "$MNT/dev" "$MNT/dev/pts"
for d in proc sys dev; do mount --bind "/$d" "$MNT/$d"; done
mount --bind /dev/pts "$MNT/dev/pts" 2>/dev/null || true
# pacman and gpg need DNS and /dev/urandom inside the chroot; the ALARM tarball ships
# resolv.conf as a systemd symlink
rm -f "$MNT/etc/resolv.conf"
cp /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || echo 'nameserver 1.1.1.1' > "$MNT/etc/resolv.conf"
# arch-install-scripts is an Arch package; plain chroot is equivalent here because the binds
# above are in place and the binfmt interpreter is opened by the host kernel ("F" flag).
CHROOTBIN=$(command -v arch-chroot || true)
arch() {
  if [ -n "$CHROOTBIN" ]; then "$CHROOTBIN" "$MNT" /bin/sh -c "$1"
  else chroot "$MNT" /bin/sh -c "$1"; fi
}

echo "== pacman keyring (the base tarball ships an empty one)"
# Without this every transaction fails with "keyring is not writable" / "required key missing
# from keyring". Under qemu-user the gpg calls are slow, but they do work.
arch "pacman-key --init" || echo "!! pacman-key --init failed"
arch "pacman-key --populate archlinuxarm" || echo "!! pacman-key --populate failed"
arch "pacman-key --list-keys" >/dev/null 2>&1 || echo "!! keyring still not usable"

# pacman 7 sandboxes downloads with Landlock and drops to the 'alpm' user. Under qemu-user in a
# chroot neither works (the WSL kernel has no Landlock here, and a qemu process cannot switch to
# an account that has no passwd entry in the image), so the build disables the sandbox and puts
# the stock config back before the image is closed.
grep -q '^DisableSandbox$' "$MNT/etc/pacman.conf" || \
  sed -i '0,/^\[options\]/s//[options]\nDisableSandbox/' "$MNT/etc/pacman.conf"
grep -q '^DisableSandbox$' "$MNT/etc/pacman.conf" || { echo "!! could not disable pacman sandbox"; exit 1; }

echo "== mirror + base packages (under qemu-user binfmt)"
cat > "$MNT/etc/pacman.d/mirrorlist" <<EOF
Server = $MIRROR
EOF
# Do NOT copy a qemu binary into the image: the binfmt interpreter from qemu-user-binfmt is
# opened with the "F" flag, so the kernel keeps it and aarch64 binaries run after chroot. A copy
# at /usr/bin/qemu-aarch64-static collides with the qemu-user-static package and makes pacman
# abort the whole transaction with "conflicting files".

arch "pacman -Sy --noconfirm"
# Install in stages. One transaction for everything means a single unresolvable package kills
# the whole install; staging keeps the base system and the desktop usable and makes whatever
# is missing visible.
install_group() {  # install_group <label> <packages...>
  local label=$1; shift
  echo "-- $label"
  arch "pacman -S --noconfirm --needed $*" || echo "!! $label: some packages did not install"
}
# linux-firmware's per-vendor split packages overlap each other under /usr/lib/firmware
# (linux-firmware-amd vs linux-firmware-other both ship amd/amd_sev_*.sbin), which aborts the
# whole transaction. Those paths are exactly the ones install_payload.sh rewrites anyway.
install_group core     base busybox dnsmasq openssh networkmanager wpa_supplicant iw \
                       sudo libdrm python alsa-utils
echo "-- core (firmware)"
arch "pacman -S --noconfirm --needed --overwrite '/usr/lib/firmware/*' linux-firmware" \
  || echo "!! core (firmware): some packages did not install"
install_group graphics mesa vulkan-freedreno libva-utils
install_group audio    pipewire wireplumber pipewire-pulse
# KDE Plasma 6, matching the reference device. plasmalogin (plasma-login-manager) is the
# display manager; sddm may come in as a dependency but is not enabled.
install_group desktop  plasma-meta plasma-login-manager discover konsole dolphin kcalc \
                       plasma-systemmonitor xdg-desktop-portal-kde polkit-kde-agent \
                       firefox libreoffice-fresh libreoffice-fresh-zh-cn \
                       noto-fonts-cjk noto-fonts-emoji adobe-source-han-sans-cn-fonts \
                       adobe-source-han-serif-cn-fonts ibus \
                       xorg-xwayland xdg-utils
echo "-- essentials present?"
for f in /usr/lib/systemd/systemd /usr/bin/pacman /usr/bin/bash /usr/bin/sudo \
         /usr/bin/NetworkManager /usr/bin/ssh /usr/bin/pipewire; do
  [ -e "$MNT$f" ] || echo "!! missing in image: $f"
done

echo "== root password / user"
ROOTPW=${ROOT_PASS:?set ROOT_PASS to the password for root and the alarm user}
arch "echo 'root:$ROOTPW' | chpasswd"
# The Arch Linux ARM tarball ships the desktop user "alarm" (uid 1000). Everything in
# deploy/ and the docs assumes that account.
if [ -e "$MNT/home/alarm" ]; then
  arch "echo 'alarm:$ROOTPW' | chpasswd" || echo "!! setting the alarm password failed"
  arch "usermod -aG wheel alarm" || true
fi
# The reference image also had a "tb" user on the NBD root; the UFS install uses alarm only.
# A second sudo user with the root password is not something a public image should ship.

echo "== fstab, hostname, locale"
printf 'LABEL=arch-root  /  ext4  rw,noatime  0 1\n' > "$MNT/etc/fstab"
echo tb710fu > "$MNT/etc/hostname"
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/; s/^#zh_CN.UTF-8/zh_CN.UTF-8/' "$MNT/etc/locale.gen"
arch "locale-gen"
arch "echo LANG=en_US.UTF-8 > /etc/locale.conf"

echo "== /sbin/init must exist (the initramfs checks for it before switch_root)"
[ -e "$MNT/sbin/init" ] || ln -s /usr/lib/systemd/systemd "$MNT/sbin/init"

echo "== TB710FU payload"
ROOT="$MNT" SSH_PUBKEY="${SSH_PUBKEY:-}" BOOTDIR="${BOOTDIR:-}" "$REPO/install_payload.sh" "$MOD" "$FW"

echo "== services to start"
arch "systemctl enable NetworkManager sshd plasmalogin" || true

echo "== cleanup"
# the package cache is 2-3 GiB and useless in the finished image (the release is compressed)
rm -rf "$MNT"/var/cache/pacman/pkg/* 2>/dev/null || true
sed -i '/^DisableSandbox$/d' "$MNT/etc/pacman.conf"     # restore the image's stock pacman config
if grep -q '^DisableSandbox$' "$MNT/etc/pacman.conf"; then echo "!! DisableSandbox still in the image"; fi
sync
trap - EXIT
umount -R "$MNT" 2>/dev/null || { fuser -km -m "$MNT" 2>/dev/null; sleep 1; umount -R "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null; }
losetup -d "$LOOP" 2>/dev/null || true
sync
echo "== image ready: $IMG  (serve it with nbd_server.py, export name steamos)"
