<p align="right"><a href="README.md">English</a> · <b>简体中文</b></p>

# 预构建产物（不想自己编译时用这页）

Release 里发布的是“只缺你自己的东西”的半成品：我们的内核、菜单、打包器、模块和一份
**不含厂商固件**的 Arch rootfs。原厂 `boot_a.img` 和固件必须来自你自己的设备——这既是
版权要求，也保证 ZUXOS 那一路的内核和你的 vendor 模块匹配。

这样你不用编译，但省不掉 EDL 备份（刷机前本来也必须做）。

## Release 资产

| 文件 | 作用 |
| --- | --- |
| `Image` | Arch 内核（7.2.6-tb710fu，含全部修复） |
| `sm8650-lenovo-tb710fu-kshim.dtb` | 设备树 |
| `kShimC.bin` | 开机菜单 |
| `MultiBootKernelPatcher` | 双内核打包器 |
| `modules-7.2.6-tb710fu.tar` | 内核模块（与 `Image` 同一构建） |
| `arch-nbd-base.img.zst.part00…` | 安装用 rootfs（MBR + ext4，**无厂商固件**） |
| `SHA256SUMS` | 全部文件的校验和 |

v1.1 起 Release 还附带进不了 git 的设备端补丁二进制（`.gitignore` 排除 `*.so`）：
`ksystemstats_plugin_gpu-<ver>-tb710fu-msm-aarch64.so`，系统监视器 GPU 页的预编译
插件，用 `deploy/monitor/deploy_prebuilt.sh` 安装。

本次构建的体积：`Image` 44 MB、dtb 138 KB、`kShimC.bin` 4 MB、打包器 828 KB、模块 92 MB；
rootfs 原始 10 GiB，压缩后 3.38 GiB，分两卷（1.9 GB + 1.6 GB）。产物已经生成在仓库的
`out-release/`（被 `.gitignore` 排除，可直接上传 Release）。

## 步骤

### 1. EDL 备份

按 `docs/INSTALL.zh-CN.md` 第 0 节做全分区回读，至少留下 `boot_a.img`、`super.img`。
`fastboot` 在这台机器上读不出分区，只能走 9008。

### 2. 准备工具

Linux/WSL 上需要 `python3`、`zstd`、`simg2img`、`erofs-utils`、`losetup`：

```bash
sudo apt-get install -y zstd simg2img erofs-utils python3
```

### 3. 下载并校验

把 Release 资产放进同一个目录：

```bash
sha256sum -c SHA256SUMS
```

### 4. 提取你自己的固件

```bash
bash build/collect_firmware.sh /path/to/super.img firmware/
```

### 5. 还原并注入 rootfs

```bash
cat arch-nbd-base.img.zst.part* | zstd -d > arch-nbd.img
sudo release/inject-firmware.sh arch-nbd.img firmware/
```

注入脚本会检查 DTB 要求的每个固件都在；少一个就会报错，不会给你一个“能开机但黑屏”的镜像。

### 6. 用你自己的 boot_a 打包

```bash
export TESTKEY=$PWD/build/tools/testkey_rsa4096.pem
export PACKER=$PWD/out-release/MultiBootKernelPatcher
python3 -I build/pack_boot.py \
  --boot /path/to/your_boot_a.img \
  --shim out-release/kShimC.bin \
  --linux out-release/Image \
  --dtb out-release/sm8650-lenovo-tb710fu-kshim.dtb \
  --out boot --default zui
```

得到 `boot/boot_zui.img`（默认 ZUXOS）和 `boot/boot_arch.img`（默认 Arch）。

### 7. 刷写并安装

```bash
bash flash/flash.sh boot/boot_arch.img
```

然后按 [安装指南](../docs/INSTALL.zh-CN.md) 第 3 节：PC 上跑

```bash
python3 build/nbd_server.py --image arch-nbd.img --listen 0.0.0.0 --port 10809
```

平板从菜单进 Arch，等它拿到 `172.16.42.x` 后（镜像里没有预置 SSH 公钥，用 alarm 登录）：

```bash
scp build/install_ufs.sh alarm@172.16.42.<x>:/tmp/
ssh alarm@172.16.42.<x>          # 密码 alarm
sudo CONFIRM=yes ARCH_START=... USERDATA_LAST=... bash /tmp/install_ufs.sh
```

`ARCH_START` / `USERDATA_LAST` 按 `sgdisk -p /dev/sda` 的实际值填，先备份 GPT。

### 8. 首次登录

rootfs 里的账号是 `alarm`，初始密码 `alarm`（`root` 同密码）。**第一件事是改密码**：

```bash
passwd
sudo passwd root
```

然后把你的 SSH 公钥装到 root，PC 侧部署才能连：

```bash
sudo mkdir -p /root/.ssh && sudo tee -a /root/.ssh/authorized_keys < ~/.ssh/id_ed25519.pub
sudo chmod 700 /root/.ssh && sudo chmod 600 /root/.ssh/authorized_keys
```

之后在 PC 上跑 `deploy/deploy_all.sh <平板IP>`。

## 为什么不直接给一个能刷的 boot 镜像

`boot_a` 里除了 Arch，还塞着**你机器上的 ZUXOS 内核**。别人的 ZUXOS 版本不同时，内核和
vendor 模块可能对不上，菜单进 Android 会黑屏。用每个人自己的 `boot_a` 打包可以完全避免
这个问题，也不用分发联想的 GKI 内核。

## 自己构建

见 `build/README.md`；`release/make-image.sh` 就是用来生成这份无固件 rootfs 的脚本。
