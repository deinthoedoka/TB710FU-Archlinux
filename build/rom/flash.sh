#!/bin/bash
# flash.sh - install the TB710FU Arch ROM on an unlocked TB710FU.
#
#   ./flash.sh dual     keep ZUXOS; shrink userdata, create an adaptive arch partition
#   ./flash.sh single   erase Android data; rename userdata to arch and use it whole
#
# The script writes boot_a only with fastboot.  The rootfs is served over USB-NBD
# from this PC; the installer inside the boot image partitions the UFS, copies the
# rootfs, writes the final boot_a and reboots to the bootloader.  The script then
# finishes with `fastboot reboot`.
#
# Windows users: run windows\flash.cmd instead (bundled fastboot/zstd/NBD server).
#
# Requirements: fastboot, python3, zstd, an unlocked bootloader, a data-capable USB
# cable and (for dual) a backup of the Android data you care about.
set -euo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MODE=${1:-}
case "$MODE" in
  dual|single) ;;
  *) echo "usage: $0 dual|single"; exit 2 ;;
esac

BOOT=$HERE/boot/boot_install_$MODE.img
ROOTFS_ZST=$HERE/rootfs/arch-nbd.img.zst
WORK=${WORK:-$HERE/work}
IMG=$WORK/arch-nbd.img
NBD_PORT=${NBD_PORT:-10809}
FASTBOOT=${FASTBOOT:-fastboot}
PYTHON=${PYTHON:-python3}

say() { printf '\n== %s\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }

for f in "$BOOT" "$ROOTFS_ZST" "$HERE/tools/nbd_server.py"; do
  [ -f "$f" ] || die "missing $f"
done
command -v "$FASTBOOT" >/dev/null 2>&1 || die "fastboot not found (set FASTBOOT=...)"
command -v "$PYTHON" >/dev/null 2>&1 || die "python3 not found (set PYTHON=...)"
command -v zstd >/dev/null 2>&1 || die "zstd not found"

say "verify package hashes"
if [ -f "$HERE/SHA256SUMS" ]; then
  (cd "$HERE" && sha256sum -c SHA256SUMS) || die "SHA256SUMS mismatch"
else
  die "SHA256SUMS missing"
fi

say "check the device"
"$FASTBOOT" devices
PRODUCT=$("$FASTBOOT" getvar product 2>&1 | sed -n 's/^product: //p' | head -1)
UNLOCKED=$("$FASTBOOT" getvar unlocked 2>&1 | sed -n 's/^unlocked: //p' | head -1)
[ -n "$PRODUCT" ] || die "no fastboot device; enter the bootloader first (power+volume-down, or 'adb reboot bootloader')"
echo "product=$PRODUCT unlocked=$UNLOCKED"
# The bootloader answers "topaz_prc_wifi" (Lenovo's internal codename) rather
# than the marketing name; older labels may report TB710FU or sm8650.
case "$PRODUCT" in
  *TB710FU*|*tb710fu*|*sm8650*|*SM8650*|*topaz_*) ;;
  *) die "this does not look like a TB710FU (product=$PRODUCT); refusing" ;;
esac
[ "$UNLOCKED" = "yes" ] || die "bootloader is not unlocked; unlock it first"
SLOT=$("$FASTBOOT" getvar current-slot 2>&1 | sed -n "s/^current-slot: //p" | head -1)
[ "$SLOT" = "a" ] || die "current slot is ${SLOT:-unknown}; run \"fastboot set_active a\" first (metadata only), then rerun"

if [ "$MODE" = dual ]; then
  cat <<'EOF'

This will:
  * shrink the Android `userdata` partition and create an `arch` partition in
    the free tail (ZUXOS keeps at least 40 GiB; Arch gets the rest, so 8+128,
    8+256, 12+256 and 12+512 boards each use their own capacity; Arch must be
    at least 32 GiB)
  * factory-reset ZUXOS's userdata/metadata (Android data will be lost)
  * install Arch in the new partition
  * keep persist/modemst/fsg/fsc/devinfo/frp/keystore/ssd/secdata/uefivarstore/
    super/vbmeta*/dtbo/init_boot/vendor_boot untouched

