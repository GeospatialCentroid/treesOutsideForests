#!/usr/bin/env python
"""Re-score a finished run on any split, at its stored threshold or another one.

    model/.venv/bin/python model/03_evaluate.py --run data/model/runs/<run> [--split test] [--threshold 0.5]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from tofunet.config import load_config, pick_device, setup_logging, tof_path  # noqa: E402
from tofunet.data import load_manifest  # noqa: E402
from tofunet.model import load_checkpoint  # noqa: E402
from evaluate_split import evaluate_split  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--run", required=True)
ap.add_argument("--split", default="test", choices=["train", "validation", "test"])
ap.add_argument("--threshold", type=float, default=None)
ap.add_argument("--checkpoint", default="best.pt")
ap.add_argument("--device", default=None)
args = ap.parse_args()

cfg = load_config(); cm = cfg["model"]
run_dir = tof_path(args.run)
log = setup_logging(run_dir / "evaluate.log")
torch.set_num_threads(int(cm["threads"]))
model, meta = load_checkpoint(run_dir / args.checkpoint)
device, device_desc = pick_device(args.device or cm.get("device", "auto")); model.to(device)
threshold = args.threshold if args.threshold is not None else float(meta["threshold"])
work = tof_path(cm["paths"]["work_dir"])
manifest = load_manifest(work)
pairs = manifest[(manifest["status"] == "ok") & (manifest["split"] == args.split)].reset_index(drop=True)
stats = meta["band_stats"]
res = evaluate_split(model, pairs, work / "pairs", np.array(stats["mean"]), np.array(stats["std"]), int(meta["patch_size"]),
                     int(cm["eval_stride"]), threshold, int(cm["batch_size"]), 0, run_dir / f"{args.split}_scenes_thr{threshold:.2f}.csv", device)
log.info("%s split, %d scenes, threshold %.2f: F1 %.4f IoU %.4f precision %.3f recall %.3f accuracy %.4f",
         args.split, res["scenes"], threshold, res["f1"], res["iou"], res["precision"], res["recall"], res["accuracy"])
with open(run_dir / f"{args.split}_metrics_thr{threshold:.2f}.json", "w") as f:
    json.dump(res, f, indent=2)
