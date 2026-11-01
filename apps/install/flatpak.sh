#!/bin/bash
# Flatpak + Discover integration. The SJTU mirror is used because flathub.org is slow
# from mainland China; drop the URL if you are elsewhere.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
pacman -S --needed --noconfirm --disable-sandbox flatpak
flatpak remote-add --if-not-exists flathub \
  https://mirror.sjtu.edu.cn/flathub/flathub.flatpakrepo
echo "done - open Discover, Flatpak apps are listed under Sources"
