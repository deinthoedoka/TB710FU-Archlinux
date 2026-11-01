#!/bin/bash
# build_shim.sh - build the boot-menu runtime (kShimC) and the packer (DualBootKernelPatcher)
# for the TB710FU dual-boot boot_a, without docker. Run in WSL2 Ubuntu/Debian x86_64.
#
# kShimC  = freedom's kshim-success-source
#           + pinned deps: picolibc f7edb08, lvgl 7f07a12, CrDK b6c3335 (through the tree's
#             own ports/crdk/prepare.py, which verifies the recorded patch hashes),
#             libfdt from dtc v1.6.1 laid out as lib/libfdt/{*.c,include/*.h}
#           + kshim/0001-tb710fu-sm8650-splash-mmu-reboot.patch (4-VIG split splash read,
#             temporary MMU during DT parse, size=0 DT reservation fix, pineapple reboot
#             whitelist) + kshim/tb710fu_defconfig (3200x2000, SPMI keys, no touch)
# DBKP    = DualBootKernelPatcher 2276163 + lib/inih
#           + freedom patches/boot 0001 (mbox: DTB sections default to 8-byte alignment -
#             ARM64 requires it, the stock packer defaults to 4-byte) and 0002 (PayloadFrom;
#             our build.cfg does not use it, so it is applied only if it applies cleanly)
#
# Two things this fixes over the repo's docker/kshim-build: the Dockerfile installs no
# cross compiler even though kShimC's CMakeLists pins /usr/bin/aarch64-linux-gnu-gcc, and
# lib/libfdt is not in any archive we have, so it is fetched from dtc here.
#
# Output in $OUT: kShimC.bin (exactly 4 MiB), MultiBootKernelPatcher
#
# Environment: ARCH_ROOT, REPO, FREEDOM, OUT, SRCDIR, BUILD
set -euo pipefail
ARCH_ROOT=${ARCH_ROOT:-$(cd "$(dirname "$0")" && pwd)}
REPO=${REPO:-$ARCH_ROOT/../deps/tb710fu-hyperos-steamos}
FREEDOM=${FREEDOM:-$ARCH_ROOT/../deps/armadaos-freedom}
DBKP_SRC=${DBKP_SRC:-$ARCH_ROOT/../deps/DualBootKernelPatcher}
KSHIM_SRC=${KSHIM_SRC:-$FREEDOM/devices/lenovo-tb323fu/boot/kshim-success-source}
OUT=${OUT:-$HOME/tb710fu/out}
SRCDIR=${SRCDIR:-$HOME/tb710fu/src}
BUILD=${BUILD:-$HOME/tb710fu/shim}
DEPS=$SRCDIR/deps
mkdir -p "$OUT" "$SRCDIR" "$DEPS"

echo "== packages"
sudo apt-get update -qq
sudo apt-get install -y -qq git cmake ninja-build build-essential python3 python3-pip \
  python3-kconfiglib device-tree-compiler patch rsync file xxd xz-utils \
  gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu >/dev/null
# Debian's python3-kconfiglib is not on PATH as genconfig everywhere; the CMake helper only
# imports the module, so make sure the module itself is importable.
python3 -c 'import kconfiglib' 2>/dev/null || pip3 install --break-system-packages -q kconfiglib
python3 -c 'import kconfiglib' || { echo "!! kconfiglib not importable"; exit 1; }
# CMakeLists does find_program(genconfig) and hard-fails without it. Debian/Ubuntu ship the
# kconfiglib modules (genconfig.py, menuconfig.py) but no console scripts, so provide one.
if ! command -v genconfig >/dev/null 2>&1; then
  GENCONFIG_PY=$(python3 -c 'import genconfig,sys; sys.stdout.write(genconfig.__file__)' 2>/dev/null || true)
  [ -n "$GENCONFIG_PY" ] || { pip3 install --break-system-packages -q kconfiglib; GENCONFIG_PY=$(command -v genconfig || true); }
  if [ -n "${GENCONFIG_PY:-}" ] && [ -f "$GENCONFIG_PY" ]; then
    if [ -w /usr/local/bin ]; then
      printf '#!/bin/sh\nexec python3 %s "$@"\n' "$GENCONFIG_PY" > /usr/local/bin/genconfig
      chmod +x /usr/local/bin/genconfig
    else
      printf '#!/bin/sh\nexec python3 %s "$@"\n' "$GENCONFIG_PY" | sudo tee /usr/local/bin/genconfig >/dev/null
      sudo chmod +x /usr/local/bin/genconfig
    fi
    echo "   installed /usr/local/bin/genconfig -> $GENCONFIG_PY"
  fi
