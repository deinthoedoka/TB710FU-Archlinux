#!/bin/bash
# flash.sh - write a packed boot image to boot_a, with a checksum and an explicit confirmation.
#
#   ./flash.sh out/boot/boot_arch.img
#
# Requires adb/fastboot in PATH and an unlocked bootloader. Only boot_a is written.
set -euo pipefail
IMG=${1:?usage: $0 <boot-image>}
[ -f "$IMG" ] || { echo "no such file: $IMG"; exit 1; }

SZ=$(stat -c%s "$IMG")
[ "$SZ" = 100663296 ] || echo "!! size is $SZ, expected 100663296 - check this is a packed boot image"
echo "sha256: $(sha256sum "$IMG" | cut -d' ' -f1)"
echo
echo "About to write $IMG to boot_a. boot_b, vbmeta, super and userdata are NOT touched."
printf 'Type YES to continue: '
read -r a
[ "$a" = YES ] || { echo "aborted"; exit 1; }

adb reboot bootloader 2>/dev/null || true
sleep 3
fastboot devices
fastboot flash boot_a "$IMG"
fastboot reboot
echo "done - the boot menu appears in about 8 s (volume keys select, power confirms)"
