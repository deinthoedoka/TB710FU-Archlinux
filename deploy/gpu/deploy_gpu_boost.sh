#!/bin/bash
set -u
H=${1:?usage: $0 <tablet-ip>}
KEY=${TB_SSH_KEY:-$HOME/.ssh/id_ed25519}
SCP="scp -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10"
W=$(cd "$(dirname "$0")" && pwd)
$SCP "$W/tb-gpu-boost" "root@$H:/tmp/tb-gpu-boost" || { echo "scp 守护进程失败"; exit 1; }
$SCP "$W/tb-gpu-boost.service" "root@$H:/tmp/tb-gpu-boost.service" || { echo "scp service 失败"; exit 1; }
bash "$W/../run_on.sh" "$W/install_gpu_boost.sh" 60 "$H"
