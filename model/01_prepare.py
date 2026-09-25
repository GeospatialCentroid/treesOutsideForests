#!/usr/bin/env python
"""Pair every reference mask with its NAIP imagery and write the aligned pairs.

For each <id>_<year>_mask.tif in config model.paths.mask_dirs:
  - find the naip stage export aoi_<id>_<year>/ (the 1 km tight export, or the
    1.5 km buffered one, which lies on the same 1 m grid) and require the
    imagery year to equal the mask year (status.json actual_year);
  - require the same CRS and a whole-pixel offset between the two grids, then
    crop the imagery to the mask's extent;
  - write <work_dir>/pairs/<id>_<year>_img.npy and _mask.npy;
  - assign the split from the configured sampling partition (Train /
    Validation / Test per scene id); scenes outside it are excluded.

Then compute per-band mean and standard deviation over the training pairs
(valid pixels only) and write manifest.csv, band_stats.json and a short
summary. Pairs that cannot be built are listed in manifest with their reason.

    model/.venv/bin/python model/01_prepare.py
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import rasterio
from rasterio.windows import Window

sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))
from tofunet.config import ROOT, load_config, setup_logging, tof_path  # noqa: E402
from tofunet.data import MASK_NODATA, valid_pixels  # noqa: E402

cfg = load_config()
cm = cfg["model"]
work = tof_path(cm["paths"]["work_dir"])
pairs_dir = work / "pairs"
pairs_dir.mkdir(parents=True, exist_ok=True)
log = setup_logging(work / "prepare.log")

export_dir = tof_path(cm["paths"]["naip_export_dir"])
partition_key = cm["partition"]
part_cfg = cfg["sampling"]["partitions"][partition_key]
partition = pd.read_csv(tof_path(part_cfg["csv"]), encoding="utf-8-sig", dtype={"scene_id": str})
split_of = dict(zip(partition["scene_id"], partition["Type"].map({"Train": "train", "Validation": "validation", "Test": "test"})))
log.info("Partition %s (%s): %s", partition_key, part_cfg["label"], partition["Type"].value_counts().to_dict())

rows = []
for d in cm["paths"]["mask_dirs"]:
    for mask_path in sorted(tof_path(d).glob("*_mask.tif")):
        m = re.match(r"(.+)_(\d{4})_mask\.tif$", mask_path.name)
        cell, year = m.group(1), m.group(2)
        key = f"{cell}_{year}"
        row = {"key": key, "id": cell, "year": int(year), "mask": str(mask_path.relative_to(ROOT)),
               "source_dir": Path(d).name, "split": split_of.get(cell, "excluded"), "image": None,
               "status": None, "height": None, "width": None, "tree_fraction": None}
        rows.append(row)
        if row["split"] == "excluded":
            row["status"] = "scene not in partition"
            continue
        folder = export_dir / f"aoi_{cell}_{year}"
        status_file = folder / "status.json"
        if not folder.is_dir():
            row["status"] = "no NAIP export"
            continue
        if status_file.exists():
            status = json.loads(status_file.read_text())
            if status.get("status") != "Success" or str(status.get("actual_year")) != year:
                row["status"] = f"NAIP export {status.get('status')}, actual year {status.get('actual_year')}"
                continue
        # Exports made before the naip stage wrote status.json carry the actual
        # year in the folder and file names; accept those on the name alone.
        image = next(iter(sorted(folder.glob(f"naip_1km_{cell}_{year}.tif"))), None) or \
            next(iter(sorted(folder.glob(f"naip_1.5km_{cell}_{year}.tif"))), None)
        if image is None:
            row["status"] = "export folder without a NAIP GeoTIFF"
            continue
        img_out, mask_out = pairs_dir / f"{key}_img.npy", pairs_dir / f"{key}_mask.npy"
        with rasterio.open(mask_path) as ms, rasterio.open(image) as im:
            if ms.crs != im.crs:
                row["status"] = f"CRS differs: mask {ms.crs.to_epsg()} vs image {im.crs.to_epsg()}"
                continue
            if im.count != 4:
                row["status"] = f"image has {im.count} bands"
                continue
            tm, ti = ms.transform, im.transform
            if abs(tm.a - ti.a) > 1e-6 or abs(tm.e - ti.e) > 1e-6:
                row["status"] = "pixel size differs"
                continue
            col_off = (tm.c - ti.c) / ti.a
            row_off = (tm.f - ti.f) / ti.e
            if abs(col_off - round(col_off)) > 1e-3 or abs(row_off - round(row_off)) > 1e-3:
                row["status"] = f"grids not pixel-aligned (offset {col_off:.3f}, {row_off:.3f})"
                continue
            col_off, row_off = int(round(col_off)), int(round(row_off))
            # Intersection of the two rasters, in the image's pixel space.
            c0, r0 = max(col_off, 0), max(row_off, 0)
            c1, r1 = min(col_off + ms.width, im.width), min(row_off + ms.height, im.height)
            if c1 - c0 < 64 or r1 - r0 < 64:
                row["status"] = "mask and image barely overlap"
                continue
            img = im.read(window=Window(c0, r0, c1 - c0, r1 - r0)).astype(np.uint8)
            mask = ms.read(1, window=Window(c0 - col_off, r0 - row_off, c1 - c0, r1 - r0)).astype(np.uint8)
            mask[(mask != 0) & (mask != 1)] = MASK_NODATA
            if not (img_out.exists() and mask_out.exists()):
                np.save(img_out, img)
                np.save(mask_out, mask)
            valid = valid_pixels(img, mask)
            row.update(image=str(Path(image).relative_to(ROOT)), status="ok", height=int(mask.shape[0]), width=int(mask.shape[1]),
                       tree_fraction=float((mask[valid] == 1).mean()) if valid.any() else 0.0,
                       valid_fraction=float(valid.mean()))

manifest = pd.DataFrame(rows)
manifest.to_csv(work / "manifest.csv", index=False)
ok = manifest[manifest["status"] == "ok"]
log.info("Pairs: %d of %d masks paired. Reasons for the rest: %s", len(ok), len(manifest),
         manifest.loc[manifest["status"] != "ok", "status"].value_counts().to_dict())
log.info("Split of paired scenes: %s", ok.groupby("split")["id"].nunique().to_dict())
log.info("Split of paired masks (scene-years): %s", ok["split"].value_counts().to_dict())

# Per-band mean / std over the training pairs, valid pixels only, on the 0-1 scale.
train = ok[ok["split"] == "train"]
if len(train) == 0:
    log.error("No training pairs; run model/00_fetch_naip.R first.")
    sys.exit(1)
s1 = np.zeros(4); s2 = np.zeros(4); n = 0
for key in train["key"]:
    img = np.load(pairs_dir / f"{key}_img.npy")
    mask = np.load(pairs_dir / f"{key}_mask.npy")
    v = valid_pixels(img, mask)
    x = img[:, v].astype(np.float64) / 255.0
    s1 += x.sum(axis=1); s2 += (x ** 2).sum(axis=1); n += int(v.sum())
mean = s1 / n
std = np.sqrt(np.maximum(s2 / n - mean ** 2, 1e-12))
stats = {"mean": mean.tolist(), "std": std.tolist(), "n_pixels": n, "scale": "image / 255",
         "bands": ["red", "green", "blue", "nir"], "partition": partition_key,
         "train_keys": int(len(train)), "train_scenes": int(train["id"].nunique())}
with open(work / "band_stats.json", "w") as f:
    json.dump(stats, f, indent=2)
log.info("Band mean %s std %s over %d training pixels", np.round(mean, 4), np.round(std, 4), n)
log.info("Tree share over paired masks: train %.3f, validation %.3f, test %.3f",
         *[ok.loc[ok["split"] == s, "tree_fraction"].mean() if (ok["split"] == s).any() else float("nan")
           for s in ("train", "validation", "test")])
log.info("Wrote %s and %s", work / "manifest.csv", work / "band_stats.json")
