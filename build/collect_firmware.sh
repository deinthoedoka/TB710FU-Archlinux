#!/bin/bash
# collect_firmware.sh SUPER_IMG OUT_DIR   - clean-provenance firmware, no device root.
#
# Pull the device-specific blobs out of the readback `super.img` backup we already have, so
# the firmware tree handed to install_payload.sh comes from YOUR device rather than from a
# redistributed archive. The source repo's tools/collect_firmware.sh does the same thing over
# adb + Magisk root (`su -c 'tar c /vendor/firmware_mnt/image'`), which a locked-bootloader
# ZUXOS cannot do - the files live in the vendor partition, so unpacking the backup works
# instead, and it never touches the tablet.
#
# Run in WSL2 (needs lpunpack + erofs-utils; install: sudo apt-get install -y
# android-sdk-platform-tools-common simg2img erofs-utils e2fsprogs file).
#
# What is copied (into a tree laid out like /usr/lib/firmware):
#   qcom/sm8650/xiaoxin/gt/  adsp/cdsp images + *_dtb + the pd-mapper *.jsn + gen70900_zap.mbn
#                            + vpu33_4v.mbn + the gen70900 sqe/aqe/gmu blobs
#   novatek/novatek_nt36532_fw.bin          (from vendor's novatek_ts_fw.bin)
#   aw882xx_acf.bin, awinic/aw88461_tb710fu.bin, qca/*, ath12k/WCN7850/hw2.0/*, topology
# install_payload.sh then also places the GPU blobs at qcom/<name>, which is where the driver
# actually looks (docs/firmware.md; adreno_gpu.c tries "qcom/$name" first).
#
# If a file is only in linux-firmware (nothing on this board is), pacman's linux-firmware
# already provides it in the rootfs; this script deliberately does not fabricate blobs.
set -euo pipefail
SUPER=${1:?usage: collect_firmware.sh SUPER_IMG OUT_DIR}
OUT=${2:?}
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
G=$OUT/qcom/sm8650/xiaoxin/gt
mkdir -p "$G" "$OUT/qcom" "$OUT/novatek" "$OUT/awinic" "$OUT/qca" \
       "$OUT/ath12k/WCN7850/hw2.0" "$OUT/qcom/sm8650" "$OUT/tplg"

echo "== super.img"
RAW=$WORK/super.raw
if file "$SUPER" | grep -q "Android sparse image"; then
  command -v simg2img >/dev/null || { echo "!! need simg2img (apt install simg2img)"; exit 1; }
  simg2img "$SUPER" "$RAW"
else
  RAW=$SUPER                     # our readback is raw, not sparse
fi
command -v lpunpack >/dev/null || { echo "!! need lpunpack (apt install simg2img ships it)"; exit 1; }
lpunpack -p vendor "$RAW" "$WORK/vendor.img"
[ -s "$WORK/vendor.img" ] || { echo "!! vendor partition not found in super"; exit 1; }

echo "== vendor filesystem"
V=$WORK/vendor; mkdir -p "$V"
if file "$WORK/vendor.img" | grep -qi "erofs"; then
  command -v fsck.erofs >/dev/null || { echo "!! need erofs-utils (fsck.erofs)"; exit 1; }
  fsck.erofs --extract="$V" "$WORK/vendor.img" >/dev/null
elif file "$WORK/vendor.img" | grep -qi "ext4"; then
  mkdir -p "$V/firmware_mnt/image" "$V/firmware"
  for d in firmware_mnt/image firmware; do
    debugfs -R "ls -l /$d" "$WORK/vendor.img" >/dev/null 2>&1 || \
      { echo "!! /$d not present in vendor"; exit 1; }
    # dump every regular entry; debugfs warns for '.'/'..'/dirs, which is harmless here
    cmds=$WORK/dump-$d.txt
    for f in $(debugfs -R "ls /$d" "$WORK/vendor.img" 2>/dev/null | tr -s ' ' '\n'); do
      if [ "$f" = "." ] || [ "$f" = ".." ] || [ "${f:0:1}" = "(" ]; then continue; fi
      echo "dump /$d/$f $V/$d/$f" >> "$cmds"
    done
    debugfs -f "$cmds" "$WORK/vendor.img" >/dev/null 2>&1 || true
  done
else
  echo "!! unrecognized vendor image: $(file "$WORK/vendor.img")"; exit 1
fi
[ -d "$V" ] && [ -n "$(find "$V" -maxdepth 1 -mindepth 1)" ] || { echo "!! vendor extract produced nothing"; exit 1; }

