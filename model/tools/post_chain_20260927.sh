#!/usr/bin/env bash
# Sequential follow-up to the phase 2c / 3 chain (replaces the after_chain / after_phase3 waiters,
# whose process check matched the launching shells and never fired): whole panel for the P3_full
# seeds and B0 s1, then the phase 2d late-season queue, then tranche 1 panel and the 2015
# harmonisation test for its runs. Detach it: setsid nohup ... < /dev/null &
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"; root="$(cd "$here/.." && pwd)"; R="$root/data/model/runs"
cd "$root"
echo "$(date '+%F %T')  whole panel for the P3_full seeds and B0 s1"
model/tools/run_panel.sh --out-name panel_full "$R/20260927_P3_full_s1" "$R/20260927_P3_full_s2" "$R/20260927_P3_full_s3" "$R/20260926_B0_base_s1"
echo "$(date '+%F %T')  phase 2d"
model/tools/run_experiments.sh model/experiments_phase2d.txt
runs=""; for n in 20260927_H2a_late3_s1 20260927_H2a_late6_s1 20260927_H2a_late3_P3_s1; do [ -f "$R/$n/results.json" ] && runs="$runs $R/$n"; done
# shellcheck disable=SC2086
[ -n "$runs" ] && model/tools/run_panel.sh --tranche 1 $runs
# shellcheck disable=SC2086
[ -n "$runs" ] && model/tools/harmonize_year_test.sh $runs
echo "$(date '+%F %T')  done"
