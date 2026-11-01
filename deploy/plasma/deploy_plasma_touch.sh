#!/bin/bash
set -u
H=${1:?usage: $0 <tablet-ip>}
KEY=${TB_SSH_KEY:-$HOME/.ssh/id_ed25519}
SCP="scp -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10"
W=$(cd "$(dirname "$0")" && pwd)
$SCP "$W/tb-plasma-touch-defaults" "root@$H:/tmp/tb-plasma-touch-defaults" || exit 1
$SCP "$W/tb-plasma-touch-defaults.desktop" "root@$H:/tmp/tb-plasma-touch-defaults.desktop" || exit 1
bash "$W/../run_on.sh" "$W/setup_plasma_touch.sh" 60 "$H"
