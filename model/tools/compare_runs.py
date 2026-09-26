#!/usr/bin/env python
"""Compare finished runs side by side, and give the spread across a group of them.

    model/.venv/bin/python model/tools/compare_runs.py --runs 20260926_B0_base_s1 20260926_B0_base_s2 ... [--baseline 20260924_resnet34_test34]
        [--calibration stored|calibrated|both] [--out data/model/runs/compare_<label>.csv] [--label B0]

Reads data/model/runs/registry.csv (one row per suite pass) and, per run, the
suite's t1_scenes.csv and t2_changes.csv, and reports for the held-out scenes:

- per run: stored threshold, best epoch, pooled F1, relaxed F1, area bias, share
  MAE, delta MAE, false-change p90, and the calibrated versions where a
  calibrated pass exists;
- across the group: mean, standard deviation, min and max of each metric, which
  is "the seed spread": the smallest difference between two configurations the
  plan will call real (TESTING_PLAN.md section 6);
- per MLRA: area bias per run and its spread.

Writes a CSV beside the registry and prints the tables.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from tofunet.config import load_config, tof_path  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--runs", nargs="+", required=True)
ap.add_argument("--baseline", default=None, help="a run shown alongside but left out of the spread")
ap.add_argument("--label", default="group")
ap.add_argument("--out", default=None)
args = ap.parse_args()

cfg = load_config(); cm = cfg["model"]
runs_dir = tof_path(cm["paths"]["runs_dir"])
reg = pd.read_csv(runs_dir / "registry.csv")
reg["calibrated"] = reg["calibration"].fillna("none").ne("none")
metrics = ["f1_pooled", "f1_scene_mean", "f1_r1_scene_mean", "area_bias_ratio", "soft_area_bias_ratio", "share_mae_pp",
           "delta_mae_pp", "false_change_p90_pp"]
show = ["f1_pooled", "f1_r1_scene_mean", "area_bias_ratio", "share_mae_pp", "delta_mae_pp", "false_change_p90_pp"]


def latest(run: str, calibrated: bool) -> pd.Series | None:
    r = reg[(reg["run"] == run) & (reg["calibrated"] == calibrated) & (reg["limit"].isna())]
    r = r[r["splits"].str.contains("validation") & r["splits"].str.contains("test")]
    return None if r.empty else r.iloc[-1]


rows = []
for run in ([args.baseline] if args.baseline else []) + args.runs:
    res = json.load(open(runs_dir / run / "results.json"))
    cfgj = json.load(open(runs_dir / run / "config.json"))
    for cal in (False, True):
        r = latest(run, cal)
        if r is None:
            continue
        rows.append({"run": run, "group": "baseline" if run == args.baseline else args.label, "pass": "calibrated" if cal else "stored",
                     "seed": cfgj.get("seed"), "best_epoch": res["best_epoch"], "epochs_run": res["epochs_run"],
                     "stored_threshold": res["threshold"], "threshold_used": r["threshold"], "device": r["device"],
                     **{m: r[m] for m in metrics}})
tbl = pd.DataFrame(rows)
if tbl.empty:
    sys.exit("no registry rows for those runs; run 05_evaluate_suite.py first")

print(f"\nHeld-out scenes, per run (registry rows; wall-clock host in registry.csv):")
for p in ("stored", "calibrated"):
    t = tbl[tbl["pass"] == p]
    if t.empty:
        continue
    print(f"\n-- {p} threshold")
    print(t[["run", "seed", "best_epoch", "epochs_run", "stored_threshold", "threshold_used"] + show].round(3).to_string(index=False))

# ---- spread across the group -----------------------------------------------------------------
spread_rows = []
for p in ("stored", "calibrated"):
    g = tbl[(tbl["pass"] == p) & (tbl["group"] == args.label)]
    if len(g) < 2:
        continue
    for m in metrics:
        v = g[m].astype(float)
        spread_rows.append({"pass": p, "metric": m, "n_runs": len(v), "mean": v.mean(), "sd": v.std(ddof=1), "min": v.min(),
                            "max": v.max(), "range": v.max() - v.min(), "two_sd": 2 * v.std(ddof=1)})
spread = pd.DataFrame(spread_rows)
if not spread.empty:
    print(f"\nSeed spread over the {args.label} runs (2 sd is the smallest difference to call real):")
    print(spread[spread["metric"].isin(show)].round(4).to_string(index=False))

# ---- per-MLRA area bias per run (stored threshold, from t1_scenes.csv) -------------------------
mlra_rows = []
for run in ([args.baseline] if args.baseline else []) + args.runs:
    p = runs_dir / run / "suite" / "t1_scenes.csv"
    if not p.exists():
        continue
    t1 = pd.read_csv(p, dtype={"id": str})
    t0 = pd.read_csv(runs_dir / run / "suite" / "t0_scenes.csv", dtype={"id": str, "MLRARSYM": str})
    t1 = t1.merge(t0[["key", "MLRARSYM"]], on="key", how="left")
    held = t1[t1["split"].isin(["validation", "test"])]
    for m, g in held.groupby("MLRARSYM"):
        mlra_rows.append({"run": run, "MLRARSYM": m, "n_scenes": len(g), "bias": g["pred_m2"].sum() / g["true_m2"].sum() if g["true_m2"].sum() else np.nan})
if mlra_rows:
    mt = pd.DataFrame(mlra_rows).pivot(index="MLRARSYM", columns="run", values="bias")
    grp = [r for r in args.runs if r in mt.columns]
    mt["group_mean"] = mt[grp].mean(axis=1); mt["group_sd"] = mt[grp].std(axis=1, ddof=1)
    print("\nPer-MLRA area bias on held-out scenes (last suite pass of each run; note the threshold may differ):")
    print(mt.round(3).to_string())

out = tof_path(args.out) if args.out else runs_dir / f"compare_{args.label}.csv"
tbl.to_csv(out, index=False)
if not spread.empty:
    spread.to_csv(out.with_name(out.stem + "_spread.csv"), index=False)
print(f"\nwrote {out}")
