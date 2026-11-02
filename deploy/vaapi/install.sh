#!/bin/bash
# install.sh - VA-API hardware decode/encode on a running TB710FU Arch install.
#
# Installs the qcom-va-driver (VA-API backend for the Iris VPU), optionally
# installs a VA-API-ready qcom-iris.ko for the next boot, and configures
# mpv / Firefox / VLC.
# The iris kernel patches live in build/patches/000[2-6]-media-iris-*.patch and
# are baked into kernels built by build/build_kernel.sh; a prebuilt module is
# attached to the GitHub release.
#
# Usage (as root, ON the tablet):
#   bash install.sh [--driver <v4l2_drv_video.so | qcom-va-driver_*.deb>] [--ko <qcom-iris.ko>]
#
# --driver accepts either the compiled .so or radxa's Debian package (its payload
# is installed under /usr/lib/aarch64-linux-gnu on Debian; this script puts it
# where libva looks on Arch). Without --driver it uses a local copy in /root if
# present, else downloads the Release asset.
# --ko without a value is not possible: omit it to keep the installed module,
# which must already contain the iris VA-API patches or decode fails after one
# frame with "Failed to end picture decode". A supplied module is installed and
# loads on the NEXT BOOT - qcom_iris is never unloaded at runtime, because an
# interrupted unload wedges it and then blocks shutdown (see the modprobe.d
# rule this script installs).
set -euo pipefail

DRIVER="" KO="" NEEDS_REBOOT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --driver|--deb) DRIVER=$2; shift 2 ;;
    --ko) KO=$2; shift 2 ;;
    *) echo "usage: $0 [--driver <.so|.deb>] [--ko <qcom-iris.ko>]"; exit 2 ;;
  esac
done

say() { printf '\n== %s\n' "$*"; }
die() { echo "!! $*"; exit 1; }

KVER=$(uname -r)
IRISDEV=/sys/bus/platform/devices/aa00000.video-codec
REL=https://github.com/deinthoedoka/TB710FU-Archlinux/releases/download/v1.2

say "preflight"
[ "$KVER" = "7.2.6-tb710fu" ] || echo "   note: built for 7.2.6-tb710fu, running $KVER"
[ -e /dev/dri/renderD128 ] || die "no render node (/dev/dri/renderD128)"
[ -d "$IRISDEV" ] || die "iris VPU not enabled in this kernel's DT (aa00000.video-codec missing)"
[ -f /lib/firmware/qcom/vpu/vpu33_p4.mbn ] || \
  echo "   note: /lib/firmware/qcom/vpu/vpu33_p4.mbn not found - iris won't probe without it"

say "libva"
pacman -Qq libva >/dev/null 2>&1 || pacman -S --needed --noconfirm libva || \
  echo "   note: could not install libva (offline?) - VA-API clients will need it"

say "qcom-va-driver (userspace VA-API)"
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

driver_from_deb() { # .deb -> path of the compiled driver .so
  # A .deb is an ar archive holding data.tar.{xz,zst,gz}; bsdtar (pacman's own
  # backend) reads it, so no dpkg is needed.
  bsdtar -xf "$1" -C "$TMPD" || die "cannot unpack $1"
  local d
  d=$(ls "$TMPD"/data.tar.* 2>/dev/null | head -1)
  [ -n "$d" ] || die "no data.tar.* inside $1"
  mkdir -p "$TMPD/root"; bsdtar -xf "$d" -C "$TMPD/root" || die "cannot extract $1 payload"
  local so
  so=$(find "$TMPD/root" -name v4l2_drv_video.so -type f | head -1)
  [ -n "$so" ] || die "$1 does not contain v4l2_drv_video.so"
  # the package also ships GStreamer ranking; keep it if present
  local env
  env=$(find "$TMPD/root" -name '60-libva-v4l2.conf' -type f | head -1)
  [ -n "$env" ] && install -D -m0644 "$env" /usr/lib/environment.d/60-libva-v4l2.conf
  echo "$so"
}

if [ -z "$DRIVER" ]; then
  for c in /root/v4l2_drv_video.so /root/qcom-va-driver_*_arm64.deb; do
    [ -e "$c" ] && { DRIVER=$c; break; }
  done
