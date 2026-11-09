# TB710FU ROM 打包流程

目标：把当前平板上的 Arch + GNOME + droidloom 系统做成可分发的首次安装镜像。
产物不写进 git（`out-rom/`）。

## 产物

```
out-rom/
  tb710fu-arch-rom-v2.0/                    打包源目录
    README.zh-CN.md         用户说明
    CREDITS.md              上游/许可
    flash.sh                Linux/WSL2 线刷脚本（dual / single）
    windows/flash.cmd       Windows 入口（自动提权）
    windows/flash.ps1       Windows 刷机脚本
    windows/tools/          内置 fastboot / zstd / nbdserver.exe
    boot/                   boot_install_dual.img / boot_install_single.img
    rootfs/arch-nbd.img.zst MBR + ext4(p2, LABEL=arch-root) 的干净系统
    tools/nbd_server.py     Linux 安装时的 USB-NBD 服务
  tb710fu-arch-rom-v2.0-windows.zip          Windows 包：固件 + windows/
  tb710fu-arch-rom-v2.0-linux.tar.zst        Linux 包：固件 + flash.sh + tools/
  *.sha256
```

两个发行包**各自完整**：固件（rootfs + boot 镜像）都带，只是按操作系统放对应的
刷机工具；用户只下载自己系统的那一个。用 `package-release.py` 生成，不要手工
拼包（每包的 `SHA256SUMS` 由它按包内实际文件生成）。

两个安装模式共用同一份 rootfs；dual 缩 `userdata` 并在尾部建 `arch`，single 把
`userdata` 改名成 `arch` 整块使用。最终 `boot_*` 镜像在 rootfs 的 `/boot/tbboot/`，
安装器按模式写入 `boot_a`。

`arch` 的大小由安装器按实际 `userdata` 计算：给 Android 至少留 40 GiB，其余给 Arch，
不设上限。因此 8+128（Arch ≈59 GiB）、8+256 / 12+256（≈93 GiB）、12+512（≈199 GiB）
共用同一份镜像；不要改回固定 80 GiB，否则 128 GB 机型会失败、512 GB 机型会浪费空间。

## 关键事实

- `boot_a` 是 DBKP PackedKernel：`[GKI][Shim][Arch Image][DTB][Manifest]`。
- **真正传给内核的 cmdline 是 DTB 的 `/chosen/bootargs`**；boot header 的 cmdline
  被 kShim 忽略。所以镜像变体必须改 DTB，而不是只改 boot header。
- 启动参数包含 `androidboot.slot_suffix=_a`：让 droidloom 的 Android cell 和
  ZUXOS 一样有机会把 slot 标记成功，减少 A/B retry 被 Arch 消耗的问题。
- **合盖唤醒键必须是 KEY_WAKEUP=143**。247 是 `KEY_RFKILL`，内核的
  `rfkill-input` 会把它当成“射频总开关”，开盖时同时软锁 Wi-Fi 和蓝牙
  （NetworkManager 日志 `Wi-Fi now disabled by radio killswitch`）。旧的
  `tb-cover-daemon` 用的 247，已在 r27 改成 143。
- **`systemd-rfkill` 已 mask**：它会在任何进程打开 `/dev/rfkill` 时启动并恢复
  保存的软锁状态，曾把正在使用的 Wi-Fi 锁掉。镜像里
  `systemd-rfkill.{service,socket} -> /dev/null`，并由
  `tb-rfkill-unblock.service` 开机 unblock wifi+bluetooth。
- **挂起策略（GNOME）**：GNOME 下 s2idle 实测可稳定唤醒，`tb-no-suspend.service`
  保持 **disabled**；短按电源键由 `tb-power-key` 调 `org.gnome.SessionManager.Suspend`
  （安卓式熄屏即休眠），长按 ≥1 s 弹「重启 / 关机 / 取消」。`power-button-action`
  必须是 `nothing`，否则 gsd 在按下的瞬间就挂起、长按来不及识别。合盖挂起仍是
  `/etc/tb-cover-suspend` opt-in；合盖默认只关背光+锁屏。
- 安装器 `tb-install-run` 在 `sysinit.target` 之前运行，避免 rootfs 的
  `tb-usb-ncm`/NetworkManager 在 rsync 期间重配 USB gadget、把 NBD 连接弄断。
- `sgdisk -i` 的 sector 输出带 `(at ...)` 文本；`sgdisk` 某些版本不打印
  `Partition type GUID`。安装器已按这两个坑解析/回退。
- 动态修改 rootfs 里的脚本要用 `debugfs`，并确保模式 0755：

  ```sh
  debugfs -w -R "rm /usr/local/sbin/tb-install-run" arch-root.img
  debugfs -w -R "write tb-install-run /usr/local/sbin/tb-install-run" arch-root.img
  debugfs -w -R "sif /usr/local/sbin/tb-install-run mode 0100755" arch-root.img
  ```

## 构建步骤

### 1. 生成启动镜像

从**设备当前** `boot_a` 读 96 MiB（不是仓库里的旧 `out/boot`）：

```sh
ssh root@<pad> 'dd if=/dev/sde11 bs=4M count=24' > boot_a.live.img
DTC=/path/to/linux/scripts/dtc/dtc \
  python3 -I make-boot.py --boot boot_a.live.img --out boot-variants
```

