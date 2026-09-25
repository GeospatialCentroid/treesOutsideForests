"""Score a model on every pair of one split at a fixed threshold, globally and per scene."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd
import torch
from torch.utils.data import DataLoader

from tofunet.data import PatchDataset, index_patches
from tofunet.metrics import ThresholdSweep


def evaluate_split(model, pairs: pd.DataFrame, pairs_dir: Path, mean, std, size: int, stride: int,
                   threshold: float, batch_size: int, workers: int, per_scene_csv: Path | None = None,
                   device=None) -> dict:
    device = device or torch.device("cpu")
    model.eval()
    overall = ThresholdSweep(np.array([threshold]))
    rows = []
    for i in range(len(pairs)):
        one = pairs.iloc[[i]].reset_index(drop=True)
        patches = index_patches(one, pairs_dir, size, stride)
        if not patches:
            continue
        ds = PatchDataset(one, pairs_dir, patches, mean, std, augment=False); ds.set_patch_size(size)
        sweep = ThresholdSweep(np.array([threshold]))
        with torch.no_grad():
            for x, y in DataLoader(ds, batch_size=batch_size, shuffle=False, num_workers=0):
                x = x.to(device); y = y.to(device)
                p = torch.sigmoid(model(x).float()); sweep.update(p, y); overall.update(p, y)
        r = sweep.at(threshold)
        rows.append({"key": one["key"][0], "id": one["id"][0], "year": int(one["year"][0]), "split": one["split"][0],
                     "patches": len(patches), "tree_pixels": r["tp"] + r["fn"], "predicted_tree_pixels": r["tp"] + r["fp"],
                     "f1": r["f1"], "iou": r["iou"], "precision": r["precision"], "recall": r["recall"], "accuracy": r["accuracy"]})
    if per_scene_csv is not None:
        pd.DataFrame(rows).to_csv(per_scene_csv, index=False)
    out = overall.at(threshold)
    out["scenes"] = len(rows)
    return out
