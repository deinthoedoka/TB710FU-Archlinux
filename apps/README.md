# Applications

The desktop is KDE Plasma 6. This directory records what is installed on the reference
device and how to reproduce it. Nothing here redistributes third-party binaries: scripts
install from pacman/Flatpak, and the proprietary clients (Steam, QQ, WeChat, 302) are
documented with download instructions instead.

| App | How it is installed | Guide |
| --- | --- | --- |
| KDE Plasma 6, Dolphin, Konsole, KCalc, Discover | pacman | `install/desktop.sh` |
| Firefox, LibreOffice (zh-CN), Noto/Source Han fonts | pacman | `install/desktop.sh` |
| Flatpak apps | Flatpak + SJTU mirror | `install/flatpak.sh` |
| Steam (Valve arm64 client) | manual, from Valve | [steam.md](steam.md) |
| x86_64 Windows games | FEX-Emu + guest rootfs | [fex.md](fex.md) |
| QQ 3.2.35 / WeChat 4.1.13 (official arm64) | AUR-style local packages | [qq-wechat.md](qq-wechat.md) |
| Steamcommunity 302 v15 | third-party CLI + systemd unit | [s302.md](s302.md) |

`../packages/pacman-explicit.txt` is the exact `pacman -Qqe` snapshot of the reference
device (824 packages total). Do not feed it to `pacman -S` blindly: it includes
`linux-aarch64`, the distribution kernel, which must never replace the custom
`7.2.6-tb710fu` build. Use it as a reference for what should be present.