Back up anything you need from Android before continuing.
EOF
else
  cat <<'EOF'

This will:
  * erase ALL Android user data (the `userdata` partition is reformatted as Arch)
  * rename `userdata` to `arch` and install Arch there
  * keep persist/modemst/fsg/fsc/devinfo/frp/keystore/ssd/secdata/uefivarstore/
    super/vbmeta*/dtbo/init_boot/vendor_boot untouched

There is no Android left to boot after this.
EOF
fi
printf '\nType YES to continue: '
read -r answer
[ "$answer" = YES ] || die "aborted"

ARCHSIZE=$("$FASTBOOT" getvar partition-size:arch 2>&1 | head -1)
case "$ARCHSIZE" in
  *"unknown"*|*"not found"*|*"FAILED"*|"") ;;
  *) echo "!! note: this device already has an arch partition ($ARCHSIZE)."
     echo "   The installer boot image tries the on-disk arch partition first, so a"
     echo "   reinstall will boot the old system instead of the NBD installer. This"
     echo "   package is for a first install; aborting is recommended."
     printf "   Type YES to continue anyway: "; read -r a2; [ "$a2" = YES ] || exit 1 ;;
esac

say "unpack the rootfs (one-time; needs ~22 GiB free under $WORK)"
mkdir -p "$WORK"
if [ ! -f "$IMG" ] || [ "$ROOTFS_ZST" -nt "$IMG" ]; then
  tmp=$IMG.tmp
  rm -f "$tmp"
  zstd -d -q -o "$tmp" "$ROOTFS_ZST"
  mv "$tmp" "$IMG"
fi
ls -lh "$IMG"

say "start the NBD server (port $NBD_PORT)"
rm -f "$WORK/nbd.log"
"$PYTHON" "$HERE/tools/nbd_server.py" --image "$IMG" --listen 0.0.0.0 \
  --port "$NBD_PORT" --verbose >"$WORK/nbd.log" 2>&1 &
NBD_PID=$!
cleanup() {
  kill "$NBD_PID" 2>/dev/null || true
  wait "$NBD_PID" 2>/dev/null || true
}
trap cleanup EXIT

say "write boot_install_$MODE.img to boot_a"
"$FASTBOOT" flash boot_a "$BOOT"
"$FASTBOOT" reboot

# Give the device DHCP time to hand this PC an address on 172.16.42.0/24.
say "wait for the USB-NBD link (172.16.42.x on this PC)"
for i in $(seq 1 60); do
  if ip -4 addr 2>/dev/null | grep -q 'inet 172\.16\.42\.'; then
    echo "host USB address:"; ip -4 addr | grep 'inet 172\.16\.42\.' || true
    break
  fi
  sleep 2
done
if ! ip -4 addr 2>/dev/null | grep -q 'inet 172\.16\.42\.'; then
  echo "!! This PC has no 172.16.42.x address yet."
  echo "   The device assigns one over DHCP; if your NetworkManager ignores the new"
  echo "   USB interface, set it manually, e.g.:"
  echo "     sudo ip addr add 172.16.42.2/24 dev <usb-iface>; sudo ip link set <usb-iface> up"
fi

say "waiting for the installer (the device reboots to fastboot when done)"
# The device disappears from fastboot, boots the installer, copies the rootfs and
# returns to fastboot with the BCB command 'bootonce-bootloader'.
sleep 20
DEADLINE=$(( $(date +%s) + 45*60 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if "$FASTBOOT" devices 2>/dev/null | grep -q .; then
    break
  fi
  sleep 5
done
if ! "$FASTBOOT" devices 2>/dev/null | grep -q .; then
  die "timed out waiting for the installer. Check the tablet screen and $WORK/nbd.log; the NBD image is $IMG"
fi

say "installer finished; rebooting into the installed system"
"$FASTBOOT" getvar current-slot 2>&1 | sed -n 's/^current-slot: /current-slot: /p' || true
"$FASTBOOT" reboot
say "done"
echo "First boot can take a few minutes (GNOME + droidloom initialize the fresh cell)."
echo "Default password for alarm and root: tb710fu  (change it after first login)."
