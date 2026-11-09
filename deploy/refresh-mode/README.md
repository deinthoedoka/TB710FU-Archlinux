# TB710FU 刷新率：自适应 / 60Hz 上限

## 背景

内置 DSI 面板在 KMS 里只有一个 `3200x2000@120Hz` 模式（`is-current` 也是它），
没有可变刷新率（VRR）能力。真正切到 60Hz 模式会让面板重新上电，出现花屏，
所以不能走「换模式」这条路。

本方案把「60Hz」做成**合成器出帧上限**：

- **自适应**（默认）：mutter 按内容需要出帧，最高 120Hz。
- **60Hz 上限**：mutter 的 frame clock 按 16.6ms 排帧，KMS 仍然扫描 120Hz 模式，
  面板不重新配置；画面看起来是 60fps，功耗和 GPU 负载下降。

## 实现

`libtb-refreshcap.so` 是 LD_PRELOAD 到 `org.gnome.Shell@user.service` 的小库。
mutter 51 从 libmutter 跨库调用
`clutter_stage_view_notify_presented(view, frame_info)`，后者再调用
`clutter_frame_clock_notify_presented(clock, frame_info)`，把
`frame_info->refresh_rate` 存进 frame clock。库同时钩住这两个入口
（stage view 是跨库 PLT 调用，保证可拦截；frame clock 作为兜底）：

- 读 `~/.config/tb-display-mode`；内容 `60` 时把 `refresh_rate` 改成 60.0，
  其他内容（或文件不存在）保持原值；
- 每 0.5s 最多检查一次文件，切换在下一帧生效，无需重启 shell；
- 写一个 `$XDG_RUNTIME_DIR/tb-refreshcap-loaded` 标记，扩展用它判断预载是否生效；
- 只在 `gnome-shell` 进程里写标记/打日志，并 `unsetenv("LD_PRELOAD")`，
  避免把预载泄漏给 shell 启动的子进程。

`ClutterFrameInfo` 的布局按 `/usr/include/mutter-51/clutter/clutter/clutter-stage.h`
逐字段复制，并加了 `_Static_assert`（refresh_rate 偏移 24、结构 48 字节）。

`tb-display-mode@tb710fu` 扩展在快捷设置里加一个「刷新率」磁贴：
点磁贴本身在两种模式间切换，点右侧箭头打开「自适应 / 60Hz 上限」菜单；
写入 `~/.config/tb-display-mode` 并立即更新副标题。如果预载还没生效
（第一次登录前），副标题显示「重启后生效」。

## 安装

```sh
sh install.sh
# 注销/重启后 LD_PRELOAD 才会进入 gnome-shell
```

## 验证

- 交叉编译 an interposition 测试（见 `test/`）：120Hz 输入在 60 模式下被改成
  60.0，自适应模式保持 120.0；无预载时保持 120.0。
- 无头 GNOME Shell 里预载可加载、扩展创建磁贴无 JS 错误。
- 真机：`journalctl -b -o cat | grep tb-refreshcap` 应出现
  `loaded`、`observed 120.00Hz`，切到 60 后出现 `applied cap: ... -> 60Hz`。
- 注意：60Hz 是**出帧节奏**上限，KMS 模式仍是 120Hz；`modetest`/DisplayConfig
  不会显示 60Hz 模式，这是预期行为。

## 文件与校验（2026-11-07）

```
0d14d7ee1f59f5f7473ad4a3c600e22cb6566338fffe7f20ce77f4011c2bbb8a  libtb-refreshcap.so
3428b26b92454b596f3f06bc3889d7168113460fc093dffecbd2e8410e4f76be  tb-display-mode@tb710fu/extension.js
eb1c891546215c8dd46fb77427c397a7c27903c85b37787b651b9c9e788de8f6  tb-display-mode@tb710fu/metadata.json
```

## 限制 / 回滚

- 依赖 mutter 51 的 `clutter_frame_clock_notify_presented` 导出符号；mutter
  升级后需确认符号和 `ClutterFrameInfo` 布局未变（assert 会在编译期发现）。
- 回滚：删掉
  `/etc/systemd/user/org.gnome.Shell@user.service.d/tb-refreshcap.conf`、
  `/usr/local/lib/libtb-refreshcap.so` 和扩展目录，注销/重启。
- 60Hz 模式下所有 shell 动画也按 60fps 走；这是「最大刷新率锁 60」的定义。
