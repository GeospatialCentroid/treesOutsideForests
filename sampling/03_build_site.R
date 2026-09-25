# ==============================================================================
# Build the GitHub Pages site in docs/: mirror the finished maps from
# data/sampling/maps/, make gallery thumbnails, write one Markdown page per map
# into docs/_maps/ (front matter is regenerated, the body text is yours to edit
# and is preserved), and write docs/index.html, a landing page with project
# context that links to every map page.
#
# Run after 01_map_lrr_sites.R and 02_map_mlra_sites.R, then commit docs/ and
# push; GitHub Pages (Settings > Pages, branch main, folder /docs) runs Jekyll
# and publishes it. See docs/README.md for the plan and rationale.
#
# Run from the root project:  source("sampling/03_build_site.R")
# ==============================================================================
source(here::here("shared/R/setup.R"))
pacman::p_load(sf, dplyr, readr, png, glue, yaml)
source(tof_root("sampling/functions/grid_cells.R"))

cfg     <- tof_config()
cfg_smp <- cfg$sampling
llr_id  <- cfg_smp$llr_id
src_dir <- tof_path(cfg_smp$paths$map_dir)
docs    <- tof_root("docs")
dst_dir <- file.path(docs, "maps")
pages_dir <- file.path(docs, "_maps")   # Jekyll collection: one Markdown page per map
thumb_dir <- file.path(dst_dir, "thumbs")
max_file_mb <- 95      # GitHub refuses files over 100 MB

# --- 1. Mirror the maps into docs/maps (delete stale, copy changed) -----------
if (!dir.exists(src_dir) || length(list.files(src_dir, "[.]html$", recursive = TRUE)) == 0)
  stop("No maps found under ", src_dir, ". Run 01_map_lrr_sites.R and 02_map_mlra_sites.R first.")
big <- list.files(src_dir, recursive = TRUE, full.names = TRUE)
big <- big[file.size(big) > max_file_mb * 1024^2]
if (length(big) > 0) stop("Refusing to publish files over ", max_file_mb, " MB:\n  ", paste(big, collapse = "\n  "))

unlink(dst_dir, recursive = TRUE)
dir.create(thumb_dir, recursive = TRUE, showWarnings = FALSE)
src_files <- list.files(src_dir, recursive = TRUE, full.names = FALSE, all.files = TRUE, no.. = TRUE)
src_files <- src_files[!grepl("(^|/)thumbs/", src_files)]
for (f in src_files) {
  dir.create(dirname(file.path(dst_dir, f)), recursive = TRUE, showWarnings = FALSE)
  file.copy(file.path(src_dir, f), file.path(dst_dir, f), overwrite = TRUE, copy.date = TRUE)
}
message(sprintf("Mirrored %d files (%.1f MB) into %s", length(src_files),
                sum(file.size(file.path(src_dir, src_files))) / 1024^2, dst_dir))
unlink(file.path(docs, ".nojekyll"))   # the site is rendered by Jekyll; this file would switch it off

# --- 2. Thumbnails (block-mean downsample with the png package) ---------------
thumbnail <- function(src, dst, width = 640) {
  img <- png::readPNG(src)
  if (length(dim(img)) == 2) img <- array(img, c(dim(img), 1))
  f <- max(1L, floor(ncol(img) / width))
  nr <- floor(nrow(img) / f); nc <- floor(ncol(img) / f)
  out <- array(0, c(nr, nc, dim(img)[3]))
  for (ch in seq_len(dim(img)[3])) {
    m <- img[seq_len(nr * f), seq_len(nc * f), ch]
    # Column-major reshape to (f, nr, f, nc) puts each f x f block on dims 1 and 3.
    out[, , ch] <- apply(array(m, c(f, nr, f, nc)), c(2, 4), mean)
  }
  png::writePNG(out, dst)
}
pngs <- list.files(dst_dir, "[.]png$", recursive = TRUE, full.names = TRUE)
pngs <- pngs[!grepl("/thumbs/|_files/|/libs/", pngs)]   # map PNGs only, not widget icons
for (p in pngs) thumbnail(p, file.path(thumb_dir, basename(p)))
message("Wrote ", length(pngs), " thumbnails")

