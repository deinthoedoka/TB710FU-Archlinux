# TB710FU 幽灵按键唤醒修复补丁（免刷机）

**日期**：2026-11-08
**适用**：刷了 tb710fu-arch ROM（v1.1 / v2.0 均可）的设备，在运行的系统上直接打补丁，无需重刷。
**修什么**：没碰任何按键，平板却从挂起中自己醒来、点亮锁屏（偶发）。同时装一个监控守护，把幽灵按键的原始事件记录下来，给硬件检修留证据。

## 问题根因

按键板（电源键和音量键在同一块板/排线上）间歇性短路，会产生成簇的幽灵按键事件：

- 幽灵**音量加**：走 `gpio-keys` 平台设备（SPMI GPIO 中断 IRQ161）。这个设备在挂起中 wake 是开着的，幽灵事件直接把 s2idle 里的平板唤醒。
- 幽灵**电源键**：走 `pmic_pwrkey`（真实 PMIC 按键驱动）。logind 收到后当作用户活动，gsd 把屏幕点亮——这就是"自己亮屏"；亮屏状态下若再有幽灵短按，`tb-power-key` 会挂起，几秒后自灭。

journal 里两条键线在**同一秒**同时幽灵触发、间隔呈 4s/20s/1min 的簇发，是机械间歇接触的特征，不是软件 bug。

## 修复内容

| 组件 | 作用 |
| --- | --- |
| `70-tb-gpiokeys-nowake.rules`（udev 规则）+ 运行时 sysfs 写入 | 关闭 `gpio-keys` 整设备的 wake（音量加 + 皮套 Hall SW_LID），挂起中幽灵音量加不再唤醒。**`pmic_pwrkey` 的 wake 保留**，真按电源键唤醒不受影响 |
| `tb-event-watch`（root 系统服务） | 常驻记录 event0/1/2 的原始 evdev 事件 + DPMS/背光变化 + GPIO66 皮套电平，落盘 `/root/event-watch/log-*.txt`（5MB 轮转），journal 用 `journalctl -u tb-event-watch -f` |

皮套检测不受影响：`tb-cover-daemon` 走 GPIO66 的 chardev 中断（独立于 gpio-keys/SW_LID），合盖唤醒路径照常。

## 与电源键修复包的关系

与本机已发的 `tb710fu-powerkey-fix-20261108` 无文件重叠，可单独装，也可都装。都装时后装的包不会覆盖前一个的任何文件。

## 安装

把整个目录（或 tar 包）放到平板上，以 root 执行：

```sh
./install.sh
```

- 内容一致的文件自动跳过（幂等，可重复执行）；
- 被替换的旧文件按原路径备份到 `/var/backups/tb710fu-phantomkey-fix/<时间戳>/`；
- 只想预览不写入：`DRY_RUN=1 ./install.sh`。

装完立即生效（运行时 wake 状态当场切掉，udev 规则管以后每次开机），无需重启。

## 验证

1. `cat /sys/devices/platform/gpio-keys/power/wakeup` → `disabled`；
2. `cat /sys/devices/platform/gpio-.../`（pmic_pwrkey 对应设备的 `power/wakeup`）→ 仍是 `enabled`；
3. `systemctl is-active tb-event-watch` → `active`；合一次盖/按一次音量键，`journalctl -u tb-event-watch -f` 里能看到对应原始事件；
4. 熄屏挂起后静置，不再出现"自己醒来看锁屏"。幽灵电源键簇发若仍在亮屏状态发生，日志里会有 `KEY_POWER(116) value=1` 且用户当时没碰按键——这就是给报修看的证据。

## 效果边界（说清楚）

- **已消除**：挂起状态被幽灵音量加唤醒（掉网、耗电、点亮锁屏的主要路径）。
- **不处理**：亮屏（含熄屏未挂起的 DPMS 状态）下幽灵电源键造成的"亮一下自灭"。这是按键板硬件间歇短路，软件无法安全过滤——电源+音量加同时按是合法组合键，加大防抖会毁掉真实短按。根治靠检修按键板/排线（潮湿、触点氧化、异物、电池挤压）。
- 长期挂机仍有低频的定时唤醒（Android 侧定时器），属另一回事，屏幕不会亮。

## 回滚

```sh
# 关监控：
systemctl disable --now tb-event-watch.service
rm /etc/systemd/system/tb-event-watch.service /usr/local/bin/tb-event-watch.py
systemctl daemon-reload
# 恢复 gpio-keys 唤醒：
rm /etc/udev/rules.d/70-tb-gpiokeys-nowake.rules
udevadm control --reload-rules
echo enabled > /sys/devices/platform/gpio-keys/power/wakeup
```

被替换文件的上一版在备份目录 `/var/backups/tb710fu-phantomkey-fix/<时间戳>/`（按原路径存放）。

## 文件清单与校验

见 `SHA256SUMS`（安装前会自动 `sha256sum -c` 校验一遍）。

## 备注

- 只动 udev 规则、一个脚本、一个 systemd 单元，不触碰分区、persist/modemst、挂起策略或其他配置。
- 下次 ROM 打包（v2.1 起）这三个文件会直接进 rootfs；已装本包的设备升级后出现同名文件属正常，内容一致，`install.sh` 幂等可重复执行。
