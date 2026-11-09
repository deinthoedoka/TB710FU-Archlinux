#!/bin/sh
# Sample scheduler/thread state around a pinch-to-resize test.
out=${1:-/tmp/pinchmon.log}
deniald=$(pgrep -x deniald | head -1)
settings=$(pgrep -x denial-settings | head -1)
audio=$(pgrep -x pw-play | head -1)
[ -z "$audio" ] && audio=$(pgrep -x mpv | head -1)
: > "$out"
end=$(( $(date +%s) + ${2:-60} ))
tick=0
while [ "$(date +%s)" -lt "$end" ]; do
  now=$(date +%s.%N)
  {
    echo "T $now load=$(cat /proc/loadavg)"
    awk '/^cpu /{print "stat " $2, $3, $4, $5, $6, $7, $8}' /proc/stat
    grep -E '^(MemAvailable|SwapFree|Dirty|Writeback):' /proc/meminfo | tr '\n' ' '; echo
    grep -E '^(pgscan_direct|pgsteal_direct|allocstall|oom_kill)' /proc/vmstat | tr '\n' ' '; echo
    for pid in "$deniald" "$settings" "$audio"; do
      [ -n "$pid" ] || continue
      echo "PID $pid $(cat /proc/$pid/comm 2>/dev/null)"
      for t in /proc/$pid/task/*; do
        [ -r "$t/stat" ] || continue
        tid=${t##*/}
        comm=$(cat "$t/comm" 2>/dev/null)
        st=$(awk '{print $3}' "$t/stat")
        ut=$(awk '{print $14}' "$t/stat")
        kt=$(awk '{print $15}' "$t/stat")
        wc=$(cat "$t/wchan" 2>/dev/null)
        echo "  TH $tid $comm state=$st ut=$ut kt=$kt wchan=$wc"
      done
    done
    if [ $((tick % 5)) -eq 0 ]; then
      for pid in "$deniald" "$settings"; do
        [ -n "$pid" ] || continue
        for t in /proc/$pid/task/*; do
          tid=${t##*/}
          comm=$(cat "$t/comm" 2>/dev/null)
          st=$(awk '{print $3}' "$t/stat")
          if [ "$st" = "D" ] || [ "$st" = "R" ]; then
            echo "STACK $pid/$tid $comm state=$st"
            cat "$t/stack" 2>&1 | sed 's/^/    /'
          fi
        done
      done
    fi
  } >> "$out"
  tick=$((tick + 1))
  sleep 0.2
done
echo "DONE $now" >> "$out"