# --- 3. Card data from the roles tables and the MLRA layer --------------------
# One roles CSV per partition (written by 00_prepare_sites.R); every partition
# gets its own set of cards and pages.
partitions <- cfg_smp$partitions
if (length(partitions) == 0) partitions <- list(random = list(csv = NULL, label = sprintf("random split, seed %d", cfg_smp$seed)))
roles_by <- lapply(names(partitions), function(key)
  read_sites_csv(tof_path(sub("{partition}", key, cfg_smp$paths$roles_csv, fixed = TRUE))))
names(roles_by) <- names(partitions)
mlra  <- sf::st_read(tof_path(cfg$reference$mlra_gpkg), quiet = TRUE) |>
  sf::st_drop_geometry() |> dplyr::filter(LRRSYM == llr_id) |> dplyr::arrange(MLRARSYM)
# The maps draw the partition's test sites as validation sites, so the counts do too.
n_of   <- function(r, role) if (role == "validation") sum(r$role %in% c("validation", "test")) else sum(r$role == role)
counts <- function(r) sprintf("%s sampled cells &middot; %d training &middot; %d validation",
                              format(n_of(r, "sample"), big.mark = ","), n_of(r, "training"), n_of(r, "validation"))
rel <- function(...) file.path("maps", ...)
card <- function(title, blurb, stub, dir = NULL) {
  page <- paste0(rel(stub), "/")                      # Jekyll page: maps/<stub>/ (see docs/_config.yml)
  raw  <- if (is.null(dir)) rel(paste0(stub, ".html")) else rel(dir, paste0(stub, ".html"))   # the Leaflet page itself
  pngp <- sub("[.]html$", ".png", raw)
  glue::glue('
    <article class="card">
      <a class="thumb" href="{page}"><img src="{rel("thumbs", paste0(stub, ".png"))}" alt="{title}" loading="lazy"></a>
      <div class="card-body">
        <h3><a href="{page}">{title}</a></h3>
        <p class="meta">{blurb}</p>
        <p class="links"><a href="{page}">Map page</a> &middot; <a href="{raw}">Full-screen map</a> &middot; <a href="{pngp}">Print map (PNG)</a></p>
      </div>
    </article>')
}
stub_lrr  <- function(key)      sprintf("lrr_%s_sample_design_%s", llr_id, key)
stub_mlra <- function(key, sym) sprintf("lrr_%s_mlra_%s_sample_design_%s", llr_id, sym, key)
missing_maps <- unlist(lapply(names(partitions), function(key) {
  f <- c(rel(paste0(stub_lrr(key), ".html")), rel("mlra", paste0(stub_mlra(key, mlra$MLRARSYM), ".html")))
  f[!file.exists(file.path(docs, f))]
}))
if (length(missing_maps) > 0) stop("Maps not built for every partition; run 01 and 02 first. Missing:\n  ", paste(missing_maps, collapse = "\n  "))

section_html <- function(key) {
  roles <- roles_by[[key]]; label <- partitions[[key]]$label
  lrr_card <- card(sprintf("LRR %s: whole-region sample design", llr_id), counts(roles), stub_lrr(key))
  lrr_card <- sub("<article class=\"card\">", "<article class=\"card feature\">", lrr_card)
  mlra_cards <- vapply(seq_len(nrow(mlra)), function(i) {
    sym <- mlra$MLRARSYM[i]
    card(sprintf("MLRA %s: %s", sym, mlra$MLRA_NAME[i]), counts(roles[roles$MLRARSYM %in% sym, ]),
         stub_mlra(key, sym), dir = "mlra")
  }, character(1))
  glue::glue('
  <section id="{key}">
    <h2>Partition: {label}</h2>
    <p class="meta">{n_of(roles, "training")} training &middot; {n_of(roles, "validation")} validation sites, from <code>{basename(partitions[[key]]$csv %||% "random draw")}</code>.</p>
    <div class="grid">
      {lrr_card}
      {paste(mlra_cards, collapse = "\n")}
    </div>
  </section>')
}
`%||%` <- function(a, b) if (is.null(a)) b else a
sections <- paste(vapply(names(partitions), section_html, character(1)), collapse = "\n\n")

# --- 4. One Markdown page per map in docs/_maps/ ------------------------------
# Jekyll renders _maps/<stub>.md at maps/<stub>/ using _layouts/map.html, which
# embeds the Leaflet page in an iframe under a header that links back home.
# The front matter is rewritten on every build; the Markdown body below it is
# kept if the file already exists, so notes written by hand survive a rebuild.
write_map_page <- function(stub, front, default_body) {
  path <- file.path(pages_dir, paste0(stub, ".md"))
  body <- default_body
  if (file.exists(path)) {
    lines <- readLines(path, warn = FALSE)
    fences <- which(trimws(lines) == "---")
    if (length(fences) >= 2 && fences[2] < length(lines))
      body <- paste(lines[(fences[2] + 1):length(lines)], collapse = "\n")
  }
  body <- gsub("^\n+|\n+$", "", body)   # one blank line after the front matter, not one more per rebuild
  yml <- yaml::as.yaml(front, indent.mapping.sequence = TRUE)
  writeLines(c("---", sub("\n$", "", yml), "---", "", body), path)
  path
}
dir.create(pages_dir, showWarnings = FALSE)
front_counts <- function(r) list(sampled = format(n_of(r, "sample"), big.mark = ","),
                                 training = n_of(r, "training"), validation = n_of(r, "validation"))
pages <- character(0)
for (k in seq_along(partitions)) {
  key <- names(partitions)[k]; label <- partitions[[key]]$label; roles <- roles_by[[key]]
  s <- stub_lrr(key)
  pages <- c(pages, write_map_page(s,
    c(list(title = sprintf("LRR %s: whole-region sample design (%s)", llr_id, label),
           crumb = sprintf("LRR %s, %s", llr_id, label), order = (k - 1L) * 100L,
           partition = key, partition_label = label,
           map = rel(paste0(s, ".html")), png = rel(paste0(s, ".png"))),
      front_counts(roles)),
    glue::glue("
      <!-- Edit this text freely. The build script only refreshes the front matter above. -->

      The whole of Land Resource Region {llr_id} with its {nrow(mlra)} Major Land Resource
      Areas, the 1 km cells drawn for NAIP acquisition, and the sites used to train
      and validate the detection model under the {label} partition. Use the
      layer switcher to show the Census places and NLCD forest context layers;
      sampled cell outlines appear once you zoom in.")))
  for (i in seq_len(nrow(mlra))) {
    sym <- mlra$MLRARSYM[i]; nm <- mlra$MLRA_NAME[i]
    s <- stub_mlra(key, sym)
    r <- roles[roles$MLRARSYM %in% sym, ]
    pages <- c(pages, write_map_page(s,
      c(list(title = sprintf("MLRA %s: %s (%s)", sym, nm, label), crumb = sprintf("MLRA %s, %s", sym, label),
             order = (k - 1L) * 100L + i, partition = key, partition_label = label,
             mlra = as.character(sym), mlra_name = nm,
             map = rel("mlra", paste0(s, ".html")), png = rel("mlra", paste0(s, ".png"))),
        front_counts(r)),
      glue::glue("
        <!-- Edit this text freely. The build script only refreshes the front matter above. -->

        Sample design for MLRA {sym}, {nm}, within LRR {llr_id}: the 1 km cells drawn for
        NAIP acquisition and the training and validation sites inside this MLRA
        under the {label} partition.")))
  }
}
stale <- setdiff(list.files(pages_dir, "[.]md$", full.names = TRUE), pages)
if (length(stale) > 0) { unlink(stale); message("Removed ", length(stale), " stale map page(s)") }
message("Wrote ", length(pages), " map pages into ", pages_dir)

# --- 5. Landing page ----------------------------------------------------------
commit <- tryCatch(system2("git", c("-C", shQuote(tof_root()), "rev-parse", "--short", "HEAD"), stdout = TRUE), error = function(e) "unknown")
built  <- format(Sys.Date(), "%d %B %Y")
first  <- roles_by[[1]]
n_cells <- format(n_of(first, "sample"), big.mark = ",")
n_mlra  <- nrow(mlra); ctx_year <- cfg_smp$context_year
site_stats <- paste(vapply(names(partitions), function(key) {
  r <- roles_by[[key]]
  sprintf('<li><b>%d &middot; %d</b><span>training &middot; validation sites (%s)</span></li>',
          n_of(r, "training"), n_of(r, "validation"), partitions[[key]]$label)
}, character(1)), collapse = "\n      ")
partition_note <- if (is.null(partitions[[1]]$csv)) {
  sprintf("Training and validation sites are the June 2026 ground-truth cells inside LRR %s, split at random (seed %d).", llr_id, cfg_smp$seed)
} else {
  sprintf("Training and validation sites follow the partner's partition files (%s), with the partition's test sites drawn as validation sites; each partition has its own set of maps.",
          paste(vapply(partitions, function(p) basename(p$csv), character(1)), collapse = ", "))
}

page <- glue::glue('<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Trees Outside Forests: LRR {llr_id} sample design</title>
<style>
  :root {{ --ink: #0b0b0b; --ink-2: #52514e; --ink-3: #8a8880; --line: #e3e1da; --bg: #fcfcfb; --card: #ffffff; --accent: #4a3aa7; --accent-2: #e34948; }}
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; background: var(--bg); color: var(--ink); font: 16px/1.55 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }}
  a {{ color: var(--accent); text-decoration: none; }} a:hover {{ text-decoration: underline; }}
  header {{ border-bottom: 1px solid var(--line); background: var(--card); }}
  .wrap {{ max-width: 1100px; margin: 0 auto; padding: 0 20px; }}
  header .wrap {{ padding-top: 40px; padding-bottom: 32px; }}
  h1 {{ font-size: 2rem; line-height: 1.2; margin: 0 0 8px; }}
  .lede {{ font-size: 1.15rem; color: var(--ink-2); max-width: 44em; margin: 0; }}
  .stats {{ display: flex; flex-wrap: wrap; gap: 12px 36px; margin: 28px 0 0; padding: 0; list-style: none; }}
  .stats li {{ display: flex; flex-direction: column; }}
  .stats b {{ font-size: 1.6rem; line-height: 1.1; }}
  .stats span {{ color: var(--ink-2); font-size: 0.9rem; }}
  section {{ padding: 36px 0 8px; }}
  h2 {{ font-size: 1.35rem; margin: 0 0 12px; }}
  h3 {{ font-size: 1.05rem; margin: 0 0 4px; }}
  .prose {{ max-width: 44em; }}
  .prose p, .prose li {{ color: #2b2a27; }}
  .legend {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 14px 28px; margin: 12px 0 0; padding: 0; list-style: none; }}
  .legend li {{ padding-left: 26px; position: relative; color: #2b2a27; }}
  .legend li::before {{ content: ""; position: absolute; left: 0; top: 6px; width: 14px; height: 14px; border-radius: 3px; background: var(--sw); border: 1px solid rgba(0,0,0,.25); }}
  .grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 20px; margin-top: 16px; }}
  .card {{ background: var(--card); border: 1px solid var(--line); border-radius: 8px; overflow: hidden; display: flex; flex-direction: column; }}
  .card .thumb {{ display: block; aspect-ratio: 4 / 3; background: #f3f2ee; overflow: hidden; }}
  .card img {{ width: 100%; height: 100%; object-fit: contain; display: block; }}
  .card-body {{ padding: 14px 16px 16px; }}
  .meta {{ color: var(--ink-2); font-size: 0.9rem; margin: 0 0 8px; }}
  .links {{ margin: 0; font-size: 0.95rem; }}
  .feature {{ grid-column: 1 / -1; flex-direction: row; }}
  .feature .thumb {{ flex: 0 0 55%; aspect-ratio: auto; }}
  @media (max-width: 700px) {{ .feature {{ flex-direction: column; }} .feature .thumb {{ flex-basis: auto; aspect-ratio: 4 / 3; }} }}
  footer {{ border-top: 1px solid var(--line); margin-top: 40px; padding: 20px 0 40px; color: var(--ink-3); font-size: 0.85rem; }}
  footer a {{ color: var(--ink-2); }}
</style>
</head>
<body>
<header>
  <div class="wrap">
    <h1>Trees Outside Forests: LRR {llr_id} sample design</h1>
    <p class="lede">Where we are looking for trees outside forests across Land Resource Region {llr_id},
       and which sites are used to train and validate the detection model.</p>
    <ul class="stats">
      <li><b>{n_cells}</b><span>sampled 1 km cells</span></li>
      <li><b>{n_mlra}</b><span>Major Land Resource Areas</span></li>
      {site_stats}
    </ul>
  </div>
</header>

<main class="wrap">
  <section class="prose">
    <h2>About the project</h2>
    <p>Trees outside forests (TOF) are the windbreaks, riparian strips, farmstead shelterbelts and
       scattered trees that national forest inventories do not count, yet which matter for carbon,
       shelter and habitat across the northern Great Plains. This project detects them from
       high-resolution NAIP aerial imagery and estimates how much of the landscape they cover.</p>
    <p>Because we cannot classify every image, we work from a sample. LRR {llr_id} is divided into its
       {n_mlra} Major Land Resource Areas (MLRAs), and within each MLRA a set of 1 km grid cells is
       drawn for imagery acquisition and classification. The maps on this page show that sample and
       the sites that anchor it. {partition_note}</p>
    <p>The workflow lives in the
       <a href="https://github.com/GeospatialCentroid/treesOutsideForests">treesOutsideForests</a>
       repository: annual forest and urban masks from NLCD and the Census, NAIP acquisition and
       segmentation for the sampled cells, and the sample design shown here.</p>
  </section>

  <section class="prose">
    <h2>How to read the maps</h2>
    <ul class="legend">
      <li style="--sw:#4a3aa7">Training site: a 1 km scene used to fit the model.</li>
      <li style="--sw:#e34948">Validation site: a scene held back from training to check the model.</li>
      <li style="--sw:#4a4843">Sampled 1 km cell: drawn for NAIP acquisition (outlines appear when zoomed in).</li>
      <li style="--sw:#f2d3e0">MLRA fill: pale colour per Major Land Resource Area; hover for its name.</li>
      <li style="--sw:#eda100">Census places {ctx_year}: incorporated places, hidden until switched on.</li>
      <li style="--sw:#2d6a4f">NLCD forest {ctx_year}: share of each block that is forest, hidden until switched on.</li>
    </ul>
    <p style="margin-top:14px">Each interactive map has grey and satellite base maps, a layer switcher, and hover
       labels giving the cell id and MLRA. The print version is the same map as a single PNG.</p>
  </section>

{sections}
</main>

<footer>
  <div class="wrap">
    Built {built} from commit <code>{commit}</code>. {partition_note}
    Source: <a href="https://github.com/GeospatialCentroid/treesOutsideForests">GeospatialCentroid/treesOutsideForests</a>.
  </div>
</footer>
</body>
</html>
')
writeLines(page, file.path(docs, "index.html"))
message("Wrote ", file.path(docs, "index.html"))
message(sprintf("Site total: %.1f MB", sum(file.size(list.files(docs, recursive = TRUE, full.names = TRUE, all.files = TRUE))) / 1024^2))
