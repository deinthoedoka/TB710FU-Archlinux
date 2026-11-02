#!/bin/bash
# Deploy VA-API hardware decode to a running TB710FU Arch install, over SSH.
#
#   ./deploy_vaapi.sh <tablet-ip> [driver.so|qcom-va-driver.deb] [qcom-iris.ko]
#
# Both payloads are optional and attached to Release v1.2:
#   v4l2_drv_video.so                  - the VA-API driver (verified build)
#   qcom-iris-7.2.6-tb710fu-vaapi.ko   - iris module with the VA-API patches
# Without the driver the tablet downloads it; without the module it keeps the
# installed one (which must already contain the iris patches).
set -euo pipefail
H=${1:?usage: $0 <tablet-ip> [driver.so|driver.deb] [qcom-iris.ko]}
shift || true
D=$(cd "$(dirname "$0")" && pwd)
KEY=${TB_SSH_KEY:-$HOME/.ssh/id_ed25519}
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o BatchMode=yes -o ConnectTimeout=10)

ssh "${SSH_OPTS[@]}" root@"$H" 'rm -rf /root/tb-vaapi && mkdir -p /root/tb-vaapi'
scp "${SSH_OPTS[@]}" "$D/install.sh" "$D/hwdec-selfcheck.sh" "$D/build_driver.sh" root@"$H":/root/tb-vaapi/

ARGS=""
if [ -n "${1:-}" ] && [ -f "${1:-}" ]; then
  scp "${SSH_OPTS[@]}" "$1" root@"$H":/root/tb-vaapi/"$(basename "$1")"
  ARGS="$ARGS --driver /root/tb-vaapi/$(basename "$1")"
  shift || true
fi
if [ -n "${1:-}" ] && [ -f "${1:-}" ]; then
  scp "${SSH_OPTS[@]}" "$1" root@"$H":/root/tb-vaapi/qcom-iris.ko
  ARGS="$ARGS --ko /root/tb-vaapi/qcom-iris.ko"
fi

ssh "${SSH_OPTS[@]}" root@"$H" "bash /root/tb-vaapi/install.sh$ARGS"
