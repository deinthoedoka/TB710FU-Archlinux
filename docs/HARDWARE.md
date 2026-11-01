# 硬件与启动链

## 设备

| 项目 | 参数 |
| --- | --- |
| 型号 | Lenovo TB710FU（小新 Pad Pro GT，2025） |
| SoC | Qualcomm SM8650（骁龙 8 Gen 3），4 nm |
| CPU | 1× Cortex-X4 + 3× A720 + 2× A720 + 2× A520 |
| GPU | Adreno 750 |
| 内存 | 12 GB LPDDR5X（Linux 显示 10.7 GiB，正常） |
| 存储 | 256 GB UFS 4.0 |
| 屏幕 | 12.7" 3200×2000 LCD，120 Hz，双 DSI + DSC，NT36532 |
| 触摸 | Novatek NT36532（SPI），支持手写笔 |
| 音频 | 4× AW882xx 功放 + WCD939x，TDM |
| Wi-Fi / BT | WCN7850（ath12k），Wi-Fi 7 |
| 传感器 | ADSP（Light / ACC），hexagonrpcd |
| 电池 | 10200 mAh，PMIC 通过 qcom_battmgr 上报 |
| 皮套 | 霍尔传感器接 GPIO66 |

## 分区与启动

```
GPT (UFS LUN0, 4 KiB 扇区)
├─ boot_a      96 MiB   kShimC 菜单 + ZUXOS 内核 + Arch Image + DTB（本项目唯一写入的分区）
├─ boot_b      96 MiB   原厂，保持不动
├─ vbmeta_a/b  64 KiB   原厂（解锁后不再需要替换）
├─ super       Android 动态分区
├─ userdata    ZUXOS 用户数据；尾部划出 arch 分区
└─ sda15 arch  80–128 GiB  ext4 LABEL=arch-root  ← Arch 根
```

### 双系统菜单

`boot_a` 里不是单个内核，而是 [kShimC](https://github.com/sunflower2333/kShimC) 菜单 +
两个 payload：

- **ZUXOS**：原厂 GKI 内核 + Android boot 参数
- **Arch**：`Image`（7.2.6-tb710fu）+ 我们的 DTB + initramfs

开机 8 秒倒计时，音量键选择、电源键确认。默认项由打包时的 `--default` 决定
（`boot_zui.img` 默认 ZUXOS，`boot_arch.img` 默认 Arch）。

### initramfs 的根查找顺序

1. GPT 分区名 `arch`（也接受 `steamos`）→ 直接 `switch_root`
2. 命令行带 `tb710fu.nbd` → USB 网卡 + NBD（安装时用）
3. 都没有 → telnet 诊断 shell（`tb710fu.diag` 可强制进入）

### 为什么只写 boot_a

Bootloader 解锁后，ABL 不再强制校验 `vbmeta_a` 链，因此只需要替换 `boot_a`。
`boot_b`、`vbmeta`、`super` 保持原厂，出问题可以用 `fastboot flash boot_a
原厂 boot_a.img` 回滚。

### A/B 重试计数

Linux 启动后不会通知 ABL“这个 slot 成功了”，ABL 每启动一次 Arch 就把
`slot-retry-count:a` 减一。归零后 ABL 不再加载 `boot_a`，直接进 fastboot。

**唯一的持久修法**：定期启动一次 ZUXOS，Android 的 `fs_mgr` 会把 slot 标记为成功。
计数已经归零时：`fastboot set_active a` + `fastboot reboot`（只改 slot 元数据）。
