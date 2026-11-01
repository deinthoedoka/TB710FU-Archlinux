<p align="right"><b>English</b> · <a href="INSTALL.zh-CN.md">简体中文</a></p>

# Installation guide

> Every step in this document writes to the device. **Read it from start to finish
> first**, take an EDL full-partition backup, and only then start.
> Only `boot_a` is written; never touch `boot_b`, ABL/XBL, or any unique-data partition.

> **Don't want to build anything?** Use the prebuilt Release artifacts — see
> [../release/README.md](../release/README.md). All you need is the EDL backup, firmware
> extracted from your own device, and your own `boot_a` for packing; no cross-compile
> environment required.

## 0. Prerequisites

| Item | Requirement |
| --- | --- |
| Device | Lenovo TB710FU (Xiaoxin Pad Pro GT), SM8650 / 256 GB |
| Bootloader | **Unlocked** (`fastboot flash boot_a` works; `fastboot boot` is disabled by the stock ABL) |
| Backup | EDL full-partition read-back (at least `boot_a`, `vbmeta_a`, `super`, and the GPT of `userdata`) |
| Build host | Linux x86_64 or WSL2 Ubuntu, ≥ 30 GB free; on Windows use `wsl_build.sh` |
| Cable | A USB-C cable that carries data; during installation the tablet boots from a USB NIC (NBD) |

> **Red lines**: never write `persist` `modemst1` `modemst2` `fsg` `fsc` `devinfo` `frp`
> `keystore` `ssd` `secdata` `uefivarstore` `cdt` `ddr`. Never flash an old raw userdata
> image back: QTEE enforces anti-rollback, and after a rollback the PIN is permanently
> unusable (`IKMHal_sendCmd status -30`).

## 1. Build

```bash
cd build
./fetch-deps.sh          # pulls tb710fu-hyperos-steamos / armadaos-freedom / DualBootKernelPatcher + linux-7.2.6
```

`wsl_setup.sh` installs the cross-compile toolchain (aarch64 gcc, qemu-user-binfmt,
dtc, avbtool dependencies). Then:

```bash
bash wsl_build.sh all
```

Artifacts land in `out/` at the repository root:

| File | Purpose |
| --- | --- |
| `Image` | Kernel (arm64 raw Image) |
| `sm8650-lenovo-tb710fu-kshim.dtb` | Device tree |
| `modules-7.2.6-tb710fu.tar` | Kernel modules |
| `kShimC.bin` | Boot menu (4 MiB) |
| `MultiBootKernelPatcher` | Dual-kernel boot packer |
| `arch-nbd.img` | Rootfs image for the NBD install (12 GiB sparse) |

### 1.1 Collect firmware

Vendor firmware (ADSP/CDSP, GPU, Wi-Fi, touch, speaker amps, panel) is **not in the
repository** — it must be extracted from your own device's `super.img`:

```bash
sudo apt-get install -y simg2img erofs-utils android-sdk-platform-tools-common
bash build/collect_firmware.sh <your super.img> build/firmware
```

`build/firmware/` is baked into the rootfs by `build_rootfs.sh` and installed to
`/usr/lib/firmware` by `install_payload.sh`.

### 1.2 Build the rootfs

```bash
export ROOT_PASS='your own password'     # required; there is no default
export MODULES_TAR=$PWD/out/modules-7.2.6-tb710fu.tar
export FWDIR=$PWD/build/firmware
export SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"
bash build/build_rootfs.sh
```

`ROOT_PASS` is used for both `root` and the initial user `alarm`. The build script runs
aarch64 pacman through qemu-user on x86, so the first build is slow.

### 1.3 Pack boot_a

