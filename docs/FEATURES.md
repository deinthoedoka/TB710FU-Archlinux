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
| 开机竞速修复（PowerDevil 只探测一次） | `deploy/power/tb-powerprofiles.service`：`WantedBy=graphical.target` + `Before=display-manager.service` |
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
| MTP 有线存储（与 NCM 共用 gadget） | `deploy/mtp/`（uMTP-Responder 源码平板端编译）+ `tb-usb-ncm` 里的 ffs.mtp 兼容块 |
| 屏蔽 networkd-wait-online 死等 | `build/install_payload.sh`（networkd 管理 0 个接口） |

## 视频硬解

| 行为 | 实现 |
| --- | --- |
| mpv 默认 v4l2m2m-copy 硬解 | `build/rootfs/etc/mpv/mpv.conf`（iris 是有状态解码器，v4l2m2m 直连） |
| Firefox 硬解 | 无需配置：Firefox ≥116 的 V4L2m2m 编在默认构建里（实测 4K H264 RDD CPU 0.2%） |
| iris VPU 启用 | kshim dts `&iris status=okay` + `vpu33_p4.mbn` 固件（用户自设备注入） |
| VA-API 解码/编码（VLC、OBS、libva 应用） | `deploy/vaapi/`（radxa qcom-va-driver + 5 个 iris 补丁）；Release v1.2 附预编译驱动和模块 |
| VA-API 所需的内核补丁 | `build/patches/000[2-6]-media-iris-*`，`build_kernel.sh` 自动应用；0002 是针对本机基线的移植版 |
| 硬解自检 | `tb-hwdec-check`（`deploy/vaapi/hwdec-selfcheck.sh`，播 8 秒采样 VPU 状态） |
| 驱动源码构建（新版本/其他机型） | `deploy/vaapi/build_driver.sh`（meson，关掉 cdsp_vpp/vulkan_vpp） |

## 系统监视器 GPU 页

| 行为 | 实现 |
| --- | --- |
| msm/Adreno 平台设备后端（官方插件只枚举 PCI） | `deploy/monitor/ksystemstats/`（LinuxMsmGpu：fdinfo 占用/显存、devfreq 频率、gpuss hwmon 温度） |
| 平板端编译 / 预编译安装 | `deploy/monitor/build_plugin.sh` / `install_prebuilt.sh`（Release 页有 6.8.2 版 .so） |

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
