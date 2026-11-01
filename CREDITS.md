# 致谢与许可

这个移植建立在很多人的工作之上。仓库里只包含本项目的脚本、配置和我们自己的补丁；
上游代码通过 `build/fetch-deps.sh` 拉取，各自遵循原许可。

## 上游项目

| 项目 | 用途 | 许可 |
| --- | --- | --- |
| [lich-wang/tb710fu-hyperos-steamos](https://github.com/lich-wang/tb710fu-hyperos-steamos) | TB710FU 板级支持、内核补丁、kShimC 集成 | 见仓库 |
| [mydanyi/armadaos-freedom](https://github.com/mydanyi/armadaos-freedom) | SM8650 内核补丁基线、kShimC 源码 | 见仓库 |
| [MeteoricmeteorLL/tb710fu-linux](https://github.com/MeteoricmeteorLL/tb710fu-linux) | DTS、面板/触摸/音频/Wi-Fi 补丁 | 见仓库 |
| [sunflower2333/kShimC](https://github.com/sunflower2333/kShimC) | boot_a 里的开机菜单 | GPL-2.0 |
| [Project-Aloha/DualBootKernelPatcher](https://github.com/Project-Aloha/DualBootKernelPatcher) | 双内核打包器 | 见仓库 |
| [linux-msm/hexagonrpc](https://github.com/linux-msm/hexagonrpc) | ADSP 传感器 FastRPC 守护 | GPL-3.0（`third_party/hexagonrpc/COPYING`） |
| [Arch Linux ARM](https://archlinuxarm.org/) | 基础发行版 | 各包许可 |
| [KDE Plasma](https://kde.org/plasma-desktop/) | 桌面 | GPL/LGPL |
| AOSP `avbtool` / `mkbootimg` | boot 镜像签名与打包 | Apache-2.0（`build/tools/`） |
| AOSP test keys (`testkey_rsa4096.pem`) | AVB 签名 | 公开的 AOSP 测试密钥 |

## 固件

`qcom/`、`ath12k/`、`novatek/`、`awinic/`、`qca/` 下的固件、传感器注册表和
`Lenovo-TB710FU-tplg.bin` **不在仓库里**，也不能从别人机器复制。用
`build/collect_firmware.sh` 从你自己设备的 `super.img` 提取；这些文件受 Lenovo /
Qualcomm / Novatek / Awinic 的许可约束，只允许在你自己拥有的设备上使用。

## 本项目

脚本、文档和设备侧配置：MIT（见 [LICENSE](LICENSE)）。
内核补丁（`build/patches/`）是 Linux 内核的衍生作品，遵循 GPL-2.0。

## 特别说明

- 本项目和 Lenovo、Qualcomm、Valve、腾讯均无关联。
- Steam 客户端、QQ、微信、Steamcommunity 302 的二进制不随仓库分发。
- Waydroid、GNOME 等历史方案没有包含在这里；当前桌面是 KDE Plasma。
