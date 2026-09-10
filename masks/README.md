# Agroforestry LLR Masks

R workflow that builds annual **forest** and **urban** mask products covering a
whole USDA Land Resource Region (LRR), from Annual NLCD and US Census places.

For the current configuration (LRR `F`, 2009–2021) that is 13 years × 4 layers.

Forest comes from NLCD; urban comes from Census places rather than the NLCD
developed classes, so that these products line up with the other teams'
carbon-storage metrics for forest and urban areas. The subject of the work is
trees *outside* of forests, so the two masks are used together.

## Products

Everything lands in `outputs/llr_masks/`, one set per year:

| file | contents |
|---|---|
| `llr_F_forest_<year>.tif` | `0` = not forest, `1` = forest, 30 m, INT1U, NoData 255 |
| `llr_F_forest_<year>.gpkg` | the same mask as polygons, EPSG:5070 |
| `llr_F_places_<year>.gpkg` | Census places clipped to the study area, attributes intact |
| `llr_F_urban_<year>.gpkg` | those places dissolved into a single urban mask |

Plus `llr_F_study_area.gpkg` (the exact clip boundary) and
`llr_mask_summary.csv` (per-year forest percentage, place count, and Census
provenance).

The **rasters stay on the native NLCD grid** and the **polygons are written in
EPSG:5070**. Reprojecting a categorical raster resamples it for no gain, whereas
vector reprojection is exact — so the lossless archive stays where the source
data is, and the working product lands in the project frame. Set
`llr_raster_crs` in `src/02_llr_masks.R` to reproject the rasters too.

The polygon version is what carries the mask across a resolution change: a
polygon boundary can be intersected against any grid, whereas a 30 m raster can
only be resampled onto one.

## Study area

All products are clipped to the LRR polygon **buffered by 1 km**
(`llr_buffer_m`). The buffer is comfortably wider than one 30 m NLCD pixel, so
no real data is lost where the irregular boundary cuts through a pixel.

The buffer is applied to the *unioned* LRR polygon. Buffering the parts
separately and unioning afterwards leaves hairline slivers along shared internal
edges.

## Repository Structure

```text
agroforestry_Masks/
├── 0_run.R                        # Runs the three steps in order
├── data/
│   ├── lower48LRR.gpkg            # LRR boundaries (input)
│   ├── raw/NLCD/                  # Downloaded national NLCD GeoTIFFs
│   ├── raw/census/                # Census places per year
│   └── processed/NLCD/            # LRR-scale cropped + binary rasters
├── outputs/llr_masks/             # The products
└── src/
    ├── 00_global_init.R           # Config, packages, LRR boundary
    ├── 01_pipeline_worker.R       # Download + prepare NLCD and Census
    ├── 02_llr_masks.R             # Build the LLR-scale products
    └── 99_audit_census_cache.R    # Check the Census cache for silent fallbacks
```

## Running

```r
source("0_run.R")
```

or the final step alone, once the inputs are cached:

```sh
Rscript src/02_llr_masks.R
```

Step 2 downloads ~1.3 GB per NLCD year on first run and is skipped thereafter.
Step 3 takes roughly two minutes per year, most of it polygonising a
1.1-billion-cell raster.

## Caveat: three years of Census places are substituted

Not every year is served by the Census API. When a year is unavailable the
pipeline falls back to the nearest available year and records what it actually
used in a `census_source_year` column, carried into every places and urban
layer and reported in `llr_mask_summary.csv`.

For the current cache:

```text
2009 <- 2011     2010 <- 2011     2013 <- 2012
```

The urban masks for those three years do not reflect that year's place
boundaries. The other ten are genuine. **Pass this on with the data**, since the
filenames say 2009/2010/2013.

Run `src/99_audit_census_cache.R` to re-check the cache for silent fallbacks.

## Note on the place-count step change

Place counts sit at 717–720 for 2009–2019 and jump to 817 for 2020–2021. That is
the decennial boundary revision, not growth. Anything longitudinal across that
break should account for it as a definitional change.
