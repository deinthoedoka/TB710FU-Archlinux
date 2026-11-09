# TB710FU Windows 刷机教程（v2.0）

适用于 **联想小新 Pad Pro GT（TB710FU，SM8650）**，Windows 10/11 x64。
**不是这个型号不要刷。** Bootloader 必须已解锁，当前 slot 必须是 `a`。

本教程分两条路径，任选一条：

| 方式 | 适合谁 | 入口 | 特点 |
| --- | --- | --- | --- |
| **Agent 一键刷机** | 大多数人 | `windows\flash.cmd dual\|single` | 自动校验、解压、开 NBD、刷 boot、等到安装完成 |
| **手动刷机** | 想看清每一步 / Agent 失败时排查 | 本文第 3 节 | 自己敲 `fastboot` 和 `nbdserver.exe` 命令 |

两条路径刷的是同一个 `rootfs\arch-nbd.img.zst` 和同一对
`boot\boot_install_*.img`，结果完全一样。

---

## 0. 刷机前准备

### 0.1 必须满足

- Windows 10/11 **x64**，管理员权限。
- 一条**能传数据**的 USB-C 线（很多充电线没有数据线芯）。
- 平板 Bootloader 已解锁。
- 平板当前 slot 是 `a`；如果是 `b`，先执行：
  ```bat
  windows\tools\fastboot.exe set_active a
  ```
- 电脑本地磁盘至少 **40 GiB 空闲**（压缩包约 4.5 GiB，解压后的
  `work\arch-nbd.img` 是 22 GiB）。
- 解压到 **本地 NTFS/exFAT** 磁盘。不要放网络共享/UNC 路径，也不要放
  FAT32（单文件超过 4 GiB）。
- 双系统模式会 factory-reset Android 数据；单系统模式会删除全部 Android
  数据。**先备份**照片、微信/QQ、账号等。
- 强烈建议先用 EDL 做全分区备份，至少留下 `boot_a`、`super`、GPT。

> **防回滚警告**：不要回刷旧的 `userdata` 原始镜像。QTEE 有防回滚，
> 回滚后 PIN 可能永久不可用（`IKMHal_sendCmd status -30`）。

### 0.2 解压

把 `tb710fu-arch-rom-v2.0-windows.zip` 解压到本地磁盘，例如：

```text
D:\tb710fu-arch-rom-v2.0-windows\
  boot\
  rootfs\
  windows\
  README.zh-CN.md
  SHA256SUMS
```

