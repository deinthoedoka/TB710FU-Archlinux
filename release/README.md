<p align="right"><b>English</b> · <a href="README.zh-CN.md">简体中文</a></p>

# Prebuilt release artifacts (use this page if you don't want to build)

What the Release ships is a half-finished product that is "missing only your own
parts": our kernel, boot menu, packer, modules, and an Arch rootfs **without vendor
firmware**. The stock `boot_a.img` and the firmware must come from your own device —
that is both a licensing requirement and the guarantee that the ZUXOS-side kernel
matches your vendor modules.

This saves you the build, but not the EDL backup (you need that before flashing
anyway).

## Release assets

| File | Purpose |
| --- | --- |
| `Image` | Arch kernel (7.2.6-tb710fu, with all fixes) |
| `sm8650-lenovo-tb710fu-kshim.dtb` | Device tree |
| `kShimC.bin` | Boot menu |
| `MultiBootKernelPatcher` | Dual-kernel boot packer |
| `modules-7.2.6-tb710fu.tar` | Kernel modules (same build as `Image`) |
| `arch-nbd-base.img.zst.part00…` | Rootfs for installing (MBR + ext4, **no vendor firmware**) |
| `SHA256SUMS` | Checksums for every file |

Since v1.1 the Release also carries device-side patches that cannot live in git
(gitignored binaries): `ksystemstats_plugin_gpu-<ver>-tb710fu-msm-aarch64.so`, the
prebuilt System Monitor GPU plugin — install with `deploy/monitor/deploy_prebuilt.sh`.

Since v1.2 it also carries the two VA-API pieces (hardware decode/encode for VLC, OBS
and other libva apps):

| File | Purpose |
| --- | --- |
| `v4l2_drv_video.so` | qcom-va-driver 1.1.1 driver, built and verified on this device (`md5 a83093d4…`, unstripped) — **decode only**, see v1.3 for the encoder fix |
| `qcom-iris-7.2.6-tb710fu-vaapi.ko` | iris module with the five VA-API patches (`modinfo` 7.2.6-tb710fu, `md5 2d96f48d…`); only needed if you did not rebuild the kernel |

Since v1.3 the `v4l2_drv_video.so` asset is rebuilt with
`deploy/vaapi/patches/0001-iris-encoder-handle-missing-v4l2-controls.patch`
(`md5 1928dd2a…`). Use that one: the v1.2 build decodes fine but OBS stops
recording after a few seconds with `vaapi_encode: Error encoding: 输入/输出错误`.
The module and the kernel patches are unchanged.

Install with `deploy/vaapi/deploy_vaapi.sh <tablet-ip> v4l2_drv_video.so
qcom-iris-7.2.6-tb710fu-vaapi.ko` (the module is optional; without it the installed
module must already be a patched one). Note `deploy_all.sh` does **not** include this
step. Upstream radxa's `.deb` is carried for reference only: on Debian it installs
into `/usr/lib/aarch64-linux-gnu/dri`, so on Arch `install.sh` converts it.

Sizes of this build: `Image` 44 MB, dtb 138 KB, `kShimC.bin` 4 MB, packer 828 KB,
modules 92 MB; the rootfs is 10 GiB raw / 3.38 GiB compressed, split into two volumes
(1.9 GB + 1.6 GB). The artifacts are generated into the repository's `out-release/`
(excluded by `.gitignore`, ready for a direct Release upload).

## Steps

### 1. EDL backup

Do the full-partition read-back as in section 0 of `docs/INSTALL.md`; at minimum keep
`boot_a.img` and `super.img`. `fastboot` cannot read partitions on this device — EDL
(9008) is the only way.

### 2. Prepare tools

Linux/WSL needs `python3`, `zstd`, `simg2img`, `erofs-utils`, `losetup`:

```bash
sudo apt-get install -y zstd simg2img erofs-utils python3
```

### 3. Download and verify

Put the Release assets into one directory:

```bash
sha256sum -c SHA256SUMS
```

### 4. Extract your own firmware

```bash
bash build/collect_firmware.sh /path/to/super.img firmware/
```

### 5. Restore and inject the rootfs

```bash
cat arch-nbd-base.img.zst.part* | zstd -d > arch-nbd.img
sudo release/inject-firmware.sh arch-nbd.img firmware/
```

The injection script checks that every firmware file the DTB asks for is present; if
one is missing it errors out — you never get a "boots but black screen" image.

### 6. Pack with your own boot_a

```bash
export TESTKEY=$PWD/build/tools/testkey_rsa4096.pem
export PACKER=$PWD/out-release/MultiBootKernelPatcher
python3 -I build/pack_boot.py \
  --boot /path/to/your_boot_a.img \
  --shim out-release/kShimC.bin \
  --linux out-release/Image \
  --dtb out-release/sm8650-lenovo-tb710fu-kshim.dtb \
  --out boot --default zui
```

That gives `boot/boot_zui.img` (defaults to ZUXOS) and `boot/boot_arch.img` (defaults
to Arch).

### 7. Flash and install

```bash
bash flash/flash.sh boot/boot_arch.img
```

Then follow section 3 of the [install guide](../docs/INSTALL.md): on the PC run

```bash
python3 build/nbd_server.py --image arch-nbd.img --listen 0.0.0.0 --port 10809
```

Boot Arch from the tablet's menu; once it has `172.16.42.x` (the image ships no SSH
public keys — log in as `alarm`):

```bash
scp build/install_ufs.sh alarm@172.16.42.<x>:/tmp/
ssh alarm@172.16.42.<x>          # password alarm
sudo CONFIRM=yes ARCH_START=... USERDATA_LAST=... bash /tmp/install_ufs.sh
```

Fill in `ARCH_START` / `USERDATA_LAST` from the actual `sgdisk -p /dev/sda` output,
and back up the GPT first.

### 8. First login

The account in the rootfs is `alarm`, initial password `alarm` (`root` has the same
password). **The first thing to do is change the passwords**:

```bash
passwd
sudo passwd root
```

Then install your SSH public key for root, so the PC-side deploy can connect:

```bash
sudo mkdir -p /root/.ssh && sudo tee -a /root/.ssh/authorized_keys < ~/.ssh/id_ed25519.pub
sudo chmod 700 /root/.ssh && sudo chmod 600 /root/.ssh/authorized_keys
```

After that run `deploy/deploy_all.sh <tablet-ip>` on the PC.

## Why there is no ready-to-flash boot image

`boot_a` contains, besides Arch, **your own device's ZUXOS kernel**. With someone
else's ZUXOS version, the kernel and vendor modules may not match, and the Android
side of the menu black-screens. Packing from each user's own `boot_a` avoids this
entirely, and keeps Lenovo's GKI kernel out of distribution.

## Building it yourself

See `build/README.md`; `release/make-image.sh` is the script that generates this
firmware-less rootfs.
