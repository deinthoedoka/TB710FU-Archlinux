# TB710FU Arch Linux 刷机包（双系统 / 单系统）

适用于 **联想小新 Pad Pro GT（TB710FU，SM8650）**，存储 **128 GB / 256 GB / 512 GB**
三种容量都支持（安装器按实际 `userdata` 大小自动分配）。Bootloader 必须已解锁。
不是这个型号不要刷。

系统内容：Arch Linux ARM + GNOME 51（含刷新率切换、电源键长按菜单、安卓窗口控制、
旋转动画、自动亮度、GPU 触摸加速）+ droidloom（Android 容器）+ Firefox +
Steam（ARM64 客户端）+ Shelly + Nautilus + GNOME Console + APK 安装器。
没有个人数据、没有 QQ/微信/LibreOffice/VLC/mpv/Flatpak 应用/FEX 根文件系统。

> **Windows 用户**：包内 `windows\WINDOWS-FLASH-GUIDE.zh-CN.md` 是分步教程，
> 分为 **Agent 一键刷机** 和 **手动刷机** 两条路径；本 README 是速查版。

---

## 下载哪个包

| 你的电脑 | 下载 | 内容 |
| --- | --- | --- |
| Windows 10/11 x64 | `tb710fu-arch-rom-v2.0-windows.zip` | 固件 + `windows\flash.cmd` + 内置 fastboot / nbdserver / zstd |
| Linux / WSL2 | `tb710fu-arch-rom-v2.0-linux.tar.zst` | 固件 + `flash.sh` + Python NBD 服务 |

两个包里的固件（rootfs、两个安装 boot 镜像）**完全相同**，只是各自带上该系统的
刷机工具和脚本。**只下载一个**，不要两个都下。

---

## 0. 先读：这是怎么刷的

这台机器的 ABL **禁用了 `fastboot boot`**，也没有第三方 recovery，所以做不出安卓那种
recovery zip 卡刷。本包的流程是：

1. 电脑用 `fastboot flash boot_a` 写入一个**安装专用**启动镜像；
2. 平板重启后，内核自带的 initramfs 建一条 USB 网卡，通过 **NBD** 从电脑读取干净的
   Arch rootfs；
3. 安装器在平板上分区、`mkfs.ext4`、`rsync` 整个系统，然后写入最终的 `boot_a`，
   带 `bootonce-bootloader` 标志重启回 fastboot；
4. 电脑检测到 fastboot 后自动 `fastboot reboot`，进入新系统。

全程只写 `boot_a`、`userdata`/新 `arch`、`metadata` 头部（双系统）和 `misc` 的 BCB。
`super`、`boot_b`、`vbmeta*`、`dtbo`、`init_boot`、`vendor_boot` 以及
`persist`/`modemst`/`fsg`/`fsc`/`devinfo`/`frp`/`keystore`/`ssd`/`secdata`/
`uefivarstore` 都不写。

> **注意**：不要回刷旧的 `userdata` 原始镜像。QTEE 有防回滚，回滚后 PIN 会永久不可用
> （`IKMHal_sendCmd status -30`）。刷机前请做 EDL 全分区备份，至少留下 `boot_a`、
> `super`、GPT。

---

## 1. 两种安装形式

| | 双系统（dual） | 单系统（single） |
| --- | --- | --- |
| Android / ZUXOS | 保留 | 不保留 |
| 分区 | 缩小 `userdata`，在尾部新建 `arch` | 把 `userdata` 改名为 `arch`，扩展到磁盘可用末尾 |
| Arch 容量 | 自动：ZUXOS 至少留 40 GiB，其余全给 Arch | `userdata` 全部容量 + 磁盘尾部空闲空间 |
| Android 数据 | 会 factory-reset（`userdata`/`metadata` 头部清零） | 全部清除 |
| 重要分区 | 都不动 | 都不动 |
| 首次启动 | 8 秒 kShim 菜单，默认 Arch；可选 ZUXOS | 无菜单，直接 Arch |

### 不同容量的实际大小（约）

| 机型 | `userdata` | 双系统 Arch | 单系统 Arch |
| --- | --- | --- | --- |
| 8 GB + 128 GB | ~100 GiB | ~59 GiB | ~100 GiB |
| 8 GB + 256 GB | ~215 GiB | ~174 GiB | ~215 GiB |
| 12 GB + 256 GB | ~215 GiB | ~174 GiB | ~215 GiB |
| 12 GB + 512 GB | ~390 GiB | ~350 GiB | ~390 GiB |

具体数字以安装器在平板屏幕（tty0）上打印的
`userdata extent` / `planned arch` 为准。Arch 分区最小 32 GiB；如果 `userdata`
小到分不出 32 GiB，安装器会拒绝并保持原样。

