import time
from pathlib import Path
import rasterio
from rasterio.features import rasterize
import geopandas as gpd
from shapely.geometry import box

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

input_yearly_file_folder = Path('D:/Shahriar/Work_Datasets/Agroforestry/NE_Unet_maps/')
classified_map_file_pattern = 'X12-{grid_id}_{year}_trees_map.tif'
grid_range = range(1,774)

# Note: It is assumed that the Makss folder contains three forest vector masks and three settlements vector masks.
# The forest masks should be named forestxxxxpoly.gpkg and the settlement maks should be named tl_xxxx_31_place.shp
# where xxxx is the year (2010/2016/2020).
masks_folder = Path('D:/Shahriar/Work_Datasets/Agroforestry/Masks')
forest_mask_file_format = 'forest{year}poly.gpkg'
settlement_mask_file_format = 'tl_{year}_31_place.shp'

output_folder = Path('D:/Shahriar/Work_Datasets/Agroforestry/NE_Unet_maps/Masked')
yearly_output_file_format = 'X12-{grid_id}_{year}_masked_Unet.tif'
COT_output_file_format = 'X12-{grid_id}_changeOverTime_Unet.tif'

def do_masking(raster_path, year):

    # A) read input raster data and metadata
    with rasterio.open(raster_path) as input_raster:
        data = input_raster.read(1)
        data_profile = input_raster.profile.copy()
        raster_bounds = input_raster.bounds
        raster_height = input_raster.height
        raster_width = input_raster.width
        raster_crs = input_raster.crs
        raster_transform = input_raster.transform

    # Step 1: mask input raster with NLCD forest vector mask
    # -------------------------------------------------------

    # A) Load vector and ensure CRS matches raster
    gdf = gpd.read_file(masks_folder / forest_mask_file_format.format(year=year))
    if gdf.crs != raster_crs:
        gdf = gdf.to_crs(raster_crs)

    # B) Clip vector to raster bounds
    bbox = box(*raster_bounds)
    clipped = gdf.clip(bbox)

    # C) Rasterize clipped vector to raster grid
    mask_1m = rasterize(
        ((geom, 1) for geom in clipped.geometry),  # burn value = 1
        out_shape=(raster_height, raster_width),
        transform=raster_transform,
        fill=0,
        dtype="uint8"
    )

    masked_data = data * (1-mask_1m)

    # Step 2: mask input raster with tiger lines vector mask
    # -------------------------------------------------------

    # A) Load vector and ensure CRS matches raster
    gdf = gpd.read_file(masks_folder / settlement_mask_file_format.format(year=year))
    if gdf.crs != raster_crs:
        gdf = gdf.to_crs(raster_crs)

    # B) Clip vector to raster bounds
    bbox = box(*raster_bounds)
    clipped = gdf.clip(bbox)

    # C) Rasterize clipped vector to raster grid
    mask_1m = rasterize(
        ((geom, 1) for geom in clipped.geometry),  # burn value = 1
        out_shape=(raster_height, raster_width),
        transform=raster_transform,
        fill=0,
        dtype="uint8"
    )

    masked_data = masked_data * (1-mask_1m)

    return masked_data, data_profile

# --- Loop over all grid files
time0 = time.time()
for grid_id in grid_range:

    print('Processing grid#', grid_id)

    raster_path_2010 = input_yearly_file_folder / classified_map_file_pattern.format(grid_id=str(grid_id),year='2010')
    raster_path_2016 = input_yearly_file_folder / classified_map_file_pattern.format(grid_id=str(grid_id),year='2016')
    raster_path_2020 = input_yearly_file_folder / classified_map_file_pattern.format(grid_id=str(grid_id),year='2020')
    if not raster_path_2010.exists():
        print(f"Raster not found: {raster_path_2010}, skipping.")
        continue
    if not raster_path_2016.exists():
        print(f"Raster not found: {raster_path_2016}, skipping.")
        continue
    if not raster_path_2020.exists():
        print(f"Raster not found: {raster_path_2020}, skipping.")
        continue

    data_2010, data_profile = do_masking(raster_path_2010, '2010')
    data_2016, _ = do_masking(raster_path_2016, '2016')
    data_2020, _ = do_masking(raster_path_2020, '2020')
    with rasterio.open(output_folder / "Yearly" / yearly_output_file_format.format(grid_id=str(grid_id), year=str(2010)), "w", **data_profile) as dst:
        dst.write(data_2010, 1)
    with rasterio.open(output_folder / "Yearly" /yearly_output_file_format.format(grid_id=str(grid_id), year=str(2016)), "w", **data_profile) as dst:
        dst.write(data_2016, 1)
    with rasterio.open(output_folder / "Yearly" / yearly_output_file_format.format(grid_id=str(grid_id), year=str(2020)), "w", **data_profile) as dst:
        dst.write(data_2020, 1)

    COT_data = data_2010 + data_2016*3 + data_2020*5

    with rasterio.open(output_folder / "COT" / COT_output_file_format.format(grid_id=str(grid_id)), "w", **data_profile) as dst:
        dst.write(COT_data, 1)

print('Total elapsed time was {:.0f} seconds'.format(time.time()-time0))

#Total elapsed time was 13518 seconds

