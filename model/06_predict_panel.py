#!/usr/bin/env python
"""Predict the evaluation panel (unlabelled cells) with one run: estimator rasters
per cell-year and the T5 self-consistency table.

    model/.venv/bin/python model/06_predict_panel.py --run data/model/runs/<run> [--cells <panel csv>] [--tranche 1]
        [--calibration <calibration.json>] [--threshold 0.2] [--device auto] [--limit N] [--repredict]

TESTING_PLAN.md sections 3.1 and 2.1 (T3b, T5). For every cell of the panel CSV
(config sampling.panel.out_csv by default) and every export folder
aoi_<id>_<year>/ holding naip_1km_<id>_<year>.tif, the model predicts the 1 km
scene and writes to <run>/panel/predictions/:

    <id>_<year>_prob.tif    tree probability (float32, NaN no data)
    tof_<id>_<year>.tif     1 tree / 0 not / 255 no data or inside the combined mask for that year

which is exactly what estimates/00_run_estimates.R reads in raster mode
(--model-dir <run>/panel/predictions --cells <panel csv> --eligible-from model).
Per cell-year, <run>/panel/panel_cells.csv holds the predicted tree share (all
valid pixels, and eligible land), the summed-probability share, the target and
actual year, capture month, states and item count from status.json, and the
harmoniser's KS drift where the harmonise log has the cell. panel_summary.json
gives T5: per year the mean predicted share, per cell the spread between years,
the share of cells whose predicted change between target years exceeds the
run's labelled false-change floor, and the cells the 20 % rule of
neymanSampling script 33 would flag for harmonisation.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from itertools import combinations
from pathlib import Path

import numpy as np
import pandas as pd
import rasterio
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))
from tofunet.config import load_config, pick_device, setup_logging, tof_path  # noqa: E402
from tofunet.model import load_checkpoint  # noqa: E402
from tofunet.predict import predict_scene, read_scene  # noqa: E402
from tofunet.suite.rasters import CombinedMask, pixel_area_m2, write_prob, write_tof  # noqa: E402
from tofunet.suite.stats import clean  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--run", required=True)
ap.add_argument("--cells", default=None, help="panel CSV with id (default: config sampling.panel.out_csv)")
ap.add_argument("--tranche", default=None, help="only rows whose tranche column matches")
ap.add_argument("--calibration", default=None, help="calibration.json: its recommended threshold is used")
ap.add_argument("--threshold", type=float, default=None)
ap.add_argument("--window", type=int, default=512)
ap.add_argument("--batch-size", type=int, default=8)
ap.add_argument("--device", default=None)
ap.add_argument("--limit", type=int, default=None, help="first N cells (smoke test)")
ap.add_argument("--repredict", action="store_true")
ap.add_argument("--false-change-floor-pp", type=float, default=None,
                help="pp of predicted change above which a stable cell counts as false change; default: the run's held-out "
                     "false_change_p90_pp from suite/scorecard.json, else 0.3")
args = ap.parse_args()

t_start = time.time()
cfg = load_config(); cm = cfg["model"]; cn = cfg["naip"]
run_dir = tof_path(args.run)
out_dir = run_dir / "panel"; pred_dir = out_dir / "predictions"
pred_dir.mkdir(parents=True, exist_ok=True)
log = setup_logging(out_dir / "panel.log")
torch.set_num_threads(int(cm["threads"]))

model, meta = load_checkpoint(run_dir / "best.pt")
device, device_desc = pick_device(args.device or cm.get("device", "auto")); model.to(device)
threshold = float(meta["threshold"]); calibration = "stored"
if args.calibration:
    with open(tof_path(args.calibration)) as f:
        rec = json.load(f)["recommended"]
    threshold, calibration = float(rec["threshold"]), rec["method"]
if args.threshold is not None:
    threshold, calibration = args.threshold, "manual"
mean, std = np.array(meta["band_stats"]["mean"]), np.array(meta["band_stats"]["std"])

cells_csv = tof_path(args.cells or cfg["sampling"]["panel"]["out_csv"])
panel = pd.read_csv(cells_csv, dtype={"id": str, "MLRA_ID": str, "MLRARSYM": str, "tranche": str})
if args.tranche:
    panel = panel[panel["tranche"] == str(args.tranche)]
panel = panel.drop_duplicates("id")
if args.limit:
    panel = panel.head(args.limit)
export_dir = tof_path(cn["paths"]["export_dir"])
target_years = [int(y) for y in cn["target_years"]]
masks_dir = tof_path(cfg["estimates"]["paths"]["masks_outputs"])
combined = CombinedMask(masks_dir, cm["llr_id"])
harm_path = tof_path(cfg["harmonize"]["paths"]["out_dir"]) / "harmonization_log.csv"
harm = pd.read_csv(harm_path, dtype={"id": str}) if harm_path.exists() else None
tags = {"model_run": meta["run_name"], "encoder": meta["encoder"], "threshold": threshold, "calibration": calibration}
log.info("Run %s on %s, threshold %.2f (%s): %d panel cells from %s%s", meta["run_name"], device_desc, threshold, calibration,
         len(panel), cells_csv.name, f" (tranche {args.tranche})" if args.tranche else "")


def read_status(folder: Path) -> dict:
    p = folder / "status.json"
    if not p.exists():
        return {}
    with open(p) as f:
        s = json.load(f)
    dates = sorted({d.strip()[:10] for d in str(s.get("capture_dates", "")).split(";") if d.strip()})
    states = sorted({x.strip() for x in str(s.get("naip_states", "")).split(";") if x.strip()})
    return {"target_year": s.get("target_year"), "actual_year": s.get("actual_year"), "status": s.get("status"),
            "capture_first": dates[0] if dates else None, "capture_month": int(dates[0][5:7]) if dates else None,
            "n_capture_months": len({d[:7] for d in dates}), "naip_states": "; ".join(states),
            "n_items": len([i for i in str(s.get("item_ids", "")).split(";") if i.strip()])}


rows = []
n_pred = n_missing = 0
for _, c in panel.iterrows():
    cid = c["id"]
    folders = sorted(export_dir.glob(f"aoi_{cid}_*"))
    found = 0
    for folder in folders:
        m = re.match(rf"aoi_{re.escape(cid)}_(\d{{4}})$", folder.name)
        if not m:
            continue
        year = int(m.group(1))
        image = folder / f"naip_1km_{cid}_{year}.tif"
        st = read_status(folder)
        if not image.exists() or st.get("status") not in (None, "Success"):
            continue
        found += 1
        t0 = time.time()
        prob_path = pred_dir / f"{cid}_{year}_prob.tif"
        if prob_path.exists() and not args.repredict:
            with rasterio.open(prob_path) as src:
                prob = src.read(1); crs, transform = src.crs, src.transform
            nodata = np.isnan(prob); prob = np.nan_to_num(prob, nan=0.0); source = "reused"
        else:
            img, nodata, profile = read_scene(image)
            crs, transform = profile["crs"], profile["transform"]
            prob = predict_scene(model, img, mean, std, args.window, args.batch_size, device)
            write_prob(prob_path, prob, nodata, crs, transform, tags | {"year": year}); source = "predicted"; n_pred += 1
        in_combined = combined.on_grid(year, crs, transform, prob.shape)
        valid = ~nodata; eligible = valid & ~in_combined
        pred = prob >= threshold
        write_tof(pred_dir / f"tof_{cid}_{year}.tif", pred, ~eligible, crs, transform, tags | {"year": year, "content": "model"})
        px = pixel_area_m2(transform)
        n_valid, n_elig = int(valid.sum()), int(eligible.sum())
        row = {"id": cid, "MLRA_ID": c.get("MLRA_ID"), "MLRARSYM": c.get("MLRARSYM"), "tranche": c.get("tranche"),
               "year": year, "target_year": st.get("target_year"), "actual_year": st.get("actual_year"),
               "fallback": (str(st.get("actual_year")) != str(st.get("target_year"))) if st.get("target_year") else None,
               "capture_first": st.get("capture_first"), "capture_month": st.get("capture_month"),
               "n_capture_months": st.get("n_capture_months"), "naip_states": st.get("naip_states"), "n_items": st.get("n_items"),
               "n_valid": n_valid, "n_eligible": n_elig, "valid_m2": n_valid * px, "eligible_m2": n_elig * px,
               "masked_frac": float((valid & in_combined).sum() / max(n_valid, 1)),
               "pred_px": int((pred & valid).sum()), "soft_px": float(prob[valid].sum()),
               "pred_px_elig": int((pred & eligible).sum()), "soft_px_elig": float(prob[eligible].sum()),
               "source": source, "seconds": time.time() - t0}
        row["pred_share_pp"] = 100 * row["pred_px"] / max(n_valid, 1)
        row["soft_share_pp"] = 100 * row["soft_px"] / max(n_valid, 1)
        row["pred_share_elig_pp"] = 100 * row["pred_px_elig"] / max(n_elig, 1)
        row["pred_m2_elig"] = row["pred_px_elig"] * px
        if harm is not None:
            h = harm[(harm["id"] == cid) & (harm["year"].astype(int) == year)]
            if len(h):
                row["harm_action"] = h.iloc[0]["action"]; row["harm_ks_to_reference"] = h.iloc[0]["ks_to_reference"]
        rows.append(row)
    if found == 0:
        n_missing += 1
    else:
        log.info("%-16s %d years  %s", cid, found, "  ".join(f"{r['year']}:{r['pred_share_pp']:.2f}pp" for r in rows[-found:]))
combined.close()
cells = pd.DataFrame(rows)
cells.to_csv(out_dir / "panel_cells.csv", index=False)
log.info("%d cells with exports, %d without; %d cell-years (%d predicted, %d reused) in %.0f s",
         panel["id"].nunique() - n_missing, n_missing, len(cells), n_pred, len(cells) - n_pred, time.time() - t_start)

# ---- T5: self-consistency ----------------------------------------------------------------------
floor = args.false_change_floor_pp
if floor is None:
    sc = run_dir / "suite" / "scorecard.json"
    if sc.exists():
        try:
            floor = json.load(open(sc))["change"]["heldout"]["false_change_p90_pp"]["est"]
        except KeyError:
            floor = None
    floor = 0.3 if floor is None else float(floor)
summary = {"run": run_dir.name, "threshold": threshold, "calibration": calibration, "cells_csv": cells_csv.name,
           "tranche": args.tranche, "n_cells": int(cells["id"].nunique()) if len(cells) else 0, "n_cell_years": int(len(cells)),
           "false_change_floor_pp": floor, "by_year": {}, "by_target_year": {}, "change": {}, "harmonisation_rule": {}}
if len(cells):
    cells["target_year"] = pd.to_numeric(cells["target_year"], errors="coerce")
    for y, g in cells.groupby("year"):
        summary["by_year"][str(y)] = {"n": int(len(g)), "mean_pred_share_pp": float(g["pred_share_pp"].mean()),
                                      "median_pred_share_pp": float(g["pred_share_pp"].median()),
                                      "share_zero": float((g["pred_px"] == 0).mean())}
    for y, g in cells.dropna(subset=["target_year"]).groupby("target_year"):
        summary["by_target_year"][str(int(y))] = {"n": int(len(g)), "mean_pred_share_pp": float(g["pred_share_pp"].mean()),
                                                  "fallback_share": float(g["fallback"].astype(bool).mean())}
    pairs = []
    for cid, g in cells.dropna(subset=["target_year"]).groupby("id"):
        g = g.sort_values("target_year").drop_duplicates("target_year")
        for a, b in combinations(g.itertuples(index=False), 2):
            pairs.append({"id": cid, "MLRARSYM": a.MLRARSYM, "ty_a": int(a.target_year), "ty_b": int(b.target_year),
                          "delta_pp": b.pred_share_pp - a.pred_share_pp, "either_fallback": bool(a.fallback) or bool(b.fallback),
                          "mean_share_pp": (a.pred_share_pp + b.pred_share_pp) / 2})
    pairs = pd.DataFrame(pairs)
    if len(pairs):
        pairs.to_csv(out_dir / "panel_changes.csv", index=False)
        summary["change"] = {"n_pairs": int(len(pairs)), "abs_delta_mean_pp": float(pairs["delta_pp"].abs().mean()),
                             "abs_delta_p50_pp": float(pairs["delta_pp"].abs().median()), "abs_delta_p90_pp": float(pairs["delta_pp"].abs().quantile(0.9)),
                             "share_above_floor": float((pairs["delta_pp"].abs() > floor).mean()),
                             "share_above_floor_fallback_pairs": float((pairs[pairs["either_fallback"]]["delta_pp"].abs() > floor).mean()) if pairs["either_fallback"].any() else None,
                             "share_above_floor_target_pairs": float((pairs[~pairs["either_fallback"]]["delta_pp"].abs() > floor).mean()) if (~pairs["either_fallback"]).any() else None,
                             "by_pair": {f"{a}-{b}": {"n": int(len(g)), "mean_delta_pp": float(g["delta_pp"].mean()), "abs_delta_p90_pp": float(g["delta_pp"].abs().quantile(0.9))}
                                         for (a, b), g in pairs.groupby(["ty_a", "ty_b"])}}
    # The 20 % rule of neymanSampling/scripts/33: (max - min) / max of a cell's yearly tree area above 0.2 -> harmonisation candidate
    spread = cells.groupby("id").agg(n_years=("year", "size"), pmin=("pred_share_pp", "min"), pmax=("pred_share_pp", "max"), MLRARSYM=("MLRARSYM", "first"))
    spread = spread[spread["n_years"] >= 2]
    spread["rel_range"] = np.where(spread["pmax"] > 0, (spread["pmax"] - spread["pmin"]) / spread["pmax"], 0.0)
    spread["abs_range_pp"] = spread["pmax"] - spread["pmin"]
    flagged = spread[(spread["rel_range"] > 0.2) & (spread["abs_range_pp"] > floor)]
    spread.to_csv(out_dir / "panel_cell_spread.csv")
    summary["harmonisation_rule"] = {"cells_with_2plus_years": int(len(spread)), "flagged_rel20_and_above_floor": int(len(flagged)),
                                     "flagged_share": float(len(flagged) / max(len(spread), 1)),
                                     "flagged_ids": flagged.index.tolist()[:200]}
with open(out_dir / "panel_summary.json", "w") as f:
    json.dump(clean(summary), f, indent=2)
if summary["change"]:
    ch = summary["change"]
    log.info("T5: %d year pairs; |delta| median %.3f pp, p90 %.3f pp; %.1f%% of pairs above the %.2f pp floor (target-only pairs %s, fallback pairs %s)",
             ch["n_pairs"], ch["abs_delta_p50_pp"], ch["abs_delta_p90_pp"], 100 * ch["share_above_floor"], floor,
             "NA" if ch["share_above_floor_target_pairs"] is None else f"{100 * ch['share_above_floor_target_pairs']:.1f}%",
             "NA" if ch["share_above_floor_fallback_pairs"] is None else f"{100 * ch['share_above_floor_fallback_pairs']:.1f}%")
    hr = summary["harmonisation_rule"]
    log.info("20 %% rule: %d of %d cells flagged (%.1f%%)", hr["flagged_rel20_and_above_floor"], hr["cells_with_2plus_years"], 100 * hr["flagged_share"])
log.info("wrote %s", out_dir / "panel_summary.json")
