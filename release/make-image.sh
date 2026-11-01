#!/bin/bash
# make-image.sh <modules-7.2.6-tb710fu.tar> [size]
#
# Build the public rootfs image: an MBR disk whose p2 is ext4 LABEL=arch-root, with the
# KDE desktop and the port payload, but WITHOUT vendor firmware. Then compress + split it
# into Release assets (GitHub caps a single asset at 2 GiB).
#
# Run in WSL/Linux as root (qemu-user-binfmt must be registered).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MOD=${1:?usage: $0 <modules-7.2.6-tb710fu.tar> [size]}
SIZE=${2:-10G}
OUT=${OUT:-$ROOT/out-release}     # put this on ext4 when building in WSL, not on /mnt/f
STAGE=${STAGE:-$ROOT/out}         # where wsl_build.sh left Image/dtb/kShimC/packer
EMPTYFW=$(mktemp -d)
trap 'rmdir "$EMPTYFW" 2>/dev/null || true' EXIT

export ROOT_PASS=${ROOT_PASS:?set ROOT_PASS (suggested: alarm, then force a change at first login)}
export MODULES_TAR=$MOD
export FWDIR=$EMPTYFW
export SKIP_FIRMWARE=1
export SIZE
export OUT
mkdir -p "$OUT"

# stage the rest of the release assets next to the image
for f in Image sm8650-lenovo-tb710fu-kshim.dtb kShimC.bin MultiBootKernelPatcher; do
  [ -f "$OUT/$f" ] || cp -f "$STAGE/$f" "$OUT/" 2>/dev/null || true
  [ -f "$OUT/$f" ] || { echo "!! missing artifact: $STAGE/$f"; exit 1; }
done
[ -f "$MOD" ] || { echo "!! missing modules tarball: $MOD"; exit 1; }
cp -f "$MOD" "$OUT/"

bash "$ROOT/build/build_rootfs.sh"

echo "== compress"
zstd -T0 -12 -f -o "$OUT/arch-nbd-base.img.zst" "$OUT/arch-nbd.img"
rm -f "$OUT"/arch-nbd-base.img.zst.part*
split -b 1900M -d -a 2 "$OUT/arch-nbd-base.img.zst" "$OUT/arch-nbd-base.img.zst.part"
rm -f "$OUT/arch-nbd-base.img.zst"

echo "== checksums"
( cd "$OUT" && sha256sum Image sm8650-lenovo-tb710fu-kshim.dtb kShimC.bin \
    MultiBootKernelPatcher modules-7.2.6-tb710fu.tar arch-nbd-base.img.zst.part* \
    > SHA256SUMS )
ls -lh "$OUT"