fi
command -v genconfig >/dev/null || { echo "!! genconfig (kconfiglib console script) still missing"; exit 1; }
command -v aarch64-linux-gnu-gcc >/dev/null || { echo "!! no aarch64 cross gcc"; exit 1; }

# clone at a pinned revision (sha or tag), reuse if already correct
pin() {  # pin <dir> <url> <revision>
  local dir=$DEPS/$1 url=$2 rev=$3 want
  want=$(git -C "$dir" rev-parse --verify -q "$rev^{commit}" 2>/dev/null || true)
  if [ -n "$want" ] && [ "$(git -C "$dir" rev-parse HEAD)" = "$want" ]; then
    echo "   $1 already at $rev ($want)"; return
  fi
  echo "   fetching $1 @ $rev"
  rm -rf "$dir"; mkdir -p "$dir"; cd "$dir"
  git init -q; git remote add origin "$url"
  git fetch -q --depth 1 origin "$rev" 2>/dev/null || git fetch -q origin "$rev" || git fetch -q origin
  want=$(git rev-parse --verify -q "$rev^{commit}" 2>/dev/null || git rev-parse FETCH_HEAD)
  git checkout -q "$want"
  [ "$(git rev-parse HEAD)" = "$want" ] || { echo "!! $1 is at $(git rev-parse HEAD), wanted $rev"; exit 1; }
  echo "   $1 at $want"
}

# work/src on Windows: work/fetch_deps.ps1 stages the pinned tarballs there with a
# deps.sha256, so the build works with no GitHub access. Falls back to git when absent.
SRCWIN=${SRCWIN:-$ARCH_ROOT/../sources}
verify_hash() {  # verify_hash <file> - check against SRCWIN/deps.sha256 when the name is listed
  local f=$(basename "$1") line
  line=$(tr -d '\r' < "$SRCWIN/deps.sha256" 2>/dev/null | grep -m1 "  $f\$" || true)
  if [ -n "$line" ]; then
    (cd "$SRCWIN" && echo "$line" | sha256sum -c - >/dev/null 2>&1) \
      || { echo "!! $f does not match deps.sha256 - refuse to use it"; exit 1; }
    echo "   $f sha256 verified against deps.sha256"
  fi
}

# a dependency as a plain source tree: staged tarball first, git second
pin_tree() {  # pin_tree <name> <url> <revision>
  local name=$1 dir=$DEPS/$1
  if [ -d "$dir" ] && [ -f "$dir/.staged-from-tarball" ]; then echo "   $1 already staged"; return; fi
  if [ -f "$SRCWIN/$1.tar.gz" ]; then
    verify_hash "$SRCWIN/$1.tar.gz"
    rm -rf "$dir"; mkdir -p "$dir"
    tar -xf "$SRCWIN/$1.tar.gz" -C "$dir" --strip-components=1
    touch "$dir/.staged-from-tarball"
    echo "   $1 from the staged tarball"
    return
  fi
  pin "$1" "$2" "$3"
}

echo "== pinned dependencies"
pin_tree picolibc https://github.com/picolibc/picolibc f7edb08
pin_tree lvgl     https://github.com/lvgl/lvgl         7f07a12
# CrDK must be a git checkout for the port's own prepare.py (it compares rev-parse HEAD to
# UPSTREAM.json and uses `git archive`). Offline: hand build_shim the staged codeload tarball
# for exactly that revision, and materialize_crdk.py does the same job with its patch hashes.
CRDK_REV=b6c3335136b7f6b28271917de11e8f11982975fc
if [ -d "$DEPS/crdk/.git" ] && [ "$(git -C "$DEPS/crdk" rev-parse HEAD 2>/dev/null)" = "$CRDK_REV" ]; then
  echo "   crdk already at $CRDK_REV"
elif [ -f "$SRCWIN/crdk.tar.gz" ]; then
  echo "   crdk will come from $SRCWIN/crdk.tar.gz (codeload archive of $CRDK_REV)"
else
  pin crdk https://github.com/Project-Aloha/CrDK "$CRDK_REV"
