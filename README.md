<p align="right"><b>English</b> · <a href="README.zh-CN.md">简体中文</a></p>

# Arch Linux ARM for the Lenovo Xiaoxin Pad Pro GT (TB710FU)

Turn this Snapdragon 8 Gen 3 tablet into a full Arch Linux desktop while **keeping the
stock ZUXOS intact**: `boot_a` hosts a kShimC boot menu — pick ZUXOS or Arch with the
volume keys at every boot, and neither side touches the other.

**Supported hardware**: TB710FU (Xiaoxin Pad Pro GT, SM8650 / 12 GB / 256 GB) with an
unlocked bootloader only. Do not flash this on any other device.

> The install guide ([docs/INSTALL.md](docs/INSTALL.md)) and the prebuilt-release guide
> ([release/README.md](release/README.md)) are bilingual (English + 简体中文); the other
> docs in `docs/` are currently Chinese-only.

---

## What you get

A tablet that works like a laptop:

- 3200×2000 @ 120 Hz built-in display, native panel driver, KDE Plasma 6 desktop
- Touch, stylus (incl. button mapping), external keyboard and mouse
- Quad speakers, microphones, headphone / Bluetooth audio
- Wi-Fi 7 (WCN7850) and Bluetooth
- Ambient light sensor → auto brightness with learning; the login screen too
- Flip-cover hall sensor: close the cover → screen off + lock; open → wake
- Three power profiles (power-saver / balanced / performance), GPU touch boost
- Battery level and charging status display correctly; suspend via s2idle
- Everyday desktop software: Firefox, LibreOffice, Dolphin, Konsole, Discover (Flatpak)
- Optional: QQ, WeChat (official ARM64 builds), Steam (Valve ARM64 client), FEX to run
  x86_64 games

The Android side (ZUXOS) stays exactly as it is — switch back any time.

---

## Hardware support status

| Part | Status | Notes |
| --- | --- | --- |
| Built-in display 3200×2000 | ✅ | Dual DSI + DSC, native panel driver; **120 Hz only** — 60 Hz gives a black screen / artifacts |
| Touch / stylus | ✅ | NT36532, incl. stylus button mapping |
| GPU | ✅ | Adreno 750 (freedreno), Vulkan / OpenGL |
| Audio | ✅ | 4× AW882xx + TDM; speakers, microphones, headset |
| Wi-Fi 7 | ✅ | WCN7850 / ath12k, 2.4 / 5 / 6 GHz |
| Bluetooth | ✅ | WCN7850 |
| Ambient light / accelerometer | ✅ | ADSP + hexagonrpcd + iio-sensor-proxy |
| Flip-cover hall | ✅ | GPIO66; closed = screen off + lock |
| Charging / battery | ✅ | incl. the "fast charging shows as discharging" fix |
| Suspend | ✅ | s2idle + UFS self-heal |
| Volume / power keys | ✅ | Hardware order is reversed; swapped in software |
| Fingerprint | ❌ | No Linux driver |
| Camera | ❌ | No Linux driver |
| Cellular / GPS | ❌ | This model has no modem |

---

## Fixes and optimizations

This is not a "it boots" port — it is tuned for daily use:

### Display

- The panel drivers load in a fixed order (`aw37503 → sy7758 → dispcc → panel → msm`)
  so udev's early probing cannot wipe the ABL's simpledrm framebuffer; after loading,
  one DRM off/on cycle clears the NT36532 latching race.
- `dispcc_sm8550` auto-probe is blocked — otherwise it reconfigures the PLL and blacks
  the screen out.
- The panel driver carries full dual-DSI + DSC timing; 3200×2000 @ 120 Hz is stable.
- The login screen and the desktop share one `kwinoutputconfig.json` (scaling, ICC,
  brightness).

### Colour

- The panel covers ~98% DCI-P3 but has no EDID, so KDE defaults to sRGB output and
  colours look oversaturated.
- Ships a minimal Display P3 ICC (604 B, generated in pure Python): the `accurate` mode
  maps sRGB content correctly. Two more modes — `native` (vivid, untagged) and `soft`
  (AdobeRGB, softer) — switchable from the menu / CLI in one click.

### Touch & performance

