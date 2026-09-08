# Aligning Mask Products to naipScrape Imagery — 2026-09-08

How the mask products need to change so their projection, resolution and extent
match the NAIP imagery produced by
[`naipScrape`](https://github.com/GeospatialCentroid/naipScrape) at commit
[`2386e60`](https://github.com/GeospatialCentroid/naipScrape/commit/2386e60b2a7a1a1244e2024a423cd0c8e9c9b7c0).

Everything below was verified against real files — the 46 NAIP exports in
`naipScrape/data/exportData/` and the grid cache in
`data/processed/llr_grids_sample.gpkg` — not inferred from reading code.

---

## Summary

The masks are not misaligned because of a bug in this repo. They are misaligned
because **naipScrape never adopted the Albers frame this project is built in**,
and instead inherits a different UTM grid for every AOI.

The fix does not require re-downloading imagery. Given only the EPSG code of the
NAIP tile used at each site, the entire NAIP grid — origin, dimensions, extent —
is reproducible from the AOI id. That is what `src/03_naip_reference.R` records.

---

## What naipScrape actually produces

`mergeAndExportNAIP()` in `function/postDownloadFunctions.R` builds its grid from
the CRS of the **first downloaded tile**:

```r
r1           <- terra::rast(files[1])
master_crs   <- terra::crs(r1)                                   # NAD83 / UTM zone N
aoi_buf_proj <- terra::project(terra::vect(st_buffer(aoi, 250)), master_crs)
temp         <- terra::rast(extent = terra::ext(aoi_buf_proj),
                            crs = master_crs, nlyrs = 4, resolution = 1)
```

No reprojection to Albers happens anywhere in the download path. The result:

| property | value |
|---|---|
| CRS | native NAIP UTM zone, **per AOI** — 26912/13/14/15 all present in LRR F |
| resolution | exactly 1 m, in UTM (source `gsd` is 0.6 m; naipScrape resamples) |
| origin | `ext()` of the 250 m-buffered AOI **projected into UTM** — anchored at that bbox's `xmin`/`ymin` |
| `naip_1.5km_*` | the full template |
| `naip_1km_*` | that grid cropped to the unbuffered AOI extent |
| type | INT1U, NoData 255, 4 bands, masked to the buffered AOI polygon |

Two details that matter and are easy to get wrong:

- `terra::rast(extent =, resolution =)` sets cell counts by **rounding**, not by
  ceiling, so the template extent can end up marginally *smaller* than the extent
  passed in. Call terra rather than reimplementing the arithmetic.
- `sf::st_buffer()` uses round joins by default, so the 1.5 km product is a
  rounded square, and the raster is the axis-aligned bbox of that shape rotated
  into UTM. Measured across the 46 exports, **5.6%–19.1%** of each image is
  NoData for purely geometric reasons, varying with the rotation angle.

### The tiles are not a fixed pixel size

A 1 km cell defined in Albers is a **rotated** quadrilateral in UTM, and the
rotation varies with distance from each zone's central meridian. The axis-aligned
bbox of a rotated square is always larger than the square, by a varying amount.

Measured across the 46 real exports:

```
sizes range from 1511 x 1542 to 1636 x 1665 px
```

Predicted across 300 randomly sampled AOIs from the full grid set:

```
width  1520 – 1714 px      height 1539 – 1747 px
261 distinct (w,h) shapes in 300 AOIs
```

**There is no 1000 × 1000 invariant in the current NAIP products.** Effectively
every AOI has a unique array shape. This is worth knowing independently of the
mask work, because those arrays are U-Net inputs.

"1 km cell, 1 m pixel, fixed pixel count" and "axis-aligned UTM tile" are
mutually exclusive. Only the Albers frame delivers the former — which is what
this repo already builds.

---

## What the mask pipeline produces

`process_grid()` in `src/02_run_pipeline.R` builds:

```r
grid_template <- terra::rast(terra::ext(grid_row), resolution = 1, crs = "EPSG:5070")
```

Exactly 1000 × 1000 px, EPSG:5070, origin fixed by the grid hierarchy. Outputs are
**vector** GeoPackages (`*_NLCD_Forest.gpkg`, `*_Census.gpkg`), 13 years ×
15,380 sites.

Against the NAIP grid: different CRS, different origin, ~5° rotation, different
dimensions, and vector rather than raster. Nothing aligns.

---

## The grid is fully reproducible from the EPSG code alone

This is the load-bearing finding, and it is why the plan works without touching
the imagery.

`naip_template()` in `src/03_naip_reference.R` mirrors naipScrape's call sequence.
Tested against all 46 exports with
`terra::compareGeom(crs, ext, rowcol, res)`:

```
1.5km grids reproduced: 46 / 46
1km   grids reproduced: 45 / 45   (one AOI has no 1km sibling)
```

Across UTM zones 26912, 26913, 26914 and 26915. So the JSON only needs to store
the EPSG; the pipeline computes the rest.

---

## Reference step — `src/03_naip_reference.R`

A standalone step. It does not depend on, and is not depended on by, `00`–`02`:

```sh
Rscript src/03_naip_reference.R
```

Design decisions:

- **One STAC query per site, covering all years.** The CRS was identical across
  all three years for every one of the 16 test AOIs, which fits how NAIP is
  tiled (fixed zone per state/quad). But per-year records are still emitted,
  because `actual_year` is needed for pairing regardless. One query per site
  (15,380) rather than one per site-year (46,000).
- **Resumable.** Progress is appended to `data/naip_reference_cache.jsonl` after
  every chunk; an interrupted run continues rather than re-querying.
- **Ambiguity is recorded, not hidden.** See below.
- Output: `data/naip_reference.json`, ~36 MB for the full sample.

Runtime is API-bound: ~5 s per site per worker, so roughly **5 h at 4 workers**
or **3 h at 8**. `naip_ref_workers` is deliberately low because the Planetary
Computer rate-limits aggressively.

### Validation

Run against the 16 AOIs that have real exports on disk:

```
epsg mismatches: 0 / 16
```

and the year-fallback logic — `c(y, y-1, y-2, y+1)`, identical in
`process_aoi.R` and `produce_groundTruthSites.R` — reproduced **every**
`actual_year` in the export folder names:

```
1869-4-16-8-3   2012->2011  2016->2015  2020->2021     (folder: aoi_..._2021)
1880-2-15-b-3   2012->2010  2016->2015  2020->2019     (folders: _2010 _2015 _2019)
2003-2-1-c-2    2012->2011  2016->2015  2020->2019     (folders: _2011 _2015 _2019)
```

### Known limitation: ~68 sites have an ambiguous CRS

naipScrape takes the CRS of `files[1]` — the first tile in the order the
catalogue returned it *at the time of the original download*. For AOIs whose
buffered footprint straddles a UTM zone boundary, that order decides the answer
and is not guaranteed stable on re-query. Demonstrated:

```
AOI on the 108°W line, 2019 -> 2 tiles:
  mt_m_4810824_se_12_060_20190722_20191218   epsg=26912
  mt_m_4810717_sw_13_060_20190713_20191218   epsg=26913
```

Counted across the real grid set:

```
UTM zones touched: {12: 1022, 13: 3107, 14: 10778, 15: 488}
AOIs whose 250 m-buffered footprint crosses a zone boundary: 68  (0.44%)
```

`downloadNAIP_vsi()` also silently skips tiles that fail to overlap, which shifts
`files[1]` again.

These sites carry `crs_ambiguous: true` and a full `epsg_candidates` list. For
the other 99.6%, ordering is irrelevant because there is only one candidate.
Verify the flagged sites against the imagery before relying on them.

---

## Changes to the mask pipeline

Implemented in `src/04_naip_aligned_masks.R` (`process_grid_naip()`,
`verify_against_naip()`); item 5 is the remaining scoping decision.

1. **Emit a raster mask on the NAIP grid.** Look up the site in
   `data/naip_reference.json`, build the template with `naip_template()`, and
   project the binary NLCD straight onto it:

   ```r
   tmpl <- naip_template(grid_row, epsg, which = "buffered")
   mask <- terra::project(nlcd_crop, tmpl, method = "near")
   ```

   One reprojection of the 30 m source, not two.

2. **Crop the NLCD to the buffered AOI, not the bare cell.** `process_grid()`
   crops to `grid_row` with a 30 m margin; on the 1.5 km extent that leaves the
   whole outer ring as NA. `process_grid_naip()` buffers first and then applies
   the 30 m margin, which is equivalent to a 280 m margin on the bare cell but
   states the intent directly.

3. **Clip Census to the buffered footprint**, not the 1 km cell, or the outer
   ring is undefined.

4. **Match the NAIP NoData footprint** — INT1U / NoData 255, masked to the same
   round-joined buffer polygon, so "no data" agrees pixel for pixel.

5. **Scope to `(site, actual_year)` pairs that exist in the reference.** NAIP
   exists only for 2012/2016/2020 ± fallback. Keep the existing EPSG:5070 vector
   outputs as the general-purpose 13-year layer; emit NAIP-aligned rasters only
   where imagery exists. Roughly 4× less work.

6. **Assert alignment rather than assume it:**

   ```r
   terra::compareGeom(terra::rast(naip_path), terra::rast(mask_path), stopOnError = TRUE)
   ```

### Pilot results

`src/99_verify_naip_alignment.R` builds masks for every site-year with real
imagery on disk and checks each against the image it must overlay:

```
geometry match      : 46 / 46      (compareGeom: crs, ext, rowcol, res)
nodata agreement    : 43 / 46 at >= 99.997%
```

Across UTM zones 26912–26915 and years 2010–2021. In every single image,
`mask NA & NAIP has data = 0` — the mask never claims NoData where the imagery
has coverage.

### One site has incomplete NAIP coverage

The three exceptions are all the same site, in all three of its years:

```
tag                   na_pct  expected  excess
1940-1-4-17-2_2020     38.16     13.28   24.88
1940-1-4-17-2_2016     32.05     13.28   18.77
1940-1-4-17-2_2012     31.07     13.28   17.79
...every other image                     within 0.15% of baseline
```

This is missing imagery, not a mask defect. The catalogue returns only two tiles
for that AOI — the `se` and `ne` quarter-quads of `4810464` — leaving the western
side of the buffered footprint uncovered:

```
2012 -> nd_m_4810464_se_13_1_20120627, nd_m_4810464_ne_13_1_20120627
2016 -> nd_m_4810464_se_13_h_20160725, nd_m_4810464_ne_13_h_20160725
2020 -> nd_m_4810464_se_13_060_20200726, nd_m_4810464_ne_13_060_20200726
```

It reproduces on a fresh query today, so it is a property of the AOI's position
against NAIP coverage rather than a transient download failure.

**Recommended:** audit the whole NAIP archive with this metric — observed NoData
versus the geometric baseline — and flag or drop sites whose excess exceeds a
threshold. A site delivering 38% empty imagery to the U-Net is a training and
inference problem independent of alignment. 1 of 16 sites in the sample set is
affected; the rate across all 15,380 is unknown until the archive is scanned.

### Re-run or retrofit?

Re-running the grid phase is recommended. `run_logs/latest.log` shows **~30 min
per year, ~6.7 h for all 13**, with NLCD and Census already cached — the
expensive part (13 × 1.3 GB of NLCD) is done. Scoped to the three NAIP target
years it is under two hours.

The retrofit alternative — reprojecting the existing 5070 polygons onto the NAIP
grid — is faster but resamples an already-resampled categorical layer a second
time and bakes Albers pixel stair-steps into a UTM product.

---

## Recommendations for naipScrape

Not required for this work; they stop the problem recurring on the next download.

1. **Make the grid deterministic.** Choose the zone from the AOI centroid rather
   than inheriting `files[1]`, and snap the template origin to whole metres. The
   grid then becomes a pure function of the AOI id, and both repos can compute it
   independently with no metadata exchange.
2. **Write a grid sidecar at download time** — `epsg`, origin, dimensions,
   `actual_year`, item ids. `downloadNAIP_vsi()` already builds `meta_df`; adding
   `proj:epsg` to it is one line. That makes `src/03_naip_reference.R` a
   verification tool rather than a reconstruction.
3. **Avoid the double resample.** In the multi-tile branch each tile is resampled
   onto `temp`, mosaicked, then cropped and resampled onto `temp` again — two
   bilinear passes on the imagery. Mosaic in the native CRS first, then reproject
   once.
4. **`mosaic(fun = "mean")` blends across capture dates.** The two tiles in the
   boundary example above were flown nine days apart; averaging smears that
   across the seam. `fun = "first"`, or selecting by date, keeps it honest.
5. **`generateAOI.R` is duplicated and has already drifted** — the
   `as.character(as.hexmode())` fix in this repo is not upstream. Geometry is
   unaffected, but the copies should be a shared dependency.

---

## Handoff note

The 1.5 km buffered image is what goes to whoever runs the U-Net, so that is the
grid the masks target. Those images are **not a constant array shape**
(1511 × 1542 … 1636 × 1665 in the sample set), so the model side has to normalise
them somehow. If that normalisation **resizes** rather than crops or pads, the
pixel-to-ground mapping breaks downstream no matter how well the masks align
here — worth confirming with them.
