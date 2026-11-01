#!/bin/sh
# TB710FU: MTP gadget 前置准备(幂等)。
# 必须在 UDC bind 之前把 ffs.mtp function 挂进 g1(configs 目录在 bind 后不可改)。
# 注意:configfs 的 symlink 目标按当前目录解析,必须先 cd $G 再 ln。
# 由 tb-mtp.service 的 ExecStartPre 调用。
G=/sys/kernel/config/usb_gadget/g1
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
modprobe libcomposite 2>/dev/null
# umtprd 的命令队列需要 /dev/mqueue(缺它只影响 -cmd:lock 等外部控制,不影响传输)
mountpoint -q /dev/mqueue || { mkdir -p /dev/mqueue; mount -t mqueue none /dev/mqueue 2>/dev/null; }
mkdir -p $G/functions/ffs.mtp $G/configs/c.1
[ -e $G/configs/c.1/ffs.mtp ] || (cd $G && ln -s functions/ffs.mtp configs/c.1/ffs.mtp)
mkdir -p /dev/ffs-mtp
mountpoint -q /dev/ffs-mtp || mount -t functionfs mtp /dev/ffs-mtp
