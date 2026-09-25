#!/usr/bin/env python
"""Tree / no-tree maps for 4-band NAIP GeoTIFFs with a trained run.

    model/.venv/bin/python model/04_predict.py --run data/model/runs/<run> --out <dir> <naip.tif or folder> [...]

Writes <stem>_tof_prob.tif (float32 tree probability) and <stem>_tof.tif
(uint8: 0 no tree, 1 tree, 255 no data) beside each other in --out. Inference
slides a window across the scene with half overlap and blends the overlapping
predictions with a cosine weight, so tile seams do not show.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import rasterio
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))
from tofunet.config import load_config, pick_device, setup_logging, tof_path  # noqa: E402
from tofunet.model import load_checkpoint  # noqa: E402
from tofunet.predict import predict_scene, read_scene  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("inputs", nargs="+")
ap.add_argument("--run", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--window", type=int, default=512)
ap.add_argument("--threshold", type=float, default=None)
ap.add_argument("--batch-size", type=int, default=4)
ap.add_argument("--device", default=None, help="auto (config default), cpu, or cuda / cuda:N (ROCm builds also present as cuda)")
ap.add_argument("--harmonized", action="store_true",
                help="read each input from the harmonised tree (config harmonize.paths.out_dir) instead of the export tree")
args = ap.parse_args()

cfg = load_config(); cm = cfg["model"]
torch.set_num_threads(int(cm["threads"]))
out_dir = Path(args.out); out_dir.mkdir(parents=True, exist_ok=True)
log = setup_logging(out_dir / "predict.log")
model, meta = load_checkpoint(tof_path(args.run) / "best.pt")
device, device_desc = pick_device(args.device or cm.get("device", "auto")); model.to(device)
log.info("Predicting on %s", device_desc)
threshold = args.threshold if args.threshold is not None else float(meta["threshold"])
mean = np.array(meta["band_stats"]["mean"], dtype=np.float32).reshape(4, 1, 1)
std = np.array(meta["band_stats"]["std"], dtype=np.float32).reshape(4, 1, 1)

files: list[tuple[Path, bool]] = []   # (path, read from the harmonised tree)
for inp in args.inputs:
    p = Path(inp).resolve(); swapped = False
    if args.harmonized:
        # The harmonised tree mirrors the export tree, so swap the root and keep
        # the rest of the path. A cell-year that was never harmonised is read raw.
        export_root = tof_path(cfg["harmonize"]["paths"]["export_dir"]).resolve()
        harm_root = tof_path(cfg["harmonize"]["paths"]["out_dir"]).resolve()
        try:
            q = harm_root / p.relative_to(export_root)
        except ValueError:
            q = p
        if q.exists():
            p, swapped = q, True
        else:
            log.warning("%s has no harmonised counterpart; reading the raw export.", inp)
    files += [(f, swapped) for f in (sorted(p.glob("*.tif")) if p.is_dir() else [p])]


for f, harmonised in files:
    try:
        img, nodata, profile = read_scene(f)
    except ValueError as e:
        log.warning("%s; skipped.", e); continue
    prob = predict_scene(model, img, mean, std, args.window, args.batch_size, device)
    prob[nodata] = np.nan
    binary = np.where(nodata, 255, (prob >= threshold).astype(np.uint8)).astype(np.uint8)
    prob_profile = profile | {"count": 1, "dtype": "float32", "nodata": np.nan, "compress": "deflate", "tiled": True}
    bin_profile = profile | {"count": 1, "dtype": "uint8", "nodata": 255, "compress": "deflate", "tiled": True}
    # Raw exports are strip-organised (one row per block); tiled output needs
    # its own block size, so the source's block keys are dropped.
    for key in ("photometric", "blockxsize", "blockysize"):
        prob_profile.pop(key, None); bin_profile.pop(key, None)
    prob_profile.update(blockxsize=256, blockysize=256); bin_profile.update(blockxsize=256, blockysize=256)
    with rasterio.open(out_dir / f"{f.stem}_tof_prob.tif", "w", **prob_profile) as dst:
        dst.write(prob.astype(np.float32), 1)
        dst.update_tags(model_run=meta["run_name"], encoder=meta["encoder"], threshold=str(threshold))
    with rasterio.open(out_dir / f"{f.stem}_tof.tif", "w", **bin_profile) as dst:
        dst.write(binary, 1)
        dst.update_tags(model_run=meta["run_name"], encoder=meta["encoder"], threshold=str(threshold),
                        legend="0 no tree, 1 tree, 255 no data")
    log.info("%s: tree share %.3f (threshold %.2f)%s", f.name, float((binary == 1).sum() / max((~nodata).sum(), 1)), threshold,
             "  [harmonised]" if harmonised else "")
