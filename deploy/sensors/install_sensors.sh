#!/bin/bash
# Build and install hexagonrpcd, then hook it to the ADSP fastrpc node.
# Prerequisite: build/patches + kernel with CONFIG_QCOM_FASTRPC, and the sensor config
# directory taken from your own device (see README.md).
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$D/../.." && pwd)
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

echo "== fastrpc account"
getent group fastrpc >/dev/null || groupadd -r fastrpc
getent passwd fastrpc >/dev/null || useradd -r -g fastrpc -d / -s /usr/bin/nologin fastrpc

echo "== build hexagonrpc (meson)"
command -v meson >/dev/null || { echo "!! install meson + ninja first"; exit 1; }
cd "$TOP/third_party/hexagonrpc"
meson setup build --prefix=/usr/local --buildtype=release
ninja -C build
ninja -C build install
ldconfig

echo "== sensor config"
install -d /usr/share/qcom/sm8650/LENOVO/tb710fu/sensors
cp -a "$TOP/third_party/qcom-sensors/." /usr/share/qcom/sm8650/LENOVO/tb710fu/sensors/

echo "== iio-sensor-proxy"
if ! command -v iio-sensor-proxy >/dev/null 2>&1 && [ -f /etc/arch-release ]; then
  pacman -S --needed --noconfirm --disable-sandbox iio-sensor-proxy
fi

echo "== unit"
install -Dm644 "$D/hexagonrpcd-adsp-sensorspd.service" /etc/systemd/system/hexagonrpcd-adsp-sensorspd.service
systemctl daemon-reload
systemctl enable --now hexagonrpcd-adsp-sensorspd.service
echo "done - check with: monitor-sensor"
