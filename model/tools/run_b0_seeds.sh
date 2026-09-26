#!/usr/bin/env bash
# Step 6 of TESTING_PLAN.md: the baseline configuration (B0) trained with three
# seeds, each scored by the evaluation suite at its stored threshold, calibrated
# on its own validation scenes, and scored again calibrated.
#
#     model/tools/run_b0_seeds.sh [python] [date_prefix] [seeds...]
#     model/tools/run_b0_seeds.sh ~/venvs/tof-rocm/bin/python 20260926 1 2 3
#
# Runs are named <date>_B0_base_s<seed>. A run whose results.json exists is not
# retrained (rerun the script to resume after an interruption). Each training
# runs under tools/run_guarded.sh (memory ceiling from config.yml). Progress is
# appended to data/model/runs/b0_seeds.log.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
root="$(cd "$here/.." && pwd)"
py="${1:-$HOME/venvs/tof-rocm/bin/python}"; shift || true
date_prefix="${1:-$(date +%Y%m%d)}"; shift || true
seeds=("$@"); [ ${#seeds[@]} -eq 0 ] && seeds=(1 2 3)
runs_dir="$root/data/model/runs"
log="$runs_dir/b0_seeds.log"
mkdir -p "$runs_dir"
say() { echo "$(date '+%F %T')  $*" | tee -a "$log"; }

say "B0 x ${#seeds[@]} seeds with $py on $(hostname)"
for s in "${seeds[@]}"; do
  name="${date_prefix}_B0_base_s${s}"
  run="$runs_dir/$name"
  if [ -f "$run/results.json" ]; then
    say "$name: results.json exists, training skipped"
  else
    say "$name: training (seed $s)"
    t0=$(date +%s)
    "$here/tools/run_guarded.sh" "$py" "$here/02_train.py" --run-name "$name" --seed "$s" > "$runs_dir/${name}.train.out" 2>&1
    status=$?
    say "$name: training exit $status after $(( ($(date +%s) - t0) / 60 )) min"
    if [ $status -ne 0 ] || [ ! -f "$run/results.json" ]; then
      say "$name: no results.json; see $runs_dir/${name}.train.out. Stopping."
      exit 1
    fi
    grep -E "Best epoch" "$run/train.log" | tail -1 | tee -a "$log"
  fi
  say "$name: suite at stored threshold"
  "$py" "$here/05_evaluate_suite.py" --run "$run" --splits all > "$runs_dir/${name}.suite.out" 2>&1 || { say "$name: suite failed"; exit 1; }
  say "$name: calibration"
  "$py" "$here/tools/calibrate_threshold.py" --run "$run" > "$runs_dir/${name}.calibrate.out" 2>&1 || { say "$name: calibration failed"; exit 1; }
  say "$name: suite calibrated"
  "$py" "$here/05_evaluate_suite.py" --run "$run" --calibration "$run/suite/calibration.json" > "$runs_dir/${name}.suite_cal.out" 2>&1 || { say "$name: calibrated suite failed"; exit 1; }
  grep -E "^.{9} (heldout) +n=" "$runs_dir/${name}.suite.out" | cut -c10- | tee -a "$log"
  grep -E "recommended thresholded" "$runs_dir/${name}.calibrate.out" | cut -c10- | tee -a "$log"
done
say "done: $(find "$runs_dir" -maxdepth 1 -type d -name "${date_prefix}_B0_base_s*" | wc -l) runs; registry $runs_dir/registry.csv"
