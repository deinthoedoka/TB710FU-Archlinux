#!/bin/bash
# install_payload.sh MODULES_TAR FIRMWARE_DIR
#
# Install the TB710FU kernel modules, firmware and rootfs/ of this port into an Arch
# Linux aarch64 system. Arch counterpart of the SteamOS steamos/install_payload.sh.
#
#   MODULES_TAR   modules-7.2.6-tb710fu.tar produced by the kernel build
#   FIRMWARE_DIR  a tree laid out like /usr/lib/firmware with this device's firmware
#                 (see ../PORT-NOTES.md; the Lenovo/Qualcomm/Awinic/Novatek blobs must
#                 come from YOUR device and cannot be redistributed)
#
# Environment:
#   ROOT         install into a mounted root instead of the running system
#                (offline: ROOT=/mnt/arch). On a live tablet just run it as root.
#   SSH_PUBKEY   add this key for root and the first user, enable sshd
#                (the UFS install step runs over ssh on the NBD-booted system)
#   SKIP_FIRMWARE=1  do not copy/validate vendor firmware (public release images)
#   BOOTDIR      directory holding boot_zui.img / boot_arch.img; they are copied to
#                /boot/tbboot with .sha256 files so tbboot can verify and switch
#
# Unlike SteamOS, Arch has no /etc overlay, so units and masks can be written
# straight into /etc - no bind mount of / needed.
set -euo pipefail
REPO=$(cd "$(dirname "$0")" && pwd)
MOD=${1:?usage: install_payload.sh MODULES_TAR FIRMWARE_DIR}; FW=${2:?}
KV=7.2.6-tb710fu
ROOT=${ROOT:-/}
E=$ROOT

echo "== kernel modules"
rm -rf "$ROOT/usr/lib/modules/$KV"
tar xf "$MOD" -C "$ROOT/usr/lib/modules"
depmod -b "$ROOT" "$KV"

if [ "${SKIP_FIRMWARE:-0}" = 1 ]; then
  # Public release images must not redistribute vendor blobs. The user injects their own
  # firmware from their device before first boot (release/inject-firmware.sh).
  echo "== firmware SKIPPED (release image)"
else
echo "== firmware"
# The firmware tree keeps reference copies (`*.stock`, `*.community` from the vendor/
# community ath12k comparison, and the unpatched `*.tplg.bin.stock`). Only the files the
# kernel actually loads belong in /usr/lib/firmware.
tar -C "$FW" --exclude='*.stock' --exclude='*.community' --exclude='MD5SUMS' -cf - . \
  | tar -xf - -C "$ROOT/usr/lib/firmware/"

# GPU firmware path fix-up. The driver resolves the gen70900 blobs as `qcom/<name>` and only
# then the bare name (adreno_gpu.c: kasprintf("qcom/%s", fwname)); the DT overrides the zap
# shader path, but sqe/gmu have no DT override. Device firmware trees keep these blobs
# together under qcom/sm8650/xiaoxin/gt/, so without this the panel stays black.
GT=$ROOT/usr/lib/firmware/qcom/sm8650/xiaoxin/gt
mkdir -p "$ROOT/usr/lib/firmware/qcom"
for f in gen70900_sqe.fw gen70900_aqe.fw gmu_gen70900.bin gen70900_zap.mbn; do
  if [ -f "$GT/$f" ]; then install -m 0644 "$GT/$f" "$ROOT/usr/lib/firmware/qcom/$f"; fi
done

# every file the kernel/DT asks for must be present - catch a missing blob here, not on the tablet
MISS=""
for f in qcom/sm8650/xiaoxin/gt/gen70900_zap.mbn qcom/sm8650/xiaoxin/gt/adsp.mbn \
         qcom/sm8650/xiaoxin/gt/adsp_dtb.mbn qcom/sm8650/xiaoxin/gt/cdsp.mbn \
         qcom/sm8650/xiaoxin/gt/cdsp_dtb.mbn qcom/sm8650/xiaoxin/gt/adspr.jsn \
         qcom/sm8650/xiaoxin/gt/adsps.jsn qcom/sm8650/xiaoxin/gt/adspua.jsn \
         qcom/sm8650/xiaoxin/gt/cdspr.jsn qcom/sm8650/xiaoxin/gt/battmgr.jsn \
         qcom/sm8650/xiaoxin/gt/vpu33_4v.mbn qcom/gen70900_sqe.fw qcom/gmu_gen70900.bin \
         qcom/sm8650/Lenovo-TB710FU-tplg.bin aw882xx_acf.bin awinic/aw88461_tb710fu.bin \
         novatek/novatek_nt36532_fw.bin ath12k/WCN7850/hw2.0/amss.bin \
         ath12k/WCN7850/hw2.0/board-2.bin ath12k/WCN7850/hw2.0/m3.bin \
         qca/hmtbtfw20.tlv qca/hmtnv20.bin; do
  [ -s "$ROOT/usr/lib/firmware/$f" ] || MISS="$MISS $f"
