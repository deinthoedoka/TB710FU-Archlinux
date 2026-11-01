# x86_64 games with FEX-Emu

The reference device runs x86_64 Windows/Linux games through FEX with a guest Mesa
rootfs. This is what makes an ARM64 tablet usable for a normal Steam library.

## Packages and files

- `fex-mesa` from the ALARM/AUR repositories (the emulator + a guest Mesa build)
- a guest rootfs under `/usr/share/guestos/` (the reference device uses `fex-mesa`)
- `~/.config/fex-emu/` on the desktop user (FEX config)
- Steam's per-title launch options point at FEX through the container's `emulator.json`
  (`FEX_ROOTFS` must point at the guest rootfs, not the host root)

## Reference layout

```
/usr/share/guestos/fex-mesa/        guest rootfs (libraries + Mesa)
~/.config/fex-emu/                  FEX config
~/.steam/sdkarm64/                  ARM64 Steamworks library for native games
```

## Notes

- Only install the FEX packages; do not pull a distribution upgrade for them.
- `FEX_ROOTFS` is read by the Steam Linux Runtime container; if games fail with
  "cannot execute binary file", check that the container's `emulator.json` points at the
  guest rootfs and that `/usr/share/guestos/fex-mesa` exists.
- Performance is best at the 120 Hz panel rate with the GPU boost service running
  (`deploy/gpu/`).
