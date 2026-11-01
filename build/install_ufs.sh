#!/bin/bash
# TB710FU: move the running (NBD-root) Arch system onto UFS, next to stock ZUXOS.
# Run as root on the tablet while booted into Arch over NBD (ssh on 172.16.42.x).
#
# What this does, and nothing else:
#  1. GPT on /dev/sda (4 KiB sectors): shrink the `userdata` partition to
#     5105064..27836415 (86.7 GiB, same name/type/unique GUID) and add a new partition
#     named `arch` at 27836416..61390842 (128 GiB) -> sda15 on this layout.
#  2. Zero the heads of `userdata` and `metadata` so ZUXOS reformats both on its next boot
#     (factory-reset state). BACK THEM UP FIRST if you need anything on them.
#  3. ext4 labelled arch-root on the new partition; copy the running root into it.
#  4. fstab: root by label.
#
# NOT touched: super, boot_a/boot_b, vbmeta*, init_boot, vendor_boot, dtbo, and every
# unique-data partition (persist modemst1 modemst2 fsg fsc devinfo frp keystore ssd
# secdata uefivarstore cdt ddr). Never write an old raw userdata image back - QTEE
# anti-rollback makes the PIN permanently unusable (IKMHal_sendCmd status -30).
#
# Sector numbers are for the 256 GB model (userdata = 5105064..61390842). The script
# re-reads the real table and refuses if it differs; override with USERDATA_LAST and
# ARCH_START if your model is different.
#
# Requires: sgdisk, rsync, mkfs.ext4, e2fsprogs, coreutils. Set CONFIRM=yes to proceed.
set -euo pipefail
D=/dev/sda
USERDATA_LAST=${USERDATA_LAST:-61390842}
ARCH_START=${ARCH_START:-27836416}      # first sector of the new arch partition
CONFIRM=${CONFIRM:-}
[ "$CONFIRM" = yes ] || { echo "refusing: this rewrites the GPT on UFS and wipes userdata/metadata heads."; echo "Run with CONFIRM=yes after you have read the header and have gpt_main0-5/gpt_backup0-5 backed up."; exit 1; }
[ "$(blockdev --getss $D)" = 4096 ] || { echo "unexpected sector size on $D"; exit 1; }

# mainline Linux has no /dev/block/by-name: resolve partition names from uevent
partdev() {
  for b in /sys/class/block/sd*; do
    if grep -q "^PARTNAME=$1$" $b/uevent 2>/dev/null; then
      echo /dev/$(basename $b); return 0
    fi
  done
  return 1
}
UD=$(partdev userdata) || { echo "no userdata partition found"; exit 1; }
UDI=${UD#/dev/sda}
echo "userdata = $UD (index $UDI)"

sgdisk -i $UDI $D | grep -q "Partition name: 'userdata'" || { echo "$UD is not userdata"; exit 1; }
sgdisk -i $UDI $D | grep -q "Last sector: $USERDATA_LAST" || {
  echo "userdata does not end at $USERDATA_LAST - check your model:"
  sgdisk -i $UDI $D | grep -E "name|First|Last"; exit 1; }
G=$(sgdisk -i $UDI $D | sed -n 's/^Partition unique GUID: //p')   # userdata keeps its own GUID
[ -n "$G" ] || { echo "cannot read userdata GUID"; exit 1; }
MD=$(partdev metadata || true)
for p in $UD $MD; do
  [ -n "$p" ] || continue
  ! grep -q "^$p " /proc/mounts || { echo "$p is mounted"; exit 1; }
done
grep -q "^/dev/nbd0" /proc/mounts || echo "note: root is not an NBD disk - copying the current root as-is"

# safety net: pull both GPT copies off the disk before rewriting anything
BK=/root/gpt-sda-before-arch-$(date +%Y%m%d-%H%M%S).gpt
sgdisk -b "$BK" $D          # -b saves the GPT (primary+backup) to a file; -E only moves it
echo "GPT backup written to $BK  - scp it to the host before continuing:"
echo "  scp root@172.16.42.<pad-ip>:$BK ."
[ -s "$BK" ] || { echo "GPT backup failed"; exit 1; }

sgdisk -d $UDI \
  -n $UDI:5105064:$((ARCH_START-1)) -c $UDI:userdata -t $UDI:1B81E7E6-F50D-419B-A739-2AEEF8DA3335 -u $UDI:$G \
  -n 15:$ARCH_START:$USERDATA_LAST -c 15:arch -t 15:8300 $D
sgdisk -v $D | tail -2
# A plain `partx -u` only refreshes existing partitions; the new sda15 needs a real rescan.
# Seen 2026-10-31: the table was written correctly but the uevent PARTNAME=arch appeared only
# after partprobe + blockdev --rereadpt, so retry for a while instead of failing on the spot.
NEW=""
for i in $(seq 1 20); do
  NEW=$(partdev arch) || true
  if [ -n "$NEW" ] && [ -b "$NEW" ]; then break; fi
  partx -a $D 2>/dev/null || true
  partprobe $D 2>/dev/null || true
  blockdev --rereadpt $D 2>/dev/null || true
  sleep 1
done
[ -n "$NEW" ] && [ -b "$NEW" ] || { echo "no partition named arch after reread"; exit 1; }
echo "new root partition = $NEW"
sgdisk -i $UDI $D | grep -E "name|First|Last|unique"; sgdisk -i ${NEW#/dev/sda} $D | grep -E "name|First|Last"

# Android reformats userdata/metadata from scratch when their superblocks are gone
dd if=/dev/zero of=$UD bs=1M count=64 conv=fsync status=none
[ -n "$MD" ] && dd if=/dev/zero of=$MD bs=1M count=64 conv=fsync status=none || true

mkfs.ext4 -q -F -L arch-root $NEW
mkdir -p /mnt/arch; mount -o noatime $NEW /mnt/arch
rsync -aHAXx --numeric-ids --info=stats1 / /mnt/arch/     # -x: stays inside the NBD root fs
# Arch has no /etc overlay (unlike SteamOS), so a plain copy of / carries /etc too.
mkdir -p /mnt/arch/{proc,sys,dev,run,tmp,boot,mnt,home}
printf 'LABEL=arch-root  /  ext4  rw,noatime  0 1\n' > /mnt/arch/etc/fstab
cat /mnt/arch/etc/fstab

# our services and the boot_a variants travel with the copy; make sure they are enabled
S=/mnt/arch/etc/systemd/system
mkdir -p $S/multi-user.target.wants $S/display-manager.target.wants $S/display-manager.service.wants
for u in tb-native-display tb-usb-ncm tb-usb-ncm-watch tb-wifi tb-audio-init tb-adsp-audio-check tb-touch-check; do
  ln -sfn /etc/systemd/system/$u.service $S/multi-user.target.wants/$u.service
done
ln -sfn /etc/systemd/system/tb-native-display.service $S/display-manager.service.wants/tb-native-display.service
[ -e /mnt/arch/sbin/init ] || ln -s /usr/lib/systemd/systemd /mnt/arch/sbin/init
ls -l /mnt/arch/boot/tbboot 2>/dev/null || echo "note: /boot/tbboot is empty - tbboot needs the packed boot images"

sync; df -h /mnt/arch
blkid $NEW
umount /mnt/arch
echo "INSTALL-OK  now reboot into the new root:  tbboot arch   (or reboot; the menu defaults to Arch)"
