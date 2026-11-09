# android-launch — 安卓应用按需启停

平板上的 droidloom 一旦被拉起就永远在后台：Android 空闲时仍占 1.2 GB 内存、
918 个 task、4.5% 单核 CPU，AlarmManager 还持续武装 RTC 闹钟（`rtc@6100`
的 `power/wakeup=enabled`，一次 boot 响 56 次），自动挂起期间会被它叫醒。

装上这套东西之后：

- 点安卓应用图标：运行环境没跑就先整套拉起（实测 4 秒上屏），再起应用；
- 最后一个安卓任务消失 120 秒后：自动停掉运行环境（内存回落约 0.57 GB，安卓闹钟随之消失）。

规则（2026-11-09 定的）：最小化不算退出（任务还在，就不停）；没有保活名单；宽限 120 秒。

2026-11-09 部署并验收；当天晚上修掉了"点图标不拉起"（见下面的"冷启动放在哪里"）。

## 组成

| 文件 | 装到哪 | 作用 |
|---|---|---|
| `tb-droidloom-idle` | `/usr/local/bin/` | 空闲守卫：从 journal 跟踪安卓任务集合，归零满 120 秒就停运行环境 |
| `tb-droidloom-idle.service` | `/usr/lib/systemd/user/` | 守卫的用户单元，`WantedBy=default.target`，故意不 `PartOf=droidloom.service` |
| `install.sh` | — | 幂等安装：装上面两件、用 `Hidden=true` 屏蔽常驻入口、停掉 adb 单元 |

冷启动拉起不在这里，在 `droidloomctl` 里（见下一节）。

## 冷启动放在哪里

`droidloomctl launch` 需要一个活的 cell，运行环境停着时它会报
`connect to droidloomd: No such file or directory` 然后立刻退出。第一版把包装脚本
`tb-android-launch` 写进 desktop 条目的 `Exec=`，实测点图标仍然不拉起：
GNOME Shell 51 在会话启动时就把应用列表连命令行一起缓存在内存里，catalog 之后重写
`.desktop` 不会改变它实际执行的那一行（11-09 的 journal：点击进程毫秒级退出，
没有任何单元启动记录，而磁盘上的条目用 `gio launch` 能正常冷启动）。

所以预热做进了 `runtime/droidloom-supervisor/src/bin/droidloomctl.rs`：
`Launch` 发现 `/run/droidloom/control.sock` 不存在且自己是桌面会话里的普通用户
（euid 非 0、`XDG_RUNTIME_DIR` 属于这个 uid），就先走 `session_lifecycle("start")`
把用户单元整套起起来，再发 launch 请求。这样新旧命令行都能用，不依赖 GNOME 何时刷新缓存，
条目也回到上游原样（`Exec=/usr/bin/droidloomctl launch …`），包装脚本已删除。

`--json` 调用不会多出第二行输出：`session_lifecycle` 多了一个 `announce` 参数，预热时
不打印结果行，进度信息仍走 stderr。root 或服务上下文不做预热（它们没有可启动单元的
user manager，保持原来的报错）。

## 安装

工作站交叉编译（配方见记忆 `tb710fu-droidloom-install`）：

```sh
cd work/droidloom
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=/home/asus/x-tools/usr/bin/aarch64-linux-gnu-gcc
export RUSTFLAGS="-C link-arg=--sysroot=/home/asus/denial-sysroot"
export CARGO_TARGET_DIR=/home/asus/denial-cross-work/rust
export PKG_CONFIG_SYSROOT_DIR=/home/asus/denial-sysroot
export PKG_CONFIG_LIBDIR=/home/asus/denial-sysroot/usr/lib/pkgconfig:/home/asus/denial-sysroot/usr/share/pkgconfig
cargo build --release --locked -p droidloom-supervisor --bin droidloomctl --target aarch64-unknown-linux-gnu
cargo build --release --locked -p droidloom-applications --target aarch64-unknown-linux-gnu
```

两个二进制都要装：`droidloomctl` 带冷启动预热，`droidloom-applications` 写回上游的 `Exec=`。
注意 `--bin` 会作用到所有 `-p` 选中的包，分开构建否则第二个包不会重编。

