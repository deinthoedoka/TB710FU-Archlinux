#!/bin/bash
# build_driver.sh - build the VA-API driver (v4l2_drv_video.so) from source
# ON the tablet (native aarch64; there is no easy cross build because of the
# CDSP subprojects).
#
#   bash build_driver.sh [qcom-va-driver-vX.Y.Z.tar.gz]
#
# Without an argument the tarball is downloaded from the radxa release. The
# result is copied to /root/v4l2_drv_video.so, ready for install.sh --driver.
#
# Why the two -D flags: cdsp_vpp is enabled by default and needs the FastRPC
# skeleton built with the Qualcomm Hexagon toolchain (GHC, Haskell). Vulkan VPP
# is optional. Neither is needed for plain decode/encode on this device.
set -euo pipefail
VER=${VER:-1.1.1}
SRC=${1:-}
OUTDIR=${OUTDIR:-/root/qcom-va}

say() { printf '\n== %s\n' "$*"; }

say "build deps"
pacman -S --needed --noconfirm meson ninja gcc pkgconf libdrm mesa libva git || true

say "source"
mkdir -p "$OUTDIR"
if [ -z "$SRC" ]; then
  if [ -f "$OUTDIR/qcom-va-driver-v$VER.tar.gz" ]; then
    SRC=$OUTDIR/qcom-va-driver-v$VER.tar.gz
  else
    URL=https://github.com/radxa-pkg/qcom-va-driver/archive/refs/tags/$VER.tar.gz
    echo "   downloading $URL"
    wget -qO "$OUTDIR/qcom-va-driver-v$VER.tar.gz" "$URL" || {
      echo "!! download failed - fetch the tag tarball from the radxa-pkg release and pass it here"; exit 1; }
    SRC=$OUTDIR/qcom-va-driver-v$VER.tar.gz
  fi
fi
[ -f "$SRC" ] || { echo "!! no source tarball: $SRC"; exit 1; }
rm -rf "$OUTDIR/src"; mkdir -p "$OUTDIR/src"
tar -xf "$SRC" -C "$OUTDIR/src" --strip-components=1

say "meson setup (cdsp_vpp/vulkan_vpp off)"
cd "$OUTDIR/src"
rm -rf build
meson setup build -Dcdsp_vpp=disabled -Dvulkan_vpp=disabled
ninja -C build

SO=$OUTDIR/src/build/v4l2_drv_video.so
[ -f "$SO" ] || { echo "!! build produced no v4l2_drv_video.so"; exit 1; }
cp "$SO" /root/v4l2_drv_video.so
ls -l /root/v4l2_drv_video.so
echo "   md5 $(md5sum /root/v4l2_drv_video.so | cut -d' ' -f1)"
echo
echo "install it with:  bash install.sh --driver /root/v4l2_drv_video.so"
