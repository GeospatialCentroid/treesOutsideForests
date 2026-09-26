"""Reading a mask with its imagery window, the combined mask on a scene grid,
and writing the suite's GeoTIFFs."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import rasterio
from rasterio.enums import Resampling
from rasterio.warp import reproject, transform_bounds
from rasterio.windows import Window, transform as window_transform

MASK_NODATA = 255


def mask_window(ms, im) -> tuple[Window, Window]:
    """The overlap of mask and image, as a window in each (01_prepare.py's alignment)."""
    tm, ti = ms.transform, im.transform
    col_off = int(round((tm.c - ti.c) / ti.a)); row_off = int(round((tm.f - ti.f) / ti.e))
    c0, r0 = max(col_off, 0), max(row_off, 0)
    c1, r1 = min(col_off + ms.width, im.width), min(row_off + ms.height, im.height)
    return Window(c0, r0, c1 - c0, r1 - r0), Window(c0 - col_off, r0 - row_off, c1 - c0, r1 - r0)


def read_pair(mask_path: Path, image_path: Path):
    """(mask uint8 0/1/255, image window, crs, transform of the window). The mask
    is read on its overlap with the image; anything but 0 or 1 is no data."""
    with rasterio.open(mask_path) as ms, rasterio.open(image_path) as im:
        w_img, w_mask = mask_window(ms, im)
        mask = ms.read(1, window=w_mask).astype(np.uint8)
        crs = im.crs
        transform = window_transform(w_img, im.transform)
    mask[(mask != 0) & (mask != 1)] = MASK_NODATA
    return mask, w_img, crs, transform


class CombinedMask:
    """The masks stage's combined mask (NLCD forest or Census place) for one
    year, resampled by nearest neighbour onto a scene's grid. The 30 m raster
    product is used because the venv has no vector reader; the estimates stage
    measures the same layer from its polygon, which differs at pixel edges."""

    def __init__(self, masks_dir: Path, llr_id: str):
        self.masks_dir, self.llr_id = Path(masks_dir), llr_id
        self._open: dict[int, rasterio.DatasetReader] = {}

    def path(self, year: int) -> Path:
        return self.masks_dir / f"llr_{self.llr_id}_mask_{year}.tif"

    def _src(self, year: int):
        if year not in self._open:
            p = self.path(year)
            if not p.exists():
                raise FileNotFoundError(f"no combined mask for {year}: {p}")
            self._open[year] = rasterio.open(p)
        return self._open[year]

    def on_grid(self, year: int, crs, transform, shape: tuple[int, int]) -> np.ndarray:
        """bool (H, W): True where the pixel is inside the combined mask."""
        src = self._src(year)
        # Read only the source window that covers the scene, with a margin.
        h, w = shape
        xs = [transform.c, transform.c + transform.a * w]
        ys = [transform.f, transform.f + transform.e * h]
        left, bottom, right, top = transform_bounds(crs, src.crs, min(xs), min(ys), max(xs), max(ys))
        margin = 3 * src.res[0]
        win = src.window(left - margin, bottom - margin, right + margin, top + margin).round_offsets().round_lengths()
        data = src.read(1, window=win, boundless=True, fill_value=src.nodata if src.nodata is not None else 255)
        win_transform = src.window_transform(win)
        out = np.full(shape, 255, dtype=np.uint8)
        reproject(data, out, src_transform=win_transform, src_crs=src.crs, src_nodata=255,
                  dst_transform=transform, dst_crs=crs, dst_nodata=255, resampling=Resampling.nearest)
        return out == 1

    def close(self) -> None:
        for s in self._open.values():
            s.close()
        self._open.clear()


def _profile(crs, transform, shape, dtype, nodata) -> dict:
    return {"driver": "GTiff", "height": shape[0], "width": shape[1], "count": 1, "dtype": dtype, "crs": crs,
            "transform": transform, "nodata": nodata, "compress": "deflate", "tiled": True,
            "blockxsize": 256, "blockysize": 256}


def write_prob(path: Path, prob: np.ndarray, nodata: np.ndarray, crs, transform, tags: dict) -> None:
    arr = prob.astype(np.float32).copy()
    arr[nodata] = np.nan
    with rasterio.open(path, "w", **_profile(crs, transform, arr.shape, "float32", np.nan)) as dst:
        dst.write(arr, 1)
        dst.update_tags(**{k: str(v) for k, v in tags.items()})


def write_tof(path: Path, tree: np.ndarray, excluded: np.ndarray, crs, transform, tags: dict) -> None:
    """The estimator's format: 1 tree, 0 not, 255 where excluded (scene no data
    or inside the combined mask)."""
    arr = np.where(excluded, MASK_NODATA, tree.astype(np.uint8)).astype(np.uint8)
    with rasterio.open(path, "w", **_profile(crs, transform, arr.shape, "uint8", MASK_NODATA)) as dst:
        dst.write(arr, 1)
        dst.update_tags(legend="0 no tree, 1 tree outside forest, 255 no data or masked (NLCD forest / Census place)",
                        **{k: str(v) for k, v in tags.items()})


def pixel_area_m2(transform) -> float:
    return abs(transform.a * transform.e)