- First login auto-sets the panel scaling to 2× (changeable).
- GPU `min_freq` touch boost: 629 → 422 → 231 MHz while touching, back down on release —
  scrolling feels much snappier.
- Three power profiles, served by a bundled daemon that owns
  `org.freedesktop.UPower.PowerProfiles`:
  - `power-saver`: CPU capped at 50%, GPU ≤ 422 MHz, touch boost off
  - `balanced`: everything unrestricted
  - `performance`: CPU min frequency raised to 35% of the maximum
- The "Power Management" page in System Settings actually switches profiles (the stock
  power-profiles-daemon only shows "unavailable" on Snapdragon).

### Audio

- Fixed the LPASS clock race during ADSP bring-up: clock registration no longer sends
  commands to a DSP that has not started yet — `rpmsg_send()` used to block forever and
  hang the boot.
- Fixed the "first playback is silent" issue: `tb-audio-init` plays one second of
  silence to clock the TDM bus, then turns the four amplifiers "on" (they are ENUM
  controls where `on` actually writes 0).
- WirePlumber config pins the speaker routing and disables the unpopulated inputs.

### Network

- ath12k: process-context polling disabled (it races NAPI for the same SRNG and
  oopses), hardware dedup enabled (otherwise retransmitted MPDUs are dropped as
  duplicates and TCP falls to 0.1–0.5 MB/s), board name pinned.
- The driver loads on demand (`tb-wifi.service`) so the early boot phase cannot take
  the board down.
- Regulatory domain CN; NetworkManager owns every interface except `usb0`.

### Sensors & auto brightness

- The ADSP sensor chain: `hexagonrpcd` (with a local method-36 patch) + the sensor
  registry + `iio-sensor-proxy` → lux readings.
- Custom auto-brightness: stepless 0.5%–2% per 100 ms across 12 logarithmic lux
  anchors; manual brightness changes are learned (the curve stops overriding you under
  the same light); idle dimming only pauses the daemon and never learns.
- On the plasmalogin login screen, a separate `tb-als-greeter` writes the backlight
  directly, so brightness stays continuous across login.

### Power, charging & suspend

- **Charging display fix**: the PMIC firmware reports charging current as negative, so
  UPower 1.91 showed fast charging as "discharging". The driver gains a
  `current_inverted=1` module parameter (no DTB / boot_a changes) and wall charging now
  displays correctly.
- Forced s2idle (deep sleep never wakes on this board), plus a `host_reset` self-heal
  for the UFS controller on resume — fixes sporadic UFS dropouts.
- UFS runtime power management enabled to cut idle power.
- The volume keys are wired opposite to their labels; `tb-volume-swap` swaps them after
  udev enumeration.

### Desktop & interaction

- Plasma 6 + the plasmalogin login manager; 2× scaling on first login (the reference
  device runs 2.5× — change any time); Dolphin / Konsole / Discover included.
- Chinese environment: `zh_CN.UTF-8`, Noto / Source Han fonts, fontconfig prefers SC
  glyphs.
- A short power-button press does not power off (the desktop menu decides); a long
  press stays with the PMIC; the flip cover is handled by its own daemon.

---

## Repository layout

```
build/       kernel / boot / rootfs / vbmeta builds; local kernel patches; NBD install service
deploy/      one-shot device-side fixes over SSH: brightness, gamut, cover, GPU, power, misc
apps/        install notes for the desktop and apps (Steam / FEX / QQ / WeChat / 302)
packages/    reference device pacman package list
docs/        install, features, hardware, known issues, troubleshooting
release/     prebuilt-release usage, firmware injection, image packing scripts
third_party/ hexagonrpc sources and sensor config
```

## Quick start

> Full steps (partitioning, NBD install, UFS write, pitfalls) in
> [docs/INSTALL.md](docs/INSTALL.md). Flashing `boot_a` writes to the device — read it
> before you act.

1. **Prepare**: unlock the bootloader; take an EDL full-partition backup; you need a
   Linux / WSL2 build host.
2. **Build**:
   ```bash
   ./build/fetch-deps.sh
   bash build/wsl_build.sh all                        # Image, dtb, modules, kShimC, arch-nbd.img
   bash build/make-boot.sh /path/to/stock_boot_a.img  # boot_zui.img / boot_arch.img
   ```