产物：`boot_arch`（dual，默认 Arch，8 s）、`boot_zui`（dual，默认 ZUXOS，8 s）、
`boot_single`（single，默认 Arch，1 s）、两个 `boot_install_*`（强制 NBD + install 标记，
1 s）。`make-boot.py` 会改 DTB、重排 DTB/manifest、重签 AVB footer。

### 2. 在平板上生成干净 rootfs

把 `boot_arch.img`、`boot_zui.img`、`boot_single.img`、`tb-install-run`、
`tb-installer.service`、`clean-rootfs.sh` 放到平板 `/root/rom-stage/`；
`steam.desktop` / `tb-als-toggle.*` 可选。然后：

```sh
/root/rom-stage/build-image-on-tablet.sh
```

脚本在 `/root/rom-build/arch-root.img` 建 22 GiB ext4（loop，不写 UFS）：

1. `rsync` 当前根，排除 `/home/alarm`、`/root`、`/opt`、缓存、日志、旧内核、
   LibreOffice/VLC 等；
2. chroot 里删除 QQ/微信/LibreOffice/VLC/mpv/开发工具，清理个人状态，
   `DisableSandbox`、`IgnorePkg`，建 `alarm` 新家、密码 `tb710fu`；
3. 复制 Steam 客户端（排除 `steamapps`/`config`/`userdata`/`ssfn*`/`*.vdf`）、
   GNOME/扩展的系统级配置（dconf、systemd user drop-in、udev 规则）；
4. 放安装器和最终启动镜像；
5. 归一化 world-writable 目录（live 的 `/usr` 是 777）、清日志、生成 hash。

产物：`/root/rom-build/arch-root.img`（ext4 LABEL `arch-root`）。

### 3. 传回并包 MBR

```sh
ssh root@<pad> 'zstd -T0 -3 -c /root/rom-build/arch-root.img' > arch-root.img.zst
zstd -d arch-root.img.zst
SIZE=$(stat -c%s arch-root.img)
truncate -s $((SIZE + 5*1024*1024)) arch-nbd.img
sfdisk arch-nbd.img <<EOF
label: dos
unit: sectors
start=2048, size=8192, type=83
start=10240, size=$((SIZE/512)), type=83
EOF
dd if=arch-root.img of=arch-nbd.img bs=1M seek=5 conv=notrunc,sparse
zstd -T0 -6 -o arch-nbd.img.zst arch-nbd.img
```

注意 `ssh 'zstd -c ...'` 不要把 `command -v zstd` 的输出混进流里；用
`ssh ... 'zstd ...'` 直接从 stdin 读。

### 3.5 Windows 工具

`windows/tools/nbdserver.exe` 由本仓库的 Go 源码交叉编译（默认读写，安装器要在
NBD root 上写日志；`--ro` 仅用于只读演练）：

```sh
cd build/rom/windows-src/nbdserver
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" \
  -o ../../windows/tools/nbdserver.exe .
```

`zstd.exe` 来自 facebook/zstd v1.5.7 win64；`fastboot.exe` + `AdbWinApi.dll` +
`AdbWinUsbApi.dll` 来自 Android platform-tools。两者的许可写在
`windows/tools/` 和 `CREDITS.md`。**不要**把 `nbdserver.exe` 改成默认只读：
initramfs 用 `-o rw` 挂载 NBD root，只读会导致挂载/日志失败。

### 4. 组装和校验

把 `README.zh-CN.md`、`CREDITS.md`、`flash.sh`、`windows/`、`tools/`、`boot/`、
`rootfs/` 放进 `out-rom/tb710fu-arch-rom-v2.0/`，然后：

```sh
build/rom/package-release.py --src out-rom/tb710fu-arch-rom-v2.0 \
  --out out-rom --name tb710fu-arch-rom-v2.0
```

脚本对每个平台：硬链接大文件到临时目录 → 按包内实际文件生成 `SHA256SUMS`
（README 除外）→ 打 `-windows.zip`（ZIP64，大文件 STORED）/
`-linux.tar.zst`（zstd -3）→ 写 `<archive>.sha256`。

校验：

```sh
cd out-rom && sha256sum -c *.sha256
unzip -t tb710fu-arch-rom-v2.0-windows.zip
zstd -t tb710fu-arch-rom-v2.0-linux.tar.zst
```

只读 NBD 挂载验证（不会写 UFS）：在平板上用 `nbdclient` 连本机 `nbd_server.py`
（export `arch`），`mount -o ro /dev/nbd0p2`，检查 `/etc/fstab`、`/boot/tbboot`、
`/usr/local/sbin/tb-install-run` 权限和 `/etc/machine-id` 为 0 字节。

## 不写 UFS 的构建

构建全程只在平板上读根、写 `/root/rom-build` 文件；安装器的 `sgdisk`/`dd` 只在
用户实际执行 `flash.sh` 后才碰 UFS，且只碰 `userdata`/新 `arch`/`metadata` 头和
`boot_a`/`misc` BCB。`persist`/`modemst`/`fsg`/`fsc`/`devinfo`/`frp`/`keystore`/
`ssd`/`secdata`/`uefivarstore`/`super`/`vbmeta*`/`dtbo`/`init_boot`/`vendor_boot` 不写。

## 固件与版权

镜像包含从本机 `super` 提取的 Lenovo/Qualcomm 固件（显示/触摸/Wi-Fi/音频/GPU）。
私下分发前确认版权；公开再分发建议改成“用户从自己的机器注入固件”。
