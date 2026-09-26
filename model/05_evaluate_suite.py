#!/usr/bin/env python
"""The evaluation suite: predict every held-out scene once, write the rasters the
estimator reads, and score tiers T0 (pixel), T1 (area) and T2 (change).

    model/.venv/bin/python model/05_evaluate_suite.py --run data/model/runs/<run> [--splits validation,test|all]
        [--threshold 0.2] [--device auto] [--resamples 1000] [--limit N] [--repredict]

TESTING_PLAN.md sections 4 and 9.2 (step 3). Per prepared pair of the chosen
splits the model predicts the mask's window of the 1 km export with
`tofunet.predict.predict_scene` (device-agnostic: CPU, CUDA or ROCm), and writes to
<run>/suite/predictions/:

    <key>_prob.tif         tree probability, float32, NaN where the scene has no data
    tof_<id>_<year>.tif    1 tree / 0 not / 255 excluded: the estimator's format
    tof_truth_<id>_<year>.tif  the reference mask in the same format

"Excluded" is scene no data, mask no data, or inside the masks stage's combined
mask (NLCD forest or Census place) for the imagery year, so model and truth
rasters cover identical pixels. A probability raster that already exists is
reused unless --repredict is given, so the scorecard can be rebuilt on any host.

Scores per scene: strict confusion counts on valid pixels; boundary-tolerant
precision / recall / F1 at 1 and 2 m; best-F1 and area-unbiased thresholds;
tree share over all valid pixels, predicted (at the threshold and as summed
probability) against the mask, with the same on eligible land as *_elig. The
model is a model of every tree; the mask is the estimator's business. Per cell
and year pair: the change in share.
Scorecard with 1,000-resample bootstrap intervals over scenes (T0, T1) and
over cells (T2), sliced by the scene metadata table. One row is appended to
data/model/runs/registry.csv.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import subprocess
import sys
import time
from itertools import combinations
from pathlib import Path

import numpy as np
import pandas as pd
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))
from tofunet.config import ROOT, load_config, pick_device, setup_logging, tof_path  # noqa: E402
from tofunet.data import load_manifest  # noqa: E402
from tofunet.model import load_checkpoint  # noqa: E402
from tofunet.predict import predict_scene, read_scene  # noqa: E402
from tofunet.suite import metrics as M  # noqa: E402
from tofunet.suite import stats as S  # noqa: E402
from tofunet.suite.rasters import MASK_NODATA, CombinedMask, pixel_area_m2, read_pair, write_prob, write_tof  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--run", required=True)
ap.add_argument("--splits", default="validation,test", help="comma list of train/validation/test, or 'all'")
ap.add_argument("--threshold", type=float, default=None, help="default: the run's stored threshold")
ap.add_argument("--window", type=int, default=512)
ap.add_argument("--batch-size", type=int, default=8)
ap.add_argument("--device", default=None)
ap.add_argument("--resamples", type=int, default=1000)
ap.add_argument("--seed", type=int, default=2026)
ap.add_argument("--min-scenes", type=int, default=5)
ap.add_argument("--stable-tol", type=float, default=0.05, help="pp of true change below which a year pair is 'stable'")
ap.add_argument("--limit", type=int, default=None, help="score only the first N pairs (smoke test)")
ap.add_argument("--repredict", action="store_true", help="ignore existing probability rasters")
ap.add_argument("--meta", default=None, help="default: <work_dir>/scene_meta.csv")
ap.add_argument("--calibration", default=None,
                help="a calibration.json from tools/calibrate_threshold.py: its recommended threshold and area scale are applied "
                     "(the scale multiplies predicted area in T1 and T2; rasters are still written at the threshold)")
args = ap.parse_args()

t_start = time.time()
cfg = load_config(); cm = cfg["model"]
run_dir = tof_path(args.run)
suite = run_dir / "suite"; pred_dir = suite / "predictions"
pred_dir.mkdir(parents=True, exist_ok=True)
log = setup_logging(suite / "suite.log")
torch.set_num_threads(int(cm["threads"]))
work = tof_path(cm["paths"]["work_dir"])

model, meta = load_checkpoint(run_dir / "best.pt")
device, device_desc = pick_device(args.device or cm.get("device", "auto")); model.to(device)
threshold = args.threshold if args.threshold is not None else float(meta["threshold"])
area_scale, calibration = 1.0, "none"
if args.calibration:
    with open(tof_path(args.calibration)) as f:
        rec = json.load(f)["recommended"]
    threshold = float(rec["threshold"]) if args.threshold is None else threshold
    area_scale = float(rec.get("area_scale", 1.0)); calibration = rec["method"]
mean, std = np.array(meta["band_stats"]["mean"]), np.array(meta["band_stats"]["std"])
splits = ["train", "validation", "test"] if args.splits == "all" else [s.strip() for s in args.splits.split(",")]

manifest = load_manifest(work)
pairs = manifest[(manifest["status"] == "ok") & (manifest["split"].isin(splits))].copy()
pairs["year"] = pairs["year"].astype(int)
pairs = pairs.sort_values(["id", "year"]).reset_index(drop=True)
if args.limit:
    pairs = pairs.head(args.limit)
log.info("Run %s on %s (%s), threshold %.2f, calibration %s (area scale %.3f): %d scenes in %s", meta["run_name"],
         device_desc, platform.node(), threshold, calibration, area_scale, len(pairs), splits)

masks_dir = tof_path(cfg["estimates"]["paths"]["masks_outputs"])
combined = CombinedMask(masks_dir, cm["llr_id"])
tags = {"model_run": meta["run_name"], "encoder": meta["encoder"], "threshold": threshold,
        "combined_mask": f"{masks_dir.name}/llr_{cm['llr_id']}_mask_<year>.tif (30 m raster, nearest)"}

# ---- per scene ---------------------------------------------------------------
rows = []
n_pred = 0
for i, s in pairs.iterrows():
    t0 = time.time()
    mask_path, image_path = ROOT / s["mask"], ROOT / s["image"]
    mask, w_img, crs, transform = read_pair(mask_path, image_path)
    prob_path = pred_dir / f"{s['key']}_prob.tif"
    if prob_path.exists() and not args.repredict:
        import rasterio
        with rasterio.open(prob_path) as src:
            prob = src.read(1)
        nodata = np.isnan(prob); prob = np.nan_to_num(prob, nan=0.0)
        source = "reused"
    else:
        img, nodata, _ = read_scene(image_path, window=w_img)
        prob = predict_scene(model, img, mean, std, args.window, args.batch_size, device)
        write_prob(prob_path, prob, nodata, crs, transform, tags | {"mask_year": int(s["year"])})
        source = "predicted"; n_pred += 1
    if prob.shape != mask.shape:
        raise RuntimeError(f"{s['key']}: probability {prob.shape} and mask {mask.shape} differ")

    year = int(s["year"])
    in_combined = combined.on_grid(year, crs, transform, mask.shape)
    valid = (mask != MASK_NODATA) & ~nodata
    eligible = valid & ~in_combined
    truth = mask == 1
    pred = prob >= threshold
    px_m2 = pixel_area_m2(transform)

    write_tof(pred_dir / f"tof_{s['id']}_{year}.tif", pred, ~eligible, crs, transform, tags | {"mask_year": year, "content": "model"})
    write_tof(pred_dir / f"tof_truth_{s['id']}_{year}.tif", truth, ~eligible, crs, transform, tags | {"mask_year": year, "content": "reference mask"})

    # The model predicts every tree; the combined mask is the estimator's business.
    # So the primary scores are over all valid pixels, and the eligible-land
    # (outside the combined mask) versions are kept alongside as *_elig.
    c = M.counts(pred, truth, valid)
    ce = M.counts(pred, truth, eligible)
    n_valid, n_elig = int(valid.sum()), int(eligible.sum())
    true_px, pred_px, soft_px = int((truth & valid).sum()), area_scale * int((pred & valid).sum()), float(prob[valid].sum())
    true_e, pred_e, soft_e = int((truth & eligible).sum()), area_scale * int((pred & eligible).sum()), float(prob[eligible].sum())
    row = {"key": s["key"], "id": s["id"], "year": year, "split": s["split"], "threshold": threshold,
           "source": source, "height": mask.shape[0], "width": mask.shape[1], "pixel_m2": px_m2,
           "n_valid": n_valid, "valid_m2": n_valid * px_m2, "n_eligible": n_elig, "eligible_m2": n_elig * px_m2,
           "masked_frac": float((valid & in_combined).sum() / max(n_valid, 1)),
           "truth_in_combined_px": int((truth & valid & in_combined).sum()),
           **c, **M.scores(c),
           **{f"{k}_elig": v for k, v in ce.items()},
           **M.relaxed(pred, truth, valid, 1), **M.relaxed(pred, truth, valid, 2),
           **M.sweep(prob, truth, valid),
           "true_px": true_px, "pred_px": pred_px, "soft_px": soft_px,
           "true_m2": true_px * px_m2, "pred_m2": pred_px * px_m2, "soft_m2": soft_px * px_m2,
           "true_share_pp": 100 * true_px / max(n_valid, 1), "pred_share_pp": 100 * pred_px / max(n_valid, 1),
           "soft_share_pp": 100 * soft_px / max(n_valid, 1),
           "true_px_elig": true_e, "pred_px_elig": pred_e, "soft_px_elig": soft_e,
           "true_m2_elig": true_e * px_m2, "pred_m2_elig": pred_e * px_m2, "soft_m2_elig": soft_e * px_m2,
           "true_share_elig_pp": 100 * true_e / max(n_elig, 1), "pred_share_elig_pp": 100 * pred_e / max(n_elig, 1),
           "soft_share_elig_pp": 100 * soft_e / max(n_elig, 1),
           "seconds": time.time() - t0}
    rows.append(row)
    log.info("%-22s %-10s %4d  F1 %.3f  r1 %.3f  share true %.3f pred %.3f pp  masked %.1f%%  %s %.1fs",
             s["key"], s["split"], year, row["f1"], row["f1_r1"], row["true_share_pp"], row["pred_share_pp"],
             100 * row["masked_frac"], source, row["seconds"])
combined.close()
scenes = pd.DataFrame(rows)
log.info("%d scenes scored, %d predicted, %d reused, %.0f s", len(scenes), n_pred, len(scenes) - n_pred, time.time() - t_start)

# ---- metadata ------------------------------------------------------------------
meta_path = tof_path(args.meta) if args.meta else work / "scene_meta.csv"
if meta_path.exists():
    sm = pd.read_csv(meta_path, dtype={"id": str, "key": str, "MLRA_ID": str, "MLRARSYM": str, "actual_year": str})
    cols = ["key", "cover_class", "transition_class", "CLUSTER_ID", "tree_percentage", "MLRA_ID", "MLRARSYM",
            "off_target", "actual_year", "capture_month", "two_month_mosaic", "naip_state", "harm_action",
            "harm_ks_to_reference", "in_sample_list"]
    scenes = scenes.merge(sm[cols], on="key", how="left", validate="one_to_one")
    scenes["year_kind"] = np.where(scenes["off_target"].fillna(False).astype(bool), "off_target", "target")
    scenes["harm_action"] = scenes["harm_action"].fillna("none")
    scenes["capture_month"] = scenes["capture_month"].astype("Int64")
else:
    log.warning("no scene metadata at %s; slices are unavailable (run tools/build_scene_meta.py)", meta_path)
    scenes["year_kind"] = "unknown"

scenes.to_csv(suite / "t0_scenes.csv", index=False)
t1_cols = ["key", "id", "year", "split", "n_valid", "valid_m2", "n_eligible", "eligible_m2", "masked_frac",
           "truth_in_combined_px", "true_px", "pred_px", "soft_px", "true_m2", "pred_m2", "soft_m2",
           "true_share_pp", "pred_share_pp", "soft_share_pp", "true_px_elig", "pred_px_elig", "soft_px_elig",
           "true_m2_elig", "pred_m2_elig", "soft_m2_elig", "true_share_elig_pp", "pred_share_elig_pp",
           "soft_share_elig_pp", "area_unbiased_threshold"]
scenes[t1_cols].to_csv(suite / "t1_scenes.csv", index=False)

# ---- T2: change per cell and year pair -----------------------------------------
pairs_rows = []
for cid, d in scenes.groupby("id"):
    d = d.sort_values("year")
    for a, b in combinations(d.itertuples(index=False), 2):
        pairs_rows.append({"id": cid, "split": a.split, "year_a": a.year, "year_b": b.year,
                           "years_apart": b.year - a.year,
                           "true_delta_pp": b.true_share_pp - a.true_share_pp,
                           "pred_delta_pp": b.pred_share_pp - a.pred_share_pp,
                           "soft_delta_pp": b.soft_share_pp - a.soft_share_pp,
                           "true_delta_m2": b.true_m2 - a.true_m2, "pred_delta_m2": b.pred_m2 - a.pred_m2,
                           "either_off_target": (a.year_kind == "off_target") or (b.year_kind == "off_target"),
                           "cover_class": getattr(a, "cover_class", None),
                           "transition_class": getattr(a, "transition_class", None),
                           "MLRARSYM": getattr(a, "MLRARSYM", None)})
changes = pd.DataFrame(pairs_rows)
changes.to_csv(suite / "t2_changes.csv", index=False)

# ---- scorecard -------------------------------------------------------------------
rng = np.random.default_rng(args.seed)
populations = {sp: scenes[scenes["split"] == sp] for sp in splits if (scenes["split"] == sp).any()}
if {"validation", "test"} <= set(populations):
    populations["heldout"] = scenes[scenes["split"].isin(["validation", "test"])]
slice_cols = [c for c in ["cover_class", "year", "year_kind", "capture_month", "naip_state", "MLRARSYM",
                          "transition_class", "two_month_mosaic", "harm_action"] if c in scenes]
card: dict = {"run": run_dir.name, "threshold": threshold, "calibration": calibration, "area_scale": area_scale,
              "splits": splits, "resamples": args.resamples,
              "seed": args.seed, "stable_tol_pp": args.stable_tol, "device": device_desc, "host": platform.node(),
              "note": ("T1 shares and T2 deltas are over all valid pixels: the model predicts every tree, and the "
                       "combined mask is applied downstream by the estimator. *_elig keys repeat them on eligible land "
                       "(outside the combined mask, 30 m raster, nearest)."),
              "populations": {}, "slices": {}, "change": {}, "gaps": {}}
rows_out = []
for pop, d in populations.items():
    card["populations"][pop] = {"n_scenes": int(len(d)), "n_cells": int(d["id"].nunique()),
                                **S.bootstrap(d, S.scene_stats, args.resamples, rng)}
    ch = changes[changes["id"].isin(d["id"])] if pop == "heldout" else changes[changes["split"] == pop]
    if len(ch):
        card["change"][pop] = {"n_cells": int(ch["id"].nunique()),
                               **S.bootstrap(ch, lambda x: S.change_stats(x, args.stable_tol), args.resamples, rng, group="id")}
    if pop in ("test", "heldout"):
        card["slices"][pop] = {}
        for col in slice_cols:
            card["slices"][pop][col] = {}
            for level, g in d.groupby(col, dropna=False, sort=True):
                key = "NA" if pd.isna(level) else str(level)
                b = S.bootstrap(g, S.scene_stats, args.resamples, rng)
                card["slices"][pop][col][key] = {"n_scenes": int(len(g)), "small": bool(len(g) < args.min_scenes), **b}
                rows_out.append({"population": pop, "slice": col, "level": key, "n_scenes": len(g),
                                 "small": len(g) < args.min_scenes,
                                 **{k: v["est"] for k, v in b.items()},
                                 **{f"{k}_lo": v["lo"] for k, v in b.items()},
                                 **{f"{k}_hi": v["hi"] for k, v in b.items()}})
        gap_keys = ["f1_scene_mean", "f1_pooled", "area_bias_ratio", "share_mae_pp", "share_bias_pp"]
        on, off = d[d["year_kind"] == "target"], d[d["year_kind"] == "off_target"]
        card["gaps"][pop] = {"target_minus_off_target": {"n_target": int(len(on)), "n_off_target": int(len(off)),
                                                         **S.bootstrap_diff(on, off, S.scene_stats, args.resamples, rng, gap_keys)}}
        if "cover_class" in d:
            c3, c1 = d[d["cover_class"].astype(str).str.startswith("c3")], d[d["cover_class"].astype(str).str.startswith("c1")]
            card["gaps"][pop]["c3_minus_c1"] = {"n_c3": int(len(c3)), "n_c1": int(len(c1)),
                                                **S.bootstrap_diff(c3, c1, S.scene_stats, args.resamples, rng, gap_keys)}

with open(suite / "scorecard.json", "w") as f:
    json.dump(S.clean(card), f, indent=2)
pd.DataFrame(rows_out).to_csv(suite / "scorecard_slices.csv", index=False)

# ---- registry ----------------------------------------------------------------------
def git(*a) -> str:
    try:
        return subprocess.run(["git", *a], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        return ""


cfg_hash = hashlib.sha1((run_dir / "config.json").read_bytes()).hexdigest()[:10]
headline = card["populations"].get("heldout") or card["populations"].get("test") or next(iter(card["populations"].values()))
change_head = card["change"].get("heldout") or card["change"].get("test") or {}
reg_row = {"timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"), "run": run_dir.name, "git_commit": git("rev-parse", "--short", "HEAD"),
           "git_dirty": bool(git("status", "--porcelain")), "config_hash": cfg_hash, "encoder": meta["encoder"],
           "seed": meta.get("seed", json.load(open(run_dir / "config.json")).get("seed")), "partition": cm["partition"],
           "threshold": threshold, "calibration": calibration, "area_scale": area_scale, "splits": "+".join(splits),
           "n_scenes": int(len(scenes)),
           "f1_pooled": headline["f1_pooled"]["est"], "f1_scene_mean": headline["f1_scene_mean"]["est"],
           "f1_r1_scene_mean": headline["f1_r1_scene_mean"]["est"], "area_bias_ratio": headline["area_bias_ratio"]["est"],
           "share_mae_pp": headline["share_mae_pp"]["est"], "soft_area_bias_ratio": headline["soft_area_bias_ratio"]["est"],
           "delta_mae_pp": change_head.get("delta_mae_pp", {}).get("est"),
           "false_change_p90_pp": change_head.get("false_change_p90_pp", {}).get("est"),
           "wall_s": round(time.time() - t_start), "host": platform.node(), "device": device_desc,
           "limit": args.limit or ""}
registry = run_dir.parent / "registry.csv"
reg = pd.DataFrame([reg_row])
if registry.exists():   # align on column names, so a new column never shifts older rows
    reg = pd.concat([pd.read_csv(registry), reg], ignore_index=True)
tmp = registry.with_suffix(".csv.tmp")   # write whole, then rename, so a concurrent reader never sees a half file
reg.to_csv(tmp, index=False); tmp.replace(registry)

# ---- headline ------------------------------------------------------------------------
for pop, p in card["populations"].items():
    log.info("%-10s n=%3d  F1 pooled %s  relaxed-1m %s  area bias %s  soft bias %s  share MAE pp %s  calib slope %s",
             pop, p["n_scenes"], S.fmt(p["f1_pooled"]), S.fmt(p["f1_r1_scene_mean"]), S.fmt(p["area_bias_ratio"]),
             S.fmt(p["soft_area_bias_ratio"]), S.fmt(p["share_mae_pp"]), S.fmt(p["calib_slope"], 2))
for pop, c in card["change"].items():
    log.info("%-10s change: %d pairs over %d cells  delta MAE pp %s  bias pp %s  false change p90 pp %s (stable pairs %d)",
             pop, int(c["n_pairs"]["est"]), c["n_cells"], S.fmt(c["delta_mae_pp"]), S.fmt(c["delta_bias_pp"]),
             S.fmt(c["false_change_p90_pp"]), int(c["n_stable"]["est"]))
for pop, g in card["gaps"].items():
    for name, gg in g.items():
        for k in ("f1_scene_mean", "area_bias_ratio"):
            e = gg[k]
            log.info("%s %s %s: %+.3f [%+.3f, %+.3f]%s", pop, name, k, e["est"], e["lo"], e["hi"],
                     "" if e["excludes_zero"] else "  (covers zero)")
log.info("wrote %s  (%d s total)", suite / "scorecard.json", round(time.time() - t_start))
