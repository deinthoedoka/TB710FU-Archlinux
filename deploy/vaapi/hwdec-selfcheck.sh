#!/bin/bash
# TB710FU hardware-decode self-check: plays 8 s of a video with VA-API and
# reports the decode path plus whether the Iris VPU actually ran.
#
# Usage (on the tablet):  tb-hwdec-check [video-file]
# Without an argument it picks the first mp4/mkv under ~/视频/硬解测试, ~/Videos
# or ~. Keep the video window visible while it runs - a background/occluded
# window gets throttled and the VPU samples will read "suspended" even though
# decode is fine.
VPUBUSY=/sys/bus/platform/devices/aa00000.video-codec/power/runtime_status
V=${1:-$(ls "$HOME"/视频/硬解测试/*.mp4 "$HOME"/Videos/*.mp4 "$HOME"/*.mp4 \
           "$HOME"/视频/硬解测试/*.mkv "$HOME"/Videos/*.mkv 2>/dev/null | head -1)}
[ -n "$V" ] || { echo "no test video found - pass one: tb-hwdec-check /path/file.mp4"; exit 1; }
[ -e "$VPUBUSY" ] || { echo "iris VPU not present ($VPUBUSY missing)"; exit 1; }
T=$(mktemp); S=$(mktemp)

echo "test file: $(basename "$V")  (8 s, window closes itself - keep it visible)"
mpv --end=8 --hwdec=vaapi --osc=no "$V" >"$T" 2>&1 &
P=$!
( while kill -0 "$P" 2>/dev/null; do cat "$VPUBUSY" 2>/dev/null; sleep 0.3; done ) | sort | uniq -c > "$S"
wait "$P" 2>/dev/null

LINE=$(grep -m1 -o "Using .*decoding[^.]*" "$T")
ACT=$(awk '/active/{print $1; exit}' "$S")
echo
echo "---------------- result ----------------"
if grep -q "Using hardware decoding" "$T"; then
    echo "(1) mpv decode path : hardware (${LINE#Using })"
else
    echo "(1) mpv decode path : SOFTWARE! ${LINE:+($LINE)}"
fi
if [ -n "$ACT" ] && [ "$ACT" -gt 0 ] 2>/dev/null; then
    echo "(2) Iris VPU        : ran during playback ($ACT active samples)"
else
    echo "(2) Iris VPU        : no active samples seen"
fi
if grep -q "Using hardware decoding" "$T" && [ -n "$ACT" ] && [ "$ACT" -gt 0 ] 2>/dev/null; then
    echo "overall: OK - hardware decode works"
else
    echo "overall: FAILED - software decode. Send the full output for diagnosis."
fi
rm -f "$T" "$S"
