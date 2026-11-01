#!/bin/bash
# Deploy every device-side fix to a running TB710FU Arch install, over SSH.
#
#   ./deploy_all.sh <tablet-ip>          # uses $HOME/.ssh/id_ed25519, or TB_SSH_KEY
#
# Run from the PC, not on the tablet. Each step is idempotent; a failure stops the run.
set -euo pipefail
H=${1:?usage: $0 <tablet-ip>}
D=$(cd "$(dirname "$0")" && pwd)
KEY=${TB_SSH_KEY:-$HOME/.ssh/id_ed25519}
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o BatchMode=yes -o ConnectTimeout=10)

echo "== system extras (modprobe, udev, UFS PM, volume keys, fonts)"
ssh "${SSH_OPTS[@]}" root@"$H" 'rm -rf /root/tb-system && mkdir -p /root/tb-system'
scp "${SSH_OPTS[@]}" -r "$D/system/." root@"$H":/root/tb-system/
ssh "${SSH_OPTS[@]}" root@"$H" 'bash /root/tb-system/install_system_extras.sh'

echo "== automatic brightness"
bash "$D/als/deploy_tb_als_v4.sh" "$H"
echo "== colour profile switching"
bash "$D/gamut/deploy_tb_gamut.sh" "$H"
echo "== flip cover (hall sensor)"
bash "$D/cover/deploy_cover2.sh" "$H"
echo "== GPU touch boost"
bash "$D/gpu/deploy_gpu_boost.sh" "$H"
echo "== power profiles"
bash "$D/power/deploy_tb_powerprofiles.sh" "$H"
echo "== Plasma touch defaults"
bash "$D/plasma/deploy_plasma_touch.sh" "$H"

echo
echo "done. Sensors are separate: deploy/sensors/install_sensors.sh (needs meson on the tablet)."
echo "MTP needs the uMTP-Responder tarball: deploy/mtp/deploy_mtp.sh (see its README)."
echo "GPU monitoring is separate: deploy/monitor/deploy_monitor.sh (builds on the tablet)."
echo "Log out and back in (or reboot) so plasmalogin and the session pick everything up."
