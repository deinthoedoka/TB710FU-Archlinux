#!/bin/bash
# build_kernel.sh - build 7.2.6-tb710fu for the TB710FU Arch port, without docker.
# Run in WSL2 Ubuntu (x86_64): the kernel is cross-compiled, the initramfs gets an
# aarch64 static busybox fetched from the Debian arm64 archive.
#
# Kernel tree = linux 7.2.6 + armadaos-freedom kernel patches/dts (ba692d8)
#             + tb710fu-kernel-on-freedom.patch (everything TB710FU specific)
#             + arch.config fragment (systemd / removable media / debug; see the file header)
#             + arch/initramfs/* (arch partition root, NBD with RNDIS fallback, diag telnet)
#
# Output in $OUT: Image, sm8650-lenovo-tb710fu-kshim.dtb, modules-7.2.6-tb710fu.tar
#
# Environment: ARCH_ROOT (this dir), REPO (the tb710fu repo), FREEDOM (freedom checkout),
#              OUT (output dir), SRCDIR (where linux-7.2.6.tar.xz lives/downloaded)
set -euo pipefail
V=7.2.6
ARCH_ROOT=${ARCH_ROOT:-$(cd "$(dirname "$0")" && pwd)}
REPO=${REPO:-$ARCH_ROOT/../deps/tb710fu-hyperos-steamos}
FREEDOM=${FREEDOM:-$ARCH_ROOT/../deps/armadaos-freedom}
OUT=${OUT:-$HOME/tb710fu/out}
SRCDIR=${SRCDIR:-$HOME/tb710fu/src}
BUILD=${BUILD:-$HOME/tb710fu/build}
mkdir -p "$OUT" "$SRCDIR"

echo "== packages"
sudo apt-get update -qq
sudo apt-get install -y -qq build-essential bc bison flex libssl-dev libelf-dev dwarves \
  kmod python3 rsync xz-utils zstd patch git file device-tree-compiler \
  gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu qemu-user-binfmt binfmt-support dpkg-dev wget >/dev/null
# qemu-user-static no longer exists in current Ubuntu/Debian; qemu-user-binfmt ships the
# static-pie qemu-aarch64 binary under that name (used below to read busybox's applet list).
QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
[ -n "$QEMU" ] || { echo "!! no qemu-aarch64 binary (apt install qemu-user-binfmt)"; exit 1; }

# an aarch64 STATIC busybox for the initramfs (/bin/busybox is x86_64 here)
BB=$SRCDIR/busybox-arm64
if [ ! -x "$BB" ]; then
  sudo dpkg --add-architecture arm64
  # Take arm64 from THIS distro's archive, as an arm64-only source. Adding Debian trixie
  # instead would let apt pick Debian packages for ordinary installs in this Ubuntu rootfs.
  CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-noble}")
  cat > /etc/apt/sources.list.d/arm64.sources <<EOF
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: $CODENAME $CODENAME-updates $CODENAME-security
Components: main universe
Architectures: arm64
EOF
  sudo apt-get update -qq || echo "   note: apt update reported errors for the arm64 source"
  (cd "$SRCDIR" && apt-get download busybox-static:arm64) || {
    echo "!! could not download busybox-static:arm64"; exit 1; }
  deb=$(ls "$SRCDIR"/busybox-static_*_arm64.deb | head -1)
  rm -rf "$SRCDIR"/bbx; dpkg-deb -x "$deb" "$SRCDIR"/bbx
  cp "$SRCDIR"/bbx/usr/bin/busybox "$BB"; chmod +x "$BB"
fi
file "$BB" | grep -q "aarch64\|ARM aarch64" || { echo "$BB is not aarch64"; exit 1; }
echo "== initramfs busybox applets (must include nbd-client)"
# read the applet list once: `busybox | grep -q` would let grep exit early, busybox would take
# SIGPIPE, and `set -o pipefail` would report that as a failure
APPLETS=$("$QEMU" "$BB" 2>/dev/null || true)
printf '%s\n' "$APPLETS" | tr ',' '\n' | grep -E "nbd-client|udhcpd|telnetd|switch_root|blockdev|losetup" | tr '\n' ' '; echo
printf '%s\n' "$APPLETS" | grep -q nbd-client || \
  { echo "!! this busybox has no nbd-client applet - the NBD dry run cannot work"; exit 1; }

echo "== kernel tree"
cd "$SRCDIR"
# prefer the copy already staged by build/fetch-deps.sh (it hashes against
# kernel.org's published sha256 in work/src/deps.sha256)
SRCWIN=${SRCWIN:-$ARCH_ROOT/../sources}
if [ ! -f linux-$V.tar.xz ] && [ -f "$SRCWIN/linux-$V.tar.xz" ]; then
  cp "$SRCWIN/linux-$V.tar.xz" .
  LINE=$(tr -d '\r' < "$SRCWIN/deps.sha256" 2>/dev/null | grep -m1 "  linux-$V\.tar\.xz\$" || true)
  [ -n "$LINE" ] || { echo "!! no recorded hash for linux-$V.tar.xz"; exit 1; }
  echo "$LINE" | sha256sum -c - || { echo "!! staged linux-$V.tar.xz does not match deps.sha256"; exit 1; }
