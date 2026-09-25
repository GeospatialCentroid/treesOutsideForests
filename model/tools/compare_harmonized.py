#!/usr/bin/env python
"""Score a run on the masked scenes the harmonise step remapped, raw versus harmonised.

    model/.venv/bin/python model/tools/compare_harmonized.py --run data/model/runs/<run> [--threshold 0.2]

For every prepared pair (manifest status ok) whose cell-year the harmonised
tree lists as "normalized", the model predicts the same mask window from the
raw export and from the harmonised GeoTIFF; both are scored against the mask.
Writes <run>/harmonized_compare_thr<t>.csv (one row per scene and source) and
prints the pooled scores for the training scenes and the held-out ones.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import rasterio
import torch
from rasterio.windows import Window

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from tofunet.config import ROOT, load_config, pick_device, setup_logging, tof_path  # noqa: E402
from tofunet.data import MASK_NODATA, load_manifest  # noqa: E402
from tofunet.model import load_checkpoint  # noqa: E402
from tofunet.predict import predict_scene, read_scene  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--run", required=True)
ap.add_argument("--threshold", type=float, default=None, help="default: the run's stored threshold")
ap.add_argument("--window", type=int, default=512)
ap.add_argument("--batch-size", type=int, default=4)
ap.add_argument("--device", default=None)
ap.add_argument("--harmonized-dir", default=None, help="default: config harmonize.paths.out_dir")
args = ap.parse_args()

cfg = load_config(); cm = cfg["model"]; ch = cfg["harmonize"]
torch.set_num_threads(int(cm["threads"]))
run_dir = tof_path(args.run)
log = setup_logging(run_dir / "harmonized_compare.log")
model, meta = load_checkpoint(run_dir / "best.pt")
device, device_desc = pick_device(args.device or cm.get("device", "auto")); model.to(device)
threshold = args.threshold if args.threshold is not None else float(meta["threshold"])
mean, std = np.array(meta["band_stats"]["mean"]), np.array(meta["band_stats"]["std"])

export_root = tof_path(ch["paths"]["export_dir"]).resolve()
harm_root = tof_path(args.harmonized_dir or ch["paths"]["out_dir"]).resolve()
harm_log = pd.read_csv(harm_root / "harmonization_log.csv", dtype={"id": str, "year": str})
remapped = harm_log[harm_log["action"] == "normalized"].set_index(["id", "year"])
manifest = load_manifest(tof_path(cm["paths"]["work_dir"]))
pairs = manifest[manifest["status"] == "ok"].copy()
pairs["year"] = pairs["year"].astype(int).astype(str)
pairs = pairs[[(i, y) in remapped.index for i, y in zip(pairs["id"], pairs["year"])]].reset_index(drop=True)
log.info("Run %s on %s, threshold %.2f: %d masked scenes were remapped (%s)", meta["run_name"], device_desc, threshold,
         len(pairs), pairs["split"].value_counts().to_dict())


def mask_window(ms, im) -> tuple[Window, Window]:
    """The overlap of mask and image, as a window in each (01_prepare.py's alignment)."""
    tm, ti = ms.transform, im.transform
    col_off = int(round((tm.c - ti.c) / ti.a)); row_off = int(round((tm.f - ti.f) / ti.e))
    c0, r0 = max(col_off, 0), max(row_off, 0)
    c1, r1 = min(col_off + ms.width, im.width), min(row_off + ms.height, im.height)
    return Window(c0, r0, c1 - c0, r1 - r0), Window(c0 - col_off, r0 - row_off, c1 - c0, r1 - r0)


def score(prob: np.ndarray, mask: np.ndarray, valid: np.ndarray) -> dict:
    pred = (prob >= threshold)[valid]; y = (mask == 1)[valid]
    tp = int((pred & y).sum()); fp = int(pred.sum()) - tp; fn = int(y.sum()) - tp
    return {"tp": tp, "fp": fp, "fn": fn, "precision": tp / max(tp + fp, 1), "recall": tp / max(tp + fn, 1),
            "f1": 2 * tp / max(2 * tp + fp + fn, 1), "iou": tp / max(tp + fp + fn, 1)}


rows = []
for _, s in pairs.iterrows():
    raw = ROOT / s["image"]
    harm = harm_root / raw.resolve().relative_to(export_root)
    ref = remapped.loc[(s["id"], s["year"])]
    with rasterio.open(ROOT / s["mask"]) as ms, rasterio.open(raw) as im:
        w_img, w_mask = mask_window(ms, im)
        mask = ms.read(1, window=w_mask).astype(np.uint8)
    mask[(mask != 0) & (mask != 1)] = MASK_NODATA
    for source, path in (("raw", raw), ("harmonised", harm)):
        img, nodata, _ = read_scene(path, window=w_img)
        prob = predict_scene(model, img, mean, std, args.window, args.batch_size, device)
        r = score(prob, mask, (mask != MASK_NODATA) & ~nodata)
        rows.append({"key": s["key"], "id": s["id"], "year": s["year"], "split": s["split"],
                     "group": "train" if s["split"] == "train" else "held_out",
                     "reference_year": ref["reference_year"], "ks_to_reference": ref["ks_to_reference"],
                     "source": source, **r})
    a, b = rows[-2], rows[-1]
    log.info("%-22s %-10s ref %s  F1 raw %.3f harmonised %.3f  recall raw %.3f harmonised %.3f",
             s["key"], s["split"], ref["reference_year"], a["f1"], b["f1"], a["recall"], b["recall"])

df = pd.DataFrame(rows)
out = run_dir / f"harmonized_compare_thr{threshold:.2f}.csv"
df.to_csv(out, index=False)


def pooled(d: pd.DataFrame) -> pd.Series:
    tp, fp, fn = d["tp"].sum(), d["fp"].sum(), d["fn"].sum()
    return pd.Series({"scenes": len(d), "precision": tp / max(tp + fp, 1), "recall": tp / max(tp + fn, 1),
                      "f1": 2 * tp / max(2 * tp + fp + fn, 1), "iou": tp / max(tp + fp + fn, 1)})


table = df.groupby(["group", "source"]).apply(pooled, include_groups=False).unstack("source")
log.info("Pooled over the remapped scenes (threshold %.2f):\n%s", threshold, table.round(3).to_string())
wide = df.pivot(index="key", columns="source", values="f1")
log.info("Harmonised beat raw on %d of %d held-out scenes and %d of %d training scenes.",
         int((wide.loc[df[df.group == "held_out"].key.unique(), "harmonised"] > wide.loc[df[df.group == "held_out"].key.unique(), "raw"]).sum()),
         df[df.group == "held_out"].key.nunique(),
         int((wide.loc[df[df.group == "train"].key.unique(), "harmonised"] > wide.loc[df[df.group == "train"].key.unique(), "raw"]).sum()),
         df[df.group == "train"].key.nunique())
log.info("Per-scene table: %s", out)
