#!/usr/bin/env python
"""One row of metadata per prepared mask / imagery pair, joined from every source.

    model/.venv/bin/python model/tools/build_scene_meta.py [--out data/model/scene_meta.csv]

Step 1 of the testing plan (TESTING_PLAN.md, 9.2). For every manifest row with
status ok it joins:

- the manifest itself: split, mask path, image path, size, tree and valid fraction;
- the partner's partition CSV (config `sampling.partitions[model.partition]`):
  Type, cover_class, transition_class, CLUSTER_ID, tree_percentage, state 0..7,
  scene centre;
- the roles CSV of that partition: MLRA_ID, MLRARSYM, in_sample_list, groundtruth_year;
- the naip export's status.json: target and actual year, capture dates (first,
  last, month of the earliest, number of months spanned), NAIP item ids and states.
  Ten early-pull cells (30 pairs) have no status.json; their actual year is the
  export folder's year and their capture and item fields are empty
  (`status_json` = False);
- the harmonise log: action (linked / normalized), reference year, KS to reference.

Derived flags: `off_target` is `year not in naip.target_years`, the labelled-set
definition of a fallback year (the mask was drawn on 2011 imagery), not the
export's own target_year, which for these cells equals the mask year.
Exits 1 if any row is missing its MLRA or cover class.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from tofunet.config import load_config, setup_logging, tof_path  # noqa: E402
from tofunet.data import load_manifest  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--out", default=None, help="default: <model.paths.work_dir>/scene_meta.csv")
args = ap.parse_args()

cfg = load_config()
cm, cs, cn, ch = cfg["model"], cfg["sampling"], cfg["naip"], cfg["harmonize"]
work = tof_path(cm["paths"]["work_dir"])
out = tof_path(args.out) if args.out else work / "scene_meta.csv"
log = setup_logging(work / "scene_meta.log")

partition = cm["partition"]
target_years = {str(y) for y in cn["target_years"]}

# ---- manifest -------------------------------------------------------------
manifest = load_manifest(work)
n_all = len(manifest)
pairs = manifest[manifest["status"] == "ok"].copy()
pairs["year"] = pairs["year"].astype(int)
log.info("manifest: %d rows, %d prepared pairs over %d scenes", n_all, len(pairs), pairs["id"].nunique())

# ---- partition CSV --------------------------------------------------------
part_path = tof_path(cs["partitions"][partition]["csv"])
part = pd.read_csv(part_path, dtype={"scene_id": str})
state_cols = [c for c in part.columns if c.startswith("state ")]
part = part.rename(columns={"scene_id": "id", "Type": "partition_type",
                            **{c: c.replace(" ", "_") for c in state_cols}})
part["tree_percentage"] = part["tree_percentage"].astype(str).str.rstrip("%").astype(float)
keep = ["id", "partition_type", "cover_class", "transition_class", "CLUSTER_ID", "tree_percentage",
        "center_lon", "center_lat"] + [c.replace(" ", "_") for c in state_cols]
part = part[keep]
log.info("partition %s: %d scenes from %s", partition, len(part), part_path.name)

# ---- roles CSV ------------------------------------------------------------
roles_path = tof_path(cs["paths"]["roles_csv"].replace("{partition}", partition))
roles = pd.read_csv(roles_path, dtype={"id": str, "MLRA_ID": str, "MLRARSYM": str})
roles = roles[["id", "MLRA_ID", "MLRARSYM", "in_sample_list", "groundtruth_year"]]
roles = roles.drop_duplicates("id")   # a cell drawn by two MLRAs keeps the first, as 00_prepare_sites.R does
log.info("roles: %d cells from %s", len(roles), roles_path.name)

# ---- naip status.json -----------------------------------------------------
export_dir = tof_path(cn["paths"]["export_dir"])


def read_status(cell_id: str, year: int) -> dict:
    p = export_dir / f"aoi_{cell_id}_{year}" / "status.json"
    if not p.exists():
        # Early exports (September 2026 test pulls) have imagery but no status.json.
        # The export folder is named by the actual NAIP year, so that much is known.
        return {"status_json": False, "actual_year": str(year), "export_status": "no status.json; year from folder name"}
    with open(p) as f:
        s = json.load(f)
    dates = sorted({d.strip()[:10] for d in str(s.get("capture_dates", "")).split(";") if d.strip()})
    months = sorted({d[:7] for d in dates})
    items = [i.strip() for i in str(s.get("item_ids", "")).split(";") if i.strip()]
    states = sorted({x.strip() for x in str(s.get("naip_states", "")).split(";") if x.strip()})
    return {
        "status_json": True,
        "export_target_year": str(s.get("target_year", "")),
        "actual_year": str(s.get("actual_year", "")),
        "export_status": s.get("status", ""),
        "capture_first": dates[0] if dates else None,
        "capture_last": dates[-1] if dates else None,
        "capture_month": int(dates[0][5:7]) if dates else None,
        "n_capture_months": len(months),
        "two_month_mosaic": len(months) > 1,
        "n_items": len(items),
        "item_ids": "; ".join(items),
        "naip_states": "; ".join(states),
        "naip_state": states[0] if len(states) == 1 else ("; ".join(states) if states else None),
    }


status = pd.DataFrame([read_status(i, y) for i, y in zip(pairs["id"], pairs["year"])], index=pairs.index)

# ---- harmonise log --------------------------------------------------------
harm_path = tof_path(ch["paths"]["out_dir"]) / "harmonization_log.csv"
if harm_path.exists():
    harm = pd.read_csv(harm_path, dtype={"id": str})
    harm = harm.rename(columns={"action": "harm_action", "reference_year": "harm_reference_year",
                                "ks_to_reference": "harm_ks_to_reference", "mode": "harm_mode"})
    harm = harm[["id", "year", "harm_action", "harm_reference_year", "harm_ks_to_reference", "harm_mode"]]
    harm["year"] = harm["year"].astype(int)
    log.info("harmonise log: %d cell-years", len(harm))
else:
    harm = pd.DataFrame(columns=["id", "year", "harm_action", "harm_reference_year", "harm_ks_to_reference", "harm_mode"])
    log.warning("no harmonise log at %s; harm_* columns will be empty", harm_path)

# ---- join -----------------------------------------------------------------
meta = pd.concat([pairs, status], axis=1)
meta = meta.merge(part, on="id", how="left").merge(roles, on="id", how="left")
meta = meta.merge(harm, on=["id", "year"], how="left")
meta["off_target"] = ~meta["year"].astype(str).isin(target_years)
meta["actual_matches_mask_year"] = meta["actual_year"] == meta["year"].astype(str)
meta["partition"] = partition

front = ["key", "id", "year", "split", "partition", "partition_type", "MLRA_ID", "MLRARSYM", "in_sample_list",
         "cover_class", "transition_class", "CLUSTER_ID", "tree_percentage", "tree_fraction", "valid_fraction",
         "off_target", "actual_year", "actual_matches_mask_year", "export_target_year",
         "capture_first", "capture_last", "capture_month", "n_capture_months", "two_month_mosaic",
         "naip_state", "naip_states", "n_items", "harm_action", "harm_reference_year", "harm_ks_to_reference"]
rest = [c for c in meta.columns if c not in front]
meta = meta[front + rest].sort_values(["id", "year"]).reset_index(drop=True)

out.parent.mkdir(parents=True, exist_ok=True)
meta.to_csv(out, index=False)

# ---- report ---------------------------------------------------------------
log.info("wrote %s: %d rows, %d scenes", out, len(meta), meta["id"].nunique())
log.info("split: %s", meta["split"].value_counts().to_dict())
log.info("year: %s", meta["year"].value_counts().sort_index().to_dict())
log.info("off-target pairs: %d of %d", int(meta["off_target"].sum()), len(meta))
log.info("actual year differs from mask year: %d", int((~meta["actual_matches_mask_year"]).sum()))
log.info("capture month: %s", meta["capture_month"].value_counts().sort_index().to_dict())
log.info("two-month mosaics: %d", int(meta["two_month_mosaic"].sum()))
log.info("states: %s", meta["naip_state"].value_counts().to_dict())
log.info("harmoniser action: %s", meta["harm_action"].fillna("none").value_counts().to_dict())
log.info("cover class: %s", meta["cover_class"].value_counts().to_dict())
log.info("MLRA: %s", meta["MLRARSYM"].value_counts().to_dict())

problems = []
for col in ["MLRA_ID", "cover_class", "partition_type", "actual_year"]:
    n = int(meta[col].isna().sum())
    if n:
        problems.append(f"{n} rows missing {col}")
mismatch = meta[(meta["partition_type"].str.lower() != meta["split"].str.lower())]
if len(mismatch):
    problems.append(f"{len(mismatch)} rows whose manifest split differs from the partition Type")
if problems:
    for p in problems:
        log.error(p)
    sys.exit(1)
log.info("every row has its MLRA, cover class, partition type and actual year")
