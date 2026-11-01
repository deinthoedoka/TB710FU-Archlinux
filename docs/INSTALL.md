# 安装指南

> 这份文档里的每一步都会写设备。**先完整读一遍**，准备好 EDL 全分区备份，再动手。
> 只写 `boot_a`；绝不碰 `boot_b`、ABL/XBL，以及任何唯一数据分区。

> **不想自己编译？** 用 Release 的预构建产物，步骤见 [../release/README.md](../release/README.md)：
> 只需要 EDL 备份、提取自己的固件、用自己的 `boot_a` 打包，不需要交叉编译环境。

## 0. 前提

| 项目 | 要求 |
| --- | --- |
| 设备 | Lenovo TB710FU（小新 Pad Pro GT），SM8650 / 256 GB |
| Bootloader | **已解锁**（`fastboot flash boot_a` 可用；`fastboot boot` 被厂商 ABL 禁用） |
| 备份 | EDL 全分区回读（至少 `boot_a`、`vbmeta_a`、`super`、`userdata` 的 GPT 副本） |
| 构建机 | Linux x86_64 或 WSL2 Ubuntu，≥30 GB 空闲；Windows 侧用 `wsl_build.sh` |
| 线材 | 能传数据的 USB-C 线；安装阶段平板通过 USB 网卡（NBD）启动 |

> **红线**：不要写 `persist` `modemst1` `modemst2` `fsg` `fsc` `devinfo` `frp` `keystore`
> `ssd` `secdata` `uefivarstore` `cdt` `ddr`。不要把旧的 userdata 原始镜像刷回去：
> QTEE 有防回滚，回滚后 PIN 永久不可用（`IKMHal_sendCmd status -30`）。

## 1. 构建

```bash
cd build
./fetch-deps.sh          # 拉 tb710fu-hyperos-steamos / armadaos-freedom / DualBootKernelPatcher + linux-7.2.6
```

`wsl_setup.sh` 装好交叉编译工具链（aarch64 gcc、qemu-user-binfmt、dtc、avbtool 依赖）。
然后：

```bash
bash wsl_build.sh all
```

产物在仓库根目录的 `out/`：

| 文件 | 用途 |
| --- | --- |
| `Image` | 内核（arm64 raw Image） |
| `sm8650-lenovo-tb710fu-kshim.dtb` | 设备树 |
| `modules-7.2.6-tb710fu.tar` | 内核模块 |
| `kShimC.bin` | 开机菜单（4 MiB） |
| `MultiBootKernelPatcher` | 双内核打包器 |
| `arch-nbd.img` | NBD 安装用 rootfs（12 GiB 稀疏镜像） |

### 1.1 收集固件

厂商固件（ADSP/CDSP、GPU、Wi-Fi、触摸、功放、面板）**不在仓库里**，必须从你自己
设备的 `super.img` 里提取：

```bash
sudo apt-get install -y simg2img erofs-utils android-sdk-platform-tools-common
bash build/collect_firmware.sh <你的 super.img> build/firmware
```

`build/firmware/` 会被 `build_rootfs.sh` 打进 rootfs，也会被 `install_payload.sh`
装到 `/usr/lib/firmware`。

### 1.2 构建 rootfs

```bash
export ROOT_PASS='你自己的密码'          # 必须设置；没有默认密码
export MODULES_TAR=$PWD/out/modules-7.2.6-tb710fu.tar
export FWDIR=$PWD/build/firmware
export SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"
bash build/build_rootfs.sh
```

`ROOT_PASS` 会同时用于 `root` 和初始用户 `tb`。构建脚本用 qemu-user 在 x86 上跑
aarch64 pacman，第一次会比较慢。

### 1.3 打包 boot_a

需要一份**原厂 `boot_a.img`**（从 EDL 备份里取，不要用别人机器的）：

```bash
bash build/make-boot.sh /path/to/stock_boot_a.img
```

它会打包两次，产物：

- `out/boot/boot_zui.img`：菜单默认进 ZUXOS
- `out/boot/boot_arch.img`：菜单默认进 Arch

两个都是 96 MiB，带 AVB footer，用 AOSP testkey 签名。也可以手动调用
`build/pack_boot.py`（参数见 `build/README.md`）。

> Bootloader 已解锁时，不再需要替换 `vbmeta_a`；boot 镜像的 AVB footer 只是为了通过
> ABL 的校验。若你的机器仍锁着，先看 `docs/TROUBLESHOOTING.md` 的 AVB 一节。

## 2. 刷写 boot_a

