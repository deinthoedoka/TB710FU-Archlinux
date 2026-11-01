#!/bin/bash
# wsl_build.sh - run the TB710FU builds in WSL2 and bring the artifacts back to Windows.
#
#   wsl.exe -d Ubuntu -u root -- bash <repo>/build/wsl_build.sh kernel
#   wsl.exe -d Ubuntu -u root -- bash <repo>/build/wsl_build.sh shim
#   wsl.exe -d Ubuntu -u root -- bash <repo>/build/wsl_build.sh rootfs
#   wsl.exe -d Ubuntu -u root -- bash <repo>/build/wsl_build.sh all
#
# Builds happen on the ext4 side of WSL ($HOME/tb710fu) because compiling over a Windows mount is slow;
# only the finished artifacts are copied to <repo>/out. Logs land in
# <repo>/logs/build-<date> so the Windows side can read them afterwards.
#
# Set -u only: these scripts print long progress output and we want the log, not a silent exit.
set -uo pipefail
WIN=$(cd "$(dirname "$0")/.." && pwd)
export ARCH_ROOT=$WIN/arch
export REPO=$WIN/deps/tb710fu-hyperos-steamos
export FREEDOM=$WIN/deps/armadaos-freedom
export DBKP_SRC=$WIN/deps/DualBootKernelPatcher
export SRCWIN=$WIN/sources
export OUT=$HOME/tb710fu/out
export SRCDIR=$HOME/tb710fu/src
# do NOT export BUILD: build_kernel.sh and build_shim.sh have their own defaults
# ($HOME/tb710fu/build and $HOME/tb710fu/shim) and build_shim.sh starts with `rm -rf "$BUILD"`,
# so a shared value would delete the kernel tree.
LOGDIR=$WIN/logs/build-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT" "$SRCDIR" "$LOGDIR"

WHAT=${1:-all}
rc=0
run() {  # run <name> <script>
  local name=$1 script=$2 log=$LOGDIR/$1.log
  echo "== $name -> $log"
  bash "$script" 2>&1 | tee "$log"
  local r=${PIPESTATUS[0]}
  [ "$r" = 0 ] || { echo "!! $name failed ($r) - see $log"; rc=$r; }
}

case "$WHAT" in
  kernel|all) run kernel "$ARCH_ROOT/build_kernel.sh" ;;
esac
case "$WHAT" in
  shim|all)   run shim   "$ARCH_ROOT/build_shim.sh" ;;
esac
case "$WHAT" in
  rootfs|all)
    MODULES_TAR=$OUT/modules-7.2.6-tb710fu.tar \
    FWDIR=$WIN/build/firmware \
    SSH_PUBKEY=${SSH_PUBKEY:-} \
    BOOTDIR=$WIN/out/boot \
    run rootfs "$ARCH_ROOT/build_rootfs.sh"
    ;;
esac

echo "== copy artifacts to $WIN/out"
for f in Image sm8650-lenovo-tb710fu-kshim.dtb modules-7.2.6-tb710fu.tar \
         kShimC.bin MultiBootKernelPatcher arch-nbd.img; do
  if [ -e "$OUT/$f" ]; then
    cp -f "$OUT/$f" "$WIN/out/"
    printf '   %-40s %12d bytes  %s\n' "$f" "$(stat -c%s "$OUT/$f")" "$(sha256sum "$OUT/$f" | cut -d' ' -f1)"
  fi
done
if [ "$rc" -eq 0 ]; then
  echo "== done (rc=0)"
  exit 0
fi
echo "== FAILED (rc=$rc) - read the logs above before going on"
exit 1
