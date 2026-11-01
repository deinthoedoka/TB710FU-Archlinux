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
