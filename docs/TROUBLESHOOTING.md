# 排错

## 开机直接进 fastboot / 没有菜单

ABL 的 slot 重试计数归零了。

```bash
fastboot set_active a
fastboot reboot
```

这只是改 slot 元数据，不写分区。之后先启动一次 ZUXOS，让 Android 把 slot 标记成功。
平时每重启几次 Arch 就进一次 ZUXOS。

## 开机黑屏 / 花屏

1. 触摸屏幕或按电源键，确认是不是“登录黑屏”（见下）。
2. 如果一直不亮：接 USB，等 30 秒，`ssh root@<ip>` 是否还能进？能进说明只是显示问题。
3. 进诊断 shell：在 `boot_a` 打包时加 `--diag`，或把 8 秒菜单停在 Arch 上，
   init 找不到根分区时会自动进 `/diag.sh`（telnet 172.16.42.1:23）。
4. 检查面板模块加载顺序：

   ```bash
   journalctl -b | grep -E 'panel-nt36532|sy7758|aw37503|dispcc|msm'
   systemctl status tb-native-display
   ```

   `modprobe.d/tb710fu-display.conf` 必须屏蔽 `msm`/`panel_*`/`sy7758`/`aw37503_regulator`
   的自动 probe，由 `tb-native-display.service` 按固定顺序加载。

## 登录后黑屏，触摸才亮

已知偶发问题。登录界面（plasmalogin）和桌面切换时 compositor 首帧未提交。
`deploy/diagnostics/tb-display-watch` 会记录背光、DPMS 和帧计数，用来确认是
“面板没上电”还是“没有帧提交”。

## 关机 / 重启卡住（黑底白字，一直不动）

关机流程在等一个**杀不掉的进程**。最常见的原因是 `qcom_iris` 被 `modprobe -r`
卸到一半：内核把它标成 `Unloading`（`/proc/modules` 里 `refcnt -1`），
`iris_remove` 永远返回不了，这个进程不可中断，`systemd-shutdown` 就卡在它上面。

这时网络、显示和大部分服务都已经停了，没有软件办法：

1. **长按电源键 10–15 秒**强制断电，松手后等两秒再短按开机。
   文件系统有 journal，正常情况不会丢数据。
2. 开机后确认恢复：

   ```bash
   grep Unloading /proc/modules    # 应无输出
   vainfo --display drm --device /dev/dri/renderD128 | head -3
   ```

3. 如果开不了机、只能进 fastboot（A/B 重试计数用完了），
   `fastboot set_active a && fastboot reboot`，之后启动一次 ZUXOS 把计数复位。

防复发：这台机器上 `qcom_iris` **不允许在运行时卸载**。
`/etc/modprobe.d/qcom-iris-noremove.conf` 里的 `remove qcom_iris /bin/false`
让 `modprobe -r qcom_iris` 直接在用户态失败、根本不进内核。换模块就是装好
`.ko` 然后重启（`deploy/vaapi/install.sh` 现在只做这一件事）。

> 如果极端情况下 SSH 还活着（很少见），可以先 `echo s > /proc/sysrq-trigger`
> 把脏页刷盘，再 `echo b > /proc/sysrq-trigger` 硬重启，比长按电源键干净一点。
> `/proc/sys/kernel/sysrq` 为 0 时这两条无效。

这台机器的 DT 没有把 SoC 看门狗接出来：`qcom_wdt` / `pm8916_wdt` 能载入，但
`/sys/class/watchdog/` 是空的、也没有 `/dev/watchdog`，所以 **`ShutdownWatchdogSec=`
用不了**，卡住的关机只能靠长按电源键。

## 没有声音

```bash
systemctl status tb-audio-init tb-adsp-audio-check
journalctl -b | grep -iE 'q6dsp|lpass|aw882|adsp'
```

- 第一次播放前的 1 秒静音是给 TDM 总线打时钟的 primer，不要去掉。
- 功放开关是 ENUM 控件，必须写数字 `1`，`amixer ... on` 会写成 0。
- 如果 ADSP 启动时卡住，检查内核是否带了 `q6dsp-lpass-clocks` 的竞态补丁
  （`build/patches/0001-tb710fu-local.patch`）。

## Wi-Fi 能连但很慢

ath12k 需要 `tb_hw_dedup=1`（硬件去重）；否则 AP 重传的 MPDU 会被 mac80211 当重复包
丢掉，TCP 掉到 0.1–0.5 MB/s。检查：

```bash
cat /sys/module/ath12k_wifi7/parameters/tb_hw_dedup   # 1
cat /sys/module/ath12k/parameters/tb_poll_off          # 1
```

