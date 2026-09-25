#!/usr/bin/env python
"""Train the U-Net on the prepared pairs, then score the test split.

    model/tools/run_guarded.sh model/.venv/bin/python model/02_train.py [--run-name NAME] [--epochs N]

One folder per run under model.paths.runs_dir holding: config.json (every
setting that shaped the run), history.csv (per-epoch loss and validation
scores), best.pt / last.pt (weights plus the normalisation stats and the
chosen threshold), curves.png, and results.json with validation and test
scores. Early stopping watches the validation F1 at its best threshold.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import time
from datetime import datetime
from pathlib import Path

import numpy as np
import pandas as pd
import torch
from torch.utils.data import DataLoader

sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))
from tofunet.config import available_gb, load_config, memory_guard, pick_device, process_rss_gb, setup_logging, tof_path  # noqa: E402
from tofunet.data import PatchDataset, balanced_subset, index_patches, load_manifest, load_stats  # noqa: E402
from tofunet.metrics import ThresholdSweep  # noqa: E402
from tofunet.model import BCEDiceLoss, build_model, save_checkpoint  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--run-name", default=None)
ap.add_argument("--epochs", type=int, default=None)
ap.add_argument("--limit-train-patches", type=int, default=None, help="cap patches per epoch (smoke tests)")
ap.add_argument("--device", default=None, help="auto (default from config), cpu, cuda or cuda:N")
args = ap.parse_args()

cfg = load_config()
cm = cfg["model"]
work = tof_path(cm["paths"]["work_dir"])
pairs_dir = work / "pairs"
run_name = args.run_name or f"{datetime.now():%Y%m%d_%H%M%S}_{cm['encoder']}"
run_dir = tof_path(cm["paths"]["runs_dir"]) / run_name
run_dir.mkdir(parents=True, exist_ok=True)
log = setup_logging(run_dir / "train.log")
epochs = args.epochs or int(cm["epochs"])

torch.manual_seed(int(cm["seed"])); np.random.seed(int(cm["seed"]))
torch.set_num_threads(int(cm["threads"]))
device, device_desc = pick_device(args.device or cm.get("device", "auto"))
use_amp = device.type == "cuda" and bool(cm.get("mixed_precision", True))
rng = np.random.default_rng(int(cm["seed"]))
memory_guard(float(cm["min_available_gb"]), log, what="loading the data")

manifest = load_manifest(work)
ok = manifest[manifest["status"] == "ok"].reset_index(drop=True)
stats = load_stats(work)
mean, std = np.array(stats["mean"]), np.array(stats["std"])
size = int(cm["patch_size"])

splits = {s: ok[ok["split"] == s].reset_index(drop=True) for s in ("train", "validation", "test")}
for s, df in splits.items():
    if len(df) == 0 and s != "test":
        log.error("No %s pairs in the manifest; check the partition and 01_prepare.py.", s); sys.exit(1)
if len(splits["test"]) == 0:
    log.warning("No test pairs in the manifest; the run will be scored on validation only.")
log.info("Pairs: train %d, validation %d, test %d (scene-years)", *[len(splits[s]) for s in ("train", "validation", "test")])

t0 = time.time()
train_pool = index_patches(splits["train"], pairs_dir, size, int(cm["train_stride"]))
val_patches = index_patches(splits["validation"], pairs_dir, size, int(cm["eval_stride"]))
n_tree = sum(p.tree_fraction > float(cm["min_tree_fraction"]) for p in train_pool)
n_bg = sum(p.tree_fraction == 0.0 for p in train_pool)
log.info("Patch pool: train %d (%d with trees, %d without), validation %d; indexed in %.0f s",
         len(train_pool), n_tree, n_bg, len(val_patches), time.time() - t0)

train_ds = PatchDataset(splits["train"], pairs_dir, [], mean, std, augment=True, seed=int(cm["seed"]))
val_ds = PatchDataset(splits["validation"], pairs_dir, val_patches, mean, std, augment=False)
for ds in (train_ds, val_ds):
    ds.set_patch_size(size)
workers = int(cm["loader_workers"])
val_loader = DataLoader(val_ds, batch_size=int(cm["batch_size"]), shuffle=False, num_workers=workers, persistent_workers=workers > 0)

model = build_model(cm["encoder"], cm.get("encoder_weights")).to(device)
n_params = sum(p.numel() for p in model.parameters())
scaler = torch.amp.GradScaler("cuda", enabled=use_amp)
criterion = BCEDiceLoss()
optimizer = torch.optim.AdamW(model.parameters(), lr=float(cm["learning_rate"]), weight_decay=float(cm["weight_decay"]))

run_cfg = {k: v for k, v in cm.items() if k != "paths"} | {
    "run_name": run_name, "epochs_requested": epochs, "band_stats": stats, "n_parameters": n_params,
    "train_pairs": len(splits["train"]), "validation_pairs": len(splits["validation"]), "test_pairs": len(splits["test"]),
    "train_patch_pool": len(train_pool), "train_patches_with_trees": n_tree, "validation_patches": len(val_patches),
    "torch": torch.__version__, "device": device_desc, "mixed_precision": use_amp,
    "started": datetime.now().isoformat(timespec="seconds")}
with open(run_dir / "config.json", "w") as f:
    json.dump(run_cfg, f, indent=2)
log.info("Model %s (%s weights), %.1f M parameters on %s%s; %d torch threads, %d loader workers",
         cm["encoder"], cm.get("encoder_weights"), n_params / 1e6, device_desc,
         " with mixed precision" if use_amp else "", torch.get_num_threads(), workers)


def evaluate(loader: DataLoader) -> ThresholdSweep:
    model.eval(); sweep = ThresholdSweep()
    with torch.no_grad(), torch.autocast(device.type, enabled=use_amp):
        for x, y in loader:
            x = x.to(device, non_blocking=True); y = y.to(device, non_blocking=True)
            sweep.update(torch.sigmoid(model(x).float()), y)
    return sweep


history = []
best_f1, best_epoch, best_threshold, bad_epochs = -1.0, 0, 0.5, 0
steps_total = None
for epoch in range(1, epochs + 1):
    memory_guard(float(cm["min_available_gb"]), log, what=f"epoch {epoch}")
    subset = balanced_subset(train_pool, float(cm["min_tree_fraction"]), float(cm["background_ratio"]), rng)
    if args.limit_train_patches:
        subset = subset[: args.limit_train_patches]
    train_ds.patches = subset
    train_loader = DataLoader(train_ds, batch_size=int(cm["batch_size"]), shuffle=True, num_workers=workers,
                              drop_last=True, persistent_workers=False, pin_memory=device.type == "cuda")
    if steps_total is None:
        # One-cycle schedule over the whole run: short warm-up, then cosine decay.
        steps_total = epochs * len(train_loader)
        scheduler = torch.optim.lr_scheduler.OneCycleLR(optimizer, max_lr=float(cm["learning_rate"]), total_steps=steps_total,
                                                        pct_start=0.1, anneal_strategy="cos", div_factor=10, final_div_factor=100)
    model.train(); t_ep = time.time(); losses = []
    for step, (x, y) in enumerate(train_loader, 1):
        x = x.to(device, non_blocking=True); y = y.to(device, non_blocking=True)
        optimizer.zero_grad(set_to_none=True)
        with torch.autocast(device.type, enabled=use_amp):
            loss = criterion(model(x).float(), y)
        scaler.scale(loss).backward()
        scaler.unscale_(optimizer)
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        scaler.step(optimizer); scaler.update()
        if scheduler.last_epoch < steps_total - 1:
            scheduler.step()
        losses.append(float(loss.detach()))
        if step % 50 == 0 or step == len(train_loader):
            log.info("  epoch %d step %d/%d loss %.4f  (%.2f s/step, rss %.1f GB, avail %.0f GB%s)",
                     epoch, step, len(train_loader), float(np.mean(losses[-50:])), (time.time() - t_ep) / step,
                     process_rss_gb(), available_gb(),
                     f", gpu {torch.cuda.max_memory_allocated(device) / 1024**3:.1f} GB" if device.type == "cuda" else "")
    train_time = time.time() - t_ep
    sweep = evaluate(val_loader)
    best = sweep.best(); at_half = sweep.at(0.5)
    rec = {"epoch": epoch, "train_loss": float(np.mean(losses)), "train_patches": len(subset), "train_seconds": round(train_time),
           "val_f1_best": best["f1"], "val_threshold": best["threshold"], "val_iou_best": best["iou"],
           "val_precision_best": best["precision"], "val_recall_best": best["recall"],
           "val_f1_at_0.5": at_half["f1"], "val_iou_at_0.5": at_half["iou"], "lr": optimizer.param_groups[0]["lr"]}
    history.append(rec)
    pd.DataFrame(history).to_csv(run_dir / "history.csv", index=False)
    improved = best["f1"] > best_f1 + 1e-4
    log.info("epoch %d: loss %.4f | val F1 %.4f (thr %.2f, IoU %.4f, P %.3f, R %.3f) | F1@0.5 %.4f | %.0f s%s",
             epoch, rec["train_loss"], best["f1"], best["threshold"], best["iou"], best["precision"], best["recall"],
             at_half["f1"], train_time, "  *best*" if improved else "")
    meta = {"encoder": cm["encoder"], "band_stats": stats, "patch_size": size, "epoch": epoch,
            "threshold": best["threshold"], "val_f1": best["f1"], "run_name": run_name}
    save_checkpoint(run_dir / "last.pt", model, meta)
    if improved:
        best_f1, best_epoch, best_threshold, bad_epochs = best["f1"], epoch, best["threshold"], 0
        save_checkpoint(run_dir / "best.pt", model, meta)
    else:
        bad_epochs += 1
        if epoch >= int(cm["min_epochs"]) and bad_epochs >= int(cm["patience"]):
            log.info("No validation gain for %d epochs; stopping early.", bad_epochs); break

# --- Curves ------------------------------------------------------------------
import matplotlib  # noqa: E402
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
h = pd.DataFrame(history)
fig, ax = plt.subplots(1, 2, figsize=(11, 4))
ax[0].plot(h["epoch"], h["train_loss"], marker="o"); ax[0].set_title("Training loss (BCE + Dice)"); ax[0].set_xlabel("epoch"); ax[0].grid(alpha=.3)
ax[1].plot(h["epoch"], h["val_f1_best"], marker="o", label="F1 at best threshold")
ax[1].plot(h["epoch"], h["val_f1_at_0.5"], marker=".", label="F1 at 0.5")
ax[1].plot(h["epoch"], h["val_iou_best"], marker=".", label="IoU at best threshold")
ax[1].axvline(best_epoch, color="k", ls="--", lw=.8, label=f"best epoch {best_epoch}")
ax[1].set_title("Validation"); ax[1].set_xlabel("epoch"); ax[1].set_ylim(0, 1); ax[1].legend(); ax[1].grid(alpha=.3)
fig.suptitle(run_name); fig.tight_layout(); fig.savefig(run_dir / "curves.png", dpi=150)

# --- Test split with the best checkpoint and its validation threshold -------
from tofunet.model import load_checkpoint  # noqa: E402
model, meta = load_checkpoint(run_dir / "best.pt"); model.to(device)
from evaluate_split import evaluate_split  # noqa: E402
results = {"run_name": run_name, "best_epoch": best_epoch, "epochs_run": len(history), "threshold": best_threshold,
           "device": device_desc,
           "validation": evaluate_split(model, splits["validation"], pairs_dir, mean, std, size, int(cm["eval_stride"]),
                                        best_threshold, int(cm["batch_size"]), workers, run_dir / "validation_scenes.csv", device),
           "test": evaluate_split(model, splits["test"], pairs_dir, mean, std, size, int(cm["eval_stride"]),
                                  best_threshold, int(cm["batch_size"]), workers, run_dir / "test_scenes.csv", device)
                   if len(splits["test"]) else None,
           "finished": datetime.now().isoformat(timespec="seconds")}
with open(run_dir / "results.json", "w") as f:
    json.dump(results, f, indent=2)
t = results["test"] or {"f1": float("nan"), "iou": float("nan"), "precision": float("nan"), "recall": float("nan")}
log.info("Best epoch %d, threshold %.2f. Validation F1 %.4f IoU %.4f | Test F1 %.4f IoU %.4f P %.3f R %.3f",
         best_epoch, best_threshold, results["validation"]["f1"], results["validation"]["iou"],
         t["f1"], t["iou"], t["precision"], t["recall"])
log.info("Run folder: %s", run_dir)
