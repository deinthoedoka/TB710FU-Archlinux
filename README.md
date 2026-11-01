# 联想小新 Pad Pro GT（TB710FU）Arch Linux ARM 移植

把骁龙 8 Gen 3 平板变成一台完整的 Arch Linux 桌面，同时**保留原厂 ZUXOS**：
`boot_a` 里放 kShimC 开机菜单，开机时用音量键选择 ZUXOS 或 Arch，两边互不影响。

> **English**: A community port of Arch Linux ARM to the Lenovo Xiaoxin Pad Pro GT
> (TB710FU, SM8650). Dual-boots with the stock ZUXOS through a kShimC menu in `boot_a`;
> includes the kernel patches, firmware wiring, KDE Plasma desktop and all device fixes
> needed for daily use (display, touch, audio, Wi-Fi 7, sensors, charging, suspend).

**适用范围**：已解锁 Bootloader 的 TB710FU（小新 Pad Pro GT，SM8650 / 12 GB / 256 GB）。
不是同型号的机器不要刷。

---

## 这个系统能做什么

一台能当笔记本用的 Android 平板：

- 3200×2000 @ 120 Hz 内屏，原生面板驱动，KDE Plasma 6 桌面
- 触摸、手写笔、外接键盘鼠标
- 四扬声器、麦克风、耳机/蓝牙音频
- Wi-Fi 7（WCN7850）、蓝牙
- 环境光传感器 → 自动亮度（带学习），登录界面同样生效
- 皮套霍尔：合盖息屏 + 锁屏，开盖唤醒
- 三档电源方案（节能 / 平衡 / 性能），GPU 触摸抬频
- 电池电量/充电状态正确显示，休眠用 s2idle
- 常用桌面软件：Firefox、LibreOffice、Dolphin、Konsole、Discover（Flatpak）
- 可选：QQ、微信（官方 ARM64 版）、Steam（Valve ARM64 客户端）、FEX 跑 x86_64 游戏

Android 侧（ZUXOS）保持原样，随时可以切回去。

---

## 硬件支持状态

| 部件 | 状态 | 说明 |
| --- | --- | --- |
| 内屏 3200×2000 | ✅ | 双 DSI + DSC，原生面板驱动；**只有 120 Hz**，60 Hz 会黑屏/花屏 |
| 触摸 / 手写笔 | ✅ | NT36532，含笔的按键映射 |
| GPU | ✅ | Adreno 750（freedreno），Vulkan/OpenGL 可用 |
| 音频 | ✅ | 4× AW882xx + TDM，扬声器/麦克风/耳机 |
| Wi-Fi 7 | ✅ | WCN7850 / ath12k，2.4/5/6 GHz |
| 蓝牙 | ✅ | WCN7850 |
| 环境光 / 加速度 | ✅ | ADSP + hexagonrpcd + iio-sensor-proxy |
| 皮套霍尔 | ✅ | GPIO66，合盖息屏锁屏 |
| 充电 / 电量 | ✅ | 含“快充显示成放电”的修复 |
| 休眠 | ✅ | s2idle + UFS 掉线自愈 |
| 音量键 / 电源键 | ✅ | 硬件顺序相反，已对调 |
| 指纹 | ❌ | 无 Linux 驱动 |
| 摄像头 | ❌ | 无 Linux 驱动 |
| 蜂窝网络 / GPS | ❌ | 本机型无 modem |

---

## 优化与修复清单

这些不是“能开机”级别的移植，而是把它调到能日常使用：

### 显示

- 面板按固定顺序加载（`aw37503 → sy7758 → dispcc → panel → msm`），避免 udev
  提前探测把 ABL 的 simpledrm 画面打掉；加载后做一次 DRM off/on 解决 NT36532 的锁存竞态。
- 屏蔽 `dispcc_sm8550` 的自动 probe，防止它重配 PLL 导致黑屏。
- 面板驱动补上双 DSI + DSC 时序，3200×2000@120 稳定。
- 登录界面与桌面共用同一份 `kwinoutputconfig.json`（缩放、ICC、亮度）。

### 色彩

- 面板约 98% DCI-P3，但没有 EDID，KDE 默认按 sRGB 输出 → 颜色偏艳。
- 提供最小 Display P3 ICC（604 B，纯 Python 生成）：`accurate` 模式让 sRGB 内容正确映射；
  另有 `native`（原生鲜艳）和 `soft`（AdobeRGB，更淡）两档，菜单/CLI 一键切换。

