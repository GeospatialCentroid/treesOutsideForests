# ==============================================================================
# Shared preparation for the sample-design maps: reads the LRR, MLRAs, sample
# list and ground-truth ids; keeps only cells inside the LRR (spatial test);
# assigns training / validation roles; builds site geometry and the context
# layers (Census places, NLCD forest) from the masks/ stage products.
#
# Roles are drawn at random (seeded, see config.yml `sampling`) and written to
# data/reference/sampleGrids/ so later stages use the same assignment. The CSV
# is only written when it does not already exist, so a rerun never silently
# changes a draw; delete it to redraw.
#
# Sourced by 01_map_lrr_sites.R and 02_map_mlra_sites.R; not run on its own.
# ==============================================================================
source(here::here("shared/R/setup.R"))
pacman::p_load(sf, dplyr, readr, ggplot2, ragg, leaflet, htmlwidgets, htmltools, tigris, terra)
options(tigris_use_cache = TRUE)
terra::terraOptions(progress = 0)
source(tof_root("sampling/functions/grid_cells.R"))
source(tof_root("sampling/functions/site_maps.R"))

cfg     <- tof_config()
cfg_smp <- cfg$sampling
llr_id  <- cfg_smp$llr_id
crs     <- cfg$crs
map_dir <- tof_path(cfg_smp$paths$map_dir)
derived <- tof_path(cfg_smp$paths$derived_dir)
for (d in c(map_dir, derived)) dir.create(d, showWarnings = FALSE, recursive = TRUE)

# --- Inputs -------------------------------------------------------------------
lrr  <- read_lrr(llr_id, crs = crs)
mlra <- sf::st_read(tof_path(cfg$reference$mlra_gpkg), quiet = TRUE) |>
  dplyr::filter(LRRSYM == llr_id) |> sf::st_transform(crs) |>
  dplyr::arrange(MLRARSYM) |>
  dplyr::mutate(mlra_label = paste(MLRARSYM, MLRA_NAME))
mlra_cols <- mlra_palette(mlra)
g100 <- sf::st_read(tof_path(cfg$reference$grid_gpkg), quiet = TRUE)

# The sample list carries a handful of duplicate ids; keep the first of each.
sample_tbl <- read_sites_csv(tof_path(cfg_smp$paths$sample_csv)) |> dplyr::distinct(id, .keep_all = TRUE)
gt_tbl <- readr::read_csv(tof_path(cfg_smp$paths$groundtruth_csv), show_col_types = FALSE) |> dplyr::distinct(id, .keep_all = TRUE)

# --- Spatial test: keep only cells whose centroid lies inside the LRR ---------
all_ids <- union(sample_tbl$id, gt_tbl$id)
cells   <- cells_from_ids(all_ids, g100) |> sf::st_transform(crs)
ctr     <- suppressWarnings(sf::st_centroid(cells))
inside  <- lengths(sf::st_within(ctr, lrr)) > 0
ctr     <- suppressWarnings(sf::st_join(ctr, mlra[, c("MLRA_ID", "MLRARSYM", "MLRA_NAME")], join = sf::st_within))
dropped <- all_ids[!inside]
message(sprintf("Spatial test against LRR %s: %d of %d cells inside; dropped %d (%d from the sample list, %d ground-truth).",
                llr_id, sum(inside), length(all_ids), length(dropped),
                sum(dropped %in% sample_tbl$id), sum(dropped %in% gt_tbl$id)))
cells <- cells[inside, ]; ctr <- ctr[inside, ]
sample_tbl <- sample_tbl |> dplyr::filter(id %in% cells$id)
gt_tbl     <- gt_tbl     |> dplyr::filter(id %in% cells$id)