平板侧（先备份现有二进制，逐个 sha256 校验）：

```sh
mkdir -p /root/tb-backups
cp -a /usr/bin/droidloomctl /root/tb-backups/droidloomctl.before-cold-launch-20261109
cp -a /usr/bin/droidloom-applications /root/tb-backups/droidloom-applications.before-cold-launch-20261109
runuser -u alarm -- env XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    systemctl --user stop droidloom-applications.service
install -m755 /root/tb-android-launch/droidloomctl /usr/bin/droidloomctl
install -m755 /root/tb-android-launch/droidloom-applications /usr/bin/droidloom-applications
sh /root/tb-android-launch/install.sh
runuser -u alarm -- env XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    systemctl --user start droidloom-applications.service
```

## 验证

```sh
# 条目应是上游原样，指向 droidloomctl
grep -h '^Exec=' ~/.local/share/applications/droidloom-*.desktop
# 停止态 → 用桌面图标实际执行的那一行冷启动，约 4 秒上屏
systemctl --user stop droidloom.service
/usr/bin/droidloomctl launch com.android.settings \
    --component com.android.settings/com.android.settings.Settings --user 0
# --json 冷启动后 stdout 应只有一个对象
/usr/bin/droidloomctl --json launch com.android.settings \
    --component com.android.settings/com.android.settings.Settings --user 0 | python3 -c 'import json,sys; print(json.load(sys.stdin))'
# 关掉窗口 → 120 秒后自动停
journalctl --since '-5 min' | grep 'idle guard'
# 远程"关掉一个应用"（root 才能进 cell 的 namespace）
hp=$(runuser -u alarm -- env XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    droidloomctl --json status | grep -o '"host_pid": [0-9]*' | grep -o '[0-9]*')
nsenter -t "$hp" -m -p -- /system/bin/cmd activity force-stop com.android.settings
```

实测数字（2026-11-09）：停止态点击 → 上屏 4 秒；已跑时 0 秒；任务销毁 → 121 秒后守卫发出停止，再 14 秒拆除完；守卫自身常驻约 10 MB。

## 已实测的五个坑

- `droidloomctl status` 在停止时打印 "Droidloom is stopped" 但退出码是 0，判据只能用 control.sock 是否存在。
- `systemctl --user start --no-block` 会抢在 socket 出现之前返回，紧接着的 launch 报 `connect to droidloomd`；必须阻塞式 start。
- `droidloom-adb-server` 是 droidloomd 自己用 `systemd-run` 起的（automatic ADB），运行环境在跑时杀不掉，拆除过程中还会重生一次；守卫因此先停 droidloom.service，再循环确认 adb 单元真的没了。
- GLib 不把 `NoDisplay=true` 当作隐藏（`GioUnix.DesktopAppInfo.get_is_hidden()` 仍是 False），屏蔽条目要用 `Hidden=true`。
- **GNOME Shell 51 缓存的是会话启动时的命令行**：改 `.desktop` 的 `Exec=` 不会改变已经开着的 shell 点击时执行的内容。任何"点图标要先做点什么"的需求都必须落在被执行的那个二进制里，改条目不算修好。

## 回滚

```sh
systemctl --user disable --now tb-droidloom-idle.service
rm -f /usr/local/bin/tb-droidloom-idle /usr/lib/systemd/user/tb-droidloom-idle.service
rm -f ~/.local/share/applications/dev.denial.Droidloom.desktop
install -m755 /root/tb-backups/droidloomctl.before-cold-launch-20261109 /usr/bin/droidloomctl
install -m755 /root/tb-backups/droidloom-applications.before-cold-launch-20261109 /usr/bin/droidloom-applications
systemctl --user restart droidloom-applications.service
systemctl --user start droidloom.service                  # 恢复常驻
```

## 未做的事

不动 `/sys/devices/.../rtc@6100/power/wakeup`（用户明确要求保持 enabled）。运行环境关掉之后，安卓闹钟本身就不存在了，这已经是省电与防误醒的主要手段。
