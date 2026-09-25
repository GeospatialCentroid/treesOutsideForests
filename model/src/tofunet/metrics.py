"""Confusion counts over a sweep of thresholds, and the scores derived from them."""
from __future__ import annotations

import numpy as np
import torch


class ThresholdSweep:
    """Accumulates TP / FP / FN / TN at every threshold in `thresholds` across
    batches, so global F1, IoU, precision and recall can be read off at the end
    without holding predictions in memory."""

    def __init__(self, thresholds: np.ndarray | None = None):
        self.t = np.asarray(thresholds if thresholds is not None else np.round(np.arange(0.05, 0.96, 0.05), 2))
        self.tp = np.zeros(len(self.t), dtype=np.int64)
        self.fp = np.zeros_like(self.tp)
        self.fn = np.zeros_like(self.tp)
        self.tn = np.zeros_like(self.tp)

    @torch.no_grad()
    def update(self, probs: torch.Tensor, target: torch.Tensor) -> None:
        p = probs.reshape(-1)
        y = target.reshape(-1) > 0.5
        n = p.numel()
        n_pos = int(y.sum())
        for i, t in enumerate(self.t):
            pred = p >= float(t)
            tp = int((pred & y).sum())
            fp = int(pred.sum()) - tp
            self.tp[i] += tp
            self.fp[i] += fp
            self.fn[i] += n_pos - tp
            self.tn[i] += n - n_pos - fp

    def table(self) -> dict[str, np.ndarray]:
        tp, fp, fn, tn = (x.astype(np.float64) for x in (self.tp, self.fp, self.fn, self.tn))
        precision = tp / np.maximum(tp + fp, 1)
        recall = tp / np.maximum(tp + fn, 1)
        f1 = 2 * precision * recall / np.maximum(precision + recall, 1e-12)
        iou = tp / np.maximum(tp + fp + fn, 1)
        acc = (tp + tn) / np.maximum(tp + fp + fn + tn, 1)
        return {"threshold": self.t, "precision": precision, "recall": recall, "f1": f1, "iou": iou, "accuracy": acc}

    def best(self) -> dict[str, float]:
        tb = self.table()
        i = int(np.argmax(tb["f1"]))
        return {k: float(v[i]) for k, v in tb.items()} | {"tp": int(self.tp[i]), "fp": int(self.fp[i]),
                                                          "fn": int(self.fn[i]), "tn": int(self.tn[i])}

    def at(self, threshold: float) -> dict[str, float]:
        tb = self.table()
        i = int(np.argmin(np.abs(self.t - threshold)))
        return {k: float(v[i]) for k, v in tb.items()} | {"tp": int(self.tp[i]), "fp": int(self.fp[i]),
                                                          "fn": int(self.fn[i]), "tn": int(self.tn[i])}
