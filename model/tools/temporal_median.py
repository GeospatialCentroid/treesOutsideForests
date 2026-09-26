#!/usr/bin/env python
"""H7c: does a per-pixel median across a cell's years remove false change?

    model/.venv/bin/python model/tools/temporal_median.py --run data/model/runs/<run> [--threshold 0.2] [--resamples 1000]

Step 5 of the testing plan. A post-process only: each year is predicted alone
(the suite's probability rasters), then per cell the three years are combined
pixel by pixel. Three variants are scored against the masks, all trees on all
valid pixels:

  single        each year on its own (the baseline)
  median_all    every pixel takes the median probability across the cell's years,
                so the three years get one identical map: the ceiling on false-change
                removal, and the floor on real change (it removes all of it)
  median_unsure a pixel keeps its own year's probability when the model is confident
                (below --low or above --high) and takes the cross-year median when it
                is not; confident change survives, wobble does not
  vote          the year's own binary map, except that a pixel flips to the majority of
                the three binary maps when the year's probability is within --band of
                the threshold

Reports T1 (area bias, share MAE) and T2 (delta MAE, false-change p90 on stable
pairs, and delta MAE on the pairs with real change) per variant on the held-out
cells, with bootstrap intervals. Writes <run>/suite/temporal_median.json and
temporal_median_scenes.csv.
"""
from __future__ import annotations

import argparse
import json
import sys
from itertools import combinations
from pathlib import Path

import numpy as np
import pandas as pd
import rasterio

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from tofunet.config import ROOT, load_config, setup_logging, tof_path  # noqa: E402
from tofunet.data import load_manifest  # noqa: E402
from tofunet.suite import stats as S  # noqa: E402
from tofunet.suite.rasters import MASK_NODATA, read_pair  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--run", required=True)
ap.add_argument("--threshold", type=float, default=None, help="default: the run's stored threshold")
ap.add_argument("--low", type=float, default=0.05); ap.add_argument("--high", type=float, default=0.60)
ap.add_argument("--band", type=float, default=0.15)
ap.add_argument("--resamples", type=int, default=1000); ap.add_argument("--seed", type=int, default=2026)
ap.add_argument("--stable-tol", type=float, default=0.05)
ap.add_argument("--splits", default="validation,test")
args = ap.parse_args()

cfg = load_config(); cm = cfg["model"]
run_dir = tof_path(args.run); suite = run_dir / "suite"; pred_dir = suite / "predictions"
log = setup_logging(suite / "temporal_median.log")
work = tof_path(cm["paths"]["work_dir"])
with open(run_dir / "results.json") as f:
    thr = args.threshold if args.threshold is not None else float(json.load(f)["threshold"])
splits = [s.strip() for s in args.splits.split(",")]

manifest = load_manifest(work)
pairs = manifest[(manifest["status"] == "ok") & (manifest["split"].isin(splits))].copy()
pairs["year"] = pairs["year"].astype(int)
meta = pd.read_csv(work / "scene_meta.csv", dtype={"id": str, "key": str, "MLRARSYM": str})
pairs = pairs.merge(meta[["key", "MLRARSYM", "cover_class", "off_target"]], on="key", how="left")
log.info("%d scenes in %d cells (%s); threshold %.2f; unsure band [%.2f, %.2f]; vote band +/-%.2f",
         len(pairs), pairs["id"].nunique(), splits, thr, args.low, args.high, args.band)