fi
if [ -z "$DRIVER" ]; then
  echo "   downloading $REL/v4l2_drv_video.so"
  DRIVER=/root/v4l2_drv_video.so
  # -T/-t so a blocked GitHub stalls for 40 s at most instead of hanging forever
  wget -q -T 20 -t 2 -O "$DRIVER" "$REL/v4l2_drv_video.so" \
    || { rm -f "$DRIVER"; die "download failed. GitHub is often unreachable from CN
   networks: fetch the asset on a PC and pass it as --driver (or run
   deploy/vaapi/deploy_vaapi.sh from the PC, which copies it over). build_driver.sh
   also works if you can get the source tarball onto the tablet."; }
fi
[ -f "$DRIVER" ] || die "driver not found: $DRIVER"

case "$DRIVER" in
  *.deb) SO=$(driver_from_deb "$DRIVER") ;;
  *)     SO=$DRIVER ;;
esac
install -D -m0755 "$SO" /usr/lib/dri/v4l2_drv_video.so
# libva learns the vendor from the driver name; the Debian postinst would create
# this alias and it is what makes the driver auto-select on this device.
ln -sfn v4l2_drv_video.so /usr/lib/dri/msm_drv_video.so
echo "   /usr/lib/dri/v4l2_drv_video.so <- $(basename "$DRIVER") ($(md5sum < /usr/lib/dri/v4l2_drv_video.so | cut -d' ' -f1))"

say "kernel module"
# qcom_iris must never be unloaded at runtime. If a `modprobe -r` is interrupted
# (SSH timeout, killed process, busy VPU) the kernel leaves the module in state
# "Unloading" with refcnt -1 (/proc/modules); delete_module then never returns,
# the unkillable task blocks the next shutdown at a black screen with white text,
# and only a power cycle clears it. This rule makes `modprobe -r qcom_iris` fail
# in userspace, before it reaches the kernel. Installed before the .ko so no
# later step can ever trigger the wedge.
GUARD=$(dirname "$0")/qcom-iris-noremove.conf
if [ -f "$GUARD" ]; then
  install -D -m0644 "$GUARD" /etc/modprobe.d/qcom-iris-noremove.conf
else
  mkdir -p /etc/modprobe.d
  { echo '# TB710FU: never unload qcom_iris - an interrupted unload wedges it in'
    echo '# "Unloading"/refcnt -1 and then blocks shutdown. Bypass (don'\''t): -i'
    echo 'remove qcom_iris /bin/false'
  } > /etc/modprobe.d/qcom-iris-noremove.conf
fi
echo "   /etc/modprobe.d/qcom-iris-noremove.conf in place (no runtime unload)"

if [ -n "$KO" ]; then
  MODDIR=/usr/lib/modules/$KVER/kernel/drivers/media/platform/qcom/iris
  [ -f "$MODDIR/qcom-iris.ko" ] || die "no qcom-iris.ko for $KVER - install the kernel modules first"
  [ -f "$KO" ] || die "module not found: $KO"
  NEWMD5=$(md5sum < "$KO" | cut -d' ' -f1)
  CURMD5=$(md5sum < "$MODDIR/qcom-iris.ko" | cut -d' ' -f1)
  if [ "$NEWMD5" = "$CURMD5" ]; then
    echo "   installed module is already this build ($NEWMD5) - nothing to do"
  else
    [ -f /root/qcom-iris.ko.bak-pre-va ] || cp "$MODDIR/qcom-iris.ko" /root/qcom-iris.ko.bak-pre-va
    install -D -m0644 "$KO" "$MODDIR/qcom-iris.ko"
    depmod "$KVER"
    echo "   installed $NEWMD5 (backup: /root/qcom-iris.ko.bak-pre-va)"
    if grep -q '^qcom_iris .* Unloading' /proc/modules; then
      die "qcom_iris is stuck in Unloading (/proc/modules) - reboot: the new module loads then"
    fi
    echo "   loads on the next boot (qcom_iris is never unloaded at runtime)"
    NEEDS_REBOOT=1
  fi
