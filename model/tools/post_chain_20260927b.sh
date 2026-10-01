#!/usr/bin/env bash
# Runs after post_chain_20260927.sh: the phase 3b queue and the tranche 1 panel for its runs.
# The wait matches only a process whose command line *starts* with the runner's name, never the
# shells that launched it. Detach it: setsid nohup ... < /dev/null &
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"; root="$(cd "$here/.." && pwd)"; R="$root/data/model/runs"
cd "$root"
echo "$(date '+%F %T')  waiting for post_chain_20260927.sh"
while pgrep -f "^bash model/tools/post_chain_20260927.sh" > /dev/null; do sleep 300; done
echo "$(date '+%F %T')  phase 3b"
model/tools/run_experiments.sh model/experiments_phase3b.txt
runs=""; for n in 20260927_P3_no_bg3_s2 20260927_P3_no_bg3_s3 20260927_P3b_lean_s1 20260927_P3b_lean_s2 20260927_P3b_lean_s3 20260927_P3_no_bg3_s1; do [ -f "$R/$n/results.json" ] && runs="$runs $R/$n"; done
# shellcheck disable=SC2086
[ -n "$runs" ] && model/tools/run_panel.sh --tranche 1 $runs
echo "$(date '+%F %T')  done"
