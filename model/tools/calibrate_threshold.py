#!/usr/bin/env python
"""H11: which threshold, or which calibration, gives the right area?

    model/.venv/bin/python model/tools/calibrate_threshold.py --run data/model/runs/<run> [--fit validation] [--resamples 1000]

Step 5 of the testing plan. The stored threshold maximises pooled validation
F1; for an area estimate the right choice is whatever makes predicted tree
area unbiased on scenes the model was not trained on. One pass over the
suite's probability rasters bins every valid pixel's probability (100 bins)
separately for true-tree and true-background pixels, per scene; every method
below is then arithmetic over those histograms. All trees on all valid pixels
(the combined mask is the estimator's business).

Methods, fitted on the `--fit` split (validation) and scored on test and on
validation + test:

  stored          the run's threshold (F1-optimal on pooled validation)
  f1_best         the pooled-F1-optimal threshold on a 0.01 grid
  area_unbiased   the threshold where predicted area equals true area on the fit scenes
  scaled          stored threshold, predicted area multiplied by true / predicted on the fit scenes
  soft            summed probability (no threshold)
  soft_scaled     summed probability times true / soft on the fit scenes
  soft_isotonic   probabilities remapped by an isotonic (pool-adjacent-violators) fit
                  of the empirical tree rate per bin on the fit scenes, then summed
  per_mlra        area-unbiased threshold per MLRA, fitted on train + validation (too few
                  validation cells per MLRA); reported, flagged

For each method: area bias (sum pred / sum true), share bias, MAE and RMSE in
percentage points, calibration slope, pooled F1 (where a threshold exists),
and the T2 numbers (delta MAE, false-change p90 on stable pairs), with bootstrap
intervals over scenes (T1) or cells (T2). Writes <run>/suite/calibration.json,
calibration_methods.csv and calibration_scenes.csv, and puts the recommended
global threshold and area scale in calibration.json for 05_evaluate_suite.py
--calibration.
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
ap.add_argument("--fit", default="validation", help="split the calibrations are fitted on")
ap.add_argument("--resamples", type=int, default=1000)
ap.add_argument("--seed", type=int, default=2026)
ap.add_argument("--stable-tol", type=float, default=0.05)
ap.add_argument("--rehist", action="store_true", help="recompute the per-scene histograms")
args = ap.parse_args()

cfg = load_config(); cm = cfg["model"]
run_dir = tof_path(args.run); suite = run_dir / "suite"; pred_dir = suite / "predictions"
log = setup_logging(suite / "calibration.log")
work = tof_path(cm["paths"]["work_dir"])
with open(run_dir / "results.json") as f:
    stored_threshold = float(json.load(f)["threshold"])

NB = 100
edges = np.linspace(0, 1, NB + 1)
centres = (edges[:-1] + edges[1:]) / 2

# ---- pass 1: per-scene histograms -------------------------------------------------
manifest = load_manifest(work)
pairs = manifest[manifest["status"] == "ok"].copy(); pairs["year"] = pairs["year"].astype(int)
hist_path = suite / "calibration_hist.npz"
if hist_path.exists() and not args.rehist:
    z = np.load(hist_path, allow_pickle=True)
    keys = list(z["keys"]); H_pos, H_neg, P_pos, P_neg, n_valid = z["H_pos"], z["H_neg"], z["P_pos"], z["P_neg"], z["n_valid"]
    px_m2 = z["px_m2"]
    log.info("histograms for %d scenes read from %s", len(keys), hist_path.name)
else:
    keys, rows_h = [], []
    for _, s in pairs.iterrows():
        p = pred_dir / f"{s['key']}_prob.tif"
        if not p.exists():
            log.warning("%s: no probability raster; skipped", s["key"]); continue
        mask, _, _, transform = read_pair(ROOT / s["mask"], ROOT / s["image"])
        with rasterio.open(p) as src:
            prob = src.read(1)
        valid = (mask != MASK_NODATA) & ~np.isnan(prob)
        pv, yv = prob[valid], mask[valid] == 1
        b = np.minimum((pv * NB).astype(np.int64), NB - 1)
        rows_h.append((np.bincount(b[yv], minlength=NB), np.bincount(b[~yv], minlength=NB),
                       np.bincount(b[yv], weights=pv[yv], minlength=NB), np.bincount(b[~yv], weights=pv[~yv], minlength=NB),
                       int(valid.sum()), abs(transform.a * transform.e)))
        keys.append(s["key"])
    H_pos = np.array([r[0] for r in rows_h]); H_neg = np.array([r[1] for r in rows_h])
    P_pos = np.array([r[2] for r in rows_h]); P_neg = np.array([r[3] for r in rows_h])
    n_valid = np.array([r[4] for r in rows_h]); px_m2 = np.array([r[5] for r in rows_h])
    np.savez_compressed(hist_path, keys=np.array(keys), H_pos=H_pos, H_neg=H_neg, P_pos=P_pos, P_neg=P_neg,
                        n_valid=n_valid, px_m2=px_m2)
    log.info("histograms for %d scenes written to %s", len(keys), hist_path.name)

scenes = pairs.set_index("key").loc[keys].reset_index()
meta = pd.read_csv(work / "scene_meta.csv", dtype={"id": str, "key": str, "MLRA_ID": str, "MLRARSYM": str})
scenes = scenes.merge(meta[["key", "cover_class", "MLRARSYM", "off_target", "transition_class"]], on="key", how="left")
scenes["year_kind"] = np.where(scenes["off_target"].astype(bool), "off_target", "target")
true_px = H_pos.sum(axis=1)
H_all = H_pos + H_neg
cum_above_all = np.cumsum(H_all[:, ::-1], axis=1)[:, ::-1]   # pixels with bin >= b
cum_above_pos = np.cumsum(H_pos[:, ::-1], axis=1)[:, ::-1]
fit = (scenes["split"] == args.fit).to_numpy()
log.info("%d scenes; fitting on %d %s scenes; stored threshold %.2f", len(scenes), fit.sum(), args.fit, stored_threshold)


def bin_of(t: float) -> int:
    return int(min(max(round(t * NB), 0), NB))


def pred_at(t: float, idx=None) -> np.ndarray:
    b = bin_of(t)
    c = cum_above_all if idx is None else cum_above_all[idx]
    return c[:, b] if b < NB else np.zeros(c.shape[0])


def tp_at(t: float, idx=None) -> np.ndarray:
    b = bin_of(t)
    c = cum_above_pos if idx is None else cum_above_pos[idx]
    return c[:, b] if b < NB else np.zeros(c.shape[0])


def pooled_f1(t: float, idx) -> float:
    tp = tp_at(t, idx).sum(); n_p = pred_at(t, idx).sum(); n_y = true_px[idx].sum()
    return 2 * tp / max(n_p + n_y, 1)


grid = np.round(np.arange(0.01, 1.0, 0.01), 2)
fit_idx = np.where(fit)[0]

# ---- fits on the fit split ----------------------------------------------------------
f1_curve = np.array([pooled_f1(t, fit_idx) for t in grid])
t_f1 = float(grid[int(np.argmax(f1_curve))])
area_curve = np.array([pred_at(t, fit_idx).sum() for t in grid]) / max(true_px[fit_idx].sum(), 1)
t_unb = float(grid[int(np.argmin(np.abs(area_curve - 1)))])
scale_stored = float(true_px[fit_idx].sum() / max(pred_at(stored_threshold, fit_idx).sum(), 1))
soft_px = (P_pos + P_neg).sum(axis=1)
scale_soft = float(true_px[fit_idx].sum() / max(soft_px[fit_idx].sum(), 1))


def pav(rate: np.ndarray, weight: np.ndarray) -> np.ndarray:
    """Pool-adjacent-violators: the non-decreasing sequence closest to `rate` in weighted least squares."""
    vals, wts, sizes = [], [], []
    for r, w in zip(rate, weight):
        vals.append(r); wts.append(w); sizes.append(1)
        while len(vals) > 1 and vals[-2] > vals[-1]:
            w2 = wts[-2] + wts[-1]
            v2 = (vals[-2] * wts[-2] + vals[-1] * wts[-1]) / max(w2, 1e-12)
            vals[-2:] = [v2]; wts[-2:] = [w2]; sizes[-2:] = [sizes[-2] + sizes[-1]]
    return np.concatenate([np.full(n, v) for v, n in zip(vals, sizes)])


bin_n = H_all[fit_idx].sum(axis=0); bin_pos = H_pos[fit_idx].sum(axis=0)
rate = np.where(bin_n > 0, bin_pos / np.maximum(bin_n, 1), centres)
iso = pav(rate, bin_n)                                  # calibrated tree probability per bin
soft_iso_px = (H_all * iso[None, :]).sum(axis=1)
log.info("fits on %s: F1-best threshold %.2f (F1 %.3f), area-unbiased threshold %.2f, area scale at stored threshold %.3f, "
         "soft scale %.3f", args.fit, t_f1, f1_curve.max(), t_unb, scale_stored, scale_soft)

# per-MLRA area-unbiased thresholds on train + validation
tv_idx = np.where(scenes["split"].isin(["train", "validation"]).to_numpy())[0]
t_mlra: dict[str, float] = {}
for m in sorted(scenes["MLRARSYM"].dropna().unique()):
    idx = tv_idx[scenes["MLRARSYM"].to_numpy()[tv_idx] == m]
    if len(idx) < 3 or true_px[idx].sum() == 0:
        t_mlra[m] = stored_threshold; continue
    curve = np.array([pred_at(t, idx).sum() for t in grid]) / true_px[idx].sum()
    t_mlra[m] = float(grid[int(np.argmin(np.abs(curve - 1)))])
log.info("per-MLRA area-unbiased thresholds (train + validation): %s", t_mlra)

# ---- per-scene predicted pixels per method ------------------------------------------
methods: dict[str, dict] = {
    "stored":        {"threshold": stored_threshold, "pred": pred_at(stored_threshold), "tp": tp_at(stored_threshold)},
    "f1_best":       {"threshold": t_f1, "pred": pred_at(t_f1), "tp": tp_at(t_f1)},
    "area_unbiased": {"threshold": t_unb, "pred": pred_at(t_unb), "tp": tp_at(t_unb)},
    "scaled":        {"threshold": stored_threshold, "area_scale": scale_stored,
                      "pred": pred_at(stored_threshold) * scale_stored, "tp": tp_at(stored_threshold)},
    "soft":          {"pred": soft_px},
    "soft_scaled":   {"area_scale": scale_soft, "pred": soft_px * scale_soft},
    "soft_isotonic": {"pred": soft_iso_px, "isotonic_bins": iso.tolist()},
}
mlra_arr = scenes["MLRARSYM"].to_numpy()
pm_pred = np.zeros(len(scenes)); pm_tp = np.zeros(len(scenes))
for i in range(len(scenes)):
    t = t_mlra.get(mlra_arr[i], stored_threshold)
    pm_pred[i] = cum_above_all[i, bin_of(t)] if bin_of(t) < NB else 0
    pm_tp[i] = cum_above_pos[i, bin_of(t)] if bin_of(t) < NB else 0
methods["per_mlra"] = {"thresholds": t_mlra, "pred": pm_pred, "tp": pm_tp, "flag": "fitted on train + validation; too few validation cells per MLRA"}

# ---- scoring ------------------------------------------------------------------------------
rng = np.random.default_rng(args.seed)
base = pd.DataFrame({"key": scenes["key"], "id": scenes["id"], "year": scenes["year"], "split": scenes["split"],
                     "MLRARSYM": scenes["MLRARSYM"], "cover_class": scenes["cover_class"], "year_kind": scenes["year_kind"],
                     "n_valid": n_valid, "px_m2": px_m2, "true_px": true_px})
base["true_share_pp"] = 100 * base["true_px"] / base["n_valid"]
base["true_m2"] = base["true_px"] * base["px_m2"]


def frame_for(m: dict) -> pd.DataFrame:
    d = base.copy()
    d["pred_px"] = m["pred"]; d["pred_m2"] = d["pred_px"] * d["px_m2"]
    d["pred_share_pp"] = 100 * d["pred_px"] / d["n_valid"]
    d["soft_px"] = d["pred_px"]; d["soft_m2"] = d["pred_m2"]; d["soft_share_pp"] = d["pred_share_pp"]
    if "tp" in m:
        d["tp"] = m["tp"]; d["fp"] = d["pred_px"] - d["tp"]; d["fn"] = d["true_px"] - d["tp"]
        d["f1"] = 2 * d["tp"] / np.maximum(d["pred_px"] + d["true_px"], 1)
    else:
        d["tp"] = d["fp"] = d["fn"] = 0; d["f1"] = np.nan
    d["f1_r1"] = d["f1_r2"] = np.nan
    return d


CHANGE_COLS = ["id", "split", "true_delta_pp", "pred_delta_pp", "soft_delta_pp"]


def changes_for(d: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for cid, g in d.groupby("id"):
        g = g.sort_values("year")
        for a, b in combinations(g.itertuples(index=False), 2):
            rows.append({"id": cid, "split": a.split, "true_delta_pp": b.true_share_pp - a.true_share_pp,
                         "pred_delta_pp": b.pred_share_pp - a.pred_share_pp, "soft_delta_pp": b.pred_share_pp - a.pred_share_pp})
    return pd.DataFrame(rows, columns=CHANGE_COLS)


t1_keys = ["area_bias_ratio", "share_bias_pp", "share_mae_pp", "share_rmse_pp", "calib_slope", "f1_pooled"]
t2_keys = ["delta_mae_pp", "delta_bias_pp", "false_change_p90_pp", "false_change_mean_abs_pp"]
card = {"run": run_dir.name, "fit_split": args.fit, "stored_threshold": stored_threshold,
        "fits": {"f1_best_threshold": t_f1, "area_unbiased_threshold": t_unb, "area_scale_at_stored": scale_stored,
                 "soft_scale": scale_soft, "per_mlra_thresholds": t_mlra,
                 "f1_curve": dict(zip(map(str, grid), f1_curve.round(4))), "area_curve": dict(zip(map(str, grid), area_curve.round(4))),
                 "isotonic_bins": iso.round(4).tolist(), "bin_tree_rate": rate.round(4).tolist(), "bin_n_fit": bin_n.tolist()},
        "methods": {}}
rows_out, scene_rows = [], []
for name, m in methods.items():
    d = frame_for(m)
    scene_rows.append(d.assign(method=name)[["method", "key", "id", "year", "split", "true_share_pp", "pred_share_pp", "f1"]])
    entry = {k: v for k, v in m.items() if k not in ("pred", "tp")}
    for pop in ("test", "heldout", "validation", "train"):
        dd = d[d["split"] == pop] if pop != "heldout" else d[d["split"].isin(["validation", "test"])]
        if len(dd) == 0:
            continue   # e.g. no training-scene rasters when the suite ran on the held-out splits only
        b = S.bootstrap(dd, S.scene_stats, args.resamples, rng)
        ch = changes_for(dd)
        c = S.bootstrap(ch, lambda x: S.change_stats(x, args.stable_tol), args.resamples, rng, group="id")
        entry[pop] = {"n_scenes": int(len(dd)), **{k: b[k] for k in t1_keys}, **{k: c[k] for k in t2_keys},
                      "by_mlra_bias": {mm: float(g["pred_m2"].sum() / g["true_m2"].sum()) if g["true_m2"].sum() > 0 else None
                                       for mm, g in dd.groupby("MLRARSYM")}}
        rows_out.append({"method": name, "population": pop, "n_scenes": len(dd),
                         **{k: b[k]["est"] for k in t1_keys}, **{f"{k}_lo": b[k]["lo"] for k in t1_keys}, **{f"{k}_hi": b[k]["hi"] for k in t1_keys},
                         **{k: c[k]["est"] for k in t2_keys}, **{f"{k}_lo": c[k]["lo"] for k in t2_keys}, **{f"{k}_hi": c[k]["hi"] for k in t2_keys}})
    card["methods"][name] = entry
    t = entry["test"]; h = entry["heldout"]
    log.info("%-14s test: bias %s  share MAE %s  F1 %s  delta MAE %s  false-change p90 %s | heldout bias %s", name,
             S.fmt(t["area_bias_ratio"]), S.fmt(t["share_mae_pp"]), S.fmt(t["f1_pooled"]), S.fmt(t["delta_mae_pp"]),
             S.fmt(t["false_change_p90_pp"]), S.fmt(h["area_bias_ratio"]))

# ---- recommendation --------------------------------------------------------------------------
# Primary metric (section 2.2): share MAE + delta MAE on held-out scenes, after calibration.
tbl = pd.DataFrame(rows_out)
held = tbl[tbl["population"] == "heldout"].set_index("method")
held["primary_pp"] = held["share_mae_pp"] + held["delta_mae_pp"]
ranking = held.sort_values("primary_pp")[["primary_pp", "share_mae_pp", "delta_mae_pp", "area_bias_ratio", "false_change_p90_pp"]]
log.info("held-out ranking by primary metric (share MAE + delta MAE, pp):\n%s", ranking.round(3).to_string())
best_hard = held.loc[["stored", "f1_best", "area_unbiased", "scaled"]].sort_values("primary_pp").index[0]
card["recommended"] = {"method": best_hard, "threshold": methods[best_hard].get("threshold", stored_threshold),
                       "area_scale": methods[best_hard].get("area_scale", 1.0),
                       "primary_pp_heldout": float(held.loc[best_hard, "primary_pp"]),
                       "best_overall": ranking.index[0], "note": "recommended = best thresholded method on held-out primary metric; "
                       "soft methods need no threshold but produce no binary raster"}
with open(suite / "calibration.json", "w") as f:
    json.dump(S.clean(card), f, indent=2)
tbl.to_csv(suite / "calibration_methods.csv", index=False)
pd.concat(scene_rows).to_csv(suite / "calibration_scenes.csv", index=False)
log.info("recommended thresholded method: %s (threshold %.2f, area scale %.3f); wrote %s", best_hard,
         card["recommended"]["threshold"], card["recommended"]["area_scale"], suite / "calibration.json")