# place a blob by basename, whatever vendor subdirectory it lives in
grab() {  # grab <basename> <relative dest inside OUT> [src dir hint]
  local name=$1 dest=$2 hint=${3:-} src
  src=$(find "$V" ${hint:+-path "*$hint*"} -type f -name "$name" | head -1)
  [ -n "$src" ] || return 1
  install -m 0644 "$src" "$OUT/$dest"
  echo "   $dest  <- ${src#$V/}"
}

echo "== device-specific blobs (must exist)"
FAIL=""
for spec in \
  "adsp.mbn                 qcom/sm8650/xiaoxin/gt/adsp.mbn" \
  "adsp_dtb.mbn             qcom/sm8650/xiaoxin/gt/adsp_dtb.mbn" \
  "cdsp.mbn                 qcom/sm8650/xiaoxin/gt/cdsp.mbn" \
  "cdsp_dtb.mbn             qcom/sm8650/xiaoxin/gt/cdsp_dtb.mbn" \
  "adspr.jsn                qcom/sm8650/xiaoxin/gt/adspr.jsn" \
  "adsps.jsn                qcom/sm8650/xiaoxin/gt/adsps.jsn" \
  "adspua.jsn               qcom/sm8650/xiaoxin/gt/adspua.jsn" \
  "cdspr.jsn                qcom/sm8650/xiaoxin/gt/cdspr.jsn" \
  "battmgr.jsn              qcom/sm8650/xiaoxin/gt/battmgr.jsn" \
  "gen70900_zap.mbn         qcom/sm8650/xiaoxin/gt/gen70900_zap.mbn" \
  "vpu33_4v.mbn             qcom/sm8650/xiaoxin/gt/vpu33_4v.mbn" \
  "gen70900_sqe.fw          qcom/sm8650/xiaoxin/gt/gen70900_sqe.fw" \
  "gmu_gen70900.bin         qcom/sm8650/xiaoxin/gt/gmu_gen70900.bin" \
  "amss.bin                 ath12k/WCN7850/hw2.0/amss.bin" \
  "board-2.bin              ath12k/WCN7850/hw2.0/board-2.bin" \
  "m3.bin                   ath12k/WCN7850/hw2.0/m3.bin" \
  "hmtbtfw20.tlv            qca/hmtbtfw20.tlv" \
  "hmtnv20.bin              qca/hmtnv20.bin" \
  "aw882xx_acf.bin          aw882xx_acf.bin" \
  "Lenovo-TB710FU-tplg.bin  qcom/sm8650/Lenovo-TB710FU-tplg.bin"
do
  set -- $spec
  grab "$1" "$2" || FAIL="$FAIL $1"
done
# renamed vendor files
grab novatek_ts_fw.bin novatek/novatek_nt36532_fw.bin || FAIL="$FAIL novatek_ts_fw.bin"
# amp tuning: vendor ships it under an awinic name; the driver wants both paths
for cand in aw88461_tb710fu.bin aw882xx_cal.bin; do
  if grab "$cand" awinic/aw88461_tb710fu.bin; then break; fi
done
if [ -f "$OUT/awinic/aw88461_tb710fu.bin" ]; then
  install -m 0644 "$OUT/awinic/aw88461_tb710fu.bin" "$OUT/aw882xx_acf.bin"
fi
# the topology must be the TDM variant: the stock one carries I2S_SINK 0x0700100A, which the
# ADSP rejects for 8-slot TDM + 4 amps. Patch it in place if it is still the stock id.
python3 - "$OUT/qcom/sm8650/Lenovo-TB710FU-tplg.bin" <<'PY'
import struct, sys
p = sys.argv[1]
d = bytearray(open(p, "rb").read())
old, new = struct.pack("<I", 0x0700100A), struct.pack("<I", 0x0700100E)
if d.count(old) == 1:
    d[d.find(old):d.find(old) + 4] = new
    open(p, "wb").write(d)
    print("   topology: I2S_SINK -> TDM_SINK patched (%s)" % p)
elif d.count(new) == 1:
    print("   topology: already TDM_SINK (%s)" % p)
else:
    sys.exit("!! topology has neither exactly one I2S_SINK nor one TDM_SINK id: %s" % p)
PY
cp "$OUT/qcom/sm8650/Lenovo-TB710FU-tplg.bin" "$OUT/Lenovo-TB710FU-tplg.bin"
cp "$OUT/qcom/sm8650/Lenovo-TB710FU-tplg.bin" "$OUT/tplg/Lenovo-TB710FU-tplg.bin"

[ -z "$FAIL" ] || { echo "!! not found in vendor:$FAIL"; echo "   compare with the archive set in arch/firmware/ - those md5s were taken from this device"; exit 1; }

echo "== result: $OUT"
(cd "$OUT" && find . -type f | sort | sed 's/^/  /')
echo "== gpu path check (install_payload.sh also copies these to qcom/)"
ls -l "$G"/gen70900_* "$G"/gmu_gen70900.bin
