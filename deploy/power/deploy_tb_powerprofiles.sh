#!/bin/bash
# 部署电源管理方案服务（PPD 兼容）：三档真实作用于 CPU/GPU 频率。
set -eu
HOST=${1:?usage: $0 <tablet-ip>}
KEY=${TB_SSH_KEY:-$HOME/.ssh/id_ed25519}
D=$(cd "$(dirname "$0")" && pwd)
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o BatchMode=yes -o ConnectTimeout=10)

ssh "${SSH_OPTS[@]}" root@"$HOST" 'rm -rf /root/tb-powerprofiles-deploy && mkdir -p /root/tb-powerprofiles-deploy'
scp "${SSH_OPTS[@]}" "$D/tb-powerprofiles" "$D/tb-powerprofiles.service" \
    root@"$HOST":/root/tb-powerprofiles-deploy/
bash "$D/../run_on.sh" "$D/install_tb_powerprofiles.sh" 300 "$HOST"