> 单系统模式还会把分区扩展到磁盘的可用末尾：如果这块盘以前刷过分区版系统
> （比如旧的 dual 布局在 userdata 后面留过空隙），这些空间会被一并并入
> Arch。sgdisk 遇到 userdata 之后还有别的分区时会拒绝扩展，安装器随即
> 原样保留原始范围，不会碰到任何在用分区。

---

## 2. 准备工作

- 一台 **Windows 10/11 x64** 或 **Linux / WSL2** 电脑。
- 能传数据的 USB-C 线（很多充电线没有数据线芯）。
- 平板 Bootloader 已解锁，当前 slot 为 `a`。
- 双系统：把 Android 里需要的东西备份走（微信/QQ/照片等）。
- 电脑至少 **40 GiB 空闲磁盘**：压缩包本身约 4.5 GiB（Linux 包 4.4 GiB），解压后的 `work\arch-nbd.img`
  是 22 GiB（Windows 的 zip 解压还会再占一份）。装完可以删掉 `work\`。
- Windows：管理员权限；如果 `fastboot` 不认设备，需要装 Google USB Driver：
  <https://developer.android.com/studio/run/win-usb>

检查设备（Linux）：

```sh
fastboot devices
fastboot getvar product       # topaz_prc_wifi（TB710FU 的出厂代号）
fastboot getvar unlocked      # yes
fastboot getvar current-slot  # a
```

Windows 用包内 `windows\tools\fastboot.exe` 执行同样的命令。

---

## 3. Windows 刷机

下载 **`tb710fu-arch-rom-v2.0-windows.zip`**（ZIP64，约 4.5 GiB）。解压到
**NTFS/exFAT** 本地磁盘（不要放网络共享/UNC 路径，也不要放
FAT32 盘——单个文件超过 4 GiB）。Windows 11 的资源管理器可以直接解压；Windows 10
如果报错，用免费的 [7-Zip](https://www.7-zip.org/) 解压。

1. 把整个包 **解压到本地磁盘**。
2. 关机，按住 **电源 + 音量下** 进入 bootloader，插上 USB。
3. 双击 `windows\flash.cmd`，或在命令行里：

   ```bat
   windows\flash.cmd dual
   :: 或
   windows\flash.cmd single
   ```

   脚本会自己请求管理员权限（要加防火墙规则、必要时给 USB 网卡设静态地址）。

4. 看到设备信息后输入 `YES` 确认。脚本会：
   - 校验 `SHA256SUMS`；
   - 解压 rootfs；
   - 启动内置 NBD 服务（TCP 10809）；
   - 写 `boot_install_<mode>.img` 到 `boot_a` 并重启；
   - 等平板通过 USB 网卡连上来，安装完成回到 fastboot；
   - 最后 `fastboot reboot` 进系统。

5. 安装期间**不要拔线**。平板屏幕会显示进度，电脑端日志在 `work\nbd.log`。

### Windows 常见问题

- **`fastboot devices` 看不到设备**：装 Google USB Driver；设备管理器里应该出现
  `Android Bootloader Interface`。换一根数据线/换 USB 口再试。
- **脚本提示没有 `172.16.42.x` 地址**：Windows 通常会自动给新出现的
  `RNDIS`/`USB` 网卡分配地址。若没有，打开“网络连接”，找到新网卡，设
  IPv4 `172.16.42.2`、掩码 `255.255.255.0`，再重新运行。
- **防火墙**：脚本会加一条允许 `172.16.42.0/24` 访问 TCP 10809 的入站规则。公司电脑
  如果禁止改防火墙，需要手动放行，否则平板连不上 NBD。
- **SmartScreen / 杀软**：包里的 `nbdserver.exe` 没有签名，可能被拦；选择“仍要运行”。
- **盘符空间**：解压后的 `work\arch-nbd.img` 是 22 GiB，装完可以删掉。

### 包内的 Windows 工具

| 文件 | 用途 | 来源/许可 |
| --- | --- | --- |
| `windows\tools\nbdserver.exe` | NBD 服务（本包自带，x64） | 本项目，MIT |
| `windows\tools\zstd.exe` | 解压 rootfs | facebook/zstd，BSD-3-Clause |
| `windows\tools\fastboot.exe` + `AdbWinApi.dll` | 线刷 | Android platform-tools，Google |
| `windows\tools\AdbWinUsbApi.dll` | fastboot 依赖 | 同上 |

`fastboot.exe` 是 32 位程序，Windows x64 可以直接运行。如果不想用包内的，也可以
自己装 platform-tools 后把 `fastboot.exe` 放到 PATH。

---

## 4. Linux / WSL2 刷机

下载 **`tb710fu-arch-rom-v2.0-linux.tar.zst`**（约 4.4 GiB），解压后进入目录：

```sh
tar --zstd -xf tb710fu-arch-rom-v2.0-linux.tar.zst
cd tb710fu-arch-rom-v2.0-linux

