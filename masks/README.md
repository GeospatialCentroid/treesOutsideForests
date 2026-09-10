# Agroforestry LLR Masks

R workflow that builds annual **forest** and **urban** mask products covering a
whole USDA Land Resource Region (LRR), from Annual NLCD and US Census places.

Forest comes from NLCD; urban comes from Census places rather than the NLCD
developed classes, so that these products line up with the other teams'
carbon-storage metrics for forest and urban areas. The subject of the work is
trees *outside* of forests, so the two masks are used together.

**A mask is only built for a year that has its own independent source layer.** A
year whose source cannot be retrieved gets no product for that mask, rather than
one carrying a neighbouring year's data under its filename. For the current
configuration (LRR `F`, 2009–2021) every year clears that bar: 13 forest years
and 13 urban years, each from its own release — see [Source data, year by
year](#source-data-year-by-year).

## Products

Everything lands in `data/masks/outputs/llr_masks/`, one set per year:

| file | contents |
|---|---|
| `llr_F_forest_<year>.tif` | `0` = not forest, `1` = forest, 30 m, INT1U, NoData 255 |
| `llr_F_forest_<year>.gpkg` | the same mask as polygons, EPSG:5070 |
| `llr_F_places_<year>.gpkg` | Census places clipped to the study area, attributes intact |
| `llr_F_urban_<year>.gpkg` | those places dissolved into a single urban mask |

Every layer is self-describing, so a file that reaches someone without this
README or the summary CSV still says what it is:

| layer | fields |
|---|---|
| forest polygons | `forest` (always 1), `year`, `lrr`, `source`, `nlcd_classes` |
| forest raster | the same, as GeoTIFF metadata tags (`gdalinfo` shows them) |
| places | the Census fields, plus `census_source_year`, `census_boundary_type`, `census_requested_year`, `area_retained` |
| urban | `urban` (always 1), `year`, `lrr`, `n_places`, `census_source_year`, `census_boundary_type` |

`area_retained` is the fraction of the place's own uncut geometry that survived
the clip, so `1` means the boundary did not touch it. `ALAND` and `AWATER`
describe the **whole** place as the Census published it, and the study boundary
cuts through some of them: 23 of the 717 places in 2017, 13 of those keeping
less than half, and Green Grass keeping 0.6% while still reporting its full
`ALAND`. The count is 20–25 in every year. **Measure area from the geometry,
never by summing `ALAND`.**

The denominator is the place's own geometry rather than `ALAND` deliberately —
a generalised (`cb`) place differs from its published area by a percent or two,
the same order as a light clip, so measuring against `ALAND` flagged 39
untouched places in 2014 and 20 in 2013 purely from the change of product.

The Census field set itself varies by vintage: TIGER/Line years carry
`NAMELSAD`, `CLASSFP`, `MTFCC`, `FUNCSTAT` and `INTPTLAT`/`INTPTLON`,
cartographic years carry `AFFGEOID`, and 2020–2021 add `STUSPS`/`STATE_NAME`.
The fields guaranteed in every year are `STATEFP`, `PLACEFP`, `PLACENS`,
`GEOID`, `NAME`, `LSAD`, `ALAND`, `AWATER` plus the provenance columns above.

The forest and urban masks are **not mutually exclusive** — they come from
different definitions, so a forested park inside a city is in both. The overlap
is small but real: 42.2 km² in 2017, 1.2% of that year's forest.

A year with no retrievable Census release would have no places or urban layer;
none of 2009–2021 is in that position.

Plus `llr_F_study_area.gpkg` (the exact clip boundary) and
`llr_mask_summary.csv`, which is the manifest for the delivery: per-year forest
percentage, which files were written, place count, and Census provenance
(`census_source_year`, `census_boundary_type`, and a plain-language
`census_status`).

The **rasters stay on the native NLCD grid** and the **polygons are written in
EPSG:5070**. Reprojecting a categorical raster resamples it for no gain, whereas
vector reprojection is exact — so the lossless archive stays where the source
data is, and the working product lands in the project frame. Set
`llr_raster_crs` in `masks/src/02_llr_masks.R` to reproject the rasters too.

Annual NLCD is published with the CRS string `AEA        WGS84`: EPSG:5070's
Albers parameters exactly, but a WGS84 datum label and no EPSG code, so software
reads the rasters and the polygons as two different CRSs. The rasters are
therefore **relabelled** to EPSG:5070 — the coordinates do not move (the offset
measures 0 m), only the declared frame changes, and `relabel_raster_crs()`
refuses to do it unless the projection parameters already match. Set
`llr_raster_crs_label <- NULL` to keep the source label instead.

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
treesOutsideForests/
├── config.yml                     # `masks:` section holds this stage's settings
├── data/
│   ├── reference/lower48LRR.gpkg  # LRR boundaries (input, tracked)
│   └── masks/                     # Working data for this stage (ignored)
│       ├── raw/NLCD/              # Downloaded national NLCD GeoTIFFs
│       ├── raw/census/            # Census places per year
│       │   └── tiger_direct/      # Zips fetched straight from the Census (2009, 2010)
│       ├── processed/NLCD/        # LRR-scale cropped + binary rasters
│       └── outputs/llr_masks/     # The products
└── masks/
    ├── 0_run.R                    # Runs the three steps in order
    └── src/
        ├── 00_global_init.R       # Reads config.yml, loads packages and the LRR boundary
        ├── 00_census_provenance.R # Is a cached Census file really that year?
        ├── 01_pipeline_worker.R   # Download + prepare NLCD and Census
        ├── 02_llr_masks.R         # Build the LLR-scale products
        └── 99_audit_census_cache.R # Check the Census cache for silent fallbacks
```

## Running

From the root project (open `treesOutsideForests.Rproj`):

```r
source("masks/0_run.R")
```

or the final step alone, once the inputs are cached:

```sh
Rscript masks/src/02_llr_masks.R
```

Target LRR, years, NLCD classes, and the Census policy flags are set in the
`masks` section of the root `config.yml`.

To rebuild only the vector products, for example after a change to the vector
schema, since polygonising is the expensive half of a run:

```sh
Rscript -e 'llr_overwrite_vectors <- TRUE; source("masks/src/02_llr_masks.R")'
```

Step 2 downloads ~1.3 GB per NLCD year on first run and is skipped thereafter.
Step 3 takes roughly two minutes per year, most of it polygonising a
1.1-billion-cell raster.

## Source data, year by year

Every product comes from its own year's release. `allow_census_year_substitution`
in `config.yml` (`masks` section) is `FALSE`, which means the pipeline never fills a gap
with a neighbouring year:

- a year whose source cannot be retrieved is recorded in a
  `data/masks/raw/census/census_places_<year>.unavailable` marker and produces no
  places or urban layer;
- `llr_mask_summary.csv` says so in `census_status` rather than leaving a blank
  row, because "no independent release" and "the step failed" are different
  facts;
- a substituted file from an earlier run is moved aside to a `.quarantine` name
  in the Census cache and its outputs are deleted, so the delivery cannot keep
  asserting a mask the policy no longer allows.

Setting the flag `TRUE` restores a nearest-year fallback. Every layer is stamped
with `census_source_year` either way, so provenance is readable from the data
rather than from the filename.

### Getting each year from the right place

Three of the thirteen years needed work to reach, and none of them turned out to
be genuinely missing. What looked like absent data was three different retrieval
problems:

| year | symptom | cause | fix |
|---|---|---|---|
| 2013 | `tigris` reported the cartographic file missing | it looks under `GENZ2013/shp/`; the files sit directly in `GENZ2013/` | fall back to that year's TIGER/Line release |
| 2010 | `places is not currently available for years prior to 2011` | `tigris` does not implement pre-2011 vintages | download `TIGER2010/PLACE/2010/tl_2010_<FIPS>_place10.zip` directly |
| 2009 | same, plus `states()` also fails for 2009 | 2009 has a per-state directory layout | download `TIGER2009/<FIPS>_<STATE NAME>/tl_2009_<FIPS>_place.zip` directly |

The Census publishes places as two products: a generalised **cartographic**
boundary file (`cb`, 2013 onwards) and the full-detail **TIGER/Line** file (all
years). Both are the year's own data, so either satisfies the policy. The
download prefers `cb` and falls back to TIGER/Line *for the same year*;
`census_boundary_type` records which was used — TIGER/Line for 2009–2013,
cartographic for 2014–2021.

That is a real difference in the delivered geometry: the two are generalised
differently, so boundaries measured off a `tiger` year are not drawn at the same
detail as those off a `cb` year. **The break sits between 2013 and 2014.** Its
effect on total urban area is small — 3,210.7 → 3,237.2 → 3,270.8 → 3,285.4 km²
for 2012–2015, so the `cb` step is +1.0%, in line with the ordinary year-on-year
change either side of it — but per-place geometry is coarser from 2014 on, which
matters for anything measuring edges rather than areas.

Field names are harmonised across vintages so no year needs special-casing: the
2010 decennial suffixes (`NAME10`, `ALAND10`) are stripped, and 2009's
`PLCIDFP` is renamed `GEOID`. 2009 carries one extra field of its own, `CPI`.

For 2009 the state layer used to *choose which state files to download* comes
from 2010, because `tigris::states(2009)` fails too. That selects files; it
supplies no geometry to any product, and the places themselves are 2009's.

Directly downloaded zips and their shapefiles are cached under
`data/masks/raw/census/tiger_direct/`.

Run `Rscript masks/src/99_audit_census_cache.R` to re-check the cache for silent fallbacks.

## Note on the place-count step changes

Place counts step twice, at both decennial censuses:

```text
2009        662
2010-2019   717-720
2020-2021   817
```

Neither step is growth; both are the decennial revision of what counts as a
place, and both are entirely CDPs (LSAD 57). Across 2009 → 2010 → 2011 the
incorporated places are identical — 513 cities, 94 villages, 1 town — while CDPs
go 54 → 112 → 112. Anything longitudinal across either break should treat it as
a definitional change.
