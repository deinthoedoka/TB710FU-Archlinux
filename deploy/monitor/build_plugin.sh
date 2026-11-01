#!/bin/bash
# 在平板上重建 ksystemstats GPU 插件（msm/Adreno 平台设备支持）。
# 在平板以 root 运行；补丁文件在 /root/ksysmsm/patch/（deploy_monitor.sh 上传）。
# 用法: build_plugin.sh [ksystemstats 源码 tar.xz]
# 不带参数时自动从 download.kde.org 下载对应版本。
# 注意: 补丁按已安装的 ksystemstats 版本制作（升过级要用新版本号重打，
# 见 V= 和下面 tarball URL）。
set -eu
export LC_ALL=C
PATCH=/root/ksysmsm/patch
BASE=/root/ksysmsm
INSTALLED=$(pacman -Qi ksystemstats 2>/dev/null | awk '/^Version/{print $3; exit}')
V=${INSTALLED%%-*}
[ -n "$V" ] || { echo "没查到已安装的 ksystemstats 版本"; exit 1; }
echo "已安装 ksystemstats: $INSTALLED"
case "$V" in
  6.8.2) : ;;
  *) echo "提示: 补丁与 .so 是按 6.8.2 验证的，其它版本通常也能编，遇到冲突需手动看 $PATCH";;
esac

WORK=$BASE/ksystemstats-$V
if [ ! -d "$WORK" ]; then
    if [ -n "${1:-}" ]; then
        mkdir -p "$WORK" && tar xf "$1" -C "$WORK" --strip-components=1
    else
        URL="https://download.kde.org/stable/release-service/$V/src/ksystemstats-$V.tar.xz"
        echo "下载 $URL"
        curl -fL --retry 3 -o "$BASE/src.tar.xz" "$URL"
        mkdir -p "$WORK" && tar xf "$BASE/src.tar.xz" -C "$WORK" --strip-components=1
    fi
fi

echo "=== 套用补丁 ==="
cp "$PATCH/LinuxBackend.cpp" "$PATCH/LinuxMsmGpu.h" "$PATCH/LinuxMsmGpu.cpp" \
   "$PATCH/CMakeLists.txt" "$WORK/src/plugins/gpu/"

echo "=== 编译（只编 GPU 插件，约 1-2 分钟）==="
cmake -B "$WORK/build" -S "$WORK" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF >/dev/null
ninja -C "$WORK/build" ksystemstats_plugin_gpu
SO=$(find "$WORK/build" -name 'ksystemstats_plugin_gpu.so' | head -1)
[ -n "$SO" ] || { echo "没有编译出插件"; exit 1; }

echo "=== 安装 ==="
TGT=/usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so
[ -f "$BASE/ksystemstats_plugin_gpu.so.stock-backup" ] || cp -v "$TGT" "$BASE/ksystemstats_plugin_gpu.so.stock-backup"
install -m755 "$SO" "$TGT"
cp -v "$SO" "$BASE/ksystemstats_plugin_gpu.so.tb710fu-msm"

echo "=== 重启 ksystemstats（Plasma 会自动拉起）==="
pkill -x ksystemstats || true
sleep 2
systemctl --user -M alarm@.host is-active plasma-ksystemstats.service 2>/dev/null || true
echo "完成。系统监视器 → GPU 页应有 Adreno GPU（gpu0）"
