"""Bootstrap intervals over scenes for pooled and per-scene statistics."""
from __future__ import annotations

import warnings
from typing import Callable

import numpy as np
import pandas as pd

Stat = Callable[[pd.DataFrame], dict[str, float]]


def _safe_polyfit(x: pd.Series, y: pd.Series) -> tuple[float, float]:
    if len(x) >= 3 and float(np.std(x)) > 0:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", np.exceptions.RankWarning)  # near-constant x in small bootstrap slices
            slope, intercept = np.polyfit(x, y, 1)
        return float(slope), float(intercept)
    return float("nan"), float("nan")


def scene_stats(d: pd.DataFrame) -> dict[str, float]:
    """T0 and T1 statistics for a set of scored scenes (rows of t0/t1 tables)."""
    tp, fp, fn = (float(d[c].sum()) for c in ("tp", "fp", "fn"))
    precision = tp / max(tp + fp, 1); recall = tp / max(tp + fn, 1)
    true_m2, pred_m2, soft_m2 = (float(d[c].sum()) for c in ("true_m2", "pred_m2", "soft_m2"))
    err = d["pred_share_pp"] - d["true_share_pp"]
    soft_err = d["soft_share_pp"] - d["true_share_pp"]
    slope, intercept = _safe_polyfit(d["true_share_pp"], d["pred_share_pp"])
    out = {
        "f1_pooled": 2 * tp / max(2 * tp + fp + fn, 1),
        "precision_pooled": precision, "recall_pooled": recall,
        "iou_pooled": tp / max(tp + fp + fn, 1),
        "f1_scene_mean": float(d["f1"].mean()), "f1_scene_median": float(d["f1"].median()),
        "f1_r1_scene_mean": float(d["f1_r1"].mean()) if "f1_r1" in d else float("nan"),
        "f1_r2_scene_mean": float(d["f1_r2"].mean()) if "f1_r2" in d else float("nan"),
        "area_bias_ratio": pred_m2 / true_m2 if true_m2 > 0 else float("nan"),
        "soft_area_bias_ratio": soft_m2 / true_m2 if true_m2 > 0 else float("nan"),
        "share_bias_pp": float(err.mean()), "share_mae_pp": float(err.abs().mean()),
        "share_rmse_pp": float(np.sqrt((err ** 2).mean())),
        "soft_share_bias_pp": float(soft_err.mean()), "soft_share_mae_pp": float(soft_err.abs().mean()),
        "true_share_mean_pp": float(d["true_share_pp"].mean()), "pred_share_mean_pp": float(d["pred_share_pp"].mean()),
        "calib_slope": slope, "calib_intercept_pp": intercept,
    }
    if "true_m2_elig" in d:
        te, pe, se = (float(d[c].sum()) for c in ("true_m2_elig", "pred_m2_elig", "soft_m2_elig"))
        eerr = d["pred_share_elig_pp"] - d["true_share_elig_pp"]
        out |= {"area_bias_ratio_elig": pe / te if te > 0 else float("nan"),
                "soft_area_bias_ratio_elig": se / te if te > 0 else float("nan"),
                "share_mae_elig_pp": float(eerr.abs().mean())}
    return out


def change_stats(d: pd.DataFrame, stable_tol_pp: float = 0.05) -> dict[str, float]:
    """T2 statistics over year pairs: delta error, and false change on pairs
    whose true change is within `stable_tol_pp`."""
    err = d["pred_delta_pp"] - d["true_delta_pp"]
    soft_err = d["soft_delta_pp"] - d["true_delta_pp"]
    stable = d[d["true_delta_pp"].abs() <= stable_tol_pp]
    moving = d[d["true_delta_pp"].abs() > stable_tol_pp]
    out = {
        "n_pairs": float(len(d)), "n_stable": float(len(stable)), "n_moving": float(len(moving)),
        "delta_bias_pp": float(err.mean()), "delta_mae_pp": float(err.abs().mean()),
        "delta_rmse_pp": float(np.sqrt((err ** 2).mean())),
        "soft_delta_mae_pp": float(soft_err.abs().mean()),
        "false_change_p90_pp": float(stable["pred_delta_pp"].abs().quantile(0.9)) if len(stable) else float("nan"),
        "false_change_mean_abs_pp": float(stable["pred_delta_pp"].abs().mean()) if len(stable) else float("nan"),
        "sign_agreement_moving": float((np.sign(moving["pred_delta_pp"]) == np.sign(moving["true_delta_pp"])).mean())
        if len(moving) else float("nan"),
    }
    return out


def bootstrap(d: pd.DataFrame, fn: Stat, n: int, rng: np.random.Generator,
              group: str | None = None) -> dict[str, dict[str, float]]:
    """Point estimate with 2.5 / 97.5 percentile interval over `n` resamples of
    rows (or of the groups in column `group`, so a cell's years move together)."""
    point = fn(d)
    if len(d) < 2:
        return {k: {"est": v, "lo": float("nan"), "hi": float("nan")} for k, v in point.items()}
    if group is None:
        idx = rng.integers(0, len(d), size=(n, len(d)))
        draws = pd.DataFrame([fn(d.iloc[i]) for i in idx])
    else:
        keys = d[group].unique()
        by = {k: g for k, g in d.groupby(group)}
        draws = pd.DataFrame([fn(pd.concat([by[k] for k in rng.choice(keys, size=len(keys), replace=True)]))
                              for _ in range(n)])
    lo, hi = draws.quantile(0.025), draws.quantile(0.975)
    return {k: {"est": v, "lo": float(lo[k]), "hi": float(hi[k])} for k, v in point.items()}


def bootstrap_diff(a: pd.DataFrame, b: pd.DataFrame, fn: Stat, n: int, rng: np.random.Generator,
                   keys: list[str]) -> dict[str, dict[str, float]]:
    """a minus b, each group resampled independently."""
    pa, pb = fn(a), fn(b)
    if len(a) < 2 or len(b) < 2:
        return {k: {"est": pa[k] - pb[k], "lo": float("nan"), "hi": float("nan"), "excludes_zero": False} for k in keys}
    ia = rng.integers(0, len(a), size=(n, len(a))); ib = rng.integers(0, len(b), size=(n, len(b)))
    da = pd.DataFrame([fn(a.iloc[i]) for i in ia]); db = pd.DataFrame([fn(b.iloc[i]) for i in ib])
    diff = da[keys] - db[keys]
    lo, hi = diff.quantile(0.025), diff.quantile(0.975)
    return {k: {"est": pa[k] - pb[k], "lo": float(lo[k]), "hi": float(hi[k]),
                "excludes_zero": bool(lo[k] > 0 or hi[k] < 0)} for k in keys}


def clean(o):
    """JSON-safe: NaN to None, numpy scalars to Python."""
    if isinstance(o, dict):
        return {str(k): clean(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [clean(v) for v in o]
    if isinstance(o, (np.floating, float)):
        return None if np.isnan(o) else float(o)
    if isinstance(o, np.integer):
        return int(o)
    if isinstance(o, np.bool_):
        return bool(o)
    return o


def fmt(e: dict, digits: int = 3) -> str:
    if e is None or e.get("est") is None or (isinstance(e["est"], float) and np.isnan(e["est"])):
        return "NA"
    if e.get("lo") is None or np.isnan(e["lo"]):
        return f"{e['est']:.{digits}f}"
    return f"{e['est']:.{digits}f} [{e['lo']:.{digits}f}, {e['hi']:.{digits}f}]"
