# GPU monitoring for the System Monitor app (msm / Adreno)

Upstream ksystemstats (KDE, 6.8.2) only enumerates **PCI** GPUs in its GPU plugin.
The TB710FU's Adreno is a **platform** device, so the System Monitor's GPU page
stays empty. This patch adds a platform-device backend:

- **Usage** — DRM fdinfo aggregation (`/proc/*/fdinfo` `drm-engine-*`, per-client
  deltas so a freshly opened context doesn't read as 100 %)
- **Frequency** — devfreq `cur_freq`/`max_freq` (231–903 MHz)
- **Temperature** — first `gpu*` hwmon zone (`gpuss0_thermal`)
- **VRAM** — fdinfo `drm-total-memory` (unified memory: total = MemTotal)

Works for `adreno`; the backend also picks up `panfrost`/`panthor` (Mali) devices
by name. Usage data needs a DRM driver with fdinfo (6.2+ vendor kernels have it).

## Files

| file | what |
| --- | --- |
| `ksystemstats/LinuxMsmGpu.{h,cpp}` | new device class |
| `ksystemstats/LinuxBackend.cpp` | upstream 6.8.2 file + devfreq enumeration appended |
| `ksystemstats/CMakeLists.txt` | upstream 6.8.2 file + `LinuxMsmGpu.cpp` in target_sources |
| `build_plugin.sh` | on-tablet build (cmake + ninja, GPU plugin only, 1–2 min) |
| `install_prebuilt.sh` | install the Release asset instead of building |
| `deploy_monitor.sh` / `deploy_prebuilt.sh` | PC-side helpers (scp + run) |

## Use

```bash
# build on the tablet (needs cmake ninja extra-cmake-modules)
./deploy_monitor.sh <tablet-ip>

# or install the prebuilt plugin from the Release page
./deploy_prebuilt.sh <tablet-ip> ksystemstats_plugin_gpu-6.8.2-tb710fu-msm-aarch64.so
```

## Rollback

The stock plugin is backed up to `/root/ksysmsm/ksystemstats_plugin_gpu.so.stock-backup`;
copy it back over `/usr/lib/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so`.

## Caveats

- The plugin is rebuilt against the **installed** ksystemstats version; `pacman -Syu`
  upgrading ksystemstats overwrites it — re-run `deploy_monitor.sh` after.
- Verifying sensors from scripts: ksystemstats only polls sysfs for **subscribed**
  clients, and a one-shot `busctl subscribe` disconnects immediately — use a
  persistent client (KSysGuard::Sensor) or just watch the app.