3. **Flash**: `out/boot/boot_arch.img` → `boot_a` (only `boot_a` is written).
4. **Install**: boot the built Arch rootfs over USB NBD; `install_ufs.sh` writes the
   system into an 80 GiB partition carved off the end of userdata.
5. **Deploy**: once booted, on the PC run `deploy/deploy_all.sh <tablet-ip>`.
6. **Apps**: `apps/install/desktop.sh` installs the desktop; the rest under `apps/`.

**Don't want to build anything?** Download `Image`, the dtb, `kShimC.bin`, the packer
and the firmware-less rootfs from the
[Release](https://github.com/deinthoedoka/TB710FU-Archlinux/releases) and pack them
with your own `boot_a` — see [release/README.md](release/README.md). No cross-compile
environment needed. The Release contains no ready-to-flash boot image and no vendor
firmware — the reasons are on that page.

## Known issues

See [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md). The three most common:

- The panel runs at 120 Hz only; 60 Hz gives a black screen / artifacts.
- Login occasionally shows a black screen until you touch it.
- **Every Arch reboot burns one A/B retry count**: before rebooting repeatedly, boot
  ZUXOS once so Android marks its slot successful — otherwise the counter hitting zero
  leaves you in fastboot.

## Releases (maintainer notes)

The repository keeps sources and scripts; the "usable without building" artifacts go
to Release assets. A generated set lives in `out-release/` (excluded by `.gitignore`,
not part of the repo). After pushing code updates, cut a release:

```bash
gh release create vX.Y \
  out-release/Image out-release/sm8650-lenovo-tb710fu-kshim.dtb \
  out-release/kShimC.bin out-release/MultiBootKernelPatcher \
  out-release/modules-7.2.6-tb710fu.tar \
  out-release/arch-nbd-base.img.zst.part00 out-release/arch-nbd-base.img.zst.part01 \
  out-release/SHA256SUMS \
  --notes-file out-release/RELEASE-NOTES.md
```

When regenerating with `release/make-image.sh` the number of volume parts may change —
go by what `out-release/` actually contains. **Do not** upload `boot_arch.img`: `boot_a`
must be packed from each user's own stock image (see [release/README.md](release/README.md)).

## What is NOT in this repository

To keep this publishable, the following are **not** included (please don't ask others
for them either):

- SSH private keys, Wi-Fi passwords, account tokens
- Browser, Steam, QQ, WeChat user data and personal files
- Device serials, `socinfo/`, EDL full-partition backups, `super.img`
- Vendor firmware and the sensor registry (extract them from your own device with
  `build/collect_firmware.sh`)
- Steam / QQ / WeChat / Steamcommunity-302 binaries
- Waydroid images and temporary artifacts from the GNOME era

## Credits

This port stands on the work of many people — see [CREDITS.md](CREDITS.md). Core
upstream:

- [tb710fu-hyperos-steamos](https://github.com/lich-wang/tb710fu-hyperos-steamos) (board support, kernel patches, kShimC integration)
- [armadaos-freedom](https://github.com/mydanyi/armadaos-freedom) (SM8650 kernel patch baseline)
- [tb710fu-linux](https://github.com/MeteoricmeteorLL/tb710fu-linux) (DTS, panel / touch / audio / Wi-Fi)
- [kShimC](https://github.com/sunflower2333/kShimC), [DualBootKernelPatcher](https://github.com/Project-Aloha/DualBootKernelPatcher)
- [hexagonrpc](https://github.com/linux-msm/hexagonrpc)

## License

The scripts and docs in this repository are MIT. Kernel patches inherit the Linux
kernel's GPL-2.0; upstream code and firmware follow their own licenses — see
[CREDITS.md](CREDITS.md) and the LICENSE files in each directory.

## Disclaimer

Flashing is risky: a wrong write can brick the device or destroy data. This project
comes with no warranty. **Never** write `persist`, `modemst*`, `fsg`, `fsc`, `devinfo`,
`frp`, `keystore`, `ssd`, `secdata`, `uefivarstore`, `cdt`, `ddr`, and never restore an
old raw userdata image — QTEE anti-rollback will permanently break the PIN.