fi
[ -f linux-$V.tar.xz ] || curl -fLO https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$V.tar.xz
rm -rf "$BUILD"; mkdir -p "$BUILD"; cd "$BUILD"
tar -xf "$SRCDIR"/linux-$V.tar.xz; cd linux-$V

FK="$FREEDOM/packages/kernel"
while IFS= read -r p; do
  p="${p%%#*}"; p="${p## }"; p="${p%% *}"; if [ -z "$p" ]; then continue; fi
  patch -p1 --batch --forward -F0 --no-backup-if-mismatch --quiet < "$FK/patches/$p" >/dev/null 2>&1 \
    || echo "freedom: skipped $p"
done < "$FK/patches/series"
cp "$FK"/dts/*.dts "$FK"/dts/*.dtsi arch/arm64/boot/dts/qcom/
for p in "$FK"/dts/*.patch; do patch -p1 -F0 --no-backup-if-mismatch -s < "$p" || echo "freedom dts: skipped $p"; done

patch -p1 --no-backup-if-mismatch < "$REPO/kernel/tb710fu-kernel-on-freedom.patch"
echo "== local TB710FU kernel changes (battmgr polarity, LPASS clock race, DTS)"
patch -p1 --no-backup-if-mismatch < "$ARCH_ROOT/patches/0001-tb710fu-local.patch"

echo "== initramfs (Arch variant)"
mkdir -p ../initramfs
cp "$BB" ../initramfs/busybox
cp "$ARCH_ROOT"/initramfs/{init,diag.sh,nbdroot.sh,usb-net.sh} ../initramfs/
# our own NBD client: busybox's nbd-client applet reads only 2 of the 4 newstyle greeting
# flags, which shifts the whole stream (1.5 TiB disk, "Wrong magic (0x6744)"). See
# arch/nbdclient.c. Static, so it runs before any rootfs exists.
aarch64-linux-gnu-gcc -static -O2 -Wall -o ../initramfs/nbdclient "$ARCH_ROOT/nbdclient.c"
cat > initramfs.list <<LIST
dir /dev 755 0 0
nod /dev/console 600 0 0 c 5 1
dir /bin 755 0 0
dir /proc 755 0 0
dir /sys 755 0 0
dir /tmp 1777 0 0
dir /run 755 0 0
dir /newroot 755 0 0
file /bin/busybox $PWD/../initramfs/busybox 755 0 0
file /init $PWD/../initramfs/init 755 0 0
file /diag.sh $PWD/../initramfs/diag.sh 755 0 0
file /nbdroot.sh $PWD/../initramfs/nbdroot.sh 755 0 0
file /usb-net.sh $PWD/../initramfs/usb-net.sh 755 0 0
file /nbdclient $PWD/../initramfs/nbdclient 755 0 0
LIST

echo "== config (base + arch fragment)"
cp "$REPO/kernel/config-$V-tb710fu" .config
ARCH_ROOT="$ARCH_ROOT" scripts/kconfig/merge_config.sh -m .config "$ARCH_ROOT/fragments/arch.config" || \
  echo "!! some arch.config options were rejected - check above"
# version must stay exactly 7.2.6-tb710fu: install_payload.sh installs modules by that name
grep -q 'CONFIG_LOCALVERSION="-tb710fu"' .config || \
  { echo 'CONFIG_LOCALVERSION="-tb710fu"' >> .config; echo "# CONFIG_LOCALVERSION_AUTO is not set" >> .config; }
grep -q 'CONFIG_INITRAMFS_SOURCE="initramfs.list"' .config || \
  echo 'CONFIG_INITRAMFS_SOURCE="initramfs.list"' >> .config
make -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= olddefconfig
# these must be built in, not modules: the GPU/clock/PHY drivers have to be present before
# the display bring-up and the NBD root have any chance to load modules (docs/linux-kernel.md).
# NOTE the symbol names are this tree's own: the SM8650 GPU clock controller is
# CONFIG_SM_GPUCC_8650 (drivers/clk/qcom/Kconfig), there is no CONFIG_GPU_CC_SM8650.
MISS=""
for k in CONFIG_BLK_DEV_NBD CONFIG_PHY_QCOM_QMP CONFIG_SM_GPUCC_8650 CONFIG_QCOM_LLCC \
         CONFIG_EXT4_FS CONFIG_DMABUF_HEAPS; do
  grep -q "^$k=y" .config || MISS="$MISS $k"
done
if [ -n "$MISS" ]; then
  echo "!! these must be =y, but are not:$MISS"
  for k in $MISS; do printf '   %-26s %s\n' "$k" "$(grep -m1 "^$k" .config || echo '(absent from .config)')"; done
  exit 1
fi

echo "== build"
make -j"$(nproc)" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= Image dtbs modules
make -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= \
  INSTALL_MOD_PATH=../modstage INSTALL_MOD_STRIP=1 modules_install
KV=$(make -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= kernelrelease)
rm -f ../modstage/lib/modules/$KV/{build,source}
tar cf "$OUT"/modules-$KV.tar -C ../modstage/lib/modules "$KV"
cp arch/arm64/boot/Image "$OUT"/Image
cp arch/arm64/boot/dts/qcom/sm8650-lenovo-tb710fu-kshim.dtb "$OUT"/
ls -l "$OUT"
echo "== kernelrelease $KV"
echo "Image is $(stat -c%s "$OUT"/Image) bytes - the ABL raw limit is ~86.5 MB for the packed kernel"