fi
# libfdt: dtc release tarball from kernel.org (sha256 published there), not a GitHub tag
DTC_TAR=$(ls "$SRCWIN"/dtc-*.tar.xz 2>/dev/null | head -1)
if [ -n "$DTC_TAR" ]; then
  verify_hash "$DTC_TAR"
  rm -rf "$DEPS/dtc"; mkdir -p "$DEPS/dtc"
  tar -xf "$DTC_TAR" -C "$DEPS/dtc" --strip-components=1
  echo "   dtc $(grep -m1 '^VERSION' "$DEPS/dtc/Makefile" || echo '(version unknown)')"
else
  pin dtc https://github.com/devicetree-org/dtc v1.6.1
fi
grep -q 'VERSION 1.8' "$DEPS/picolibc/meson.build" 2>/dev/null || \
  echo "note: picolibc version string differs from the README's 1.8.11"

echo "== assemble kShimC tree"
rm -rf "$BUILD"; mkdir -p "$BUILD/kshim"
rsync -a --exclude .git "$KSHIM_SRC"/ "$BUILD/kshim"/
mkdir -p "$BUILD/kshim/lib"
rsync -a --exclude .git "$DEPS/picolibc/" "$BUILD/kshim/lib/picolibc/"
mkdir -p "$BUILD/kshim/third_party"
rsync -a --exclude .git "$DEPS/lvgl/" "$BUILD/kshim/third_party/lvgl/"
# CrDK goes through the port's own materializer when it is a git checkout at the pinned
# revision: it checks the revision, the recorded patch hashes, and never edits the clone.
# Offline (staged tarball) the same checks run through arch/materialize_crdk.py.
if [ -d "$DEPS/crdk/.git" ]; then
  python3 "$BUILD/kshim/ports/crdk/prepare.py" --source "$DEPS/crdk" --output "$BUILD/kshim/lib/CrDK"
else
  CRDK_SHA=$(tr -d '\r' < "$SRCWIN/deps.sha256" 2>/dev/null | grep -m1 '  crdk\.tar\.gz$' | cut -d' ' -f1 || true)
  # kShimC's configure re-runs prepare.py twice-over (once into lib/CrDK, once into the build
  # dir via `git archive`), and both insist on a git checkout. Patch those two spots to accept
  # the verified tarball FIRST: prepare.py's own bytes are part of the stamp signature, so
  # patching after materializing would invalidate the stamp the configure step relies on.
  python3 "$ARCH_ROOT/patch_prepare_offline.py" "$BUILD/kshim/ports/crdk/prepare.py" || exit 1
  python3 "$ARCH_ROOT/materialize_crdk.py" --port "$BUILD/kshim/ports/crdk" \
    --source "${CRDK_SRC:-$SRCWIN/crdk.tar.gz}" --output "$BUILD/kshim/lib/CrDK" \
    ${CRDK_SHA:+--sha256="$CRDK_SHA"} || { echo "!! CrDK could not be materialized"; exit 1; }
fi
[ -f "$BUILD/kshim/lib/CrDK/.kshim-crdk-stamp" ] || { echo "!! CrDK stamp missing"; exit 1; }

# libfdt: CMake lists lib/libfdt/fdt_addresses.c and include dirs lib/libfdt/include/.
# dtc v1.6.1 still has that name; newer dtc renamed it to fdt_addr.c, so bridge it if needed.
mkdir -p "$BUILD/kshim/lib/libfdt/include"
cp "$DEPS/dtc/libfdt"/*.c "$BUILD/kshim/lib/libfdt/"
cp "$DEPS/dtc/libfdt"/*.h "$BUILD/kshim/lib/libfdt/include/"
if [ ! -f "$BUILD/kshim/lib/libfdt/fdt_addresses.c" ] && [ -f "$BUILD/kshim/lib/libfdt/fdt_addr.c" ]; then
  echo '#include "fdt_addr.c"   /* dtc renamed fdt_addresses.c; kShimC lists the old name */' \
    > "$BUILD/kshim/lib/libfdt/fdt_addresses.c"
fi
for f in fdt.c fdt_check.c fdt_ro.c fdt_addresses.c fdt_rw.c fdt_sw.c fdt_wip.c \
         fdt_empty_tree.c fdt_strerror.c fdt_overlay.c; do
  [ -f "$BUILD/kshim/lib/libfdt/$f" ] || { echo "!! libfdt source missing: $f"; exit 1; }
