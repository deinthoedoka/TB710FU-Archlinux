# Steam (ARM64 client)

Valve's Linux ARM64 client is not on the public Steam CDN; it ships inside the ARM64
SteamOS images. This port runs the client from a manual unpack — **the binaries are not
included here** because they are Valve's.

## What the reference install looks like

- client tree: `~/.local/share/Steam` (a normal per-user install)
- `~/.steam/sdkarm64` → the client's `linuxarm64` steamclient library, so native ARM64
  games that ship a Steamworks SDK can load it
- `/etc/hosts`: `127.0.0.1 steamloopback.host` — required by the client's loopback
  handshake on this kernel
- a locally built GTK2 (`steam` needs 32-bit-era GTK2 symbols on ARM64); the package build
  is pinned in the project notes
- the menu icon comes from the Arch `steam` package's 256 px PNG, not from the client's
  game cache icons

## Outline

1. Obtain the ARM64 SteamOS image or the client package matching your SteamOS branch and
   extract `steamrt`/`steam` into `~/.local/share/Steam` (keep the `package/` layout).
2. Build/install GTK2 for aarch64 if `steam` complains about missing `libgtk-x11-2.0.so.0`.
3. Add the loopback host entry.
4. Link the ARM64 Steamworks library:
   `ln -s ~/.local/share/Steam/linuxarm64/libsteam_api.so ~/.steam/sdkarm64/libsteam_api.so`
5. Start from the desktop session (the first run needs a working Wayland/X display and a
   polkit agent; running over plain SSH will fail without `XAUTHORITY`).

Native ARM64 titles work directly. x86_64 titles need FEX — see [fex.md](fex.md).

## Notes

- Proton for ARM64 is separate from the x86_64 Proton runtime; the reference device only
  uses FEX for x86_64 games.
- Do not run `pacman -Syu` to satisfy a Steam dependency: it would replace the custom
  kernel. Install individual packages with `--needed` and `--disable-sandbox`.
