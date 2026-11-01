#!/bin/bash
# Run a remote command file on the tablet over ssh.
# usage: run_on.sh <local-cmds-file> [timeout] [host]
# pass the tablet IP as the 3rd argument, or export TB_HOST.
set -eu
CMDS=${1:?usage: run_on.sh <cmds-file> [timeout] [host]}
T=${2:-120}
H=${3:-${TB_HOST:-}}
[ -n "$H" ] || { echo "usage: run_on.sh <cmds-file> [timeout] <tablet-ip> (or set TB_HOST)"; exit 2; }
ssh -i "${TB_SSH_KEY:-$HOME/.ssh/id_ed25519}" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 -o BatchMode=yes \
    -o ServerAliveInterval=15 \
    root@$H "timeout $T bash -s" < "$CMDS"
