# r25 kernel changes — iris low-IOVA fix + touch wake fix

These are the source files changed for the r25 deployment (2026-11-06). They are
copies of the modified files from the build tree
`work/rtc-fix/build/linux-7.2.6`, not a patch: apply them after the existing
patches (`0001-tb710fu-local.patch`, the freedom series and `000[2-6]-media-iris-*`)
when rebuilding the kernel or the three modules.

## Why

### 1. iris VPU: SMMU fault storm on any H.264/HEVC decode with display output

The VPU's non-pixel stream (SID `0x1940`) can only address IOVA
`0x25800000–0xe0000000`, but the driver puts both stream IDs in one IOMMU
domain with one IOVA allocator. Once an allocation lands below 600 MB the
firmware walks into an unmapped IOVA (observed `iova=0x00000000`,
`fsr=0x402`, `SID=0x1940`), the fault handler floods the machine and the
`iris_core_deinit/init` recovery freezes the whole system (audio included) for
seconds. It reproduces with a plain 1080p H.264 file through `mpv
--hwdec=vaapi`, not just Bilibili/Firefox.

The fix reserves IOVA `0x0–0x257fffff` at probe with `dma_iova_try_alloc()`
before any buffer exists, so every later `dma_alloc_attrs()` lands in the range
the firmware can address. This is the upstream driver-side approach
(`media: iris: Fix iova allocation from restrict region`, Vishnu Reddy, v2):
<https://patchwork.linuxtv.org/project/linux-media/patch/20260818-reserve_iova_in_driver-v2-1-5005a1154408@oss.qualcomm.com/>

After the fix: `qcom-iris aa00000.video-codec: reserved IOVA 0x0-0x257fffff
for the non-pixel stream`; 1080p H.264 VA-API decode, Bilibili playback and
repeated pinch-resizes produce zero `cbfrsynra=0x1940` faults.

### 2. NT36532 touch: firmware lost across every panel power cycle

The touch controller's FW RAM does not survive the panel's disable/unprepare
(DSI reset + regulator drop); even the vendor deep-sleep command (`0x11`) does
not preserve it. The old driver only noticed through the 5 s health poll and
then re-flashed, leaving touch dead for several seconds after every wake.

The panel driver now exports a blocking notifier
(`include/linux/nt36532-panel.h`) called from `nt36532_disable()` (OFF) and
`nt36532_prepare()` (ON). The touch driver puts the chip into deep sleep on OFF
and, on ON, re-downloads `novatek_nt36532_fw.bin` immediately (`~222 ms`)
while the panel is still dark. The health worker is paused while the panel is
off and is the fallback if the re-flash fails.

Result: panel prepare → FW update `~222 ms` → IRQ enabled; the restore commands
(`0xBA`, `0x7F`, `0x79`, `0x7B`) succeed and no `fw health: touch FW dead`
re-flash runs after wake.

## Files

| file | change |
| --- | --- |
| `drivers/media/platform/qcom/iris/iris_core.h` | `struct dma_iova_state *iova_state`, IOVA constants |
| `drivers/media/platform/qcom/iris/iris_probe.c` | `iris_reserve_iova_region()` / `iris_unreserve_iova_region()`, called before `v4l2_device_register()` |
| `drivers/gpu/drm/panel/panel-nt36532-wqhd-dual-dsi-dsc.c` | blocking notifier chain, OFF in `disable`, ON in `prepare` |
| `include/linux/nt36532-panel.h` | new shared event enum + stubs when the panel driver is disabled |
| `drivers/input/touchscreen/NT36XXX_SPI/nt36xxx.c` | notifier client, suspend/resume, fast FW re-flash on panel ON, health-worker gate |

## Rebuilding the modules (workstation, cross)

The deployed modules were built from `work/rtc-fix/build/linux-7.2.6` with the
kernel config already in that tree and the `x-tools` aarch64 compiler. `bc` was
missing on CachyOS; a Python shim implemented only the `timeconst.bc` use. The
resulting vermagic is `7.2.6-tb710fu SMP preempt mod_unload aarch64`.

```sh
export PATH=/tmp/fakebin:/home/asus/x-tools/usr/bin:$PATH   # fakebin/bc = timeconst shim
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules_prepare
make -j8 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- KBUILD_MODPOST_WARN=1 \
     drivers/media/platform/qcom/iris/qcom-iris.ko
make -j8 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- KBUILD_MODPOST_WARN=1 \
     drivers/gpu/drm/panel/panel-nt36532-wqhd-dual-dsi-dsc.ko
make -j8 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- KBUILD_MODPOST_WARN=1 \
     drivers/input/touchscreen/NT36XXX_SPI/nvt_36xxx.ko
```

`KBUILD_MODPOST_WARN=1` is needed because the tree has no `vmlinux`/
`Module.symvers`; the modules therefore carry no `depends:` list. The device
uses `/etc/modprobe.d/tb-r25-modules.conf` (also in this directory) to preload
their dependencies:

```
softdep qcom_iris pre: v4l2-mem2mem videobuf2-v4l2 videodev videobuf2-dma-contig videobuf2-common mdt_loader ubwc_config
softdep panel_nt36532_wqhd_dual_dsi_dsc pre: drm_display_helper
softdep nvt_36xxx pre: panel_nt36532_wqhd_dual_dsi_dsc
```

Run `depmod -a 7.2.6-tb710fu` after installing the `.ko` files (`qcom_iris`
must never be unloaded at runtime; the new module takes effect on reboot).

## Deployed hashes (2026-11-06)

```
c6e4ccb0ecc145f321cb9ef5ee87b9ac1258b2f5c3751de1363518c6c1903fa4  qcom-iris.ko
001d5de27aeb4cdf2011ed8b31f8da972b933e62267aa599df9c9607a2c763bf  panel-nt36532-wqhd-dual-dsi-dsc.ko
d3835de08879b0a5417b58f6a2e2c652cebc000f3c5680e235be2d02380bdbc4  nvt_36xxx.ko
12e4c770160968417f5a82748e0aa5b4ff827d69618f0636345ccbbf844603f1  tb-r25-modules.conf
```

Pre-r25 backups and a rollback script are on the tablet in
`/root/denial-deploy/backup-r25/` (`rollback-r25.sh` restores the three modules,
removes the softdep file and runs depmod; reboot afterwards).

## Caveats

- Panel wake now spends ~0.22 s re-flashing the touch FW inside `prepare`;
  the backlight still only turns on after the first frame, so touch is ready
  when the screen becomes visible.
- `idleSuspendEnabled` remains `false` (s2idle UFS resume risk).
- VLC still uses software decode (`avcodec-hw=none` from r24); the kernel fix
  also covers it, so it can be switched back to `vaapi` if wanted.
