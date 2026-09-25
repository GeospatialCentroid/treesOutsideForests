#!/usr/bin/env bash
# Run a command under a hard memory ceiling so it can never starve the other
# service on this machine: a transient user cgroup with MemoryMax from
# config.yml (model.cgroup_max_gb), plus a memory log beside the command's
# output. If the command exceeds the ceiling, the kernel kills it alone.
#   model/tools/run_guarded.sh <command...>
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
root="$(cd "$here/.." && pwd)"
gb=$(python3 -c "import yaml; print(yaml.safe_load(open('$root/config.yml'))['model']['cgroup_max_gb'])")
mkdir -p "$root/data/model"
memlog="$root/data/model/memwatch_$(date +%Y%m%d_%H%M%S).log"
"$here/tools/memwatch.sh" "$memlog" 30 &
watch_pid=$!
trap 'kill $watch_pid 2>/dev/null' EXIT
echo "Memory ceiling ${gb} GB (user cgroup); memory log: $memlog"
if systemd-run --user --scope -p MemoryMax="${gb}G" -p MemorySwapMax=0 --quiet true 2>/dev/null; then
  systemd-run --user --scope -p MemoryMax="${gb}G" -p MemorySwapMax=0 --quiet "$@"
else
  echo "WARNING: systemd-run user scope unavailable; running without a cgroup ceiling (the in-process guard still applies)."
  "$@"
fi
status=$?
if dmesg 2>/dev/null | tail -50 | grep -qi "oom-kill\|out of memory"; then
  echo "NOTE: the kernel OOM killer fired during this run; see dmesg and $memlog"
fi
exit $status