Windows 11 资源管理器可以直接解压 ZIP64；Windows 10 如果报错，用免费的
[7-Zip](https://www.7-zip.org/) 解压。

### 0.3 装 fastboot 驱动

如果 `windows\tools\fastboot.exe devices` 看不到设备，安装 Google USB
Driver：

<https://developer.android.com/studio/run/win-usb>

设备管理器里应出现 `Android Bootloader Interface`。

### 0.4 进入 bootloader

1. 平板关机。
2. 按住 **电源 + 音量下**，直到出现 bootloader 界面。
3. 插上 USB 线，确认电脑识别。

---

## 1. 校验安装包（两种方式都建议先做）

在解压后的包根目录打开 **管理员 PowerShell**：

```powershell
Set-Location D:\tb710fu-arch-rom-v2.0-windows

Get-Content SHA256SUMS | ForEach-Object {
    if ($_ -match '^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
        $want = $Matches[1].ToLowerInvariant()
        $rel  = $Matches[2] -replace '/', '\'
        if (-not (Test-Path -LiteralPath $rel)) {
            Write-Host "MISSING $rel" -ForegroundColor Red
        } else {
            $got = (Get-FileHash -LiteralPath $rel -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($got -ne $want) {
                Write-Host "BAD     $rel" -ForegroundColor Red
            } else {
                Write-Host "OK      $rel" -ForegroundColor Green
            }
        }
    }
}
```

全部显示 `OK` 才继续。`rootfs\arch-nbd.img.zst` 有 4.3 GiB，哈希计算
可能需要一两分钟。

> Agent 模式会自动做同样的校验；手动模式建议保留这一步。

---

## 2. Agent 一键刷机

### 2.1 运行

双击：

```text
windows\flash.cmd
```

它会在没有参数时提示用法。推荐直接带参数运行（cmd 或 PowerShell）：

```bat
windows\flash.cmd dual
```

或：

```bat
windows\flash.cmd single
```

- `dual`：保留 Android/ZUXOS，缩小 `userdata`，在尾部新建 `arch`。
- `single`：删除 Android 数据，把 `userdata` 改名为 `arch`，整块给 Arch。

脚本会自己请求管理员权限（需要加防火墙规则、必要时给 USB 网卡设静态地址）。

### 2.2 脚本会依次做什么

1. 校验包内 `SHA256SUMS`。
2. 检查 `fastboot devices`、`product`、`unlocked`、`current-slot`。
   - `product` 必须是 `topaz_prc_wifi` / `TB710FU` / `sm8650` 之类；
   - `unlocked` 必须是 `yes`；
   - `current-slot` 必须是 `a`。
3. 如果检测到设备已经存在 `arch` 分区，会警告：这是首次安装包，
   重装可能先启动旧系统，需要再输一次 `YES` 才继续。
4. 解压 `rootfs\arch-nbd.img.zst` 到 `work\arch-nbd.img`（约 22 GiB）。
5. 添加防火墙规则：允许 `172.16.42.0/24` 访问 TCP `10809`。
6. 启动 `windows\tools\nbdserver.exe`，默认读写，端口 `10809`。
7. 写安装 boot 镜像：
   ```bat
   fastboot flash boot_a boot\boot_install_dual.img
   :: 或 single
   fastboot reboot
   ```
8. 等平板通过 USB 网卡连上来，安装器在平板上分区、`mkfs.ext4`、
   `rsync` 整个系统，然后写最终 `boot_a`，带 `bootonce-bootloader`
   重启回 fastboot。
9. 电脑检测到 fastboot 后自动：
   ```bat
   fastboot reboot
   ```
   进入新系统。

### 2.3 什么时候算成功

- 平板屏幕（tty0）显示 `INSTALL-OK`；
- 平板回到 bootloader，脚本打印 `installer finished; rebooting...`；
- 脚本最后打印 `done`；
- 首次启动进入 GNOME。

日志位置：

- 电脑：`work\nbd.log`、`work\nbd.err`
- 平板：`/var/log/tb-install.log`

### 2.4 安装期间

- **不要拔线。**
- 分区 + rsync 大约几分钟到十几分钟，取决于 U 盘/数据线速度。
- 45 分钟还没回到 fastboot：看平板屏幕和 `work\nbd.log`，不要直接拔线。

### 2.5 Agent 常见问题

| 现象 | 处理 |
| --- | --- |
| `fastboot devices` 看不到设备 | 装 Google USB Driver；换数据线/USB 口；确认在 bootloader 界面 |
| 脚本提示没有 `172.16.42.x` 地址 | Windows 通常会自动分配。打开“网络连接”，找到新出现的 `RNDIS`/`NCM`/`USB Ethernet` 网卡，设 IPv4 `172.16.42.2`、掩码 `255.255.255.0`，再重跑 |
| 防火墙提示/被公司策略拦截 | 手动放行 TCP 10809 入站，来源 `172.16.42.0/24` |
| SmartScreen/杀软拦截 `nbdserver.exe` | 选择“仍要运行”；它没有签名 |
| 磁盘空间不足 | 需要约 40 GiB 空闲；`work\arch-nbd.img` 装完可删 |
| 设备已有 `arch` 分区 | 首次安装包会警告；重装需要先删除/改名旧 `arch`（高级操作），或 EDL 恢复 |
| 安装后开机直接进 fastboot | 执行 `fastboot set_active a`，再 `fastboot reboot` |

---

## 3. 手动刷机

手动模式使用包内自带的工具，不需要 Python。以下命令都在
**管理员 PowerShell** 里执行，工作目录是解压后的包根目录。

### 3.1 打开管理员 PowerShell 并进入包目录

```powershell
Set-Location D:\tb710fu-arch-rom-v2.0-windows
```

### 3.2 校验

按第 1 节的 PowerShell 片段执行，确认每一行都是 `OK` 再继续。

### 3.3 解压 rootfs

```powershell
New-Item -ItemType Directory -Force -Path work | Out-Null

windows\tools\zstd.exe -d -q -f --no-progress `
    rootfs\arch-nbd.img.zst -o work\arch-nbd.img
```

确认文件存在且约 22 GiB：

```powershell
Get-Item work\arch-nbd.img | Select-Object Length, FullName
```

### 3.4 启动 NBD 服务（保持窗口开着）

新开一个 **管理员 PowerShell** 窗口，仍然在包根目录：

```powershell
windows\tools\nbdserver.exe --image work\arch-nbd.img --port 10809
```

- 必须让这个窗口一直运行到安装完成。
- 默认是**读写**导出，安装器要在 NBD root 上写 `/var/log/tb-install.log`；
  **不要**加 `--ro`。
- 如果 10809 被占用，先关掉占用进程；平板侧固定连 10809，不能换端口。

### 3.5 加防火墙规则

在另一个管理员 PowerShell 里：

```powershell
$rule = "TB710FU NBD 10809"
Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 10809 -RemoteAddress 172.16.42.0/24 -Profile Any
```

如果公司电脑禁止改防火墙，需要让 IT 放行 TCP 10809（来源
`172.16.42.0/24`），否则平板连不上 NBD。

### 3.6 检查设备

```powershell
windows\tools\fastboot.exe devices
windows\tools\fastboot.exe getvar product
windows\tools\fastboot.exe getvar unlocked
windows\tools\fastboot.exe getvar current-slot
```

预期：

```text
product: topaz_prc_wifi
unlocked: yes
current-slot: a
```

如果 `current-slot` 是 `b`：

```powershell
windows\tools\fastboot.exe set_active a
```

检查是否已经存在 `arch` 分区：

```powershell
windows\tools\fastboot.exe getvar partition-size:arch
```

- 首次安装：应显示 `not found` / `unknown` / `FAILED`。
- 如果返回一个大小，说明设备之前装过：本包是首次安装包，安装
  initramfs 可能优先启动旧系统而不是 NBD 安装器。重装需要先删除/改名
  旧 `arch`（高级操作），或 EDL 恢复。

### 3.7 写安装 boot 并重启

双系统：

```powershell
windows\tools\fastboot.exe flash boot_a boot\boot_install_dual.img
windows\tools\fastboot.exe reboot
```

单系统：

```powershell
windows\tools\fastboot.exe flash boot_a boot\boot_install_single.img
windows\tools\fastboot.exe reboot
```

### 3.8 等 USB 网卡出现

平板重启后，内核 initramfs 会建一条 USB 网卡（NCM，失败回退 RNDIS）。
电脑应自动拿到 `172.16.42.x` 地址。检查：

```powershell
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -like '172.16.42.*' }
```

如果没有地址，找新网卡：

```powershell
Get-NetAdapter |
    Where-Object { $_.InterfaceDescription -match 'RNDIS|NCM|USB Ethernet|CDC' }
