# sampling/

Sample design for the trees-outside-forests estimate: which 1 km cells are
sampled in each MLRA of a Land Resource Region, and the maps and site-role
assignment built on top of that list.

| Script | What it does |
|--------|--------------|
| `00_draw_sample_grid.R` | Draws the systematic sample grid: about 1400 1 km cells per MLRA, one seeded regular-lattice draw per MLRA, for every LRR in `config.yml` `sampling$grid$lrr_ids`. |
| `00_prepare_sites.R` | Sourced by the map scripts, not run on its own: reads the sample list and ground-truth ids, keeps the cells inside the LRR, assigns training / validation roles. |
| `01_map_lrr_sites.R` | Whole-LRR sample design map (static and web). |
| `02_map_mlra_sites.R` | One map pair per MLRA. |
| `03_build_site.R` | Assembles the GitHub Pages site in `docs/`. |
| `test/test_sample_grid_replication.R` | Redraws the grid and checks it against the tracked May 2026 lists, byte for byte. |
| `tools/derive_frame_corrections.R` | One-off, needs the old neymanSampling grid: builds the frame-corrections table described below. Not part of the pipeline. |

Settings live in the `sampling` section of the root `config.yml`.

## The systematic sample grid

`data/reference/sampleGrids/` holds the sample lists that the naip stage
downloads imagery for:

| File | LRR | Rows | Drawn | Origin |
|------|-----|------|-------|--------|
| `selectedSample_lrr_F_05_2026.csv` | F | 15,395 | 4 May 2026 | neymanSampling `scripts/Establish_stratifiedGrid.R` |
| `selectedSample_lrr_G_draw_1400_05_2026.csv` | G | 25,207 | 26 May 2026 | same script, after it was generalised to several draw sizes (now `30_Establish_stratifiedGrid.R`) |

Both were produced by the same method, which `00_draw_sample_grid.R` and
`functions/sample_grid.R` now reproduce here from the tracked reference layers
alone (`data/reference/grid100km_aea.gpkg`, `data/reference/lower48MLRA.gpkg`).
The Neyman allocation, the 500 / 650 draw sizes and the ground-truth selection
that live alongside it in neymanSampling were deliberately not ported.

For each MLRA of the target LRR, in the order the MLRAs appear in the MLRA
layer:

1. **1 km cells.** Take the 100 km cells of the equal-area grid (EPSG:5070) that
   intersect the MLRA polygon, cut each into 100 × 100 whole 1 km cells with
   `sf::st_make_grid()`, and keep the cells that intersect the MLRA. Cells are
   not clipped, so the sampling frame is a blocky outline of the MLRA.
2. **Regular lattice.** Union those cells, call `set.seed(1234)`, then
   `sf::st_sample(union, size = 1400, type = "regular")`. sf scales the
   requested size by bounding-box area over union area, lays a square lattice
   with a random offset over the bounding box, and keeps the points inside the
   union. That is why each MLRA ends up with *about* 1400 cells (1387 to 1420),
   not exactly 1400, and why the draw is spatially uniform.
3. **Cell ids.** Each point is named by descending the id hierarchy
   `<100km>-<50km>-<10km>-<2km>-<1km>` (each level a 1-based hex index into the
   `st_make_grid()` of its parent), with the same grid construction that
   `naip/function/generateAOI.R` uses to rebuild a cell from its id. Duplicate
   ids within an MLRA are dropped.

The seed is reset for every MLRA, so a draw for one MLRA does not depend on any
other, and the id of a cell does not depend on which MLRA drew it. A 1 km cell
that straddles an MLRA boundary can therefore be drawn by both neighbours; the
reference lists carry 15 such duplicate ids in F and 54 in G, and
`00_prepare_sites.R` keeps the first of each.

### Pinning the sampling frame

