#!/bin/bash
# 部署 MTP（平板插 USB 线后在电脑上弹出存储）。
# 用法: deploy_mtp.sh <tablet-ip> [uMTP-Responder 源码 tar.gz]
#   源码不传时，平板上已有 /usr/local/bin/umtprd 或已解压源码才能装。
set -eu
HOST=${1:?usage: $0 <tablet-ip> [umtp-src.tar.gz]}
UMTP=${2:-}
KEY=${TB_SSH_KEY:-$HOME/.ssh/id_ed25519}
D=$(cd "$(dirname "$0")" && pwd)
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o BatchMode=yes -o ConnectTimeout=10)

ssh "${SSH_OPTS[@]}" root@"$HOST" 'rm -rf /root/mtp-deploy && mkdir -p /root/mtp-deploy'
scp "${SSH_OPTS[@]}" "$D/tb-mtp-gadget.sh" "$D/tb-mtp.service" "$D/umtprd.conf" \
    root@"$HOST":/root/mtp-deploy/
if [ -n "$UMTP" ]; then
    scp "${SSH_OPTS[@]}" "$UMTP" root@"$HOST":/root/mtp-deploy/umtp.tar.gz
fi
bash "$D/../run_on.sh" "$D/install_mtp.sh" 600 "$HOST"
