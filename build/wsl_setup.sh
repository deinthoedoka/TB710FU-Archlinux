#!/bin/bash
# wsl_setup.sh - one-time preparation of a WSL2 Ubuntu host for the TB710FU builds.
#
# Everything this installs is a build tool, nothing touches the tablet. Run as root:
#   wsl.exe -d Ubuntu -u root -- bash <repo>/build/wsl_setup.sh
set -euo pipefail
WIN=$(cd "$(dirname "$0")/.." && pwd)

echo "== host"
uname -a
grep -qi microsoft /proc/version || echo "!! this does not look like WSL - the build scripts work on any Debian/Ubuntu too"
[ "$(id -u)" = 0 ] || { echo "!! run as root (wsl -u root)"; exit 1; }

echo "== packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  build-essential bc bison flex libssl-dev libelf-dev dwarves kmod dpkg-dev \
  cmake ninja-build git patch rsync file xxd xz-utils zstd wget curl ca-certificates \
  python3 python3-pip python3-kconfiglib python3-cryptography \
  device-tree-compiler util-linux e2fsprogs dosfstools \
  gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
  qemu-user-binfmt binfmt-support >/dev/null
# Ubuntu 26.04 has no qemu-user-static any more: qemu-user-binfmt ships the static-pie
# qemu-aarch64 plus the /usr/lib/binfmt.d registration, and its "F" flag keeps the
# interpreter open, so aarch64 binaries keep working inside the chroot build_rootfs.sh makes.
echo "   ok"
for t in python3 make aarch64-linux-gnu-gcc openssl losetup sfdisk sgdisk mkfs.ext4 rsync dtc; do
  command -v "$t" >/dev/null || { echo "!! missing tool: $t"; exit 1; }
done
python3 -c 'import kconfiglib, cryptography; print("   kconfiglib + cryptography ok")'

# qemu-aarch64 must be registered for build_rootfs.sh's pacman to run under binfmt. With
# qemu-user-binfmt + systemd running in WSL it is already registered; otherwise do it by hand.
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
  mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
  update-binfmts --enable qemu-aarch64 2>/dev/null || \
    echo "   note: could not enable qemu-aarch64 binfmt here (build_rootfs.sh will say so)"
fi
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] && echo "   qemu-aarch64 binfmt registered" || \
  echo "   note: qemu-aarch64 binfmt NOT registered"

echo "== loop devices"
[ -e /dev/loop-control ] || echo "!! /dev/loop-control missing - losetup will not work in this WSL"
ls /dev/loop0 >/dev/null 2>&1 || echo "   note: /dev/loop0 not present yet; losetup creates it on demand"

echo "== staged sources (downloaded on the Windows side)"
SRCWIN=${SRCWIN:-$WIN/sources}
if [ -f "$SRCWIN/deps.sha256" ]; then
  (cd "$SRCWIN" && sha256sum -c deps.sha256) || echo "   !! one staged file does not match deps.sha256"
else
  echo "   none staged; the build scripts will fetch from the network"
fi

echo "== done. next: bash $WIN/build/wsl_build.sh"
