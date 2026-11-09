# Droidloom APK 安装器

把 `.apk` 放到平板里，双击即可安装；也可以从应用列表打开“APK 安装器”，
选择或拖入文件。安装走官方 `droidloomctl install`，不修改 droidloom 本体，
更新已安装应用时保留数据。安装器的“已安装应用”页会列出 Android 应用，
并支持卸载（走 `droidloomctl uninstall`）。

## 文件

| 文件 | 部署位置 | 作用 |
| --- | --- | --- |
| `droidloom-apk-installer.py` | `/usr/local/bin/droidloom-apk-installer` | GTK4 图形界面 + `--cli`/`--check`/`--list`/`--uninstall` 终端模式 |
| `org.droidloom.ApkInstaller.desktop` | `/usr/share/applications/` | 应用入口 + `application/vnd.android.package-archive` MIME |
| `droidloom-apk-installer.svg` | `/usr/share/icons/hicolor/scalable/apps/` | 矢量图标 |
| `droidloom-apk-installer-128.png` | `/usr/share/icons/hicolor/128x128/apps/` | 位图图标 |
| `install.sh` | — | 在平板上一次性安装上述文件并注册 MIME |

## 安装

```sh
# 在平板 root 下
sh install.sh
# 或手动
install -Dm755 droidloom-apk-installer.py /usr/local/bin/droidloom-apk-installer
install -Dm644 org.droidloom.ApkInstaller.desktop /usr/share/applications/
install -Dm644 droidloom-apk-installer.svg /usr/share/icons/hicolor/scalable/apps/
install -Dm644 droidloom-apk-installer-128.png /usr/share/icons/hicolor/128x128/apps/
update-desktop-database /usr/share/applications
gtk-update-icon-cache -f -t /usr/share/icons/hicolor
runuser -u alarm -- xdg-mime default org.droidloom.ApkInstaller.desktop \
    application/vnd.android.package-archive
```

注册后 Nautilus 双击 `.apk` 就会打开安装器；应用列表里也会出现
“APK 安装器”条目。

## 使用

- **双击**：Nautilus 里双击 APK → 显示包名/版本/ABI/权限 → “安装”。
- **拖放**：把 APK 拖到安装器窗口。
- **应用列表**：打开“APK 安装器”，选择文件。
- **已安装应用**：点右上角“已安装应用”，可查看 Android 应用列表并逐个卸载
  （系统应用会被 droidloom 拒绝卸载）。
- **终端**：
  ```sh
  droidloom-apk-installer --check ~/下载/app.apk      # 只看信息
  droidloom-apk-installer --cli   ~/下载/app.apk      # 命令行安装
  droidloom-apk-installer --list                      # 列出已安装应用
  droidloom-apk-installer --uninstall com.example.app # 卸载
  ```
- 安装成功后可直接“打开应用”；应用目录会由 `droidloom-applications`
  自动刷新，图标和桌面条目自动生成。
- 安装/卸载日志：`~/.local/state/droidloom-apk-installer/install-*.log`。

## 行为与限制

- 只支持**单一 APK**；`.apks`、`.xapk`、`.apkm` 分包不受支持。
- APK 大小不再被安装器或 droidloom 限制在 2 GiB；实际上限由 Android
  的 `cmd package install -S` 与文件系统决定（单 APK 的 ZIP32 上限是 4 GiB）。
- “已安装应用”来自 Android 启动器目录（MAIN/LAUNCHER）；没有启动活动的
  包不会列出。卸载会删除该应用在 Android 内的数据。
- 安装器和卸载都通过控制 socket 以当前桌面用户身份调用 `droidloomctl`；
  Android 未运行时最多尝试自动 `droidloomctl start` 一次。
- GUI 用 GTK4/PyGObject，只依赖平板已有的运行时，不新增 pacman 包。
- 需要配套的新 `droidloomctl`（含 `uninstall`/`details` 子命令）与新
  `droidloomd`（取消 2 GiB 上限）；只升级安装器时“已安装应用”页会报
  `unknown command`。

## 已验证（2026-11-07，平板 TB710FU）

- 荒野乱斗 70.19.2（2,155,686,393 B ≈ 2.0 GiB，
  `com.tencent.tmgp.supercell.brawlstars`）：
  - `--check` 0.2 s；不再受 2 GiB 限制；
  - `--cli` 安装 5.6 s，返回 “APK installed successfully”；
  - 应用目录出现“荒野乱斗”，`--list` 可见；
  - `--uninstall` 卸载成功并从目录消失，随后重新安装成功。
- 卸载系统应用（`com.android.settings`）被框架拒绝：
  `System apps cannot be removed`，安装器会原样显示。
- 大 APK 的显示名在安装前可能来自包名（>64 MiB 时跳过
  `resources.arsc` 解析以保证窗口秒开），安装后由目录提供真实名称。

## 已验证（2026-11-06，平板 TB710FU）

- Material Files 1.7.5（11 MB，包名 `me.zhanghai.android.files`）：
  - GTK 窗口加载、详情展开、安装按钮、成功状态、应用图标/名称均正常；
  - `droidloomctl applications --json` 从 3 个应用变为 4 个；
  - 自动生成 `~/.local/share/applications/droidloom-*.desktop` 和 128px 图标；
  - “打开应用”成功启动 Android 窗口；安装器随后关闭。
- 命令行 `--cli` 与图形路径走同一 `run_install()`，实测成功。
- 微信 8.0.80（273 MB）仅做解析验证：包名 `com.tencent.mm`、100 项权限。
- 无效文件（非 ZIP）会显示“不是 APK（ZIP 头不正确）”，不会崩溃。
- 空状态窗口与“选择 APK”文件对话框正常。

## 回滚

平板上的备份目录带有可直接执行的 `rollback.sh`：

```sh
sh /root/denial-deploy/backup-apk-installer-20261106/rollback.sh
```

手动回滚：

```sh
rm -f /usr/local/bin/droidloom-apk-installer \
      /usr/share/applications/org.droidloom.ApkInstaller.desktop \
      /usr/share/icons/hicolor/scalable/apps/droidloom-apk-installer.svg \
      /usr/share/icons/hicolor/128x128/apps/droidloom-apk-installer.png
update-desktop-database /usr/share/applications
gtk-update-icon-cache -f -t /usr/share/icons/hicolor
# 恢复 ~/.config/mimeapps.list 的部署前备份，或删除对应的一行
```

部署前的 `mimeapps.list`、`rollback.sh` 和 `SHA256SUMS` 在平板
`/root/denial-deploy/backup-apk-installer-20261106/`。

## 校验值（2026-11-06）

```
efa8a728c13d546007306a0ac482e468d018bef411f7230ef4d04130cd77514a  droidloom-apk-installer.py
ae80fbf6a2f9be500569754b80dec3e5ff145aa5bd22c3a71da984e7e0e8d53d  org.droidloom.ApkInstaller.desktop
f016f4ec8dc3dc32e421b056039d9a16cefe3adb6c9531967d4f19e7b14f9ec3  droidloom-apk-installer.svg
4e803f752ae3e631a2cbc172869b9ad3b42035e155266fe49ebb9958470f6b23  droidloom-apk-installer-128.png
e29f54ef7936688c19999627749920b74bc20f3ca085b139cc49799170292984  install.sh
```
