# 参考设备的包清单

`pacman-explicit.txt` 是参考设备 `pacman -Qqe` 的原样输出（70 个显式包，总包数 824），
`pacman-foreign.txt` 是本地构建的包（QQ、微信）。

## 不要直接安装这份清单

- `linux-aarch64` 是发行版内核，在这台机器上**只是被 IgnorePkg 挂起**；真正的内核在
  `boot_a` 里（7.2.6-tb710fu）。装它没有任何用处，升级它还可能破坏依赖。
- `sddm` 在这里没有启用（用的是 `plasma-login-manager` 的 plasmalogin）。
- `gcc`、`meson`、`ninja` 等是构建工具，只在需要编译守护进程/传感器时安装。

## 推荐的做法

1. 用 `build/build_rootfs.sh` 生成基础系统（自带 busybox、NetworkManager、SSH、pipewire 等）。
2. 用 `apps/install/desktop.sh` 装桌面和常用软件。
3. 需要别的包时单独装：

   ```bash
   pacman -S --needed --disable-sandbox <包名>
   ```

   本内核没有 Landlock，pacman 7 的下载沙箱会失败，`--disable-sandbox` 是必须的。

## 参考设备上的额外内容（不在 pacman 清单里）

- Steam（Valve ARM64 客户端，手工安装到 `~/.local/share/Steam`）
- FEX-Emu + guest rootfs（`/usr/share/guestos/`）
- Steamcommunity 302（`/var/lib/Steamcommunity_302/`）
- 本项目部署的守护进程（`deploy/`）
