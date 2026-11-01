#!/bin/bash
# 部署亮度学习版：手动调亮度会写回曲线，登录界面复用同一份学习结果。
set -eu
HOST=${1:?usage: $0 <tablet-ip>}
KEY=${TB_SSH_KEY:-$HOME/.ssh/id_ed25519}
D=$(cd "$(dirname "$0")" && pwd)
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o BatchMode=yes -o ConnectTimeout=10)

ssh "${SSH_OPTS[@]}" root@"$HOST" 'rm -rf /root/tb-als-deploy && mkdir -p /root/tb-als-deploy'
scp "${SSH_OPTS[@]}" "$D/tb-als-daemon.py" "$D/tb-als" "$D/tb-als.service" \
    "$D/tb-als-greeter.service" "$D/tb-als-toggle.desktop" \
    root@"$HOST":/root/tb-als-deploy/
bash "$D/../run_on.sh" "$D/install_tb_als_v4.sh" 240 "$HOST"
