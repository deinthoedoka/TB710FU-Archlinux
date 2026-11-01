#!/bin/bash
# 安装 TB710FU MTP（uMTP-Responder over FunctionFS），在平板以 root 运行。
# 源码探测顺序（编译 umtprd 用）: /root/mtp-deploy/umtp.tar.gz
#   源码: https://github.com/viveris/uMTP-Responder （make 即可，无额外依赖）
# 文件由 deploy_mtp.sh 放到 /root/mtp-deploy/。
set -eu
export LC_ALL=C
SRC=/root/mtp-deploy
G=/sys/kernel/config/usb_gadget/g1

echo "=== 1. umtprd 二进制 ==="
if [ -x /usr/local/bin/umtprd ]; then
    echo "已存在，跳过编译"
else
    T=$SRC/umtp.tar.gz
    [ -f "$T" ] || { echo "缺少 /usr/local/bin/umtprd，也没有 $T"; exit 1; }
    rm -rf /root/umtp-src
    mkdir -p /root/umtp-src
    case "$T" in
        *.tar.gz|*.tgz) tar xf "$T" -C /root/umtp-src --strip-components=1 ;;
        *)              cp -r "$T"/. /root/umtp-src/ ;;
    esac
    make -C /root/umtp-src -j"$(nproc)" >/dev/null
    BIN=$(find /root/umtp-src -type f -name umtprd | head -1)
    [ -n "$BIN" ] || { echo "编译产物里没有 umtprd"; exit 1; }
    install -m755 "$BIN" /usr/local/bin/umtprd
    echo "编译并安装 /usr/local/bin/umtprd"
fi

echo "=== 2. 配置与单元 ==="
install -m755 "$SRC/tb-mtp-gadget.sh" /usr/local/sbin/tb-mtp-gadget
install -m644 "$SRC/umtprd.conf" /etc/umtprd/umtprd.conf
install -m644 "$SRC/tb-mtp.service" /etc/systemd/system/tb-mtp.service

echo "=== 3. tb-usb-ncm 兼容（MTP function 随 NCM 一起 bind）==="
# tb-usb-ncm 先起（SSH 通道），如果它先 bind 了 UDC，configfs 就改不了了；
# 所以在它 bind 前把 ffs.mtp 挂进同一 gadget。仓库版的 tb-usb-ncm 已内置，
# 这里只兜底旧版安装。
if [ -f /usr/local/sbin/tb-usb-ncm ] && ! grep -q 'ffs.mtp' /usr/local/sbin/tb-usb-ncm; then
    sed -i.bak-mtp '\|\[ -e configs/c.1/ncm.usb0 \] || ln -s functions/ncm.usb0 configs/c.1/|a\
mkdir -p functions/ffs.mtp /dev/ffs-mtp\
mountpoint -q /dev/ffs-mtp || mount -t functionfs mtp /dev/ffs-mtp 2>/dev/null || true\
[ -e configs/c.1/ffs.mtp ] || ln -s functions/ffs.mtp configs/c.1/ffs.mtp' /usr/local/sbin/tb-usb-ncm
    echo "已给 tb-usb-ncm 打 ffs.mtp 兼容补丁（备份 .bak-mtp）"
fi

echo "=== 4. 启动 ==="
systemctl daemon-reload
systemctl enable --now tb-mtp.service
sleep 2

echo "=== 5. 重枚举（让 Windows 认出 MTP）==="
UDC=$(ls /sys/class/udc | head -1)
if [ -n "$(cat $G/UDC 2>/dev/null)" ]; then
    echo "" > "$G/UDC"; sleep 1; echo "$UDC" > "$G/UDC"; sleep 3
    ip link set usb0 up 2>/dev/null || true
fi

echo "=== 6. 状态 ==="
systemctl is-active tb-mtp.service tb-usb-ncm.service || true
ls -l "$G/configs/c.1/" | grep ffs || true
journalctl -u tb-mtp.service -n 5 --no-pager
