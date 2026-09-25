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

ap = argparse.ArgumentParser()
ap.add_argument("inputs", nargs="+")
ap.add_argument("--run", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--window", type=int, default=512)
ap.add_argument("--threshold", type=float, default=None)
ap.add_argument("--batch-size", type=int, default=4)
ap.add_argument("--device", default=None)
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

files = []
for inp in args.inputs:
    p = Path(inp)
    files += sorted(p.glob("*.tif")) if p.is_dir() else [p]


def cosine_weight(n: int) -> np.ndarray:
    w = 0.5 - 0.5 * np.cos(2 * np.pi * (np.arange(n) + 0.5) / n)
    return np.outer(w, w).astype(np.float32) + 1e-3


@torch.no_grad()
def predict_scene(img: np.ndarray, window: int, batch: int) -> np.ndarray:
    C, H, W = img.shape
    step = window // 2
    pad_h = (-(H - window)) % step if H > window else window - H
    pad_w = (-(W - window)) % step if W > window else window - W
    x = np.pad(img.astype(np.float32) / 255.0, ((0, 0), (0, pad_h), (0, pad_w)), mode="reflect")
    x = (x - mean) / std
    Hp, Wp = x.shape[1:]
    prob = np.zeros((Hp, Wp), dtype=np.float32); wsum = np.zeros((Hp, Wp), dtype=np.float32)
    wt = cosine_weight(window)
    origins = [(r, c) for r in range(0, Hp - window + 1, step) for c in range(0, Wp - window + 1, step)]
    for i in range(0, len(origins), batch):
        chunk = origins[i:i + batch]
        xb = torch.from_numpy(np.stack([x[:, r:r + window, c:c + window] for r, c in chunk])).to(device)
        pb = torch.sigmoid(model(xb).float())[:, 0].cpu().numpy()
        for (r, c), p in zip(chunk, pb):
            prob[r:r + window, c:c + window] += p * wt; wsum[r:r + window, c:c + window] += wt
    return (prob / wsum)[:H, :W]


for f in files:
    with rasterio.open(f) as src:
        if src.count != 4:
            log.warning("%s has %d bands, expected 4; skipped.", f.name, src.count); continue
        img = src.read(); profile = src.profile
    nodata = ~img.any(axis=0)
    prob = predict_scene(img, args.window, args.batch_size)
    prob[nodata] = np.nan
    binary = np.where(nodata, 255, (prob >= threshold).astype(np.uint8)).astype(np.uint8)
    prob_profile = profile | {"count": 1, "dtype": "float32", "nodata": np.nan, "compress": "deflate", "tiled": True}
    bin_profile = profile | {"count": 1, "dtype": "uint8", "nodata": 255, "compress": "deflate", "tiled": True}
    for key in ("photometric",):
        prob_profile.pop(key, None); bin_profile.pop(key, None)
    with rasterio.open(out_dir / f"{f.stem}_tof_prob.tif", "w", **prob_profile) as dst:
        dst.write(prob.astype(np.float32), 1)
        dst.update_tags(model_run=meta["run_name"], encoder=meta["encoder"], threshold=str(threshold))
    with rasterio.open(out_dir / f"{f.stem}_tof.tif", "w", **bin_profile) as dst:
        dst.write(binary, 1)
        dst.update_tags(model_run=meta["run_name"], encoder=meta["encoder"], threshold=str(threshold),
                        legend="0 no tree, 1 tree, 255 no data")
    log.info("%s: tree share %.3f (threshold %.2f)", f.name, float((binary == 1).sum() / max((~nodata).sum(), 1)), threshold)