### 触摸与性能

- 首次登录自动把内屏缩放设为 2×（可改）。
- GPU `min_freq` 触摸抬频：629 → 422 → 231 MHz，松手回落，滑动更跟手。
- 三档电源方案由自带服务接管 `org.freedesktop.UPower.PowerProfiles`：
  - `power-saver`：CPU 上限 50%，GPU ≤422 MHz，停抬频
  - `balanced`：全部放开
  - `performance`：CPU 最低频率抬到最大值 35%
- 系统设置里的“电源管理”能真实切换（原版 PPD 在骁龙上只会显示“不可用”）。

### 音频

- 修复 ADSP 启动期的 LPASS 时钟竞态：注册时钟时不再向还没起来的 DSP 发命令，
  否则 `rpmsg_send()` 永久阻塞、开机卡住。
- 首次播放静音的问题：`tb-audio-init` 先播 1 秒静音给 TDM 总线打时钟，再用数字 `1`
  打开四路功放（这些是 ENUM 控件，`on` 实际写 0）。
- WirePlumber 配置固定扬声器路由，禁用未接的输入。

### 网络

- ath12k：关闭进程上下文轮询（和 NAPI 抢同一个 SRNG 会 oops），开启硬件去重
  （否则 AP 重传的 MPDU 被当重复包丢掉，TCP 掉到 0.1–0.5 MB/s），固定 board name。
- 驱动按需加载（`tb-wifi.service`），避免开机阶段把板子搞挂。
- 法规域 CN；NetworkManager 接管 usb0 之外的接口。

### 传感器与自动亮度

- ADSP 传感器链路：`hexagonrpcd`（含本地 method 36 补丁）+ 传感器注册表 +
  `iio-sensor-proxy`，输出 lux。
- 自建自动亮度：0.5%–2%/100 ms 无级调节，12 个对数光照锚点；
  用户手动调亮度会被学习（同一光照下不再拉回曲线值），空闲调暗只暂停不学习。
- 登录界面（plasmalogin）由独立的 `tb-als-greeter` 直写背光，登录前后亮度连续。

### 电源、充电与休眠

- **充电显示修复**：PMIC 固件把充电电流报成负值，UPower 1.91 因此把快充显示成“放电”。
  驱动加 `current_inverted=1` 模块参数（不动 DTB/boot_a），墙充稳定显示充电。
- 强制 s2idle（深睡在这块板子上会唤不醒），并在唤醒时对 UFS 控制器做 `host_reset`
  自愈，解决偶发 UFS 掉线。
- UFS 运行时电源管理开启，减少空闲功耗。
- 音量键硬件顺序与标注相反，`tb-volume-swap` 在 udev 枚举后对调。

### 桌面与交互

- Plasma 6 + plasmalogin 登录管理器，首次登录自动 2× 缩放（参考设备用 2.5×，可随时改），
  Dolphin/Konsole/Discover 齐全。
- 中文环境：`zh_CN.UTF-8`、Noto/Source Han 字体、fontconfig 优先 SC 字形。
- 电源键短按不关机（交给桌面菜单），长按仍由 PMIC 处理；合盖由皮套守护接管。

---

## 仓库结构

```
build/      内核 / boot / rootfs / vbmeta 构建；本地内核补丁；NBD 安装服务
deploy/     设备侧修复的一键部署（SSH）：亮度、色域、皮套、GPU、电源、系统杂项
apps/       桌面与应用的安装说明（Steam/FEX/QQ/微信/302）
packages/   参考设备的 pacman 包清单
docs/       安装、特性、硬件、已知问题、排错
release/    预构建产物的使用说明、固件注入、镜像打包脚本
third_party/ hexagonrpc 源码与传感器配置
```

## 快速开始

> 完整步骤（含分区、NBD 安装、UFS 写入、风险点）见 [docs/INSTALL.md](docs/INSTALL.md)。
> 刷写 `boot_a` 是设备写入，务必先读完再动手。

1. **准备**：解锁 Bootloader；用 EDL 全分区回读一份备份；准备一台 Linux/WSL2 构建机。
2. **构建**：
   ```bash
   ./build/fetch-deps.sh
   bash build/wsl_build.sh all                 # Image、dtb、modules、kShimC、arch-nbd.img
   bash build/make-boot.sh /path/to/stock_boot_a.img   # boot_zui.img / boot_arch.img
   ```