不要设置 `tb_sw_reorder`，也不要在运行时改 `tb_poll_ms`（会挂住板子）。

## 自动亮度不动

```bash
systemctl status hexagonrpcd-adsp-sensorspd
monitor-sensor                     # 应能看到 light sensor 和 lux
systemctl --user status tb-als
tb-als status
```

- 没有 lux：传感器注册表没装对，检查
  `/usr/share/qcom/sm8650/LENOVO/tb710fu/sensors/sns_reg_config`。
- 有 lux 但亮度不动：确认 `~/.config/tb-als-enabled` 存在，且
  `tb-als-daemon` 在跑。想清掉学习数据：`tb-als reset-profile`。

## 视频软解（VLC / OBS 没有硬件解码器）

VA-API 链路要三段都通，按顺序查：

```bash
vainfo --display drm --device /dev/dri/renderD128 | grep -E 'Driver version|VLD'
tb-hwdec-check                                   # 播 8 秒，看解码通道 + VPU 是否 active
modinfo -F vermagic /usr/lib/modules/$(uname -r)/kernel/drivers/media/platform/qcom/iris/qcom-iris.ko
```

- 第一段空/报错：`/usr/lib/dri/v4l2_drv_video.so` 没装或没软链 `msm_drv_video.so`
  → `deploy/vaapi/install.sh`。
- `vainfo` 有输出但播放报 **"Failed to end picture decode"**：内核模块不带
  decode-order 补丁 → 换 `qcom-iris-7.2.6-tb710fu-vaapi.ko`（Release v1.2）或重编内核。
- 只有 VLC 不行：ALARM 的 VLC 拆包了，`pacman -Q vlc-plugin-ffmpeg` 必须存在。
- **OBS 录几秒后报 `vaapi_encode: Error encoding: 输入/输出错误`**：装的是未打补丁的
  驱动。iris 编码器没有 `FRAME_RC_ENABLE` / `FORCE_KEY_FRAME` 两个控件，上游
  v1.1.1 无条件去设置，EINVAL 直接把编码会话打断。换 Release v1.3 的
  `v4l2_drv_video.so`，或在平板上跑 `deploy/vaapi/build_driver.sh`
  （会自动打 `patches/` 里的补丁）。
- flatpak 版永远不行（沙箱看不到宿主 `/usr/lib/dri`），换原生包。
- 采样时视频窗口必须在最前：后台/被遮挡的播放器会被节流，VPU 状态读出来是
  `suspended`，看起来像没硬解。
- `vainfo` 报 **"no Iris stateful H264 decoder found"** 且 `/proc/modules` 里
  `qcom_iris ... Unloading`：模块卸到一半被打断了（`modprobe -r` 期间中断/超时），
  `iris_remove` 卡死，用户态无法恢复，**而且会让下次关机卡住**——处置见
  [关机 / 重启卡住](#关机--重启卡住黑底白字一直不动)。现在
  `/etc/modprobe.d/qcom-iris-noremove.conf` 已禁止运行时卸载。

## 充电显示“放电”

确认模块参数生效：

```bash
cat /sys/module/qcom_battmgr/parameters/current_inverted   # Y
upower -i /org/freedesktop/UPower/devices/battery_BAT0 | grep -E 'state|time to full'
```

没生效时检查 `/etc/modprobe.d/qcom-battmgr-current.conf`，然后
`modprobe -r qcom_battmgr && modprobe qcom_battmgr`（会短暂丢电量显示）或重启。
内核必须包含本仓库的本地补丁。

## pacman 报 sandbox 错误

本内核没有 Landlock，pacman 7 的下载沙箱会失败：

```
switching to sandbox user 'alpm' failed
```

每次加 `--disable-sandbox`，例如
`pacman -S --needed --disable-sandbox <包名>`。不要为了这个去升级整个系统。

## NBD 安装时连不上

- PC 上 `nbd_server.py` 必须监听 `0.0.0.0:10809`，防火墙放行。
- 平板 USB 网卡地址是 `172.16.42.1`，PC 侧拿到 `172.16.42.2-.10`。
- 平板侧日志：`cat /tmp/nbdclient.log`，应看到 `READY`。
- `nbdclient` 是我们自己的静态客户端（`build/nbdclient.c`）；busybox 的 `nbd-client`
  applet 在这台机器上会把流读偏 2 字节，不能用。

## 想回滚到 ZUXOS

```bash
fastboot flash boot_a /path/to/stock_boot_a.img
```

如果连 fastboot 都进不去，用 EDL 9008 + 备份的 `boot_a.img` 写回。**不要**动
`vbmeta`、`super`、`userdata`。
