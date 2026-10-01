#!/usr/bin/env bash
# Targeted harmonisation test for the 2016 dip (TESTING_PLAN.md 10.12): remap only the
# 2015 imagery of the tranche 1 panel cells that carry it to each cell's most recent
# other year, re-predict those cells with the given runs from the harmonised tree, and
# compare with the run's raw panel predictions. Detach it: setsid nohup ... &
#     model/tools/harmonize_year_test.sh <run_dir> [<run_dir> ...]
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"; root="$(cd "$here/.." && pwd)"
py="$HOME/venvs/tof-rocm/bin/python"
cells="$root/data/reference/sampleGrids/evaluationPanel_lrr_F_t1_y2015.csv"
tree="data/naip/harmonized_y2015"; variant="panel_h2015"
log="$root/data/model/runs/harmonize_year_test.log"
say() { echo "$(date '+%F %T')  $*" | tee -a "$log"; }
cd "$root"
ids=$(python3 -c "import csv; print(' '.join(r['id'] for r in csv.DictReader(open('$cells'))))")
say "harmonising the 2015 imagery of $(echo $ids | wc -w) cells -> $tree"
# shellcheck disable=SC2086
Rscript harmonize/0_run.R --mode=year --years=2015 --out="$tree" $ids > data/model/runs/harmonize_year_test.R.out 2>&1 \
  || { say "harmonisation failed; see data/model/runs/harmonize_year_test.R.out"; exit 1; }
grep -E "normalized|linked|error" data/model/runs/harmonize_year_test.R.out | head -5 | tee -a "$log"
for run in "$@"; do
  run="$(cd "$run" && pwd)"; name="$(basename "$run")"
  cal=""; [ -f "$run/suite/calibration.json" ] && cal="--calibration $run/suite/calibration.json"
  say "$name: predicting the 2015 cells from $tree -> $variant"
  # shellcheck disable=SC2086
  "$py" "$here/06_predict_panel.py" --run "$run" --cells "$cells" --export-dir "$tree" --out-name "$variant" $cal > "$run/${variant}_predict.out" 2>&1 \
    || { say "$name: prediction failed (see $run/${variant}_predict.out)"; continue; }
  "$py" "$here/tools/compare_panel_variants.py" --run "$run" --variant "$variant" --cells "$cells" 2>&1 | tee -a "$log"
done
say "done"