```

给它的 `ifIndex` 设静态地址：

```powershell
New-NetIPAddress -InterfaceIndex <上一步的 ifIndex> `
    -IPAddress 172.16.42.2 -PrefixLength 24
```

如果网卡是 Disabled：

```powershell
Enable-NetAdapter -InterfaceIndex <ifIndex> -Confirm:$false
```

### 3.9 等待安装完成

安装器会自动连 `172.16.42.2:10809` 的 NBD 服务，然后：

1. 备份 GPT 到新系统的 `/root/gpt-sda-before-arch-*.gpt`；
2. 缩小/改名分区，创建/扩展 `arch`；
3. `mkfs.ext4 -L arch-root`；
4. `rsync` 整个 rootfs；
5. 校验并写最终 `boot_a`；
6. 写 `misc` 的 `bootonce-bootloader`，重启回 fastboot。

期间：

- 平板屏幕会显示 `userdata extent` / `planned arch` / `rsync` 进度；
- NBD 窗口持续输出；
- **不要拔线。**

安装完成后平板回到 bootloader。轮询：

```powershell
windows\tools\fastboot.exe devices
```

看到设备后：

```powershell
windows\tools\fastboot.exe reboot
```

如果 45 分钟还没回到 fastboot：看平板屏幕和 NBD 窗口，不要直接拔线。

### 3.10 首次启动

- 双系统：8 秒 kShim 菜单，默认 Arch，可选 ZUXOS。
- 单系统：直接进 Arch。
- 默认账号 `alarm`，密码 `tb710fu`；`root` 同密码。
  **第一件事**：在 GNOME Console 里 `passwd` 和 `sudo passwd root` 改掉。
- Wi-Fi 自己连。
- SSH 默认关闭；需要时：
  ```sh
  sudo systemctl enable --now sshd
  ```
- 第一次进 GNOME / 第一次启动 droidloom 的 Android cell 需要几分钟。

### 3.11 手动模式清理

安装成功后：

1. 在 NBD 窗口按 `Ctrl+C` 停止服务。
2. 删除防火墙规则：
   ```powershell
   Remove-NetFirewallRule -DisplayName "TB710FU NBD 10809"
   ```
3. 删除 22 GiB 的临时镜像：
   ```powershell
   Remove-Item -LiteralPath work\arch-nbd.img -Force
   ```
