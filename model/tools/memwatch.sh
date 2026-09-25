#!/usr/bin/env bash
# Log system memory every INTERVAL seconds to LOGFILE: available GB, the
# largest process, and any kernel OOM-killer lines since the last sample.
#   model/tools/memwatch.sh <logfile> [interval_seconds]
log="${1:?logfile}"; interval="${2:-30}"
last_oom=$(dmesg 2>/dev/null | grep -c -i "out of memory\|oom-kill" || true)
while true; do
  avail=$(awk '/MemAvailable/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)
  swap=$(awk '/SwapFree/ {sf=$2} /SwapTotal/ {st=$2} END {printf "%.1f", (st-sf)/1024/1024}' /proc/meminfo)
  top=$(ps -eo rss,comm --sort=-rss | awk 'NR==2 {printf "%s %.1fGB", $2, $1/1024/1024}')
  oom=$(dmesg 2>/dev/null | grep -c -i "out of memory\|oom-kill" || true)
  flag=""; if [ "${oom:-0}" -gt "${last_oom:-0}" ]; then flag="  OOM-KILL EVENT"; last_oom=$oom; fi
  echo "$(date '+%F %T')  available ${avail} GB  swap used ${swap} GB  top: ${top}${flag}" >> "$log"
  sleep "$interval"
done
