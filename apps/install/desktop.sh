#!/bin/bash
# Install the KDE Plasma desktop and the applications this port is used with.
# Deliberately no full `pacman -Syu`: the kernel is a custom build and the packaged
# linux-aarch64 must not replace it.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

PAC="pacman -S --needed --noconfirm --disable-sandbox"

echo "== KDE Plasma"
$PAC plasma-meta plasma-login-manager discover konsole dolphin kcalc \
     plasma-systemmonitor xdg-desktop-portal-kde polkit-kde-agent

echo "== fonts / input / language"
$PAC noto-fonts-cjk noto-fonts-emoji adobe-source-han-sans-cn-fonts \
     adobe-source-han-serif-cn-fonts ibus

echo "== desktop apps"
$PAC firefox libreoffice-fresh libreoffice-fresh-zh-cn fastfetch \
     network-manager-applet

echo "== sensors (auto brightness depends on this)"
$PAC iio-sensor-proxy

echo "== enable login manager"
systemctl enable plasmalogin.service

echo "done - reboot or 'systemctl start plasmalogin'"
