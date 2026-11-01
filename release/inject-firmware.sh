#!/bin/bash
# inject-firmware.sh <arch-nbd.img> <firmware-dir>
#
# The public rootfs image ships WITHOUT vendor firmware (not redistributable). Before the
# first NBD boot, copy your own device's firmware into the image with this script. It uses
# the same rules as build/install_payload.sh.
#
# Run on Linux/WSL as root. The image is a raw MBR disk: p1 = 4 MiB, p2 = ext4 root.
set -euo pipefail
IMG=${1:?usage: $0 <arch-nbd.img> <firmware-dir>}
FW=${2:?usage: $0 <arch-nbd.img> <firmware-dir>}
[ -f "$IMG" ] || { echo "no such image: $IMG"; exit 1; }
[ -d "$FW" ] || { echo "no such firmware dir: $FW"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

MNT=$(mktemp -d)
LOOP=$(losetup -f --show -P "$IMG")
cleanup() {
  umount "$MNT" 2>/dev/null || true
  losetup -d "$LOOP" 2>/dev/null || true
  rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

mount "${LOOP}p2" "$MNT"
echo "== copying $FW -> $MNT/usr/lib/firmware"
tar -C "$FW" --exclude='*.stock' --exclude='*.community' --exclude='MD5SUMS' -cf - . \
  | tar -xf - -C "$MNT/usr/lib/firmware/"

# GPU blobs must also exist as qcom/<name> (see install_payload.sh)
GT=$MNT/usr/lib/firmware/qcom/sm8650/xiaoxin/gt
mkdir -p "$MNT/usr/lib/firmware/qcom"
for f in gen70900_sqe.fw gen70900_aqe.fw gmu_gen70900.bin gen70900_zap.mbn; do
  [ -f "$GT/$f" ] && install -m 0644 "$GT/$f" "$MNT/usr/lib/firmware/qcom/$f"
done

# verify the files the DTB asks for
MISS=""
for f in qcom/sm8650/xiaoxin/gt/gen70900_zap.mbn qcom/sm8650/xiaoxin/gt/adsp.mbn \
         qcom/sm8650/xiaoxin/gt/adsp_dtb.mbn qcom/sm8650/xiaoxin/gt/cdsp.mbn \
         qcom/sm8650/xiaoxin/gt/cdsp_dtb.mbn qcom/gen70900_sqe.fw qcom/gmu_gen70900.bin \
         qcom/sm8650/Lenovo-TB710FU-tplg.bin aw882xx_acf.bin awinic/aw88461_tb710fu.bin \
         novatek/novatek_nt36532_fw.bin ath12k/WCN7850/hw2.0/amss.bin \
         ath12k/WCN7850/hw2.0/board-2.bin ath12k/WCN7850/hw2.0/m3.bin \
         qca/hmtbtfw20.tlv qca/hmtnv20.bin; do
  [ -s "$MNT/usr/lib/firmware/$f" ] || MISS="$MISS $f"
done
sync
[ -z "$MISS" ] || { echo "!! firmware still missing:$MISS"; exit 1; }
echo "firmware injected - the image is ready for the NBD install"
