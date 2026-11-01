#!/bin/bash
# 安装预编译的 GPU 监控插件（Release 资产，不想在平板上编译时用）。
# 在平板以 root 运行；预编译 .so 由 deploy_prebuilt.sh 放到 /root/ksysmsm/。
# 只适用于和资产同版本的 ksystemstats（资产名里带版本号，如 6.8.2）。
set -eu
export LC_ALL=C
BASE=/root/ksysmsm
INSTALLED=$(pacman -Qi ksystemstats 2>/dev/null | awk '/^Version/{print $3; exit}')
echo "已安装 ksystemstats: ${INSTALLED:-none}"

SO=$(find "$BASE" -maxdepth 1 -name 'ksystemstats_plugin_gpu*.so' ! -name '*.stock*' | head -1)
[ -n "$SO" ] || { echo "$BASE 下没有预编译插件"; exit 1; }
case "$SO" in
  *$(echo "$INSTALLED" | cut -d- -f1-2 | tr . .)*) : ;;
  *) echo "警告: 资产版本与已安装 $INSTALLED 可能不匹配，插件加载失败就回退原版";;
esac

TGT=/usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so
[ -f "$BASE/ksystemstats_plugin_gpu.so.stock-backup" ] || cp -v "$TGT" "$BASE/ksystemstats_plugin_gpu.so.stock-backup"
install -m755 "$SO" "$TGT"
echo "已安装（原版备份在 $BASE/ksystemstats_plugin_gpu.so.stock-backup）"
pkill -x ksystemstats || true
sleep 2
echo "完成。系统监视器 → GPU 页应有 Adreno GPU（gpu0）"
