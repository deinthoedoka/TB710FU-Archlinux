# 特性与实现位置

README 里的清单对应到具体文件，方便改动和排查。

## 显示

| 行为 | 实现 |
| --- | --- |
| 固定面板/背光/GPU 加载顺序，保留 ABL 画面直到原生面板接管 | `build/rootfs/etc/modprobe.d/tb710fu-display.conf`、`tb-native-display.service` |
| NT36532 双 DSI + DSC 时序 | `deps/tb710fu-hyperos-steamos` 的 DTS/面板补丁（构建时应用） |
| 加载后一次 DRM off/on 解决锁存竞态 | `build/rootfs/usr/local/sbin/tb-native-display` |
| 登录界面与桌面共用缩放/ICC/亮度 | `/var/lib/plasmalogin/.config/kwinoutputconfig.json`（`deploy/plasma` 写入默认值） |

## 色彩

| 行为 | 实现 |
| --- | --- |
| 生成最小 Display P3 ICC（604 B） | `deploy/gamut/make_p3_icc.py` |
| 切换 accurate / native / soft | `deploy/gamut/tb-gamut`（kscreen-doctor） |
| 应用菜单入口 | `deploy/gamut/tb-gamut-toggle.desktop` |
| 登录界面同步 | `deploy/gamut/install_tb_gamut.sh` |

## 触摸与性能

| 行为 | 实现 |
| --- | --- |
| GPU 触摸抬频 629→422→231 MHz | `deploy/gpu/tb-gpu-boost` + `.service` |
| 三档电源方案 | `deploy/power/tb-powerprofiles`（接管 UPower.PowerProfiles） |
| 首次登录 2× 缩放 | `deploy/plasma/tb-plasma-touch-defaults` |

## 音频

| 行为 | 实现 |
| --- | --- |
| ADSP 未就绪时不阻塞时钟注册 | `build/patches/0001-tb710fu-local.patch`（`q6dsp-lpass-clocks.c`） |
| 首播静音 primer + 功放 ENUM 开关 | `build/rootfs/usr/local/sbin/tb-audio-init` |
| 路由/输入配置 | `build/rootfs/etc/wireplumber/` |

## 网络

| 行为 | 实现 |
| --- | --- |
| ath12k 关闭轮询、开启硬件去重、固定 board name | `build/rootfs/etc/modprobe.d/tb710fu-wifi.conf` |
| 按需加载 Wi-Fi | `build/rootfs/usr/local/sbin/wifi-on` + `tb-wifi.service` |
| USB 网卡（NBD/救援） | `build/rootfs/usr/local/sbin/tb-usb-ncm*` + `tb-usb-ncm*.service` |

## 传感器与自动亮度

| 行为 | 实现 |
| --- | --- |
| ADSP FastRPC 守护（含 method 36） | `third_party/hexagonrpc/` + `deploy/sensors/` |
| 自动亮度曲线、手动学习、空闲暂停 | `deploy/als/tb-als-daemon.py` |
| 登录界面亮度 | `deploy/als/tb-als-greeter.service`（`--greeter` 直写背光） |
| 开关/CLI | `deploy/als/tb-als`、`tb-als-toggle.desktop` |

## 电源与充电

| 行为 | 实现 |
| --- | --- |
| 充电电流符号修正 | `build/patches/0001-tb710fu-local.patch` + `deploy/system/qcom-battmgr-current.conf` |
| 强制 s2idle | `build/rootfs/etc/systemd/sleep.conf.d/tb710fu-s2idle.conf` |
| UFS 运行时电源管理 | `deploy/system/tb-ufs-pm.service` |
| 唤醒后 UFS 自愈 | `build/rootfs/usr/local/sbin/tb-modprobe-nbd-guard` 配套钩子（见 `docs/TROUBLESHOOTING.md`） |
| 音量键对调 | `deploy/system/tb-volume-swap.c` + `.service` |

## 皮套

| 行为 | 实现 |
| --- | --- |
| 读 GPIO66 判断合盖 | `deploy/cover/tb-cover-daemon` |
| 合盖熄屏 + 锁屏，开盖唤醒 | 同上（loginctl + KDE D-Bus 双路） |

## 桌面与语言

| 行为 | 实现 |
| --- | --- |
| Plasma 6 + plasmalogin | `apps/install/desktop.sh` |
| 中文 locale/字体（优先 SC 字形） | `deploy/system/local.conf` + `desktop.sh` |
| 电源键短按不关机 | `build/rootfs/etc/systemd/logind.conf.d/tb710fu-keys.conf` |

## 安装机制

| 行为 | 实现 |
| --- | --- |
| 双系统菜单 | `deps/...` kShimC + `build/build_shim.sh` |
| 打包 boot_a（两个默认项） | `build/pack_boot.py` |
| NBD 安装 | `build/nbd_server.py` + `build/nbdclient.c` + `build/initramfs/` |
| 装到 UFS 尾部 | `build/install_ufs.sh` |
