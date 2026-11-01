# Device-side fixes

Everything here runs from the PC over SSH against a booted Arch install. Each
`deploy_*/` directory holds a `deploy_*.sh` (scp + remote install) and the files it installs.

```bash
./deploy_all.sh <tablet-ip>
```

Set `TB_SSH_KEY` if your key is not `~/.ssh/id_ed25519`. The tablet's root account must accept
that key (`install_payload.sh` does this if you pass `SSH_PUBKEY=` during the rootfs build).

| directory | what it installs |
| --- | --- |
| `system/` | `qcom_battmgr current_inverted=1` (charging display), fastrpc/backlight udev rules, UFS runtime-PM unit, volume-key swap (compiled on the tablet), CJK font preference, `tb-ufs-pm.service` |
| `als/` | ambient-light auto brightness daemon with per-user learning, plus the greeter instance for the login screen |
| `gamut/` | Display P3 ICC profile + `tb-gamut` CLI/menu entry (accurate / native / soft) |
| `cover/` | flip-cover hall GPIO daemon: screen off + lock on close, wake on open |
| `gpu/` | GPU `min_freq` touch boost (629 → 422 → 231 MHz) |
| `power/` | `org.freedesktop.UPower.PowerProfiles` three-level service (power-saver / balanced / performance); unit is ordered before `display-manager.service` so PowerDevil's one-shot probe doesn't race it |
| `monitor/` | ksystemstats GPU plugin patch (msm/Adreno platform devices: fdinfo usage, devfreq freq, hwmon temp) — build on the tablet or install the Release asset |
| `mtp/` | MTP storage over the USB cable (uMTP-Responder over FunctionFS, shares the NCM gadget) |
| `plasma/` | first-login touch defaults (2× scale, no panel hiding) |
| `sensors/` | hexagonrpcd + sensor registry (optional, needs meson on the tablet) |
| `diagnostics/` | black-screen/backlight watcher, not installed by default |

## Notes

- `deploy_all.sh` does not touch `boot_a`. Kernel changes come from the image built in `build/`.
- Everything is idempotent; re-running replaces files and restarts the affected units.
- `system/install_system_extras.sh` needs `cc` (gcc) on the tablet for the volume-key helper.
  Without it the rest still installs.
- The als/gamut/cover/gpu/power scripts write only under `/usr/local`, `/etc/systemd/system`,
  and the user's `~/.config` for the learning profile.