done
# freestanding: libfdt calls malloc/free, and dtc's env header does not declare them
envh=$BUILD/kshim/lib/libfdt/include/libfdt_env.h
grep -q 'include <stdlib.h>' "$envh" || sed -i '0,/#include <string.h>/s//#include <string.h>\n#include <stdlib.h>/' "$envh"
grep -q 'include <stdlib.h>' "$envh" || { echo "!! could not add stdlib.h to libfdt_env.h"; exit 1; }

echo "== TB710FU patch + profile"
cd "$BUILD/kshim"
patch -p1 --no-backup-if-mismatch < "$REPO/kshim/0001-tb710fu-sm8650-splash-mmu-reboot.patch"
cp "$REPO/kshim/tb710fu_defconfig" configs/tb710fu_defconfig
grep -q 'compatible' src/dt/splash.c && grep -q 'tb710fu_splash_read' src/dt/splash.c \
  || { echo "!! TB710FU splash code not present after patching"; exit 1; }

echo "== build kShimC (4 MiB manifest runtime)"
# lvgl's CMakeLists does project(lvgl LANGUAGES C CXX ASM), while kShimC pins only
# CMAKE_C_COMPILER, so CXX has to come from the environment or configure dies.
CXX=/usr/bin/aarch64-linux-gnu-g++ CC=/usr/bin/aarch64-linux-gnu-gcc \
python3 tools/build_runtime.py --config configs/tb710fu_defconfig --out "$BUILD/out/menu" \
  --jobs "$(nproc)"
cp "$BUILD/out/menu/kShimC.bin" "$OUT"/kShimC.bin
sha256sum "$OUT"/kShimC.bin
[ "$(stat -c%s "$OUT"/kShimC.bin)" = 4194304 ] || { echo "!! kShimC.bin is not 4 MiB"; exit 1; }

echo "== assemble packer"
cp -a "$DBKP_SRC" "$BUILD/dbkp"
cd "$BUILD/dbkp"
git init -q && git add -A >/dev/null && git -c user.email=build@local -c user.name=build commit -qm base >/dev/null
if [ -f "$SRCWIN/inih.tar.gz" ]; then            # staged tarball (no GitHub needed)
  verify_hash "$SRCWIN/inih.tar.gz"
  rm -rf lib/inih; mkdir -p lib/inih
  tar -xf "$SRCWIN/inih.tar.gz" -C lib/inih --strip-components=1
else
  git clone -q --depth 1 https://github.com/benhoyt/inih lib/inih
fi
[ -f lib/inih/ini.c ] || { echo "!! inih missing - DBKP cannot configure"; exit 1; }
PB=$FREEDOM/devices/lenovo-tb323fu/patches/boot
gitam() { git -c user.email=build@local -c user.name=build am -q "$1"; }
# required: DTB alignment (our build.cfg also pins Align=3, so an unpatched packer still
# produces an 8-byte aligned DTB)
gitam "$PB/0001-patcher-local-commits.mbox" \
  || patch -p1 -F0 --no-backup-if-mismatch -s < "$PB/0001-patcher-local-commits.mbox" \
  || { echo "!! patcher patch 0001 did not apply"; exit 1; }
# optional: PayloadFrom support; unused by our config, so a mismatch is only a note
gitam "$PB/0002-patcher-shared-payload-working-tree.patch" \
  || patch -p1 -F0 --no-backup-if-mismatch -s < "$PB/0002-patcher-shared-payload-working-tree.patch" \
  || echo "note: patcher patch 0002 not applied (not needed for our build.cfg)"
cmake -B build -S . -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"
packer=$(find "$BUILD/dbkp/build" -maxdepth 2 -type f -name 'MultiBootKernelPatcher' | head -1)
[ -n "$packer" ] || { echo "!! packer binary not found"; exit 1; }
cp "$packer" "$OUT"/MultiBootKernelPatcher

echo "== result"
ls -l "$OUT"/kShimC.bin "$OUT"/MultiBootKernelPatcher
cat <<'END'
next (Windows side, pack_boot.py):
  set KSHIM_BUILD to a directory containing the packer, PACKER to it, then
  python -I arch\pack_boot.py --boot <stock boot_a.img> --shim kShimC.bin \
         --linux out\Image --dtb out\sm8650-lenovo-tb710fu-kshim.dtb --out out\boot --default zui
  (the packer is a Linux binary; run pack_boot.py inside WSL, or run the packer there and
   finish the AVB step on Windows)
END