done
# novatek_nt36532_mp.bin is legitimately absent: the port's driver says a missing MP image
# "degrades gracefully" (the SPI chip-id read in probe still proves the die is alive).
[ -z "$MISS" ] || { echo "!! firmware missing:$MISS"; exit 1; }
fi

echo "== rootfs overlay (scripts, units, configs)"
cp -a --no-preserve=ownership "$REPO/rootfs/usr/." "$ROOT/usr/"
cp -a --no-preserve=ownership "$REPO/rootfs/etc/." "$E/etc/"
chmod 0755 "$ROOT"/usr/local/sbin/tb-* "$ROOT"/usr/local/sbin/wifi-on 2>/dev/null || true

echo "== enable services"
S=$E/etc/systemd/system
mkdir -p "$S/multi-user.target.wants" "$S/display-manager.service.wants"
for u in tb-native-display tb-usb-ncm tb-usb-ncm-watch tb-wifi tb-audio-init tb-adsp-audio-check tb-touch-check; do
  ln -sfn /etc/systemd/system/$u.service "$S/multi-user.target.wants/$u.service"
done
ln -sfn /etc/systemd/system/tb-native-display.service "$S/display-manager.service.wants/tb-native-display.service"

echo "== pacman must never replace our kernel"
# Our kernel lives in boot_a (packed by kShimC), not in /boot; the distro kernel is
# unused. IgnorePkg keeps a `pacman -Syu` from re-installing linux-aarch64 if the user
# ever pulls it back in, and keeps linux-api-headers from churning headers.
if ! grep -q '^IgnorePkg .*linux-aarch64' "$E/etc/pacman.conf"; then
  printf '\n# TB710FU: the running kernel comes from boot_a (kShimC), not from pacman.\nIgnorePkg   = linux-aarch64 linux-latest linux-api-headers\n' >> "$E/etc/pacman.conf"
fi

echo "== pen hwdb"
systemd-hwdb update --usr --root="$ROOT"

if [ -n "${BOOTDIR:-}" ]; then
  echo "== boot variants for tbboot"
  B=$ROOT/boot/tbboot; mkdir -p "$B"
  for v in zui arch; do
    [ -f "$BOOTDIR/boot_$v.img" ] || continue
    install -m 0644 "$BOOTDIR/boot_$v.img" "$B/boot_$v.img"
    (cd "$B" && sha256sum "boot_$v.img" > "boot_$v.img.sha256")
  done
  ls -l "$B"
fi

# sshd is always enabled: the NBD install step runs over SSH, and the prebuilt release
# image has no key baked in (log in as alarm, then sudo).
ln -sfn /usr/lib/systemd/system/sshd.service "$S/multi-user.target.wants/sshd.service"

if [ -n "${SSH_PUBKEY:-}" ]; then
  echo "== ssh keys"
  # SSH_PUBKEY may be the key itself (as wsl_build.sh passes it) or a path to a .pub file;
  # Windows-written files and keys carry a trailing CR that authorized_keys must not see.
  if [ -f "$SSH_PUBKEY" ]; then KEY=$(tr -d '\r' < "$SSH_PUBKEY"); else KEY=$(printf '%s\n' "$SSH_PUBKEY" | tr -d '\r'); fi
  case "$KEY" in
    ssh-*|ecdsa-*|sk-*) ;;
    *) echo "!! SSH_PUBKEY is neither a key nor a readable file: ${SSH_PUBKEY:0:40}..."; exit 1 ;;
  esac
  for h in "$ROOT/root" "$ROOT/home"/*; do
    [ -d "$h" ] || continue
    mkdir -p "$h/.ssh"; printf '%s\n' "$KEY" >> "$h/.ssh/authorized_keys"
    chmod 700 "$h/.ssh"; chmod 600 "$h/.ssh/authorized_keys"
    U=$(stat -c '%u:%g' "$h"); chown -R "$U" "$h/.ssh"
  done
fi

if [ "$ROOT" = / ]; then systemctl daemon-reload; fi
sync
echo done