4. 如果给 USB 网卡设过静态地址，可以在“网络连接”里改回自动获取。

### 3.12 手动模式常见问题

| 现象 | 排查 |
| --- | --- |
| NBD 窗口一闪而过 | 路径/端口错误；`work\arch-nbd.img` 是否解压完整；10809 是否被占用 |
| 平板一直连不上 NBD | 电脑没有 `172.16.42.2`；防火墙没放行；NBD 用了 `--ro`；USB 网卡被禁用 |
| 安装器报 `no room for an arch partition` | `userdata` 太小，Arch 至少需要 32 GiB；换单系统或先恢复分区 |
| 安装器报 `arch partition would be only N GiB` | 同上，`userdata` 剩余空间不足 |
| 安装后进 fastboot | `fastboot set_active a`，再 `fastboot reboot` |
| 重启又回 bootloader | 一次性 BCB 未清；装好后 `tb-clear-bcb` 会处理；也可手动 `fastboot reboot` |
| 设备已有 `arch` 分区 | 首次安装包会先启动旧系统；重装需先处理旧 `arch` |
| `fastboot flash` 失败 | 换线/换 USB 口；确认 `unlocked: yes`；不要在 `fastboot boot` 上浪费时间（ABL 禁用） |

---

## 4. 双系统 / 单系统怎么选

| | 双系统（dual） | 单系统（single） |
| --- | --- | --- |
| Android / ZUXOS | 保留 | 不保留 |
| 分区 | 缩小 `userdata`，尾部新建 `arch` | `userdata` 改名 `arch`，扩展到可用末尾 |
| Arch 容量 | Android 至少留 40 GiB，其余给 Arch | `userdata` 全部 + 磁盘尾部空闲 |
| Android 数据 | factory-reset | 全部清除 |
| 首次启动 | 8 秒菜单，默认 Arch | 直接 Arch |
| 适合 | 还想用 Android 应用/游戏 | 只要 Arch，存储全给 Linux |

容量自适应（约）：

| 机型 | 双系统 Arch | 单系统 Arch |
| --- | --- | --- |
| 8+128 | ~59 GiB | ~100 GiB |
| 8+256 / 12+256 | ~174 GiB | ~215 GiB |
| 12+512 | ~350 GiB | ~390 GiB |

Arch 分区最小 32 GiB；小于这个值安装器会拒绝并保持原样。

---

## 5. 回滚 / 救砖

- **只回滚启动**：从 EDL 备份取原厂 `boot_a.img`：
  ```bat
  windows\tools\fastboot.exe flash boot_a stock_boot_a.img
  windows\tools\fastboot.exe reboot
  ```
- **双系统回滚 Android 数据**：本包已经把 `userdata` 缩小并清零头部，
  原 Android 数据不可恢复；需要 EDL 恢复刷机前的 `userdata`/`super`
  备份。注意 QTEE 防回滚，不要刷旧 `userdata` 原始镜像。
- **单系统回滚**：需要 EDL 恢复原厂 `super`/`userdata`/GPT。本包没有
  修改 `persist`/`modemst`/`fsg`/`fsc`/`devinfo`/`frp`/`keystore`/
  `ssd`/`secdata`/`uefivarstore`/`super`/`vbmeta*`/`dtbo`/`init_boot`/
  `vendor_boot`。
- 安装器会把分区前的 GPT 备份写到新系统的
  `/root/gpt-sda-before-arch-*.gpt`。

---

## 6. 快速检查清单

刷机前：

- [ ] Windows 10/11 x64，管理员权限
- [ ] 数据线能传数据
- [ ] Bootloader 已解锁，`current-slot: a`
- [ ] 平板数据已备份
- [ ] 电脑本地磁盘 ≥ 40 GiB
- [ ] 包已解压到本地 NTFS/exFAT
- [ ] `SHA256SUMS` 全部 OK
- [ ] Google USB Driver 已装（fastboot 能识别）

刷机中：

- [ ] 平板在 bootloader
- [ ] NBD 服务在跑（手动模式）
- [ ] 防火墙放行 10809
- [ ] 电脑有 172.16.42.2 地址
- [ ] 不拔线、不关机

刷机后：

- [ ] 平板显示 `INSTALL-OK` 并回到 fastboot
- [ ] 电脑执行 `fastboot reboot`
- [ ] 首次启动进 GNOME
- [ ] 改掉 `alarm` 和 `root` 的默认密码
- [ ] 删除 `work\arch-nbd.img` 和防火墙规则