3. **刷写**：`out/boot/boot_arch.img` → `boot_a`（只写 `boot_a`）。
4. **安装**：从 USB NBD 启动构建好的 Arch rootfs，`install_ufs.sh` 把系统写进
   userdata 尾部分出的 80 GiB 分区。
5. **部署**：系统启动后，在 PC 上 `deploy/deploy_all.sh <平板IP>`。
6. **应用**：`apps/install/desktop.sh` 装桌面；其余见 `apps/`。

**不想自己编译**：下载 Release 里的 `Image`、dtb、`kShimC.bin`、打包器和无固件 rootfs，
按 [release/README.md](release/README.md) 用你自己的 `boot_a` 打包即可，不需要交叉编译环境。
Release 不包含能直接刷的 boot 镜像，也不包含厂商固件——原因见该页。

## 已知问题

见 [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md)。最常见的三条：

- 内屏只能 120 Hz；60 Hz 会黑屏/花屏。
- 登录时偶发黑屏，触摸一下才亮。
- **每次重启 Arch 都会消耗一次 A/B 重试计数**：连续重启前先启动一次 ZUXOS，
  让 Android 把 slot 标记为成功，否则计数归零后只能进 fastboot。

## 发布到 GitHub

```bash
cd tb710fu-archlinux
git init
git config core.fileMode false          # Windows 的 F: 上所有文件都是 777
git add .
git commit -m "TB710FU Arch Linux ARM port"
git branch -M main
git remote add origin git@github.com:<你的账号>/tb710fu-archlinux.git
git push -u origin main
```

Release 上传的是“别人不用编译就能用”的产物，仓库里只保留源码和脚本。已经生成好的一套在
`out-release/`（被 `.gitignore` 排除，不进仓库）：

```bash
gh release create v1.0 \
  out-release/Image out-release/sm8650-lenovo-tb710fu-kshim.dtb \
  out-release/kShimC.bin out-release/MultiBootKernelPatcher \
  out-release/modules-7.2.6-tb710fu.tar \
  out-release/arch-nbd-base.img.zst.part00 out-release/arch-nbd-base.img.zst.part01 \
  out-release/SHA256SUMS \
  --notes-file out-release/RELEASE-NOTES.md
```

按 `release/make-image.sh` 重新生成时，分卷数量可能变化，以 `out-release/` 里实际文件为准。
**不要**上传 `boot_arch.img`：`boot_a` 必须用每个人自己的原厂镜像打包，原因见
[release/README.md](release/README.md)。

## 仓库里没有什么

为了能公开发布，下面这些**没有**收进来（也请不要从别人那里要）：

- SSH 私钥、Wi-Fi 密码、各种账号 token
- 浏览器、Steam、QQ、微信的用户数据和个人文件
- 设备序列号、`socinfo/`、EDL 全分区备份、`super.img`
- 厂商固件与传感器注册表（用 `build/collect_firmware.sh` 从你自己的设备提取）
- Steam / QQ / 微信 / Steamcommunity 302 的二进制
- Waydroid 镜像、GNOME 时期的临时产物

## 致谢

这个移植站在很多人的工作上，详见 [CREDITS.md](CREDITS.md)。核心上游：

- [tb710fu-hyperos-steamos](https://github.com/lich-wang/tb710fu-hyperos-steamos)（板级支持、内核补丁、kShimC 集成）
- [armadaos-freedom](https://github.com/mydanyi/armadaos-freedom)（SM8650 内核补丁基线）
- [tb710fu-linux](https://github.com/MeteoricmeteorLL/tb710fu-linux)（DTS、面板/触摸/音频/Wi-Fi）
- [kShimC](https://github.com/sunflower2333/kShimC)、[DualBootKernelPatcher](https://github.com/Project-Aloha/DualBootKernelPatcher)
- [hexagonrpc](https://github.com/linux-msm/hexagonrpc)

## 许可

本仓库的脚本和文档用 MIT。内核补丁沿用 Linux 内核的 GPL-2.0；上游项目的代码和
固件遵循各自的许可，见 [CREDITS.md](CREDITS.md) 与各目录内的 LICENSE。

## 免责声明

刷机有风险：错误的写入可能让设备变砖或丢失数据。本项目不提供任何担保。
**绝不**写 `persist`、`modemst*`、`fsg`、`fsc`、`devinfo`、`frp`、`keystore`、`ssd`、
`secdata`、`uefivarstore`、`cdt`、`ddr` 这些分区，也不要回滚旧的 userdata 原始镜像
（QTEE 防回滚会让 PIN 永久失效）。