```bash
adb reboot bootloader          # 或关机后按住音量- 再插 USB
fastboot devices
fastboot flash boot_a out/boot/boot_arch.img
fastboot reboot
```

`flash/flash.sh` 做了 sha256 校验和二次确认，也可以用：

```bash
bash flash/flash.sh out/boot/boot_arch.img
```

开机出现 8 秒菜单：音量键选择、电源键确认，默认 ZUXOS（`boot_arch.img` 则默认 Arch）。

**回滚**：

```bash
fastboot flash boot_a /path/to/stock_boot_a.img
```

`boot_b`、`vbmeta`、`super`、`userdata` 都不需要动。

## 3. 安装到 UFS

第一次启动 Arch 时还没有 Arch 分区，initramfs 会走 NBD：把 PC 上的
`arch-nbd.img` 通过 USB 网卡喂给平板。

### 3.1 在 PC 上启动 NBD 服务

```bash
python3 build/nbd_server.py --image out/arch-nbd.img --listen 0.0.0.0 --port 10809
```

Windows 防火墙放行 10809；平板会从 USB NBD 拿到 `172.16.42.2-.10` 的地址。

### 3.2 启动 Arch 并 SSH 进去

菜单选 Arch。initramfs 依次尝试：GPT 分区名 `arch`/`steamos` → NBD → 诊断 shell。
首次没有 `arch` 分区，会落到 NBD。

```bash
ssh root@172.16.42.2        # 地址以平板实际拿到的为准
```

### 3.3 分区并复制系统

先看真实分区表：

```bash
sgdisk -p /dev/sda
```

`userdata` 的尾部就是 Arch 的位置。`install_ufs.sh` 会：

1. 缩小 `userdata`，在尾部新建 128 GiB（默认）的 `arch` 分区；
2. 清零 `userdata` 和 `metadata` 的开头 64 MiB，让 ZUXOS 下次启动时重新格式化；
3. 在新分区建 ext4（LABEL `arch-root`），把当前 NBD 根完整 `rsync` 过去。

```bash
CONFIRM=yes ARCH_START=27836416 USERDATA_LAST=61390842 bash /root/install_ufs.sh
```

- 这组数字是 256 GB 机型、128 GiB Arch 分区的默认值；脚本会先核对 `userdata` 的
  结束扇区，不匹配就拒绝执行。
- **ZUXOS 的用户数据会被清空**（分区头被清零，Android 会重建）。装之前把 Android
  侧需要的东西备份走。
- 脚本先把 GPT 备份到 `/root/gpt-sda-before-arch-*.gpt`，**先 scp 回 PC** 再继续。

完成后重启，菜单默认进 Arch，这次从 UFS 启动。

## 4. 首次启动与部署

默认用户是 `alarm`（uid 1000），root 密码是构建时的 `ROOT_PASS`。

```bash
# PC 侧，仓库根目录
export TB_HOST=<平板的局域网 IP>
bash deploy/deploy_all.sh "$TB_HOST"
```

这会安装：系统杂项（充电显示、UFS 电源、音量键、字体）、自动亮度、色域、皮套、
GPU 抬频、电源方案、Plasma 触摸默认值。

桌面和应用：

```bash
bash apps/install/desktop.sh        # 在平板上以 root 运行
bash apps/install/flatpak.sh        # 可选
```

传感器（自动亮度依赖）：

```bash
scp -r deploy/sensors root@$TB_HOST:/root/
ssh root@$TB_HOST 'bash /root/sensors/install_sensors.sh'   # 需要 meson/ninja
```

## 5. 日常维护

- **每次重启 Arch 消耗一次 A/B 重试计数**。连续重启前先启动一次 ZUXOS，让 Android
  把当前 slot 标记为成功，否则计数归零后 ABL 只进 fastboot。
  恢复：`fastboot set_active a` + `fastboot reboot`（只改 slot 元数据，不写分区）。
- 平板端**不要**跑 `pacman -Syu`：会尝试用打包版 `linux-aarch64` 覆盖自编内核。
  `/etc/pacman.conf` 已设置 `IgnorePkg = linux-aarch64 linux-latest linux-api-headers`。
  需要新包时用 `pacman -S --needed --disable-sandbox <包名>`（本内核没有 Landlock）。
- 升级内核 = 重跑 `wsl_build.sh kernel` + `pack_boot.py` + 刷 `boot_a`（设备写入，先确认）。
  只改模块时可以直接替换 `/lib/modules/7.2.6-tb710fu/` 下的 `.ko` + `depmod`，不用刷机。