Only two things fix a draw once the seed is set: the bounding box of the 1 km
cells and their count (the union area is the count times 1 km²). sf turns them
into a lattice size `round(1400 × bbox area / union area)`, and for most MLRAs
a change of one or two cells is enough to change that size and with it the
whole draw. The test prints, for every MLRA, the range of cell counts that
leaves the lattice size unchanged; for eleven of the 29 MLRAs that range is
one to three cells wide.

The cell count is not stable across library versions. Step 1 keeps a cell if
`st_intersects()` says the MLRA polygon touches it, and for a cell the boundary
crosses by less than a metre that answer changes with the PROJ version (the
WGS84 to NAD83 Albers transform moves the boundary by a fraction of a metre)
and with GEOS. Against the March 2026 grid the reference draws used, a build
with R 4.6.1, sf 1.1.2, GEOS 3.12.1 and PROJ 9.4.0 differs on 11 cells across
the 29 MLRAs of F and G: every one of them overlaps the MLRA by under 3 m² or
misses it by under 0.4 m. One of those (MLRA 72, cell `1675-b7f`) was enough to
change the lattice size and the draw for that MLRA.

So the frame is pinned by a small tracked table,
`data/reference/sampleGrids/sampleFrame_marginalCells_03_2026.csv`: every 1 km
cell within 10 m of an MLRA boundary whose overlap with the MLRA is under
5,000 m² (2,222 cells, 22 to 177 per MLRA), with `in_march_build` saying
whether the March 2026 grid contained it. `mlra_1km_cells()` builds the cells
with today's intersects test and then adds or drops the listed cells to match
that column. Any cell that a future PROJ or GEOS could flip is in the table
(the thresholds are 25 and 2,000 times the largest deviation seen), so the frame,
and therefore the draw, no longer depends on the library versions. The table was
made once by `tools/derive_frame_corrections.R` from the old grid; the draw
scripts only read it.

### Replication test

```sh
Rscript sampling/test/test_sample_grid_replication.R
```

redraws every LRR in `sampling$grid$reference`, compares row count, ids in
order, `MLRA_ID` and `LLR_ID`, per-MLRA counts, and finally writes the draw
with `readr::write_csv()` and compares the bytes with the tracked file. It exits
with status 1 on any mismatch. If `00_draw_sample_grid.R` has already run, its
output file is checked as well.

Result on 12 September 2026 (R 4.6.1, sf 1.1.2, GEOS 3.12.1, GDAL 3.8.4,
PROJ 9.4.0), both from the in-memory redraw and from the file written by
`00_draw_sample_grid.R`:

| LRR | MLRAs | Rows | Cells per MLRA | Frame cells added / dropped | Byte-identical (md5) |
|-----|-------|------|----------------|-----------------------------|----------------------|
| F | 11 | 15,395 | 1387 to 1415 | 1 / 4 | yes, `4ca6321e1f79278f4f7918b52ae46ba2` |
| G | 18 | 25,207 | 1395 to 1420 | 4 / 2 | yes, `110900fdeb9f0068779602ba96aec0f8` |

Every per-MLRA count matches, the ids are identical and in the same order,
and the cross-MLRA duplicate counts (15 in F, 54 in G) match. Without the
frame table the same environment reproduces F exactly but not G: MLRA 72 comes
out with 1398 cells instead of 1396, because its build has one boundary cell
fewer than the March grid and that one cell moves the lattice size from 3549
to 3550. The full redraw takes about 4 minutes for F and 7 for G.

### Outputs

`00_draw_sample_grid.R` writes to `data/sampling/sampleGrids/` (ignored by git):

- `selectedSample_lrr_<LRR>_draw_<n>.csv` — columns `id, MLRA_ID, LLR_ID`, the
  same layout as the reference lists.
- `selectedSample_lrr_<LRR>_draw_<n>_diagnostics.csv` — per MLRA: cell count,
  bounding box, areas, lattice size, and the cell-count range that gives the
  same draw.

An existing output is not overwritten; delete it to redraw. To adopt a new draw
(another LRR, size or seed) copy the CSV into `data/reference/sampleGrids/` and
point `naip$paths` and `sampling$paths$sample_csv` at it.
