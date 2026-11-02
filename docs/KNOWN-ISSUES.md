# 已知问题

## 不能做 / 不可用

| 项目 | 情况 |
| --- | --- |
| 内屏 60 Hz | 该模式黑屏/花屏，只有 120 Hz 可用；KDE 里不要手动切 60 Hz |
| 指纹 | 无 Linux 驱动 |
| 摄像头 | 无 Linux 驱动 |
| 蜂窝网络 / GPS | 本机型无 modem |
| VA-API **AV1 编码** | 固件只提供 AV1 解码；OBS 里没有 AV1 硬件编码器是预期行为（H264/HEVC 编码可用） |
| Android 容器（Waydroid） | 需要内核 `CONFIG_PSI`；当前内核未开，容器会在约 16 秒后被杀 |
| 完整 `pacman -Syu` | 会用打包版 `linux-aarch64` 覆盖自编内核，系统无法启动 |
| `pacman -Syu` 升级 ksystemstats | 会覆盖 GPU 监控插件（`deploy/monitor/`），重跑 `deploy/monitor/deploy_monitor.sh` 重打 |
| `pacman -Syu` 升级 firefox | 会删掉 `/usr/lib/firefox/defaults/pref/tb710fu-vaapi.js`（VA-API 偏好），重跑 `deploy/vaapi/install.sh` |
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