# --- Role assignment ----------------------------------------------------------
roles_path <- tof_path(cfg_smp$paths$roles_csv)
if (file.exists(roles_path)) {
  message("Using existing role assignment: ", roles_path)
  roles <- read_sites_csv(roles_path)
} else {
  set.seed(cfg_smp$seed)
  gt_ids  <- sample(gt_tbl$id)                       # shuffled once, seeded
  n_train <- min(cfg_smp$n_training, length(gt_ids))
  n_valid <- min(cfg_smp$n_validation, length(gt_ids) - n_train)
  train <- gt_ids[seq_len(n_train)]
  valid <- gt_ids[n_train + seq_len(n_valid)]
  if (n_train + n_valid < length(gt_ids))
    warning(sprintf("%d ground-truth sites left unassigned (config asks for %d + %d, %d available).",
                    length(gt_ids) - n_train - n_valid, cfg_smp$n_training, cfg_smp$n_validation, length(gt_ids)), call. = FALSE)
  roles <- sf::st_drop_geometry(ctr) |>
    dplyr::mutate(
      LLR_ID = llr_id,
      in_sample_list = id %in% sample_tbl$id,
      role = dplyr::case_when(id %in% train ~ "training",
                              id %in% valid ~ "validation",
                              in_sample_list ~ "sample",
                              TRUE ~ "unassigned")) |>
    dplyr::left_join(gt_tbl |> dplyr::select(id, groundtruth_year = year), by = "id") |>
    dplyr::select(id, MLRA_ID, MLRARSYM, LLR_ID, role, in_sample_list, groundtruth_year)
  readr::write_csv(roles, roles_path)
  message("Wrote role assignment (seed ", cfg_smp$seed, "): ", roles_path)
}
print(table(roles$role))

# --- Site geometry ------------------------------------------------------------
sites <- cells |> dplyr::inner_join(roles, by = "id")
pts   <- suppressWarnings(sf::st_centroid(sites)) |>
  dplyr::filter(role %in% c("sample", "training", "validation")) |>
  dplyr::mutate(role = factor(role, levels = c("sample", "training", "validation"), labels = role_labels))

# --- Context: states, Census places, NLCD forest -----------------------------
states <- tryCatch(
  tigris::states(cb = TRUE, resolution = "20m", progress_bar = FALSE) |> sf::st_transform(crs),
  error = function(e) { message("State boundaries unavailable (", conditionMessage(e), "); continuing without."); NULL })

ctx_year  <- cfg_smp$context_year
masks_out <- tof_path(cfg_smp$paths$masks_outputs)

places_path <- file.path(masks_out, sprintf("llr_%s_places_%d.gpkg", llr_id, ctx_year))
places <- if (file.exists(places_path)) {
  sf::st_read(places_path, quiet = TRUE) |> sf::st_transform(crs) |>
    sf::st_simplify(dTolerance = 50) |> dplyr::select(NAME, NAMELSAD, STUSPS)
} else { message("No Census places product for ", ctx_year, " at ", places_path); NULL }

# The 30 m forest binary is 1.1 billion cells; the web maps get a cached,
# coarsened forest-fraction version (block mean), built once per block size.
forest_fraction <- function(block) {
  src   <- file.path(masks_out, sprintf("llr_%s_forest_%d.tif", llr_id, ctx_year))
  cache <- file.path(derived, sprintf("llr_%s_forest_%d_%dm.tif", llr_id, ctx_year, block * 30))
  if (file.exists(cache)) return(terra::rast(cache))
  if (!file.exists(src)) { message("No NLCD forest product for ", ctx_year, " at ", src); return(NULL) }
  message("Aggregating ", basename(src), " to ", block * 30, " m (one-off, cached)...")
  a <- terra::aggregate(terra::rast(src), fact = block, fun = "mean", na.rm = TRUE)
  names(a) <- "forest_fraction"
  terra::writeRaster(a, cache, overwrite = TRUE, datatype = "FLT4S", gdal = "COMPRESS=DEFLATE")
  a
}
# Transparent where less than 2 % of the block is forest.
forest_layer <- function(block) { f <- forest_fraction(block); if (is.null(f)) NULL else terra::classify(f, cbind(-Inf, 0.02, NA)) }

layers <- list(pts = pts, cells = cells, states = states, places = places, forest = NULL)
