#!/bin/sh
# TB710FU suspend-death fix — ADSP q6v5 handover interrupt one-shot (2026-11-09).
# No-reflash patch installer, same pattern as tb710fu-powerkey/phantomkey-fix.
#
# Bug fixed: the tablet sometimes "dies" while suspended (s2idle) — pressing
# the power key later shows a fresh boot.  Forensics (XBL log @0x81a00000 +
# AOP log @0x81c80000) showed a PSHOLD warm reset classified by the secure
# side as "wdog or kernel error" while the kernel was frozen in suspend,
# with a ~1/82 per-cycle failure rate.  The top suspect: the vendor ADSP
# firmware toggles the smp2p lines continuously (~5/s), so qcom_q6v5's
# handover IRQ fired ~300 times/minute, each hit logging
# "Handover signaled, but it already happened" (214846 entries in a 24h
# boot).  This patch makes the handover IRQ one-shot per prepare() cycle:
# the handler disables the IRQ right after taking the first edge, and
# unprepare() skips its own disable when the flag is set, keeping the
# enable/disable ledger balanced.  Real handover semantics are unchanged.
#
# Payload: one file, /usr/lib/modules/7.2.6-tb710fu/kernel/drivers/remoteproc/
# qcom_q6v5.ko (sha256 55ea71ce782a162afbc74d7ab1114c4372d8d6e7a798a65cc9d5ce6391adb404).
# The fix takes effect at the next REBOOT (the running kernel keeps the old
# module in memory).  depmod data is untouched: same path, same version.
#
# Baseline gate: the module is built against the reference 7.2.6-tb710fu
# kernel (ROM v2.0-era).  If the device's current qcom_q6v5.ko does not match
# the known baseline sha256 below, the kernel this device runs is NOT the one
# this module was built against — the installer refuses rather than risk a
# silently mismatched module.  Rebuild from source instead (see README).
#
#   ./install.sh              install (needs root)
#   DRY_RUN=1 ./install.sh    print the actions without touching anything
#   FORCE=1 ./install.sh      install even when the baseline check fails

set -eu

PKG_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FILES_DIR="$PKG_DIR/files"
BACKUP_ROOT=/var/backups/tb710fu-q6v5-handover-fix
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=$BACKUP_ROOT/$STAMP
DRY=${DRY_RUN:-0}
FORCE=${FORCE:-0}

MOD_REL=7.2.6-tb710fu
MOD_TARGET=/usr/lib/modules/$MOD_REL/kernel/drivers/remoteproc/qcom_q6v5.ko
MOD_PAYLOAD="$FILES_DIR/usr/lib/modules/$MOD_REL/kernel/drivers/remoteproc/qcom_q6v5.ko"
# The module this package replaces, as shipped with the reference kernel.
REF_OLD_SHA=1afc7cee0801624df5477b826bf560741ee99eb05a51ba59b4e55a2428d72dc1
NEW_SHA=55ea71ce782a162afbc74d7ab1114c4372d8d6e7a798a65cc9d5ce6391adb404

say() { printf '%s\n' "$*"; }

run() {
    if [ "$DRY" = "1" ]; then
        say "  [dry-run] $*"
    else
        "$@"
    fi
}

place() {
    pkg=$1; target=$2; mode=$3
    if [ -e "$target" ] && cmp -s "$pkg" "$target"; then
        say "  up-to-date: $target"
        return 0
    fi
    if [ -e "$target" ]; then
        run mkdir -p "$BACKUP_DIR$(dirname "$target")"
        run cp -a "$target" "$BACKUP_DIR$target"
        say "  backup: $target -> $BACKUP_DIR$target"
    fi
    run install -Dm"$mode" "$pkg" "$target"
    say "  installed: $target"
    REPLACED=1
}

[ "$(id -u)" = 0 ] || { say "请用 root 运行（sudo -i 或 ssh root@）"; exit 1; }

say "== 1/5 校验补丁包完整性 =="
( cd "$PKG_DIR" && sha256sum -c SHA256SUMS --quiet ) && say "  SHA256SUMS 全部通过"

say "== 2/5 内核匹配检查 =="
CUR_REL=$(uname -r)
if [ "$CUR_REL" != "$MOD_REL" ]; then
    say "  错误: 本机内核是 $CUR_REL，补丁模块是按 $MOD_REL 编译的，vermagic 不匹配。"
    say "       本补丁只适用于运行 $MOD_REL 内核的设备。"
    exit 1
fi
say "  内核版本: $CUR_REL ✓"
if [ -e "$MOD_TARGET" ]; then
    CUR_SHA=$(sha256sum "$MOD_TARGET" | awk '{print $1}')
    if [ "$CUR_SHA" = "$NEW_SHA" ]; then
        say "  本机已是修复版模块（幂等安装，仅复核）。"
    elif [ "$CUR_SHA" != "$REF_OLD_SHA" ] && [ "$FORCE" != "1" ]; then
        say "  错误: 本机现有的 qcom_q6v5.ko 与发行基线不一致（sha256 $CUR_SHA）。"
        say "       这台设备跑的不是本补丁对应的内核构建，模块 ABI 可能不匹配。"
        say "       如确认自己的内核就是 $MOD_REL 的改动版，请改用源码重编；"
        say "       或在理解风险后用 FORCE=1 ./install.sh 强行安装。"
        exit 1
    elif [ "$FORCE" = "1" ]; then
        say "  警告: 基线校验被 FORCE=1 跳过（sha256 $CUR_SHA）。"
    fi
else
    say "  警告: 未找到 $MOD_TARGET（模块缺失？），将按补丁包内容安装。"
fi

say "== 3/5 安装模块（仅替换有差异的） =="
place "$MOD_PAYLOAD" "$MOD_TARGET" 644

say "== 4/5 安装后复核 =="
if [ "$DRY" != "1" ]; then
    INST_SHA=$(sha256sum "$MOD_TARGET" | awk '{print $1}')
    [ "$INST_SHA" = "$NEW_SHA" ] || { say "  错误: 安装后 sha256 不符"; exit 1; }
    say "  安装后 sha256: $INST_SHA ✓"
    VM=$(modinfo -F vermagic "$MOD_TARGET" 2>/dev/null || echo unknown)
    case "$VM" in
        "$CUR_REL "*) say "  vermagic: $VM ✓" ;;
        *) say "  错误: vermagic 异常: $VM"; exit 1 ;;
    esac
else
    say "  [dry-run] 跳过安装后复核"
fi

say "== 5/5 生效与验证 =="
if lsmod | grep -q "^qcom_q6v5 "; then
    if [ "${REPLACED:-0}" = "1" ]; then
        say "  修复版模块已就位，旧模块仍在内存中运行——重启一次后生效。"
        say "  重启后验证（两条命令）："
        say "    grep 'q6v5 handover' /proc/interrupts   # 隔 20 秒跑两次，计数应停在 1 不动"
        say "    journalctl -k -b 0 | grep -c 'Handover signaled'   # 应为 0"
    else
        say "  本机已在运行修复版模块，本次没有替换文件，无需重启。"
    fi
else
    say "  模块当前未加载，下次开机将直接用修复版。"
fi
say "  备份目录: $BACKUP_DIR （按原路径存放被替换的旧模块，复制回去并重启即可回滚）"
say ""
say "完成。"
