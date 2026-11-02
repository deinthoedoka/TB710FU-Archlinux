# VA-API hardware video decode/encode (Iris VPU)

The Iris VPU is a **stateful** decoder: it speaks V4L2 M2M, which is what mpv's
`hwdec=v4l2m2m-copy` and Firefox's built-in v4l2 path use. Applications that only
speak **VA-API** — VLC, OBS's hardware encoders, anything libva-based — need a
VA-API backend on top of the same V4L2 device. That backend is
[radxa's qcom-va-driver](https://github.com/radxa-pkg/qcom-va-driver).

Verified on SM8650 / 7.2.6-tb710fu: `vainfo` lists H264 (all entry points), HEVC
Main + Main10, VP9 profile 0/2 and AV1 **decode**, plus H264/HEVC **encode**. A
4K60 HEVC 56 Mbps file decodes at ~227 fps (3.8x realtime). mpv runs zero-copy
(`hwdec=vaapi`), Firefox and native VLC hardware-decode, and OBS records with
hardware H.264 / HEVC (AV1 encode is not implemented by the firmware — expected;
the encoder needs the driver patches below).

## Hardware encoding needs patched driver sources

Upstream radxa v1.1.1 sets two V4L2 controls that the iris encoder does not
implement — `V4L2_CID_MPEG_VIDEO_FRAME_RC_ENABLE` and
`V4L2_CID_MPEG_VIDEO_FORCE_KEY_FRAME`. The first `VIDIOC_S_CTRL` returns EINVAL
and aborts the whole encode, which in OBS shows up as
`vaapi_encode: Error encoding: Input/output error` a few seconds into recording.

`patches/0001-iris-encoder-handle-missing-v4l2-controls.patch` queries both
controls before using them and, because iris cannot be asked to force an IDR,
asks the firmware for periodic keyframes through `GOP_SIZE` using the stream's
intra period. `build_driver.sh` applies it automatically. Verified: 30 s 720p
and 8 s 3200×2000 H.264 CBR encodes complete with no errors and produce valid
keyframe intervals.

The prebuilt `v4l2_drv_video.so` from Release v1.2 is the **unpatched** upstream
build, and so is radxa's `.deb`: encoding with either of them fails. Use the
release asset from v1.3 or build on the tablet.

## Two pieces are needed

1. **Userspace driver** — `v4l2_drv_video.so` in `/usr/lib/dri`, plus the
   `msm_drv_video.so` alias that makes libva pick it.
2. **Kernel side** — the iris driver must expose decode-order output, otherwise
   every VA-API decode stalls after the first frame with *"Failed to end picture
   decode"*. Kernels built by `build/build_kernel.sh` carry the patches
   (`build/patches/000[2-6]-media-iris-*.patch`); a prebuilt module for
   7.2.6-tb710fu is attached to Release v1.2.

## Install

From the PC, against a running tablet (files from Release v1.2):

```bash
./deploy_vaapi.sh <tablet-ip> v4l2_drv_video.so qcom-iris-7.2.6-tb710fu-vaapi.ko
```

Or on the tablet:

```bash
bash install.sh --driver v4l2_drv_video.so --ko qcom-iris.ko
```

GitHub is unreachable from many CN networks, so the tablet's automatic download
fallback usually fails — pass the files (the PC path above copies them over) or run
`build_driver.sh` where the source tarball is already available.

`--driver` also accepts radxa's `.deb`. Note its payload lands in
`/usr/lib/aarch64-linux-gnu/dri/` (Debian multiarch) — Arch's libva only looks in
`/usr/lib/dri`, so the script unpacks and installs it there. Omit `--ko` to keep
the installed module (it must already be a patched one).

What gets configured:

| app | config |
| --- | --- |
| mpv | `/etc/mpv/mpv.conf`: `hwdec=vaapi`, `vo=gpu` (zero copy) |
| Firefox | `/usr/lib/firefox/defaults/pref/tb710fu-vaapi.js`: `media.ffmpeg.vaapi.enabled`, `media.hardware-video-decoding.force-enabled` |
| VLC | `vlcrc`: `avcodec-hw=vaapi`; needs the `vlc-plugin-*` split packages (bare `vlc` has no avcodec/vaapi module) |

Flatpak apps can **never** use this driver: the sandbox has its own
`/usr/lib/dri` and does not see the host's. Use native packages.

## Verify

```bash
vainfo --display drm --device /dev/dri/renderD128   # decode/encode entry points
tb-hwdec-check                                       # plays 8 s, samples the VPU
```

`tb-hwdec-check` needs the video window visible: a background or occluded player
gets throttled, and then the VPU samples read `suspended` even though decode is
fine.

## Rebuilding the driver from source

On the tablet (native aarch64 — the CDSP subprojects make cross builds painful):

```bash
bash build_driver.sh                # downloads the tag tarball, applies patches/, meson + ninja
bash install.sh --driver /root/v4l2_drv_video.so
```

The build disables `cdsp_vpp` (needs the Qualcomm Hexagon toolchain / GHC
Haskell) and `vulkan_vpp`; neither is required for decode/encode.

## Kernel patches

Applied by `build/build_kernel.sh` in this order (the decode-order port must come
before the upstream four):

- `0002-media-iris-support-decode-order-output-on-HFI-gen2-tb710fu.patch` —
  TB710FU port of qcom-va-driver's 0001; the upstream patch does not apply to
  this base (no `REQUEST_SYNC_FRAME` context). Exposes
  `V4L2_CID_MPEG_VIDEO_DEC_DISPLAY_DELAY(_ENABLE)` as the `DISPLAY_DELAY` caps
  and wires `HFI_PROP_DECODE_ORDER_OUTPUT` (0x0300015b) to the firmware.
- `0003`…`0006` — upstream: larger capture buffer pools, deblocking filter
  controls, error timestamps, non-display buffer recycling.

To regenerate after a kernel rebase, run `port_decode_order.py` on a pristine
tree and diff — every edit is anchored and asserted unique. The whole chain
(pristine 7.2.6 + freedom series + board patch + local patch + these five) was
verified file-by-file against the reference build tree.

## Rollback

```bash
cp /root/qcom-iris.ko.bak-pre-va /usr/lib/modules/7.2.6-tb710fu/kernel/drivers/media/platform/qcom/iris/qcom-iris.ko
depmod 7.2.6-tb710fu          # then reboot: the module is never unloaded at runtime
rm /usr/lib/dri/v4l2_drv_video.so /usr/lib/dri/msm_drv_video.so
rm /usr/lib/firefox/defaults/pref/tb710fu-vaapi.js
# the modprobe.d rule can stay: it only guards against unloading qcom_iris
# mpv: hwdec=v4l2m2m-copy still works without the driver
```

## Module swaps are install-and-reboot

`qcom_iris` is **never unloaded at runtime**. An interrupted `modprobe -r` — an SSH
timeout, a killed process, a busy VPU — leaves `delete_module` waiting forever: the
module sits in state `Unloading` with `refcnt = -1` (`/proc/modules`), `iris_remove`
never returns, and the unkillable task then blocks **shutdown**. The tablet stops at
a black screen with white text and only a long power-button press recovers it. The
VPU also stays dead until reboot (`vainfo`: "no Iris stateful H264 decoder found").

`/etc/modprobe.d/qcom-iris-noremove.conf` makes that impossible:
`remove qcom_iris /bin/false` fails the command in userspace, before the kernel is
touched. `install.sh` writes it before it touches the module. A module update is
therefore: install the `.ko`, reboot. (A deliberate bypass would be
`modprobe -r -i qcom_iris` — that is exactly the hazard, don't.)

## Maintenance

- A `pacman -Su firefox` update deletes `tb710fu-vaapi.js` — re-run `install.sh`.
- After any VLC reinstall, `vlc-plugin-ffmpeg` must be present again.
- Upstream driver v1.1.1 at the time of writing; `build_driver.sh` takes `VER=`
  to build a newer tag.
