#!/bin/bash
# 部署色域切换：ICC + CLI + 应用菜单项。
set -eu
HOST=${1:?usage: $0 <tablet-ip>}
KEY=${TB_SSH_KEY:-$HOME/.ssh/id_ed25519}
D=$(cd "$(dirname "$0")" && pwd)
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o BatchMode=yes -o ConnectTimeout=10)

ssh "${SSH_OPTS[@]}" root@"$HOST" 'rm -rf /root/tb-gamut-deploy && mkdir -p /root/tb-gamut-deploy'
scp "${SSH_OPTS[@]}" "$D/tb-gamut" "$D/tb-gamut-toggle.desktop" "$D/make_p3_icc.py" \
    root@"$HOST":/root/tb-gamut-deploy/
bash "$D/../run_on.sh" "$D/install_tb_gamut.sh" 180 "$HOST"
