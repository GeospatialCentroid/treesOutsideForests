#!/usr/bin/env bash
# Phase 2 of TESTING_PLAN.md: single-factor experiments against the B0 baseline.
# Each line of the experiment file is
#     <run_name>|<02_train.py arguments>
# for example
#     20260927_H5b_min015_s1|--seed 1 --set min_tree_fraction=0.015
# Lines starting with # are skipped. Every run is trained under run_guarded.sh,
# then scored by the suite on all splits, calibrated on its own validation
# scenes and scored again calibrated, exactly as run_b0_seeds.sh does, so the
# registry rows are comparable. A run whose results.json exists is not retrained.
#
#     model/tools/run_experiments.sh <experiments.txt> [python]
set -uo pipefail
set -f   # no globbing: --set values like train_years=[2012,2016,2020] must reach python verbatim
here="$(cd "$(dirname "$0")/.." && pwd)"
root="$(cd "$here/.." && pwd)"
exp_file="${1:?experiment file}"
py="${2:-$HOME/venvs/tof-rocm/bin/python}"
runs_dir="$root/data/model/runs"
log="$runs_dir/experiments.log"
say() { echo "$(date '+%F %T')  $*" | tee -a "$log"; }

say "experiments from $exp_file with $py on $(hostname)"
while IFS='|' read -r name argstr; do
  [[ -z "${name// }" || "$name" =~ ^# ]] && continue
  run="$runs_dir/$name"
  if [ -f "$run/results.json" ]; then
    say "$name: results.json exists, training skipped"
  else
    say "$name: training ($argstr)"
    t0=$(date +%s)
    # shellcheck disable=SC2086
    "$here/tools/run_guarded.sh" "$py" "$here/02_train.py" --run-name "$name" $argstr > "$runs_dir/${name}.train.out" 2>&1
    status=$?
    say "$name: training exit $status after $(( ($(date +%s) - t0) / 60 )) min"
    if [ $status -ne 0 ] || [ ! -f "$run/results.json" ]; then
      say "$name: no results.json; see $runs_dir/${name}.train.out. Skipping to the next experiment."
      continue
    fi
    grep -E "Best epoch" "$run/train.log" | tail -1 | tee -a "$log"
  fi
  say "$name: suite"
  "$py" "$here/05_evaluate_suite.py" --run "$run" --splits all > "$runs_dir/${name}.suite.out" 2>&1 || { say "$name: suite failed"; continue; }
  "$py" "$here/tools/calibrate_threshold.py" --run "$run" > "$runs_dir/${name}.calibrate.out" 2>&1 || { say "$name: calibration failed"; continue; }
  "$py" "$here/05_evaluate_suite.py" --run "$run" --calibration "$run/suite/calibration.json" > "$runs_dir/${name}.suite_cal.out" 2>&1 || { say "$name: calibrated suite failed"; continue; }
  grep -E "^.{9} (heldout) +n=" "$runs_dir/${name}.suite.out" | cut -c10- | tee -a "$log"
  grep -E "recommended thresholded" "$runs_dir/${name}.calibrate.out" | cut -c10- | tee -a "$log"
done < "$exp_file"
say "done"
