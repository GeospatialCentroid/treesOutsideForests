import re
import geopandas as gpd
import rasterio
import numpy as np
import pandas as pd
from pathlib import Path
import sys

# COT values definition (2010*1 + 2016*3 + 2020*5):
# 0: no tree in all years
# 1: tree in 2010 only
# 3: tree in 2016 only
# 4: tree in 2010 and 2016
# 5: tree in 2020 only
# 6: tree in 2010 and 2020
# 8: tree in 2016 and 2020
# 9: tree in all years

# --- Inputs ---
COT_range = [1,3,4,5,6,8,9]
point_files = list(Path(r'O:\Agroforestry\phase2_sampling\data\LRRF_heightDistribution\tree_tops').glob('*.gpkg'))
COT_folder = Path(r'O:\Agroforestry\phase2_sampling\data\LRRF_maps\masked_COT')
output_folder = Path(r'O:\Agroforestry\phase2_sampling\data\LRRF_heightDistribution\tree_tops')

for COT in COT_range:
    print(f'\nProcessing for COT={COT}:')
    output_file = f'COT{COT}.gpkg'

    # Collect results
    all_filtered_points = []

    # --- Loop over all point files recursively ---
    for point_file in point_files:
        # print(f'Processing point file {point_file}:')
        name_split = point_file.stem.split('_')
        scene_id = name_split[2]
        year = name_split[8][3:]
        if len(year) != 4:
            print(f' -> Lidar year field for file {point_file.name} is in wrong format. Skip to the next file.')
            continue

        raster_path = COT_folder / "part1" / f"{scene_id}_COT.tif"
        if not raster_path.exists():
            raster_path = COT_folder / "part2" / f"{scene_id}_COT.tif"
            if not raster_path.exists():
                raster_path = COT_folder / "part3" / f"{scene_id}_COT.tif"
                if not raster_path.exists():
                    raster_path = COT_folder / "part4" / f"{scene_id}_COT.tif"
                    if not raster_path.exists():
                        print(f" -> Corresponding raster file for file {point_file.name} not found, skipping.")
                        continue

        # Load points
        points_gdf = gpd.read_file(point_file)

        # Add source file name column
        points_gdf["scene_id"] = scene_id
        points_gdf["year"] = year

        # Sample raster values
        with rasterio.open(raster_path) as src:
            if points_gdf.crs != src.crs:
                points_gdf = points_gdf.to_crs(src.crs)

            coords = [(geom.x, geom.y) for geom in points_gdf.geometry]
            sampled_vals = np.array(list(src.sample(coords)))[:, 0]

        # Keep only points where raster value is within COT values
        mask = np.isin(sampled_vals, [COT])
        filtered_points = points_gdf.loc[mask]

        if not filtered_points.empty:
            all_filtered_points.append(filtered_points)

    # --- Merge results ---
    if all_filtered_points:
        final_gdf = pd.concat([g.to_crs(5070) for g in all_filtered_points], ignore_index=True)
        final_gdf.to_file(output_folder / output_file, driver="GPKG")
        print(f"Final point file written: {output_file}")
    else:
        print("No points matched any raster mask.")