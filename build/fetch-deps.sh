#!/bin/bash
# Fetch the pinned external inputs used by the build. Run once, from a Linux/WSL shell.
#
#   deps/tb710fu-hyperos-steamos   board support repo (kernel patch, config, kshim patch)
#   deps/armadaos-freedom          SM8650 kernel patch baseline (commit ba692d8)
#   deps/DualBootKernelPatcher     boot_a packer (commit 2276163)
#   sources/linux-7.2.6.tar.xz     upstream kernel tarball
#
# The tb710fu repo is tracked at HEAD. The port was developed against the 2026-10-31
# snapshot; if upstream moved, pin the commit you tested with.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEPS=$ROOT/deps
SRC=$ROOT/sources
mkdir -p "$DEPS" "$SRC"

clone() {
  local url=$1 dst=$2 rev=$3
  if [ ! -d "$dst/.git" ]; then git clone "$url" "$dst"; fi
  if [ -n "$rev" ]; then
    git -C "$dst" checkout "$rev"
  else
    git -C "$dst" pull --ff-only || true
  fi
}

clone https://github.com/lich-wang/tb710fu-hyperos-steamos "$DEPS/tb710fu-hyperos-steamos" ""
clone https://github.com/mydanyi/armadaos-freedom "$DEPS/armadaos-freedom" ba692d8
clone https://github.com/Project-Aloha/DualBootKernelPatcher "$DEPS/DualBootKernelPatcher" 2276163

if [ ! -f "$SRC/linux-7.2.6.tar.xz" ]; then
  curl -fL -o "$SRC/linux-7.2.6.tar.xz" \
    https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.6.tar.xz
fi
cp -f "$ROOT/build/deps.sha256" "$SRC/deps.sha256"
echo "== sources"
sha256sum "$SRC/linux-7.2.6.tar.xz"
echo "done"
