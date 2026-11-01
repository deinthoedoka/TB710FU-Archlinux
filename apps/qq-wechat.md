# QQ and WeChat (official ARM64 builds)

Both clients have official Linux ARM64 builds; the reference device installs them as
local packages named `linuxqq` and `wechat-bin`. Neither is redistributed here.

## Build/install

The packages are the standard AUR recipes (`linuxqq`, `wechat-bin`), built locally with
`makepkg -si` after `pacman -S --needed base-devel`. They unpack Tencent's official
ARM64 `.deb`/AppImage payload into `/opt`.

Verify the vendor URL and checksum yourself; the recipes change with each release.

## Notes

- QQ 3.2.35 and WeChat 4.1.13.26 are the versions the reference device runs.
- Starting them over SSH needs `XAUTHORITY` and the desktop session's environment
  (`DISPLAY`/`WAYLAND_DISPLAY`, `DBUS_SESSION_BUS_ADDRESS`); launch from the application
  menu instead.
- Both are Qt/Electron clients and work on Wayland through XWayland.
- Do not install a Flatpak copy alongside the native package: the two keep separate data
  directories and the tray icon will duplicate.