fi
if [ -e /dev/video0 ]; then echo "   /dev/video0 present"; else echo "   !! /dev/video0 missing (module not loaded?)"; fi

say "mpv"
if command -v mpv >/dev/null; then
  f=/etc/mpv/mpv.conf
  touch "$f"
  for kv in "hwdec=vaapi" "vo=gpu"; do
    k=${kv%%=*}
    if grep -qs "^\s*#*$k=" "$f"; then sed -i "s|^\s*#*$k=.*|$kv|" "$f"; else echo "$kv" >> "$f"; fi
  done
  echo "   $f: $(grep -E '^(hwdec|vo)=' "$f" | tr '\n' ' ')"
fi

say "firefox"
if [ -d /usr/lib/firefox ]; then
  cat > /usr/lib/firefox/defaults/pref/tb710fu-vaapi.js <<'EOF'
// TB710FU: enable VA-API hardware video decoding (qcom-va-driver).
// Re-created by deploy/vaapi/install.sh; a pacman firefox update removes it.
pref("media.ffmpeg.vaapi.enabled", true);
pref("media.hardware-video-decoding.force-enabled", true);
EOF
  echo "   /usr/lib/firefox/defaults/pref/tb710fu-vaapi.js written (restart firefox)"
fi

say "vlc (native packages only; flatpak can never see the host driver)"
if pacman -Qq vlc >/dev/null 2>&1; then
  if ! pacman -Qq vlc-plugin-ffmpeg >/dev/null 2>&1; then
    # ALARM splits VLC into subpackages; without -ffmpeg there is no vaapi module.
    mapfile -t VP < <(pacman -Ssq '^vlc-plugin-' 2>/dev/null || true)
    if [ ${#VP[@]} -gt 0 ]; then
      pacman -S --needed --noconfirm vlc "${VP[@]}" || \
        echo "   note: could not install vlc-plugin-* (offline?) - VLC stays software-only"
    fi
  fi
  setvlcrc() {
    # VLC reads avcodec-hw from the [avcodec] module section, not [core]: the
    # option belongs to the FFmpeg decoder module.
    f=$1; mkdir -p "$(dirname "$f")"; [ -f "$f" ] || { printf '[qt]\nqt-privacy-ask=0\n[avcodec]\navcodec-hw=vaapi\n' > "$f"; return; }
    grep -q '^avcodec-hw=vaapi' "$f" && return 0
    if grep -q '^#*avcodec-hw=' "$f"; then
      # the shipped default has a commented "#avcodec-hw=any" in [avcodec]
      sed -i 's/^#*avcodec-hw=.*/avcodec-hw=vaapi/' "$f"
    elif grep -q '^\[avcodec\]' "$f"; then
      sed -i '/^\[avcodec\]/a avcodec-hw=vaapi' "$f"
    else
      printf '\n[avcodec]\navcodec-hw=vaapi\n' >> "$f"
    fi
  }
  setvlcrc /etc/vlc/vlcrc || true
  if [ -d /home/alarm/.config ]; then setvlcrc /home/alarm/.config/vlc/vlcrc; chown -R alarm:alarm /home/alarm/.config/vlc; fi
  echo "   vlcrc: avcodec-hw=vaapi"
fi

say "self-check"
install -m0755 "$(dirname "$0")/hwdec-selfcheck.sh" /usr/local/bin/tb-hwdec-check 2>/dev/null \
  && echo "   installed /usr/local/bin/tb-hwdec-check" \
  || echo "   hwdec-selfcheck.sh not next to install.sh - skipped"

say "verify"
if command -v vainfo >/dev/null; then
  vainfo --display drm --device /dev/dri/renderD128 2>&1 | grep -E "Driver version|VAEntrypoint" | head -10
else
  echo "   install libva-utils for vainfo"
fi
echo
if [ "$NEEDS_REBOOT" = 1 ]; then
  echo "NOTE: reboot to load the installed qcom-iris.ko (module updates are install-and-reboot)."
fi
echo "done. Play something and run: tb-hwdec-check   (keep the video window visible!)"
