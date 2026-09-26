#!/usr/bin/env python
"""Scorecard v0: re-slice a finished run's per-scene tables with bootstrap intervals.

    model/.venv/bin/python model/tools/scorecard_v0.py --run data/model/runs/<run> [--resamples 1000] [--seed 2026]

Step 2 of the testing plan (TESTING_PLAN.md, 9.2). Reads the run's
validation_scenes.csv and test_scenes.csv, joins data/model/scene_meta.csv
(build_scene_meta.py) and reports, with percentile bootstrap intervals over
scenes:

- T0 pixel: pooled F1 / precision / recall / IoU from the recovered per-scene
  confusion counts, and the per-scene F1 distribution;
- T1 area, first version: per-scene tree share, predicted against mask, over the
  pixels the patch tiling scored (not yet on eligible land; the masks-stage
  combined mask is not applied here). Bias as sum(pred) / sum(true), MAE and
  RMSE of the share in percentage points, calibration slope and intercept
  (pred share regressed on true share);
- the same by split, cover class, mask year, off-target year, capture month,
  state, MLRA, transition class, two-month mosaic and harmoniser action;
- the target-year against off-target gap as a difference with its own interval.

Per-scene TP / FP / FN are recovered from tree_pixels, predicted_tree_pixels
and recall; the pooled test F1 they give is checked against results.json.
Slices with fewer than 5 scenes are reported but flagged `small`.

Writes <run>/suite/scorecard_v0.json and <run>/suite/scorecard_v0_slices.csv.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from tofunet.config import load_config, setup_logging, tof_path  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--run", required=True)
ap.add_argument("--meta", default=None, help="default: <model.paths.work_dir>/scene_meta.csv")
ap.add_argument("--resamples", type=int, default=1000)
ap.add_argument("--seed", type=int, default=2026)
ap.add_argument("--min-scenes", type=int, default=5)
args = ap.parse_args()

cfg = load_config(); cm = cfg["model"]
run_dir = tof_path(args.run)
suite = run_dir / "suite"
suite.mkdir(parents=True, exist_ok=True)
log = setup_logging(suite / "scorecard_v0.log")
work = tof_path(cm["paths"]["work_dir"])
meta_path = tof_path(args.meta) if args.meta else work / "scene_meta.csv"

with open(run_dir / "config.json") as f:
    run_cfg = json.load(f)
with open(run_dir / "results.json") as f:
    results = json.load(f)
patch_px = int(run_cfg["patch_size"]) ** 2

# ---- scenes with recovered counts -----------------------------------------
frames = []
for split in ("validation", "test"):
    p = run_dir / f"{split}_scenes.csv"
    if p.exists():
        frames.append(pd.read_csv(p, dtype={"id": str, "key": str}))
scenes = pd.concat(frames, ignore_index=True)
scenes["tp"] = np.rint(scenes["recall"] * scenes["tree_pixels"]).astype(np.int64)
scenes["fp"] = scenes["predicted_tree_pixels"] - scenes["tp"]
scenes["fn"] = scenes["tree_pixels"] - scenes["tp"]
scenes["scored_pixels"] = scenes["patches"] * patch_px
scenes["true_share"] = 100 * scenes["tree_pixels"] / scenes["scored_pixels"]
scenes["pred_share"] = 100 * scenes["predicted_tree_pixels"] / scenes["scored_pixels"]
scenes["share_error"] = scenes["pred_share"] - scenes["true_share"]

meta = pd.read_csv(meta_path, dtype={"id": str, "key": str, "MLRA_ID": str, "MLRARSYM": str, "actual_year": str})
meta_cols = ["key", "cover_class", "transition_class", "CLUSTER_ID", "tree_percentage", "MLRA_ID", "MLRARSYM",
             "off_target", "actual_year", "capture_month", "two_month_mosaic", "naip_state", "harm_action",
             "harm_ks_to_reference", "in_sample_list"]
scenes = scenes.merge(meta[meta_cols], on="key", how="left", validate="one_to_one")
missing = scenes["cover_class"].isna().sum()
if missing:
    log.error("%d scored scenes have no metadata row; run build_scene_meta.py first", missing)
    sys.exit(1)
scenes["year_kind"] = np.where(scenes["off_target"], "off_target", "target")
scenes["capture_month"] = scenes["capture_month"].astype("Int64")
scenes["harm_action"] = scenes["harm_action"].fillna("none")
log.info("%d scored scenes (%s)", len(scenes), scenes["split"].value_counts().to_dict())

# ---- check the recovered counts against results.json ----------------------
for split in ("validation", "test"):
    s = scenes[scenes["split"] == split]
    tp, fp, fn = (int(s[c].sum()) for c in ("tp", "fp", "fn"))
    f1 = 2 * tp / max(2 * tp + fp + fn, 1)
    ref = results[split]["f1"]
    log.info("%s pooled F1 from recovered counts %.4f, results.json %.4f (tp %d / %d)", split, f1, ref, tp, results[split]["tp"])
    if abs(f1 - ref) > 2e-3:
        log.error("recovered counts disagree with results.json; refusing to continue")
        sys.exit(1)

# ---- statistics -------------------------------------------------------------
rng = np.random.default_rng(args.seed)


def stats(d: pd.DataFrame) -> dict[str, float]:
    tp, fp, fn = (float(d[c].sum()) for c in ("tp", "fp", "fn"))
    precision = tp / max(tp + fp, 1)
    recall = tp / max(tp + fn, 1)
    true_sum = float(d["tree_pixels"].sum())
    pred_sum = float(d["predicted_tree_pixels"].sum())
    out = {
        "f1_pooled": 2 * tp / max(2 * tp + fp + fn, 1),
        "precision_pooled": precision,
        "recall_pooled": recall,
        "iou_pooled": tp / max(tp + fp + fn, 1),
        "f1_scene_mean": float(d["f1"].mean()),
        "f1_scene_median": float(d["f1"].median()),
        "area_bias_ratio": pred_sum / true_sum if true_sum > 0 else np.nan,
        "share_bias_pp": float(d["share_error"].mean()),
        "share_mae_pp": float(d["share_error"].abs().mean()),
        "share_rmse_pp": float(np.sqrt((d["share_error"] ** 2).mean())),
        "true_share_mean_pp": float(d["true_share"].mean()),
        "pred_share_mean_pp": float(d["pred_share"].mean()),
    }
    if len(d) >= 3 and d["true_share"].std() > 0:
        slope, intercept = np.polyfit(d["true_share"], d["pred_share"], 1)
        out["calib_slope"], out["calib_intercept_pp"] = float(slope), float(intercept)
    else:
        out["calib_slope"] = out["calib_intercept_pp"] = np.nan
    return out


def bootstrap(d: pd.DataFrame, n: int) -> dict[str, dict[str, float]]:
    point = stats(d)
    if len(d) < 2:
        return {k: {"est": v, "lo": np.nan, "hi": np.nan} for k, v in point.items()}
    idx = rng.integers(0, len(d), size=(n, len(d)))
    draws = pd.DataFrame([stats(d.iloc[i]) for i in idx])
    lo, hi = draws.quantile(0.025), draws.quantile(0.975)
    return {k: {"est": v, "lo": float(lo[k]), "hi": float(hi[k])} for k, v in point.items()}


def bootstrap_diff(a: pd.DataFrame, b: pd.DataFrame, n: int, keys: list[str]) -> dict[str, dict[str, float]]:
    """a minus b, resampling each group independently."""
    pa, pb = stats(a), stats(b)
    ia = rng.integers(0, len(a), size=(n, len(a)))
    ib = rng.integers(0, len(b), size=(n, len(b)))
    da = pd.DataFrame([stats(a.iloc[i]) for i in ia])
    db = pd.DataFrame([stats(b.iloc[i]) for i in ib])
    diff = da[keys] - db[keys]
    lo, hi = diff.quantile(0.025), diff.quantile(0.975)
    return {k: {"est": pa[k] - pb[k], "lo": float(lo[k]), "hi": float(hi[k]),
                "excludes_zero": bool(lo[k] > 0 or hi[k] < 0)} for k in keys}


populations = {"test": scenes[scenes["split"] == "test"],
               "validation": scenes[scenes["split"] == "validation"],
               "heldout": scenes}
slice_cols = ["cover_class", "year", "year_kind", "actual_year", "capture_month", "naip_state", "MLRARSYM",
              "transition_class", "two_month_mosaic", "harm_action"]

card: dict = {
    "run": run_dir.name,
    "threshold": results["threshold"],
    "resamples": args.resamples,
    "seed": args.seed,
    "note": ("T1 shares are over the pixels the patch tiling scored, not over eligible land; "
             "the masks-stage combined mask is not applied in v0."),
    "populations": {},
    "slices": {},
    "gaps": {},
}
rows = []
for pop, d in populations.items():
    log.info("population %s: %d scenes", pop, len(d))
    card["populations"][pop] = {"n_scenes": int(len(d)), "n_cells": int(d["id"].nunique()), **bootstrap(d, args.resamples)}
    if pop == "validation":
        continue
    card["slices"][pop] = {}
    for col in slice_cols:
        card["slices"][pop][col] = {}
        for level, g in d.groupby(col, dropna=False, sort=True):
            level_key = "NA" if pd.isna(level) else str(level)
            b = bootstrap(g, args.resamples)
            entry = {"n_scenes": int(len(g)), "small": bool(len(g) < args.min_scenes), **b}
            card["slices"][pop][col][level_key] = entry
            rows.append({"population": pop, "slice": col, "level": level_key, "n_scenes": len(g),
                         "small": len(g) < args.min_scenes,
                         **{f"{k}": v["est"] for k, v in b.items()},
                         **{f"{k}_lo": v["lo"] for k, v in b.items()},
                         **{f"{k}_hi": v["hi"] for k, v in b.items()}})

# ---- the claims from section 1.1 as differences with intervals ------------
gap_keys = ["f1_scene_mean", "f1_pooled", "area_bias_ratio", "share_mae_pp", "share_bias_pp"]
for pop in ("test", "heldout"):
    d = populations[pop]
    on, off = d[d["year_kind"] == "target"], d[d["year_kind"] == "off_target"]
    card["gaps"][pop] = {
        "target_minus_off_target": {"n_target": int(len(on)), "n_off_target": int(len(off)),
                                    **bootstrap_diff(on, off, args.resamples, gap_keys)},
    }
    c3, c1 = d[d["cover_class"].str.startswith("c3")], d[d["cover_class"].str.startswith("c1")]
    card["gaps"][pop]["c3_minus_c1"] = {"n_c3": int(len(c3)), "n_c1": int(len(c1)),
                                        **bootstrap_diff(c3, c1, args.resamples, gap_keys)}
    for name, key in (("target_minus_off_target", "f1_scene_mean"), ("c3_minus_c1", "f1_scene_mean"),
                      ("target_minus_off_target", "area_bias_ratio")):
        g = card["gaps"][pop][name][key]
        log.info("%s %s %s: %+.3f [%+.3f, %+.3f]%s", pop, name, key, g["est"], g["lo"], g["hi"],
                 "" if g["excludes_zero"] else "  (interval covers zero)")


def clean(o):
    if isinstance(o, dict):
        return {k: clean(v) for k, v in o.items()}
    if isinstance(o, float) and np.isnan(o):
        return None
    if isinstance(o, (np.integer,)):
        return int(o)
    if isinstance(o, (np.floating,)):
        return None if np.isnan(o) else float(o)
    if isinstance(o, (np.bool_,)):
        return bool(o)
    return o


with open(suite / "scorecard_v0.json", "w") as f:
    json.dump(clean(card), f, indent=2)
pd.DataFrame(rows).to_csv(suite / "scorecard_v0_slices.csv", index=False)
scenes.to_csv(suite / "scorecard_v0_scenes.csv", index=False)

# ---- print the headline ----------------------------------------------------
def fmt(e: dict, pct: bool = False, digits: int = 3) -> str:
    if e["est"] is None or (isinstance(e["est"], float) and np.isnan(e["est"])):
        return "NA"
    s = lambda x: f"{x:.{digits}f}"
    return f"{s(e['est'])} [{s(e['lo'])}, {s(e['hi'])}]"


for pop in ("validation", "test", "heldout"):
    p = card["populations"][pop]
    log.info("%-10s n=%3d  F1 pooled %s  F1 scene mean %s  area bias %s  share MAE pp %s  calib slope %s",
             pop, p["n_scenes"], fmt(p["f1_pooled"]), fmt(p["f1_scene_mean"]), fmt(p["area_bias_ratio"]),
             fmt(p["share_mae_pp"]), fmt(p["calib_slope"], digits=2))
for col in ("cover_class", "year_kind", "year", "capture_month", "naip_state", "MLRARSYM"):
    log.info("test by %s:", col)
    for level, e in card["slices"]["test"][col].items():
        log.info("  %-12s n=%3d%s  F1 scene mean %s  area bias %s  share MAE pp %s", level, e["n_scenes"],
                 "*" if e["small"] else " ", fmt(e["f1_scene_mean"]), fmt(e["area_bias_ratio"]), fmt(e["share_mae_pp"]))
log.info("* fewer than %d scenes: reported, not for decisions", args.min_scenes)
log.info("wrote %s", suite / "scorecard_v0.json")
