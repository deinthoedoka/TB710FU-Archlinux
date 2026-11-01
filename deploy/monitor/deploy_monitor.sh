#!/bin/bash
# 部署 GPU 监控补丁并在平板上编译安装（ksystemstats 的 msm/Adreno 后端）。
# 用法: deploy_monitor.sh <tablet-ip> [ksystemstats 源码 tar.xz]
# 平板需要 cmake / ninja / extra-cmake-modules（pacman -S cmake ninja extra-cmake-modules）。
set -eu
HOST=${1:?usage: $0 <tablet-ip> [ksystemstats-src.tar.xz]}
TARBALL=${2:-}
KEY=${TB_SSH_KEY:-$HOME/.ssh/id_ed25519}
D=$(cd "$(dirname "$0")" && pwd)
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o BatchMode=yes -o ConnectTimeout=10)

ssh "${SSH_OPTS[@]}" root@"$HOST" 'rm -rf /root/ksysmsm/patch && mkdir -p /root/ksysmsm/patch'
scp "${SSH_OPTS[@]}" "$D"/ksystemstats/{LinuxBackend.cpp,LinuxMsmGpu.h,LinuxMsmGpu.cpp,CMakeLists.txt} \
    root@"$HOST":/root/ksysmsm/patch/
scp "${SSH_OPTS[@]}" "$D/build_plugin.sh" root@"$HOST":/root/ksysmsm/
if [ -n "$TARBALL" ]; then
    scp "${SSH_OPTS[@]}" "$TARBALL" root@"$HOST":/root/ksysmsm/src.tar.xz
fi
bash "$D/../run_on.sh" "$D/build_plugin.sh" 900 "$HOST"
