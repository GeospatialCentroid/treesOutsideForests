"""Per-scene scores over a probability map: strict and boundary-tolerant
confusion counts, a threshold sweep, and area shares."""
from __future__ import annotations

import numpy as np


def disc_offsets(radius: int) -> list[tuple[int, int]]:
    r = int(radius)
    return [(dy, dx) for dy in range(-r, r + 1) for dx in range(-r, r + 1) if dy * dy + dx * dx <= r * r]


def dilate(a: np.ndarray, radius: int) -> np.ndarray:
    """Binary dilation with a disc of `radius` pixels, pure numpy."""
    if radius <= 0:
        return a
    H, W = a.shape
    out = np.zeros_like(a, dtype=bool)
    for dy, dx in disc_offsets(radius):
        ys, yd = (slice(dy, H), slice(0, H - dy)) if dy >= 0 else (slice(0, H + dy), slice(-dy, H))
        xs, xd = (slice(dx, W), slice(0, W - dx)) if dx >= 0 else (slice(0, W + dx), slice(-dx, W))
        out[yd, xd] |= a[ys, xs]
    return out


def counts(pred: np.ndarray, truth: np.ndarray, valid: np.ndarray) -> dict[str, int]:
    p, y = pred & valid, truth & valid
    tp = int((p & y).sum()); fp = int(p.sum()) - tp; fn = int(y.sum()) - tp
    tn = int(valid.sum()) - tp - fp - fn
    return {"tp": tp, "fp": fp, "fn": fn, "tn": tn}


def scores(c: dict[str, int]) -> dict[str, float]:
    tp, fp, fn = c["tp"], c["fp"], c["fn"]
    precision = tp / max(tp + fp, 1); recall = tp / max(tp + fn, 1)
    return {"precision": precision, "recall": recall, "f1": 2 * tp / max(2 * tp + fp + fn, 1),
            "iou": tp / max(tp + fp + fn, 1)}


def relaxed(pred: np.ndarray, truth: np.ndarray, valid: np.ndarray, radius: int) -> dict[str, float]:
    """Boundary-tolerant precision and recall: a predicted pixel counts as
    correct within `radius` of a true one, and a true pixel as found within
    `radius` of a predicted one (the usual relaxed F1)."""
    p, y = pred & valid, truth & valid
    n_p, n_y = int(p.sum()), int(y.sum())
    tp_p = int((p & dilate(y, radius)).sum())
    tp_r = int((y & dilate(p, radius)).sum())
    precision = tp_p / max(n_p, 1); recall = tp_r / max(n_y, 1)
    f1 = 2 * precision * recall / max(precision + recall, 1e-12)
    return {f"precision_r{radius}": precision, f"recall_r{radius}": recall, f"f1_r{radius}": f1}


def sweep(prob: np.ndarray, truth: np.ndarray, valid: np.ndarray,
          thresholds: np.ndarray | None = None) -> dict[str, float]:
    """Best F1 over a threshold grid, and the area-unbiased threshold: the one
    whose predicted count is closest to the true count."""
    t = thresholds if thresholds is not None else np.round(np.arange(0.05, 0.96, 0.05), 2)
    pv, yv = prob[valid], truth[valid]
    n_y = int(yv.sum())
    best_f1, best_t, unb_t, unb_gap = 0.0, float("nan"), float("nan"), np.inf
    for th in t:
        pred = pv >= th
        tp = int((pred & yv).sum()); n_p = int(pred.sum())
        f1 = 2 * tp / max(n_p + n_y, 1)  # 2tp / (2tp + fp + fn)
        if f1 > best_f1:
            best_f1, best_t = f1, float(th)
        gap = abs(n_p - n_y)
        if gap < unb_gap:
            unb_gap, unb_t = gap, float(th)
    return {"best_f1": best_f1, "best_threshold": best_t, "area_unbiased_threshold": unb_t}