You need a **stock `boot_a.img`** (take it from your EDL backup — not from someone
else's device):

```bash
bash build/make-boot.sh /path/to/stock_boot_a.img
```

It packs twice and produces:

- `out/boot/boot_zui.img`: the menu defaults to ZUXOS
- `out/boot/boot_arch.img`: the menu defaults to Arch

Both are 96 MiB with an AVB footer, signed with the AOSP testkey. You can also call
`build/pack_boot.py` manually (options in `build/README.md`).

> With the bootloader unlocked, replacing `vbmeta_a` is not needed; the AVB footer on
> the boot image only exists to pass the ABL's verification. If your device is still
> locked, see the AVB section in `docs/TROUBLESHOOTING.md` first.

## 2. Flash boot_a

```bash
adb reboot bootloader          # or power off, hold volume-down and plug in USB
fastboot devices
fastboot flash boot_a out/boot/boot_arch.img
fastboot reboot
```

`flash/flash.sh` adds a sha256 check and a second confirmation; you can use it instead:

```bash
bash flash/flash.sh out/boot/boot_arch.img
```

At boot an 8-second menu appears: volume keys to choose, power key to confirm, default
ZUXOS (with `boot_arch.img` the default is Arch).

**Rollback**:

```bash
fastboot flash boot_a /path/to/stock_boot_a.img
```

`boot_b`, `vbmeta`, `super` and `userdata` never need to be touched.

## 3. Install to UFS

On the first Arch boot there is no Arch partition yet, so the initramfs takes the NBD
route: the PC feeds `arch-nbd.img` to the tablet over a USB NIC.

### 3.1 Start the NBD server on the PC

```bash
python3 build/nbd_server.py --image out/arch-nbd.img --listen 0.0.0.0 --port 10809
```

Allow port 10809 through the Windows firewall; the tablet gets an address in
`172.16.42.2-.10` over the USB NBD link.

### 3.2 Boot Arch and SSH in

Pick Arch in the menu. The initramfs tries, in order: a GPT partition named
`arch`/`steamos` → NBD → a diagnostic shell. With no `arch` partition on the first run
it falls through to NBD.

```bash
ssh root@172.16.42.2        # use the address the tablet actually got
```

### 3.3 Partition and copy the system

First look at the real partition table:

```bash
sgdisk -p /dev/sda
```

The tail of `userdata` is where Arch goes. `install_ufs.sh` will:

1. shrink `userdata` and create a 128 GiB (default) `arch` partition at its tail;
2. zero the first 64 MiB of `userdata` and `metadata` so ZUXOS reformats them on its
   next boot;
3. create ext4 on the new partition (LABEL `arch-root`) and `rsync` the entire current
   NBD root over.

```bash
CONFIRM=yes ARCH_START=27836416 USERDATA_LAST=61390842 bash /root/install_ufs.sh
```

- These numbers are the defaults for the 256 GB model with a 128 GiB Arch partition;
  the script first checks `userdata`'s end sector and refuses to run on a mismatch.
- **ZUXOS user data will be wiped** (the partition headers are zeroed and Android
  rebuilds them). Back up whatever you need from the Android side first.
- The script saves the GPT to `/root/gpt-sda-before-arch-*.gpt` — **scp it back to the
  PC** before continuing.

When it finishes, reboot: the menu defaults to Arch, and this time it boots from UFS.

## 4. First boot and deployment

The default user is `alarm` (uid 1000); the root password is the build-time `ROOT_PASS`.

```bash
# on the PC, repository root
export TB_HOST=<tablet LAN IP>
bash deploy/deploy_all.sh "$TB_HOST"
```

This installs: system misc (charging display, UFS power, volume keys, fonts), auto
brightness, gamut, flip cover, GPU boost, power profiles, Plasma touch defaults.

Desktop and apps:

```bash
bash apps/install/desktop.sh        # run as root on the tablet
bash apps/install/flatpak.sh        # optional
```

Sensors (auto brightness depends on them):

```bash
scp -r deploy/sensors root@$TB_HOST:/root/
ssh root@$TB_HOST 'bash /root/sensors/install_sensors.sh'   # needs meson/ninja
```

## 5. Day-to-day maintenance

- **Every Arch reboot burns one A/B retry count.** Before rebooting repeatedly, boot
  ZUXOS once so Android marks the current slot successful; otherwise, once the counter
  reaches zero, the ABL only enters fastboot.
  Recovery: `fastboot set_active a` + `fastboot reboot` (changes slot metadata only,
  no partition writes).
- Do **not** run `pacman -Syu` on the tablet: it would try to overwrite the custom
  kernel with the packaged `linux-aarch64`. `/etc/pacman.conf` already sets
  `IgnorePkg = linux-aarch64 linux-latest linux-api-headers`. To add packages use
  `pacman -S --needed --disable-sandbox <pkg>` (this kernel has no Landlock).
- Upgrading the kernel = re-run `wsl_build.sh kernel` + `pack_boot.py` + flash `boot_a`
  (a device write — confirm first). Module-only changes can go straight into
  `/lib/modules/7.2.6-tb710fu/` (replace the `.ko` files + `depmod`), no reflash needed.
