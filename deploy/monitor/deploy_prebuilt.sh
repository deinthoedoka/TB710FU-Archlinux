#!/bin/bash
# 部署预编译 GPU 监控插件（Release 资产，跳过平板端编译）。
# 用法: deploy_prebuilt.sh <tablet-ip> <ksystemstats_plugin_gpu-<ver>-tb710fu-msm-aarch64.so>
set -eu
HOST=${1:?usage: $0 <tablet-ip> <plugin.so>}
SO=${2:?usage: $0 <tablet-ip> <plugin.so>}
KEY=${TB_SSH_KEY:-$HOME/.ssh/id_ed25519}
D=$(cd "$(dirname "$0")" && pwd)
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o BatchMode=yes -o ConnectTimeout=10)

ssh "${SSH_OPTS[@]}" root@"$HOST" 'mkdir -p /root/ksysmsm && rm -f /root/ksysmsm/ksystemstats_plugin_gpu*.so'
scp "${SSH_OPTS[@]}" "$SO" root@"$HOST":/root/ksysmsm/
scp "${SSH_OPTS[@]}" "$D/install_prebuilt.sh" root@"$HOST":/root/ksysmsm/
bash "$D/../run_on.sh" "$D/install_prebuilt.sh" 120 "$HOST"
