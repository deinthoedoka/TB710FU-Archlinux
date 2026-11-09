# TB710FU 安卓窗口控制（GNOME Shell 扩展）

给 droidloom 的安卓窗口补上触屏可用的窗口控制。背景：GNOME/mutter 不实现
`xdg-decoration-unstable-v1`（不画服务器端标题栏），droidloom 作为裸 Wayland
客户端也不画客户端装饰，于是安卓窗口在 GNOME 里没有标题栏、没有拖动区、没有
缩放手柄——触屏上无法移动、缩放或全屏。

## 功能

焦点落在 droidloom 窗口（`X-Droidloom-Managed=true` 的应用或 app_id 与窗口
标题相同的安卓包）时，顶栏右侧出现“安卓”入口：

- **全屏 / 退出全屏**：`Meta.Window.make_fullscreen()`，连 GNOME 顶栏一起隐藏
  （全屏时从屏幕上缘下滑可唤出顶栏再操作）。
- **最大化 / 还原**：填满工作区，保留顶栏。
- **尺寸**：铺满工作区、竖屏手机 480×800、左半屏、右半屏。
- **调整大小…**：进入调整模式，窗口四角出现 56px 触控手柄，顶部有移动手柄；
  拖动手柄实时改窗口尺寸（同时驱动 Android task 重新布局），底部“完成调整”退出。
- **关闭窗口**：向窗口发 `delete`（等同点标题栏关闭）。

## 安装

```sh
sh install.sh
# 等价于：
install -Dm644 tb-android-windows@tb710fu/metadata.json \
    /usr/share/gnome-shell/extensions/tb-android-windows@tb710fu/metadata.json
install -Dm644 tb-android-windows@tb710fu/extension.js \
    /usr/share/gnome-shell/extensions/tb-android-windows@tb710fu/extension.js
install -Dm644 tb-android-windows@tb710fu/stylesheet.css \
    /usr/share/gnome-shell/extensions/tb-android-windows@tb710fu/stylesheet.css
runuser -u alarm -- gsettings set org.gnome.shell enabled-extensions \
    "['tb-als@tb710fu', 'tb-rotate-anim@tb710fu', 'tb-android-windows@tb710fu']"
```

新扩展通常需要注销/重启 GNOME Shell 才会被扫描到；`gnome-extensions enable`
在扩展刚拷贝进去时也可能提示找不到。

## 与 droidloom 的关系

窗口尺寸完全由这个扩展通过 `Meta.Window.move_resize_frame()` 驱动，droidloom
收到新的 xdg_toplevel configure 后会把 Android task 重排到同样大小。初次打开
的默认大小仍由 `droidloomctl window-mode` 决定；建议给游戏设：

```sh
droidloomctl window-mode fit-output --package <安卓包名>
```

## 日志

```sh
journalctl -b -o cat | grep tb-android-windows
```

## 已验证（2026-11-07）

- 扩展在 `gnome-shell --headless --wayland` 的独立会话里加载成功，
  日志 `[tb-android-windows] enabled, 3 Android packages`，无 JS 错误；
  说明 metadata、ESM 导入、面板入口、catalog 解析、文件监视都能跑通。
- 触屏菜单与拖动缩放手柄需要真实会话验证（无头会话没有输入设备）。
- 荒野乱斗 `window-mode fit-output` 已实测：Android task 从 960×1600
  变为 3200×1936（工作区减去 GNOME 顶栏 64px），窗口铺满屏幕。

## 文件校验（2026-11-07）

```
116e21456a5a0a51210fc1661ab5e76d9ef0d66333aa3ce3e151d253a4b5422b  extension.js
5edac2e34f14e2bdfe165d837979fbc29c3644f9149c06494d99002306fca62d  metadata.json
6a9efc75d2d1e5add34155cba83b813cc1d61dbbe48040756e8a4c93048af5aa  stylesheet.css
c9ae93549be4889d41a13320734b8c7e55bf150f4fa9abf361dd3f97f1d185a0  install.sh
```

## 已知限制

- 只在 GNOME 51（mutter 51）上验证；依赖 `Meta.Window.move_resize_frame` 对
  Wayland 客户端可用。
- 调整模式下四角手柄会盖住窗口边缘约 28 逻辑像素，用于游戏操作时不要进入该模式。
- 全屏时顶栏隐藏；“退出全屏”需要从屏幕上缘下滑唤出顶栏后操作。
