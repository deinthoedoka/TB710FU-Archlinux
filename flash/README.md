# 刷写 boot_a

只会写 `boot_a`。`boot_b`、`vbmeta_a/b`、`super`、`userdata` 都保持原厂。

## 准备

- Bootloader 已解锁（`fastboot oem device-info` 或开机第一屏的解锁提示）
- `adb`、`fastboot` 在 PATH 里
- 一份原厂 `boot_a.img` 放在手边，用于回滚

## 刷写

```bash
bash flash.sh out/boot/boot_arch.img
```

或者手动：

```bash
adb reboot bootloader
fastboot devices
fastboot flash boot_a out/boot/boot_arch.img
fastboot reboot
```

`boot_zui.img` 和 `boot_arch.img` 的区别只是菜单默认项：

| 镜像 | 菜单默认 |
| --- | --- |
| `boot_zui.img` | ZUXOS |
| `boot_arch.img` | Arch |

## 回滚

```bash
fastboot flash boot_a /path/to/stock_boot_a.img
```

如果进不了 fastboot，用 EDL 9008 写回 `boot_a`。**不要**顺手写 `vbmeta` 或 `super`。

## 注意

- `fastboot boot` 被厂商 ABL 禁用，只能 `flash`。
- 每次刷写前确认 sha256；刷完可以 `fastboot getvar current-slot` 确认仍是 `a`。
- 这个 ABL 有 A/B 重试计数，Linux 不会回报启动成功。连续重启 Arch 前先启动一次 ZUXOS。
