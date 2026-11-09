# TB710FU 挂起"睡死"修复补丁（免刷机）

**日期**：2026-11-09
**适用**：刷了 tb710fu-arch ROM（内核 `7.2.6-tb710fu`，v1.1 / v2.0 均可）的设备，在运行的系统上直接打补丁，无需重刷。安装器会校验内核版本和模块基线，不符就拒绝。
**修什么**：挂起睡眠后按电源键，平板有时处于"正在开机"的状态——睡死重启了。

## 问题根因

取证（XBL 日志区 0x81a00000 + AOP 日志区 0x81c80000，两处保留内存热复位后仍可读）还原了死亡瞬间：

- 内核进入 s2idle（挂起）后死亡，journal 止于 `PM: suspend entry`，没有 suspend exit；新开机有 ext4 journal recovery、wtmp 标 crash；
- XBL 明确记录 **`PM: Reset by PSHOLD / Reset Type: Warm Reset`**，AOP 归类为 **"wdog or kernel error suspected"**——不是断电（死亡时电池 54%、4.2V 正常放电，插电开机即 54% charging），不是过热（无 thermal 消息），也不是 Linux panic 自动重启（`panic` 超时为 0、无看门狗设备），而是**安全侧（TZ/SDI）在内核挂起冻结期间发起的热复位**；
- 概率实测约 **1/82**（一次开机 82 轮挂起只死 1 次），与"有概率"的使用感受吻合；
- 头号嫌疑：**ADSP 的 handover 中断风暴**。厂商 ADSP 固件持续翻转 smp2p 信号线（约 5 次/秒），`qcom_q6v5` 驱动的 handover 中断跟着每分钟触发约 300 次，24 小时刷了 21 万条 "Handover signaled, but it already happened"。ADSP 同时是充电/电池管理（battmgr）的宿主，挂起的电源切换正是它状态最敏感的窗口。触发类型在驱动里写死 `IRQF_TRIGGER_RISING`，改设备树无效，只能在驱动层修。

## 修复内容

只替换一个内核模块：`/usr/lib/modules/7.2.6-tb710fu/kernel/drivers/remoteproc/qcom_q6v5.ko`。

改动是 handover 中断一次性封锁：每轮 DSP 启动（prepare）后只处理第一次边沿——照常完成 handover 记账，随即 `disable_irq_nosync` 关掉这根中断，后续边沿全部吞掉；`unprepare()` 里对应的 disable 改成条件执行，enable/disable 深度守恒。真正的 handover 语义不变，ADSP/CDSP 启动、崩溃恢复路径不受影响。

修复前后的可测差别：

| 指标 | 修复前 | 修复后 |
| --- | --- | --- |
| `Handover signaled, but it already happened` 日志 | ~300 条/分钟（24h 共 214846 条） | 0 |
| `/proc/interrupts` 中 `q6v5 handover`（irq181/188） | 持续增长（5 次/秒） | 封顶在 1，20 秒采样不动 |

参考设备（v2.0 时代内核）部署后已验证：两轮 RTC 定时挂起/唤醒正常、ADSP/CDSP running、Wi-Fi 全程在线。

## 安装

把整个目录（或 tar 包）放到平板上，以 root 执行：

```sh
./install.sh
```

- 内容一致的文件自动跳过（幂等，可重复执行；重装时没有替换任何文件则提示无需重启）；
- 被替换的旧模块备份到 `/var/backups/tb710fu-q6v5-handover-fix/<时间戳>/`（按原路径存放）；
- 只想预览不写入：`DRY_RUN=1 ./install.sh`；
- 旧模块与发行基线 sha256 不一致时拒绝安装（防止装到内核不同的设备上）；确认自己改过内核、理解风险后可用 `FORCE=1 ./install.sh` 强行安装，但更建议直接用源码重编。

**需要重启一次才生效**（正在运行的内核还持有旧模块；新模块随下次开机加载）。重启进 Arch 后即完成，无需其他操作。

## 验证

重启后：

1. `grep 'q6v5 handover' /proc/interrupts` —— 跑两次（隔 20 秒），计数应停在 1 不再增长；
2. `journalctl -k -b 0 | grep -c 'Handover signaled'` —— 应为 0（修复前每分钟约 300 条）；
3. `cat /sys/class/remoteproc/remoteproc*/{name,state}` —— adsp/cdsp 都应 running，音频、传感器正常；
4. 实际使用观察几天：挂起睡眠后按电源键，应该总是直接唤醒锁屏，不再出现"正在开机"。

## 效果边界（说清楚）

- 本补丁消除的是当前证据链下的**头号嫌疑**（ADSP handover 风暴）。它是否就是挂起死亡的唯一触发器，要靠后续几天不复现来确认。
- 如果"睡死"仍复发，说明还有别的元凶。取证不受影响：死亡后 XBL/AOP 保留内存日志照旧可读（方法见设备记忆或联系维护者），journal + ext4 recovery + wtmp crash 标记照旧留痕。注意 DDR 里的 ramoops 会在热复位时被 XBL 覆写，`/sys/fs/pstore` 是空的属正常，不是证据丢了。
- 本补丁不改变挂起策略、电源键行为、合盖行为，也不触碰任何分区（persist/modemst 等红线分区照旧不写）。

## 回滚

```sh
# 找到备份目录里的模块，按原路径复制回去：
cp /var/backups/tb710fu-q6v5-handover-fix/<时间戳>/usr/lib/modules/7.2.6-tb710fu/kernel/drivers/remoteproc/qcom_q6v5.ko \
   /usr/lib/modules/7.2.6-tb710fu/kernel/drivers/remoteproc/qcom_q6v5.ko
# 然后重启一次。
```

## 文件清单与校验

见 `SHA256SUMS`（安装前会自动 `sha256sum -c` 校验一遍）。补丁模块自身 sha256：
`55ea71ce782a162afbc74d7ab1114c4372d8d6e7a798a65cc9d5ce6391adb404`

## 备注

- 只动一个内核模块文件，不碰 depmod 元数据（同路径同版本）、不碰分区、不改挂起/电源配置。
- 下次 ROM 打包（v2.1 起）这个模块会直接进 rootfs；已装本包的设备升级后出现同名文件属正常，内容一致，`install.sh` 幂等可重复执行。
- 与已发的 `tb710fu-powerkey-fix-20261108`、`tb710fu-phantomkey-fix-20261108` 无文件重叠，可单独装，也可都装。
