import os
import re
from pathlib import Path
from collections import defaultdict

import numpy as np
import rasterio
import geopandas as gpd
from rasterio.features import geometry_mask
from rasterio.windows import Window


# ============================================================
# CONFIG
# ============================================================

INPUT_DIR = Path(
    r"N:\Research\Ogle\Agroforestry\phase2_sampling\data\LRRF_heightDistribution\naips\draft_predictions\120333"
)

MASK_GPKG = Path(
    r"C:\Users\C832742681\Documents\testMask.gpkg"
)

OUTPUT_DIR = INPUT_DIR / "temporal_change"

OUTPUT_NODATA = 255

# Size of processing chunks.
# Larger = generally faster, but uses more RAM.
WINDOW_SIZE = 2048


# ============================================================
# FILE NAME PARSING
# ============================================================

def parse_filename(filepath):
    """
    Expected filename structure:

        something_something_GRIDID_YEAR_....

    Grid ID = text between 2nd and 3rd "_"
    Year    = four digits after 3rd "_"
    """

    stem = filepath.stem
    parts = stem.split("_")

    if len(parts) < 4:
        print('len issue')
        return None

    grid_id = parts[2]

    # Find four-digit year after the third "_"
    # i.e. beginning at parts[3]
    year = None

    for part in parts[3:]:
        match = re.match(r"^(\d{4})", part)
        if match:
            year = int(match.group(1))
            break

    if year is None:
        return None

    return grid_id, year


# ============================================================
# FIND AND GROUP TIFS
# ============================================================

print("Scanning TIFF files...")

groups = defaultdict(list)

for tif in INPUT_DIR.glob("*.tif"):
    if tif.name.endswith("_temporal_change.tif"):
        continue
    parsed = parse_filename(tif)

    if parsed is None:
        print(f"Skipping unrecognized filename: {tif.name}")
        continue

    grid_id, year = parsed
    groups[grid_id].append((year, tif))


print(f"Found {len(groups):,} grid IDs.")


# ============================================================
# KEEP ONLY GROUPS WITH EXACTLY 3 YEARS
# ============================================================

valid_groups = {}

for grid_id, files in groups.items():

    # Remove duplicate years if present
    year_dict = {}

    for year, tif in files:
        year_dict[year] = tif

    if len(year_dict) != 3:
        print(
            f"Skipping grid {grid_id}: "
            f"expected 3 years, found {len(year_dict)}"
        )
        continue

    valid_groups[grid_id] = sorted(year_dict.items())


print(f"Grids with exactly 3 years: {len(valid_groups):,}")


# ============================================================
# LOAD MASK
# ============================================================

print("\nLoading mask...")

mask_gdf = gpd.read_file(MASK_GPKG)

if mask_gdf.empty:
    raise ValueError("Mask GeoPackage contains no geometries.")

# ============================================================
# OUTPUT DIRECTORY
# ============================================================

OUTPUT_DIR.mkdir(parents=True, exist_ok=True)


# ============================================================
# PROCESS
# ============================================================

total = len(valid_groups)

for counter, (grid_id, year_files) in enumerate(valid_groups.items(), start=1):

    try:

        # ----------------------------------------------------
        # SORTED YEARS
        # ----------------------------------------------------

        earliest_year, earliest_path = year_files[0]
        middle_year, middle_path = year_files[1]
        latest_year, latest_path = year_files[2]

        output_path = OUTPUT_DIR / f"{grid_id}_temporal_change.tif"

        print(
            f"[{counter:,}/{total:,}] "
            f"{grid_id}: "
            f"{earliest_year}, {middle_year}, {latest_year}"
        )

        # ----------------------------------------------------
        # OPEN THE THREE RASTERS
        # ----------------------------------------------------

        with rasterio.open(earliest_path) as src_early, \
             rasterio.open(middle_path) as src_middle, \
             rasterio.open(latest_path) as src_latest:

            # ------------------------------------------------
            # CHECK ALIGNMENT
            # ------------------------------------------------

            if (
                src_early.width != src_middle.width
                or src_early.height != src_middle.height
                or src_early.width != src_latest.width
                or src_early.height != src_latest.height
            ):
                raise ValueError("Raster dimensions do not match.")

            if (
                src_early.transform != src_middle.transform
                or src_early.transform != src_latest.transform
            ):
                raise ValueError("Raster transforms do not match.")

            if (
                src_early.crs != src_middle.crs
                or src_early.crs != src_latest.crs
            ):
                raise ValueError("Raster CRSs do not match.")

            # ------------------------------------------------
            # GET MASK GEOMETRIES
            # ------------------------------------------------

            # Reproject mask once to the raster CRS.
            mask_in_crs = mask_gdf.to_crs(src_early.crs)

            geometries = list(mask_in_crs.geometry)

            # ------------------------------------------------
            # OUTPUT PROFILE
            # ------------------------------------------------

            profile = src_early.profile.copy()

            profile.update(
                driver="GTiff",
                dtype="uint8",
                count=1,
                nodata=OUTPUT_NODATA,
                compress="lzw",
                predictor=2,
                BIGTIFF="IF_SAFER",
            )

            # ------------------------------------------------
            # CREATE OUTPUT
            # ------------------------------------------------

            with rasterio.open(output_path, "w", **profile) as dst:

                # --------------------------------------------
                # PROCESS IN WINDOWS
                # --------------------------------------------

                for row_start in range(0, src_early.height, WINDOW_SIZE):

                    height = min(
                        WINDOW_SIZE,
                        src_early.height - row_start
                    )

                    for col_start in range(0, src_early.width, WINDOW_SIZE):

                        width = min(
                            WINDOW_SIZE,
                            src_early.width - col_start
                        )

                        window = Window(
                            col_start,
                            row_start,
                            width,
                            height
                        )

                        # ------------------------------------
                        # READ THREE BINARY RASTERS
                        # ------------------------------------

                        early = src_early.read(
                            1,
                            window=window
                        )

                        middle = src_middle.read(
                            1,
                            window=window
                        )

                        latest = src_latest.read(
                            1,
                            window=window
                        )

                        # ------------------------------------
                        # TEMPORAL ENCODING
                        #
                        # earliest * 1
                        # middle   * 3
                        # latest   * 5
                        #
                        # Possible values:
                        #
                        # 0 = 000
                        # 1 = 001
                        # 3 = 010
                        # 4 = 011
                        # 5 = 100
                        # 6 = 101
                        # 8 = 110
                        # 9 = 111
                        # ------------------------------------

                        result = (
                            early.astype(np.uint8)
                            + middle.astype(np.uint8) * 3
                            + latest.astype(np.uint8) * 5
                        )

                        # ------------------------------------
                        # CREATE MASK FOR THIS WINDOW
                        # ------------------------------------

                        transform = rasterio.windows.transform(
                            window,
                            src_early.transform
                        )

                        mask = geometry_mask(
                            geometries,
                            out_shape=(height, width),
                            transform=transform,
                            invert=True
                        )

                        # Wherever mask == 1 -> NODATA
                        result[mask] = OUTPUT_NODATA

                        # ------------------------------------
                        # WRITE
                        # ------------------------------------

                        dst.write(
                            result,
                            1,
                            window=window
                        )

        print(f"    -> {output_path.name}")

    except Exception as e:

        print(
            f"    ERROR processing grid {grid_id}: {e}"
        )


print("\nFinished.")
print(f"Output directory: {OUTPUT_DIR}")