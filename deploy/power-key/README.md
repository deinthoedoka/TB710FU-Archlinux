# TB710FU 电源键长按：重启 / 关机菜单

## 现状

这块平板的电源键有两层：

- **短按**：gnome-settings-daemon 通过 shell 的 accelerator grab 收到
  `KEY_POWER`，按 `power-button-action`（原值 `suspend`）挂起。
- **长按**：PMIC 自己在引导阶段配置的 S2 reset，按下约数秒后直接复位 SoC；
  内核/用户态没有机会弹菜单（`/etc/systemd/logind.conf.d/tb710fu-keys.conf`
  也写明了这一点）。

## 新行为

- `power-button-action` 改为 `nothing`：gsd 不再在按下的瞬间挂起，否则长按
  还没来得及被识别，机器已经睡了。
- `tb-power-key`（Python + PyGObject，用户级 systemd 服务）直接读
  `/dev/input/event1`（`pmic_pwrkey`，udev 规则给活动用户加 uaccess ACL）：
  - 短按（<1s）→ 调 `org.gnome.SessionManager.Suspend()`，保持原来的挂起语义；
  - 长按（≥1s）→ 调 `org.tb.PowerMenu.Open`；
  - 从挂起恢复后的 3 秒内忽略按键，避免唤醒的那一下又被当成短按再挂起。
- `tb-power-menu@tb710fu` 扩展导出一个会话总线服务，显示 shell 的
  `ModalDialog`：**重启 / 关机 / 取消** 三个大按钮。对话框在
  `modalDialogGroup` 里，锁屏界面之上也能显示。按钮直接调
  `org.freedesktop.login1.Manager.Reboot/PowerOff`（对话框本身就是确认），
  被 polkit 拒绝时回退到 `org.gnome.SessionManager` 的确认对话框。
- 扩展没加载时（安装后第一次登录前），守护进程回退到
  `org.gnome.SessionManager.Shutdown()`，即 GNOME 自带的关机对话框。

**PMIC 硬件复位仍然存在**：如果一直按住超过引导阶段配置的阈值，SoC 还是会
被 PMIC 复位。菜单在 1 秒时出现，正常长按看到菜单松手即可；这是硬件兜底，
软件无法在用户态取消（DT 的 pwrkey 节点没有 `qcom,support-reset` 可改）。

## 文件

| 文件 | 部署位置 |
| --- | --- |
| `tb-power-key` | `/usr/local/bin/tb-power-key` |
| `tb-power-key.service` | `/usr/lib/systemd/user/tb-power-key.service` |
| `70-tb-pwrkey-uaccess.rules` | `/etc/udev/rules.d/70-tb-pwrkey-uaccess.rules` |
| `tb-power-menu@tb710fu/` | `/usr/share/gnome-shell/extensions/tb-power-menu@tb710fu/` |
| `test/uinput-key.c` | 仅测试用（虚拟键盘注入 KEY_POWER） |

## 安装

```sh
sh install.sh
```

安装脚本会保存原来的 `power-button-action` 到
`/root/tb-power-button-action.before`，把 gsettings 改成 `nothing`，启用并
启动用户服务。**扩展要下一次登录才被 GNOME 扫描到**；在那之前长按走
gnome-session 的关机对话框。

## 测试（无需真按电源键）

```sh
# 在平板上（root）
./uinput-key 300 4000 &      # 4s 后短按 300ms
NODE=$(for e in /sys/class/input/event*; do
  [ "$(cat $e/device/name)" = tb-power-test ] && echo /dev/input/$(basename $e); done | head -1)
chmod 666 "$NODE"
TB_POWER_DRY_RUN=1 TB_POWER_KEY_DEVICE="$NODE" runuser -u alarm -- \
  env XDG_RUNTIME_DIR=/run/user/1000 \
      DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
  /usr/local/bin/tb-power-key
# 短按日志：short press -> suspend / dry-run: would call Suspend
# 长按（uinput-key 2000 4000）：long press / dry-run: would open the power menu
```

- 无头 shell 里调用 `org.tb.PowerMenu.Open` 已验证对话框创建与关闭，无 JS 错误。
- 真机行为：短按挂起、长按弹菜单；PMIC 超长按仍复位。

## 回滚

```sh
runuser -u alarm -- env XDG_RUNTIME_DIR=/run/user/1000 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
  systemctl --user disable --now tb-power-key.service
runuser -u alarm -- env XDG_RUNTIME_DIR=/run/user/1000 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
  gsettings set org.gnome.settings-daemon.plugins.power power-button-action suspend
rm -f /usr/local/bin/tb-power-key /usr/lib/systemd/user/tb-power-key.service \
      /etc/udev/rules.d/70-tb-pwrkey-uaccess.rules
rm -rf /usr/share/gnome-shell/extensions/tb-power-menu@tb710fu
udevadm control --reload-rules
```

## 校验（2026-11-07）

```
29751a848f14c6089b8cdc177c7a81a61b093b3f2fb9e3faaace384698e5319b  tb-power-key
5e4ae198b887c85cb4d8f48625f21f1c5d7be523b3557f4e92a481fd670e2162  tb-power-key.service
091afc867540387f67279dca088a45589709685ea4b9c3096ccd6b649a574b98  tb-power-menu@tb710fu/extension.js
57e044324319f8ed7a041e6f1b50e2e84dac2f150a4d9921bce9f0f3ca54882d  tb-power-menu@tb710fu/metadata.json
735563777f216074ec63ed8d39b53732791cc89084321b5d2b02a29d716ed5d3  tb-power-menu@tb710fu/stylesheet.css
```
