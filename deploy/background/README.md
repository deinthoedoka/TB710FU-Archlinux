# TB710FU 后台减负

## 目的

平板的 8 GB 机型同时跑 GNOME + droidloom 时，空闲内存和后台唤醒会明显
影响前台应用。这里只做**可逆、按需恢复**的减负，不删应用：

- 去掉调试用的 `tb-display-watch`（它每秒执行一次 `loginctl list-sessions`，
  把 `systemd-logind` 拉到约 3% CPU，并写 1 Hz 日志）。
- 登录 90 秒后停掉 `gnome-software`、`localsearch-3`、
  `evolution-addressbook-factory` 这些常驻服务；它们都是 D-Bus 激活的，用户
  真正打开软件商店 / 联系人 / Nautilus 搜索时会自动重新启动。
  日历工厂和 source registry 保留，否则 gnome-shell 的日历后端会报
  “has crashed”，时钟菜单里的日程也会空掉。
- 把这些服务放进 `background.slice`（`CPUWeight=20`、`IOWeight=20`），并设置
  `Nice=19`、`IOSchedulingClass=idle`，即使它们在跑也抢不到前台。
- VM 调优：保留 dentry/inode 缓存，提前回写，避免后台拷贝/下载造成的卡顿。

## 文件

| 文件 | 部署位置 |
| --- | --- |
| `tb-background-trim` | `/usr/local/bin/tb-background-trim` |
| `tb-background-trim.service` / `.timer` | `/etc/systemd/user/` |
| `slice.d/50-tb-background.conf` | `/etc/systemd/user/background.slice.d/` |
| `dropins/*.service.d/50-tb-background.conf` | `/etc/systemd/user/` |
| `91-tb-performance.conf` | `/etc/sysctl.d/` |

## 安装

```sh
sh install.sh
```

安装脚本会停掉并 disable `tb-display-watch`，启用用户级 timer，并执行
`sysctl --system`。timer 在每次登录后 90 秒触发一次。

## 恢复

```sh
systemctl --user disable --now tb-background-trim.timer
rm -rf /etc/systemd/user/tb-background-trim.* \
       /etc/systemd/user/background.slice.d \
       /etc/systemd/user/{gnome-software,localsearch-3,evolution-*}.service.d
rm -f /etc/sysctl.d/91-tb-performance.conf
sysctl --system
```

`tb-display-watch` 只用于排查黑屏，不要在生产镜像里启用；它的源码仍在
`deploy/diagnostics/`。

## 预期

- 空闲时 `systemd-logind` 从 ~3% 回落到 0.1% 以下。
- 登录后 1-2 分钟内释放约 300-400 MB 常驻内存（8 GB 机型更明显）。
- 前台应用/游戏获得的 CPU/IO 权重不变；后台服务被降权而不是被杀。