./flash.sh dual      # 双系统
# 或
./flash.sh single    # 单系统，Android 数据全部删除
```

依赖：`fastboot`、`python3`、`zstd`。（老版本 tar 不认 `--zstd` 时用
`zstd -dc tb710fu-arch-rom-v2.0-linux.tar.zst | tar -xf -`。）

WSL2 默认看不到 USB 设备，需要先用 `usbipd-win` 把平板转发进 WSL；不熟悉的话直接
用 Windows 脚本更省事。

---

## 5. 安装过程中

- 平板屏幕（tty0）会显示分区计划和 `rsync` 进度；大约几分钟到十几分钟。
- 电脑上的 NBD 日志：Linux `work/nbd.log`；Windows `work\nbd.log`。
- 45 分钟没有回到 fastboot：看平板屏幕和日志；**不要直接拔线**。
- 安装完成后平板会自己回到 bootloader，脚本检测到后自动重启。

---

## 6. 首次启动

- 双系统：8 秒菜单选 Arch（默认 Arch）或 ZUXOS。
- 单系统：无菜单，直接进 Arch。
- 默认账号：`alarm`，默认密码：`tb710fu`；`root` 同密码。
  **第一件事**：在终端里 `passwd` 和 `sudo passwd root` 改掉。
- 第一次进 GNOME 会初始化新用户目录；droidloom 首次启动会初始化 Android cell，
  需要几分钟。
- Wi-Fi 需要自己连（没有预置任何网络配置）。
- 自动亮度由 GNOME Shell 扩展 `tb-als@tb710fu` + root 的 `tb-als-claim` 提供，
  可在 **设置 → 电源 → 自动屏幕亮度** 开关。
- **SSH 默认关闭**（默认密码是公开的）。需要远程登录时：
  `sudo systemctl enable --now sshd`，并先改掉默认密码。
- 登录 90 秒后，`gnome-software`、`localsearch`、联系人后台服务会停止以释放内存；
  打开软件商店 / 搜索 / 联系人时会自动重启，不需要手动操作。

### 刷新率、安卓窗口和电源键

- 快捷设置里的 **「刷新率」** 磁贴：**自适应**（最高 120 Hz）或 **60Hz 上限**。
  60Hz 是合成器的出帧上限，KMS 仍然扫描 120Hz 模式，**不会切换面板模式、不会花屏**；
  切换即时生效。
- 顶部 **「安卓」** 菜单：对 droidloom 窗口执行 **全屏 / 最大化 / 调整大小 / 关闭**。
  调整大小时拖动四角手柄；窗口超出屏幕时扩展会自动缩回工作区。
- **短按电源键** = 熄屏 + 锁屏 + 挂起；**长按 ≥1 秒** = 「重启 / 关机 / 取消」菜单。
  `power-button-action` 设为 `nothing`，否则 gsd 会在按下的瞬间先挂起、长按识别不到。
  一直按住超过 PMIC 硬件阈值仍会强制复位，正常长按看到菜单松手即可。
- 旋转屏幕有 600 ms 的安卓式动画；开机第一次旋转的预热由 `tb-rotate-prewarm` 提前做。

### 熄屏、锁屏和挂起

GNOME 下 s2idle 实测可稳定唤醒（多次 RTC 定时和真实按键唤醒），所以本包**允许挂起**：

- 空闲 5 分钟自动熄屏并锁屏；不会自动挂起。可在 **设置 → 电源** 改时间或关掉。
- 合盖 = 关背光 + 锁屏；开盖立刻亮屏，不会再把 Wi-Fi/蓝牙关掉。
  （旧版合盖守护注入的是 `KEY_RFKILL`=247，内核会当成“射频总开关”，已改成
  正确的 `KEY_WAKEUP`=143。）
- 合盖挂起默认关闭；确实需要：`sudo touch /etc/tb-cover-suspend`。
- 背光跟随 DPMS：`tb-backlight-dpms` 检测到面板 Off 时把 `bl_power` 置 1。
- 射频软锁不再跨重启保存：`systemd-rfkill` 已 mask，开机由
  `tb-rfkill-unblock.service` 显式 unblock Wi-Fi + 蓝牙。
- 如果以后 s2idle 又出现唤不醒，可以启用包里自带的拦截器（默认关闭）：
  ```sh
  sudo systemctl enable --now tb-no-suspend
  ```

---

## 7. 包含的软件

- 桌面：GNOME 51（Shell / Settings / Nautilus / Console），扩展：
  `tb-display-mode`（刷新率）、`tb-power-menu`（长按电源菜单）、
  `tb-android-windows`（安卓窗口控制）、`tb-rotate-anim`（旋转动画）、
  `tb-als`（自动亮度）
- Android 容器：`droidloomd` / `droidloomctl` / `droidloom-applications` + APK 安装器
- 浏览器：Firefox
- 游戏：Steam ARM64 客户端（`~/.local/share/Steam`，不含游戏、账号、Steam Guard）
- 包管理：Shelly（`shelly-ui`，可装 pacman/Flatpak；AUR 构建需自行装 base-devel）
- 文件管理器：Nautilus
- 终端：GNOME Console
- 音频/网络/显示：PipeWire、NetworkManager、WirePlumber、Mesa/freedreno、VA-API 驱动
- 其他：`nano`、`vim`、`wget`、`unzip`、`android-tools`、`gptfdisk`、`rsync` 等维护工具

已移除：QQ、微信、LibreOffice、VLC、mpv、OBS、localsend、Steamcommunity302、
Flatpak 应用、FEX 根文件系统、开发工具链、旧内核 `linux-aarch64`、文档/man。

需要更多软件用 Shelly 或：

```sh
sudo pacman -S --needed --disable-sandbox <包名>
```

> 这个内核没有 Landlock；`/etc/pacman.conf` 已写 `DisableSandbox`，Shelly 才能正常下载。

---

## 8. 已知限制

1. **没有第三方 recovery，也没有真正的“卡刷”**：ABL 禁用了 `fastboot boot`，
   没有可用的 recovery 分区方案。首次安装只能走 `fastboot + USB-NBD`。
   装好之后可以在系统里用 `tbboot` 切换启动镜像，但不能在 recovery 里刷 zip。
2. **A/B 重试计数**：启动镜像已经写回 `androidboot.slot_suffix=_a`，droidloom 的
   Android 启动有机会像 ZUXOS 一样把 slot 标记成功。若仍然逐次减少
   `slot-retry-count:a`，双系统请每隔几次 Arch 启动进一次 ZUXOS；如果开机直接进
   fastboot：
   ```sh
   fastboot set_active a
   fastboot reboot
   ```
   单系统同样保留了 droidloom 的 Android cell，理论上走同一条标记路径。
3. **重装**：本包面向首次安装。机器上已经有 `arch` 分区时，安装镜像的 initramfs
   会优先启动旧系统而不是 NBD 安装器。重装需要先删除/改名旧 `arch` 分区（高级操作）。
   单系统想覆盖重装也一样要先处理旧 `arch`。
4. **Steam**：只带 ARM64 客户端和运行库，不含游戏/账号。x86_64 游戏需要 FEX，
   本包为了体积没有带；可在系统里自行安装 FEX。
5. **厂商固件**：镜像包含从本机提取的 Lenovo/Qualcomm 固件（显示/触摸/Wi-Fi/音频/GPU）。
   私下分发请自行确认版权；公开再分发建议改成“用户从自己的机器注入固件”。
6. **硬件限制**：指纹、摄像头、蜂窝/GPS 无 Linux 驱动；内屏只有 120 Hz。
7. **不要跑 `pacman -Syu`**：`/etc/pacman.conf` 已 `IgnorePkg` 掉发行版内核，但整系统
   升级仍可能覆盖自编组件。需要新包用 `-S --needed`。
8. **8 GB 内存机型**：GNOME + Firefox + droidloom 同时跑会比较紧；登录后
   `tb-background-trim` 会停掉软件商店/索引/联系人后台释放约 200-400 MB，打开时
   自动恢复。仍建议不要同时开 Steam 和大型 Android 游戏。12 GB 机型没有这个问题。

---

## 9. 校验

Linux：

```sh
sha256sum -c SHA256SUMS
```

Windows：`flash.cmd` 会自动逐项校验，任何一项不匹配就退出。

每个包里有自己的 `SHA256SUMS`：

- Windows：rootfs、两个 boot 镜像、`windows\flash.cmd`、`flash.ps1`、
  `windows\tools\` 下的 exe/dll 和许可文件；
- Linux：rootfs、两个 boot 镜像、`flash.sh`、`tools\nbd_server.py`。

`README.zh-CN.md` 不在清单里（方便你自己加笔记）。两个包的固件哈希相同。

---

## 10. 回滚

- 只回滚启动：从你自己的 EDL 备份取原厂 `boot_a.img`：
  ```sh
  fastboot flash boot_a stock_boot_a.img
  fastboot reboot
  ```
- 双系统回滚 Android 数据：本包已经把 `userdata` 缩小并清零头部；原 Android 数据
  不可恢复，需要 EDL 恢复你刷机前的 `userdata`/`super` 备份（注意 QTEE 防回滚，
  不要刷旧 `userdata` 原始镜像）。
- 单系统回滚：需要 EDL 恢复原厂 `super`/`userdata`/GPT；重要分区没有被本包修改。

安装器会把分区前的 GPT 备份写到新系统的 `/root/gpt-sda-before-arch-*.gpt`。
