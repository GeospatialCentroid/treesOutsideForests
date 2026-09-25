"""Whole-scene inference: read a 4-band NAIP GeoTIFF and slide the model across it.

Shared by 04_predict.py and tools/compare_harmonized.py so both score a scene
the same way.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import rasterio
import torch


def read_scene(path: Path, window=None) -> tuple[np.ndarray, np.ndarray, dict]:
    """(image uint8 (4, H, W), nodata bool (H, W), profile). No data where the
    file says so, or where every band is zero (older exports); those pixels
    are zeroed in the image so the model sees a constant there."""
    with rasterio.open(path) as src:
        if src.count != 4:
            raise ValueError(f"{path.name} has {src.count} bands, expected 4")
        img = src.read(window=window)
        profile = src.profile
        flagged = (img == src.nodata).all(axis=0) if src.nodata is not None else np.zeros(img.shape[1:], bool)
    nodata = flagged | ~img.any(axis=0)
    img = np.where(nodata[None], 0, img).astype(np.uint8)
    return img, nodata, profile


def cosine_weight(n: int) -> np.ndarray:
    w = 0.5 - 0.5 * np.cos(2 * np.pi * (np.arange(n) + 0.5) / n)
    return np.outer(w, w).astype(np.float32) + 1e-3


@torch.no_grad()
def predict_scene(model, img: np.ndarray, mean: np.ndarray, std: np.ndarray, window: int, batch: int,
                  device) -> np.ndarray:
    """Tree probability (H, W) for a uint8 (4, H, W) scene. Windows overlap by
    half and are blended with a cosine weight, so tile seams do not show."""
    mean = np.asarray(mean, dtype=np.float32).reshape(4, 1, 1)
    std = np.asarray(std, dtype=np.float32).reshape(4, 1, 1)
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
