"""Aligned image / mask pairs and the patch datasets built on them.

A pair is one reference mask and the NAIP imagery under it, cropped to the
same grid and stored as two .npy files by 01_prepare.py:

    <work_dir>/pairs/<id>_<year>_img.npy    uint8 (4, H, W)  RGB + NIR, 0-255
    <work_dir>/pairs/<id>_<year>_mask.npy   uint8 (H, W)     0 no tree, 1 tree, 255 no data

The datasets memory-map those files and cut fixed-size patches from them, so
the whole set is never loaded into RAM at once.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd
import torch
from torch.utils.data import Dataset

MASK_NODATA = 255


def valid_pixels(img: np.ndarray, mask: np.ndarray) -> np.ndarray:
    """True where both the mask and the image carry data (an all-zero pixel is
    the NAIP export's no-data)."""
    return (mask != MASK_NODATA) & img.any(axis=0)


@dataclass
class Patch:
    pair: int   # row in the manifest subset
    row: int
    col: int
    tree_fraction: float


def _integral(a: np.ndarray) -> np.ndarray:
    s = np.zeros((a.shape[0] + 1, a.shape[1] + 1), dtype=np.int64)
    s[1:, 1:] = a.astype(np.int64).cumsum(0).cumsum(1)
    return s


def _window_sums(integral: np.ndarray, size: int, stride: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Sum inside every size x size window at the given stride; returns
    (rows, cols, sums) with rows/cols the window origins."""
    H, W = integral.shape[0] - 1, integral.shape[1] - 1
    rows = np.arange(0, H - size + 1, stride)
    cols = np.arange(0, W - size + 1, stride)
    r0, c0 = np.meshgrid(rows, cols, indexing="ij")
    r1, c1 = r0 + size, c0 + size
    sums = integral[r1, c1] - integral[r0, c1] - integral[r1, c0] + integral[r0, c0]
    return r0.ravel(), c0.ravel(), sums.ravel()


def index_patches(manifest: pd.DataFrame, pairs_dir: Path, size: int, stride: int) -> list[Patch]:
    """Every fully valid size x size window in every pair, with its tree share."""
    out: list[Patch] = []
    for i, key in enumerate(manifest["key"]):
        img = np.load(pairs_dir / f"{key}_img.npy", mmap_mode="r")
        mask = np.load(pairs_dir / f"{key}_mask.npy", mmap_mode="r")
        valid = valid_pixels(np.asarray(img), np.asarray(mask))
        tree = (np.asarray(mask) == 1)
        rows, cols, n_valid = _window_sums(_integral(valid), size, stride)
        _, _, n_tree = _window_sums(_integral(tree), size, stride)
        full = n_valid == size * size
        for r, c, t in zip(rows[full], cols[full], n_tree[full]):
            out.append(Patch(i, int(r), int(c), float(t) / (size * size)))
    return out


class PatchDataset(Dataset):
    """Patches from memory-mapped pairs, normalised to zero mean / unit variance
    per band, optionally augmented. Returns (image float32 (4,S,S), mask float32 (1,S,S))."""

    def __init__(self, manifest: pd.DataFrame, pairs_dir: Path, patches: list[Patch],
                 mean: np.ndarray, std: np.ndarray, augment: bool = False, seed: int = 0):
        self.keys = list(manifest["key"])
        self.pairs_dir = Path(pairs_dir)
        self.patches = patches
        self.size = None
        self.mean = np.asarray(mean, dtype=np.float32).reshape(4, 1, 1)
        self.std = np.asarray(std, dtype=np.float32).reshape(4, 1, 1)
        self.augment = augment
        self.rng = np.random.default_rng(seed)
        self._img: dict[int, np.ndarray] = {}
        self._mask: dict[int, np.ndarray] = {}

    def set_patch_size(self, size: int) -> None:
        self.size = size

    def _arrays(self, pair: int) -> tuple[np.ndarray, np.ndarray]:
        # Memory maps are opened lazily in each loader worker and kept open.
        if pair not in self._img:
            key = self.keys[pair]
            self._img[pair] = np.load(self.pairs_dir / f"{key}_img.npy", mmap_mode="r")
            self._mask[pair] = np.load(self.pairs_dir / f"{key}_mask.npy", mmap_mode="r")
        return self._img[pair], self._mask[pair]

    def __len__(self) -> int:
        return len(self.patches)

    def __getitem__(self, i: int):
        p = self.patches[i]
        img_mm, mask_mm = self._arrays(p.pair)
        s = self.size
        img = np.array(img_mm[:, p.row:p.row + s, p.col:p.col + s], dtype=np.float32) / 255.0
        mask = np.array(mask_mm[p.row:p.row + s, p.col:p.col + s], dtype=np.float32)
        mask = (mask == 1).astype(np.float32)
        if self.augment:
            img, mask = self._augment(img, mask)
        img = (img - self.mean) / self.std
        return torch.from_numpy(np.ascontiguousarray(img)), torch.from_numpy(np.ascontiguousarray(mask)[None])

    def _augment(self, img: np.ndarray, mask: np.ndarray):
        rng = self.rng
        if rng.random() < 0.5:
            img, mask = img[:, :, ::-1], mask[:, ::-1]
        if rng.random() < 0.5:
            img, mask = img[:, ::-1, :], mask[::-1, :]
        k = int(rng.integers(0, 4))
        if k:
            img, mask = np.rot90(img, k, axes=(1, 2)), np.rot90(mask, k)
        # Radiometric jitter on every band: NAIP exposure differs between
        # flights and years, and the model should not key on absolute levels.
        gain = rng.uniform(0.85, 1.15, size=(4, 1, 1)).astype(np.float32)
        bias = rng.uniform(-0.08, 0.08, size=(4, 1, 1)).astype(np.float32)
        img = np.clip(img * gain + bias, 0.0, 1.0)
        return img, mask


def balanced_subset(patches: list[Patch], min_tree_fraction: float, background_ratio: float,
                    rng: np.random.Generator) -> list[Patch]:
    """Tree patches (tree share above the floor) plus a random draw of
    tree-free patches, `background_ratio` per tree patch. Called every epoch so
    the background patches rotate through the whole pool."""
    tree = [p for p in patches if p.tree_fraction > min_tree_fraction]
    bg = [p for p in patches if p.tree_fraction == 0.0]
    n_bg = min(len(bg), int(round(background_ratio * len(tree))))
    chosen = [bg[i] for i in rng.choice(len(bg), size=n_bg, replace=False)] if n_bg else []
    out = tree + chosen
    rng.shuffle(out)
    return out


def load_manifest(work_dir: Path) -> pd.DataFrame:
    return pd.read_csv(work_dir / "manifest.csv", dtype={"id": str, "key": str, "split": str})


def load_stats(work_dir: Path) -> dict:
    with open(work_dir / "band_stats.json") as f:
        return json.load(f)
