import re
import geopandas as gpd
import rasterio
import numpy as np
import pandas as pd
from pathlib import Path

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
regions = ['East', 'South','North']
COT_range = [1,3,4,5,6,8,9]
lookup_file = Path('D:/Shahriar/Work_Datasets/Agroforestry/tree_distribution_estimation/two_sq_grid_shahriar.gpkg')  # has subgrid_ID + grid_ID
tif_dir = Path('D:/Shahriar/Work_Datasets/Agroforestry/NE_Unet_maps/COT/Keep')  # folder with <grid_ID>_changeOverTime.tif

for region in regions:
    for COT in COT_range:
        # COT_filter = [COT]
        points_dir = Path(f'D:/Shahriar/Work_Datasets/Agroforestry/tree_distribution_estimation/2016_subgrids_round2/final_files/{region}')   # root folder with subfolders
        output_folder = Path(f'D:/Shahriar/Work_Datasets/Agroforestry/tree_distribution_estimation/2016_subgrids_round2/final_files/{region}/Unet_maps')
        # name_string = '&'.join([str(x) for x in COT_range])
        output_file = f'COT{COT}_{region}.gpkg'

        # --- Load lookup table ---
        lookup_gdf = gpd.read_file(lookup_file)
        lookup_gdf["subgridID"] = lookup_gdf["subgridID"].astype(str)

        # Compile regex: subgrid + digits (3–5 digits) + anything + _final.gpkg
        pattern = re.compile(r"subgrid(\d{3,5}).*_final\.gpkg$", re.IGNORECASE)

        # Collect results
        all_filtered_points = []

        # --- Loop over all point files recursively ---
        for point_file in points_dir.rglob("*.gpkg"):
            match = pattern.match(point_file.name)
            if not match:
                continue  # skip files that don't match the pattern

            print(f'Processing point file {point_file} ...')
            subgrid_id = match.group(1)

            # Find matching grid_ID
            match_row = lookup_gdf.loc[lookup_gdf["subgridID"] == subgrid_id]
            if match_row.empty:
                print(f"No grid_ID found for subgrid_ID {subgrid_id}, skipping.")
                continue

            grid_id = match_row.iloc[0]["Unique_ID"]
            raster_path = tif_dir / f"{grid_id}_changeOverTime_Unet.tif"
            if not raster_path.exists():
                print(f"Raster not found: {raster_path}, skipping.")
                continue

            # Load points
            points_gdf = gpd.read_file(point_file)
            # points_gdf.to_file(output_folder / point_file.name, driver="GPKG")


            # Add source file name column
            points_gdf["source_file"] = point_file.name

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
            final_gdf = gpd.GeoDataFrame(
                pd.concat(all_filtered_points, ignore_index=True),
                crs=all_filtered_points[0].crs
            )
            final_gdf.to_file(output_folder / output_file, driver="GPKG")
            print(f"Final point file written: {output_file}")
        else:
            print("No points matched any raster mask.")