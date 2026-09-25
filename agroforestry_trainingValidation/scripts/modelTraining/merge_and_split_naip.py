from pathlib import Path
import rasterio
from rasterio.merge import merge
from rasterio.windows import Window
import time, os

input_folder = Path("O:/Agroforestry/phase1_nebraska/shahriar/temp")
output_folder = Path("O:/Agroforestry/phase1_nebraska/shahriar/temp/tiles")
input_grid_IDs = [1,2]
years = [2010]

for year in years:
    for grid_ID in input_grid_IDs:

        start_time = time.time()
        print(f'Processing grid ID {grid_ID} for year {year}')
        os.makedirs(str(output_folder / f"X12-{grid_ID}_{year}"), exist_ok=True)
        # Open the 4 input rasters
        tif_files = input_folder.glob("*X12-"+str(grid_ID)+"_"+str(year)+"*.tif")
        srcs = [rasterio.open(f) for f in tif_files]
        if len(srcs) > 1:
        # Merge in memory
            mosaic, out_trans = merge(srcs)  # mosaic.shape = (bands, height, width)
            out_meta = srcs[0].meta.copy()
            out_meta.update({"transform": out_trans})
        # print(' - Execution time was {:.0f} seconds'.format(time.time()-start_time))
        else:
            mosaic = srcs[0].read()
            out_meta = srcs[0].meta.copy()
            out_trans = out_meta['transform']

        # start_time = time.time()
        # Compute tile size in pixels (2 mi at 1 m resolution)
        tile_size = 3228
        print('Creating subgrid files...')
        n_tiles = 6  # 12 mi / 2 mi
        for row in range(n_tiles):
            for col in range(n_tiles):
                if row == n_tiles-1:
                    row_start = mosaic.shape[1] - tile_size
                else:
                    row_start = row*tile_size
                if col == n_tiles-1:
                    col_start = mosaic.shape[2] - tile_size
                else:
                    col_start = col*tile_size
                window = Window(col_start, row_start, tile_size, tile_size)
                tile = mosaic[:, window.row_off:window.row_off + window.height,
                                  window.col_off:window.col_off + window.width]

                tile_meta = out_meta.copy()
                tile_meta.update({
                    "height": tile.shape[1],
                    "width": tile.shape[2],
                    "transform": rasterio.windows.transform(window, out_trans),
                    "driver": "GTiff",
                    "compress": "lzw",  # or "deflate", "zstd", "jpeg" (for RGB)
                    "tiled": True,  # good for large rasters
                    "blockxsize": 256,  # tile size (multiples of 16, common is 256)
                    "blockysize": 256
                })
                out_name = output_folder / f"X12-{grid_ID}_{year}" / f"X12-{grid_ID}_{year}_naip_tile_{row}_{col}.tif"
                with rasterio.open(out_name, "w", **tile_meta) as dst:
                    dst.write(tile)

        print(' - Execution time was {:.0f} seconds'.format(time.time()-start_time))

    # Execution time was about 90 seconds, total created files size 1.8GB
    # for 773 grid cells: execution time will be about 20 hours and the space required will be about 1.4TB.