rows = []
for cid, g in pairs.groupby("id"):
    g = g.sort_values("year")
    probs, masks, px = [], [], None
    for _, s in g.iterrows():
        mask, _, _, transform = read_pair(ROOT / s["mask"], ROOT / s["image"])
        with rasterio.open(pred_dir / f"{s['key']}_prob.tif") as src:
            prob = src.read(1)
        probs.append(prob); masks.append(mask); px = abs(transform.a * transform.e)
    if len({p.shape for p in probs}) != 1:
        log.warning("%s: years on different grids; skipped", cid); continue
    P = np.stack(probs)                                  # (Y, H, W), NaN where a year has no data
    valid_all = ~np.isnan(P).any(axis=0)
    with np.errstate(all="ignore"), __import__("warnings").catch_warnings():
        __import__("warnings").simplefilter("ignore", RuntimeWarning)   # all-NaN pixels: no data in every year
        med = np.nanmedian(P, axis=0) if len(probs) >= 3 else np.nanmean(P, axis=0)
    B = P >= thr
    votes = B.sum(axis=0); majority = votes * 2 > len(probs)
    for k, (_, s) in enumerate(g.iterrows()):
        p = P[k]; m = masks[k]
        valid = (m != MASK_NODATA) & ~np.isnan(p) & valid_all
        truth = (m == 1) & valid
        variants = {
            "single": p >= thr,
            "median_all": med >= thr,
            "median_unsure": np.where((p > args.low) & (p < args.high), med, p) >= thr,
            "vote": np.where(np.abs(p - thr) <= args.band, majority, p >= thr),
        }
        n_valid = int(valid.sum()); n_true = int(truth.sum())
        for name, pred in variants.items():
            pred = pred & valid
            tp = int((pred & truth).sum()); n_p = int(pred.sum())
            rows.append({"variant": name, "key": s["key"], "id": cid, "year": int(s["year"]), "split": s["split"],
                         "MLRARSYM": s["MLRARSYM"], "cover_class": s["cover_class"], "n_valid": n_valid,
                         "true_px": n_true, "pred_px": n_p, "tp": tp, "fp": n_p - tp, "fn": n_true - tp,
                         "f1": 2 * tp / max(n_p + n_true, 1), "px_m2": px})
    log.info("%s: %d years done", cid, len(probs))

d = pd.DataFrame(rows)
d["true_m2"] = d["true_px"] * d["px_m2"]; d["pred_m2"] = d["pred_px"] * d["px_m2"]; d["soft_m2"] = d["pred_m2"]
d["true_share_pp"] = 100 * d["true_px"] / d["n_valid"]; d["pred_share_pp"] = 100 * d["pred_px"] / d["n_valid"]
d["soft_share_pp"] = d["pred_share_pp"]; d["f1_r1"] = d["f1_r2"] = np.nan
d.to_csv(suite / "temporal_median_scenes.csv", index=False)


def changes_for(x: pd.DataFrame) -> pd.DataFrame:
    out = []
    for cid, g in x.groupby("id"):
        g = g.sort_values("year")
        for a, b in combinations(g.itertuples(index=False), 2):
            out.append({"id": cid, "true_delta_pp": b.true_share_pp - a.true_share_pp,
                        "pred_delta_pp": b.pred_share_pp - a.pred_share_pp, "soft_delta_pp": b.pred_share_pp - a.pred_share_pp})
    return pd.DataFrame(out)


rng = np.random.default_rng(args.seed)
card = {"run": run_dir.name, "threshold": thr, "low": args.low, "high": args.high, "band": args.band, "variants": {}}
t1_keys = ["area_bias_ratio", "share_mae_pp", "f1_pooled", "f1_scene_mean"]
t2_keys = ["delta_mae_pp", "delta_bias_pp", "false_change_p90_pp", "false_change_mean_abs_pp", "sign_agreement_moving", "n_moving"]
for name, x in d.groupby("variant"):
    entry = {}
    for pop in ("test", "heldout"):
        xx = x[x["split"] == "test"] if pop == "test" else x
        b = S.bootstrap(xx, S.scene_stats, args.resamples, rng)
        ch = changes_for(xx)
        c = S.bootstrap(ch, lambda z: S.change_stats(z, args.stable_tol), args.resamples, rng, group="id")
        moving = ch[ch["true_delta_pp"].abs() > args.stable_tol]
        mov_mae = float((moving["pred_delta_pp"] - moving["true_delta_pp"]).abs().mean()) if len(moving) else None
        entry[pop] = {"n_scenes": int(len(xx)), "n_pairs": int(len(ch)), **{k: b[k] for k in t1_keys}, **{k: c[k] for k in t2_keys},
                      "delta_mae_moving_pp": mov_mae}
    card["variants"][name] = entry
    h = entry["heldout"]
    log.info("%-14s heldout: bias %s  share MAE %s  F1 %s | delta MAE %s  false-change p90 %s  mean|false| %s  moving-pair MAE %s",
             name, S.fmt(h["area_bias_ratio"]), S.fmt(h["share_mae_pp"]), S.fmt(h["f1_pooled"]), S.fmt(h["delta_mae_pp"]),
             S.fmt(h["false_change_p90_pp"]), S.fmt(h["false_change_mean_abs_pp"]),
             "NA" if h["delta_mae_moving_pp"] is None else f"{h['delta_mae_moving_pp']:.3f}")
with open(suite / "temporal_median.json", "w") as f:
    json.dump(S.clean(card), f, indent=2)
log.info("wrote %s", suite / "temporal_median.json")
