#!/usr/bin/env bash
# T3(b) and T5 for one or more runs: predict the evaluation panel with the run's
# calibrated threshold, then run the estimator on those rasters.
#     model/tools/run_panel.sh [--tranche N] [--python <py>] <run_dir> [<run_dir> ...]
# Outputs per run: <run>/panel/ (06_predict_panel.py) and <run>/panel/estimates/
# (estimates_mlra_lrr_F.csv, estimates_lrr_F.csv from 00_run_estimates.R with
# --cells = the panel CSV, --eligible-from=model). Rasters that exist are reused.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
root="$(cd "$here/.." && pwd)"
py="$HOME/venvs/tof-rocm/bin/python"; tranche=""
while [[ $# -gt 0 && "$1" == --* ]]; do
  case "$1" in
    --tranche) tranche="$2"; shift 2;;
    --python) py="$2"; shift 2;;
    *) echo "unknown option $1"; exit 1;;
  esac
done
panel_csv="$(python3 -c "import yaml; print(yaml.safe_load(open('$root/config.yml'))['sampling']['panel']['out_csv'])")"
log="$root/data/model/runs/panel.log"
say() { echo "$(date '+%F %T')  $*" | tee -a "$log"; }
for run in "$@"; do
  run="$(cd "$run" && pwd)"; name="$(basename "$run")"
  cal=""; [ -f "$run/suite/calibration.json" ] && cal="--calibration $run/suite/calibration.json"
  say "$name: predicting the panel${tranche:+ (tranche $tranche)} ${cal:+calibrated}"
  # shellcheck disable=SC2086
  "$py" "$here/06_predict_panel.py" --run "$run" ${tranche:+--tranche $tranche} $cal > "$run/panel_predict.out" 2>&1 || { say "$name: panel prediction failed (see $run/panel_predict.out)"; continue; }
  grep -E "cell-years|T5:|20 % rule" "$run/panel/panel.log" | tail -3 | cut -c10- | tee -a "$log"
  say "$name: estimator on the panel rasters"
  cells="$panel_csv"
  if [ -n "$tranche" ]; then
    cells="$run/panel/panel_cells_t${tranche}.csv"
    python3 - "$root/$panel_csv" "$tranche" "$cells" <<'PY'
import csv, sys
src, tr, dst = sys.argv[1:]
rows = [r for r in csv.DictReader(open(src)) if r["tranche"] == tr]
w = csv.DictWriter(open(dst, "w", newline=""), fieldnames=rows[0].keys()); w.writeheader(); w.writerows(rows)
PY
  fi
  mkdir -p "$run/panel/estimates"
  (cd "$root" && Rscript estimates/00_run_estimates.R --cells="$cells" --model-dir="$run/panel/predictions" \
      --pattern="tof_{id}_{year}.tif" --eligible-from=model --out="$run/panel/estimates" > "$run/panel/estimates/run.log" 2>&1) \
    || { say "$name: estimator failed (see $run/panel/estimates/run.log)"; continue; }
  grep -E "^ *[0-9]+ F +[0-9]{4} (eligible|total)" "$run/panel/estimates/run.log" | tee -a "$log"
done
say "done"
