#!/usr/bin/env python
"""Compare a run's panel predictions with a variant of them (other imagery, same model).

    model/.venv/bin/python model/tools/compare_panel_variants.py --run data/model/runs/<run> --variant panel_h2015 [--cells <csv>]

Reads <run>/panel/panel_cells.csv (the reference) and <run>/<variant>/panel_cells.csv,
restricts both to the cells of --cells (or to the cells the variant has), and
reports per MLRA and overall: mean predicted tree share per target year, and
the "middle-year dip" per cell (2016 share minus the mean of the cell's 2012
and 2020 shares) for the reference and the variant. Writes
<run>/<variant>/compare_with_panel.csv.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from tofunet.config import tof_path  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--run", required=True)
ap.add_argument("--variant", required=True)
ap.add_argument("--reference", default="panel")
ap.add_argument("--cells", default=None)
args = ap.parse_args()

run = tof_path(args.run)
ref = pd.read_csv(run / args.reference / "panel_cells.csv", dtype={"id": str, "MLRARSYM": str})
var = pd.read_csv(run / args.variant / "panel_cells.csv", dtype={"id": str, "MLRARSYM": str})
ids = set(var["id"])
if args.cells:
    ids &= set(pd.read_csv(tof_path(args.cells), dtype={"id": str})["id"])
ref = ref[ref["id"].isin(ids)]; var = var[var["id"].isin(ids)]


def wide(d: pd.DataFrame) -> pd.DataFrame:
    d = d.dropna(subset=["target_year"]).copy(); d["target_year"] = d["target_year"].astype(int)
    w = d.pivot_table(index=["id", "MLRARSYM"], columns="target_year", values="pred_share_pp", aggfunc="first")
    w.columns = [str(c) for c in w.columns]
    if {"2012", "2016", "2020"} <= set(w.columns):
        w["dip_2016_pp"] = w["2016"] - (w["2012"] + w["2020"]) / 2
    return w.reset_index()


wr, wv = wide(ref), wide(var)
m = wr.merge(wv, on=["id", "MLRARSYM"], suffixes=("_ref", "_var"))
m.to_csv(run / args.variant / "compare_with_panel.csv", index=False)
cols = [c for c in ("2012", "2016", "2020", "dip_2016_pp") if f"{c}_ref" in m.columns]
rows = []
for name, g in [("all", m)] + [(f"MLRA {k}", g) for k, g in m.groupby("MLRARSYM")]:
    r = {"group": name, "cells": len(g)}
    for c in cols:
        r[f"{c} ref"] = g[f"{c}_ref"].mean(); r[f"{c} var"] = g[f"{c}_var"].mean()
    rows.append(r)
out = pd.DataFrame(rows)
pd.set_option("display.width", 220)
print(f"{run.name}: {args.variant} against {args.reference}, {len(m)} cells; mean predicted tree share (pp) per target year and the 2016 dip")
print(out.round(3).to_string(index=False))
if "dip_2016_pp_ref" in m.columns:
    cnt = lambda d: int((d["dip_2016_pp"] < -0.2 * d[["2012", "2020"]].mean(axis=1)).sum())  # noqa: E731
    print(f"cells whose 2016 share sits more than 20 % below their own 2012/2020 mean: reference {cnt(wr[wr.id.isin(ids)])}, variant {cnt(wv)}")
