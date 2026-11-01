#!/bin/bash
# make-boot.sh <stock boot_a.img>
#
# Pack the boot menu + kernel + DTB into the two boot images:
#   out/boot/boot_zui.img    menu defaults to ZUXOS
#   out/boot/boot_arch.img   menu defaults to Arch
#
# The stock boot_a.img is used as the template (its header, cmdline and AVB footer layout
# are reused). Take it from YOUR device's EDL backup - a boot image from another unit will
# not carry this device's rollback index.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
STOCK=${1:?usage: $0 <stock boot_a.img>}
OUT=$ROOT/out
export TESTKEY=${TESTKEY:-$ROOT/build/tools/testkey_rsa4096.pem}
# wsl_build.sh copies the packer next to the other artifacts
export PACKER=${PACKER:-$OUT/MultiBootKernelPatcher}

for f in Image sm8650-lenovo-tb710fu-kshim.dtb kShimC.bin; do
  [ -f "$OUT/$f" ] || { echo "!! $OUT/$f missing - run wsl_build.sh kernel shim first"; exit 1; }
done
[ -x "$PACKER" ] || { echo "!! packer not found at $PACKER (set PACKER=...)"; exit 1; }

python3 -I "$ROOT/build/pack_boot.py" \
  --boot "$STOCK" --shim "$OUT/kShimC.bin" --linux "$OUT/Image" \
  --dtb "$OUT/sm8650-lenovo-tb710fu-kshim.dtb" --out "$OUT/boot" --default zui
python3 -I "$ROOT/build/pack_boot.py" \
  --boot "$STOCK" --shim "$OUT/kShimC.bin" --linux "$OUT/Image" \
  --dtb "$OUT/sm8650-lenovo-tb710fu-kshim.dtb" --out "$OUT/boot" --default arch

ls -l "$OUT"/boot/boot_*.img
