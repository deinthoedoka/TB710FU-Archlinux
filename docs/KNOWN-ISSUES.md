# 已知问题

## 不能做 / 不可用

| 项目 | 情况 |
| --- | --- |
| 内屏 60 Hz | 该模式黑屏/花屏，只有 120 Hz 可用；KDE 里不要手动切 60 Hz |
| 指纹 | 无 Linux 驱动 |
| 摄像头 | 无 Linux 驱动 |
| 蜂窝网络 / GPS | 本机型无 modem |
| VA-API **AV1 编码** | 固件只提供 AV1 解码；OBS 里没有 AV1 硬件编码器是预期行为（H264/HEVC 编码可用） |
| VA-API **H264/HEVC 编码** | 必须用打过 `deploy/vaapi/patches/` 的驱动。上游 radxa v1.1.1 / Release v1.2 的 `v4l2_drv_video.so` 会在几秒后报 `vaapi_encode: Error encoding: 输入/输出错误`（iris 没有它强设的两个控件） |
| Android 容器（Waydroid） | 需要内核 `CONFIG_PSI`；当前内核未开，容器会在约 16 秒后被杀 |
| 完整 `pacman -Syu` | 会用打包版 `linux-aarch64` 覆盖自编内核，系统无法启动 |
| `pacman -Syu` 升级 ksystemstats | 会覆盖 GPU 监控插件（`deploy/monitor/`），重跑 `deploy/monitor/deploy_monitor.sh` 重打 |
| `pacman -Syu` 升级 firefox | 会删掉 `/usr/lib/firefox/defaults/pref/tb710fu-vaapi.js`（VA-API 偏好），重跑 `deploy/vaapi/install.sh` |
| 运行时卸载 `qcom_iris` | 不允许。`modprobe -r` 只要被打断（超时、进程被 kill、VPU 正忙）模块就卡在 `Unloading`（`refcnt -1`），这个不可中断的进程会**把关机卡死**在黑底白字界面，只能长按电源键断电；`/etc/modprobe.d/qcom-iris-noremove.conf` 已把卸载拦在用户态，换模块只能装好 `.ko` 再重启 |
| VLC 重装 / 升级 | ALARM 把 VLC 拆成 `vlc-plugin-*` 子包，裸 `vlc` 连 GUI 都起不来；要装 `vlc-plugin-ffmpeg` 等才会用 VA-API |
| flatpak 应用（含 flatpak 版 VLC） | 沙箱自带 `/usr/lib/dri`，永远看不到宿主的 VA-API 驱动；硬解/硬编要装原生包 |
| Steam 客户端 / QQ / 微信二进制 | 版权原因不随仓库分发，需自行下载 |

## 偶发问题

- **登录时黑屏**：登录界面偶尔不亮，触摸一下屏幕恢复。与面板上电时序和
  compositor 首帧有关，`tb-display-watch` 可用来抓现场（`/run/tb-display-watch.log`）。
- **A/B 重试计数**：每启动一次 Arch 减一，归零后只能进 fastboot。定期启动 ZUXOS。
  见 [HARDWARE.md](HARDWARE.md#ab-重试计数)。
- **休眠唤醒后 Wi-Fi 偶发变慢**：驱动重连后可恢复；UFS 自愈钩子已处理更严重的
  UFS 掉线。
- **充电上限**：原厂 ZUXOS 的电池保护设置在 PMIC 里（默认充到 80% 停、降到 70% 恢复）。
  本项目曾提供 KDE 设置页，现已移除；需要改阈值时用
  `/sys/class/power_supply/battery/charge_control_end_threshold`，注意固件只在
  开始充电时读取，改完要重新插拔充电器。

## 需要用户确认的操作

- 刷 `boot_a`、改 GPT、写任何分区：都是设备写入，先备份、先确认。
- 传感器注册表、固件来自你自己的设备，不要从别人机器复制 `socinfo/serial_number`。
