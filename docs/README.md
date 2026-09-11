# Publishing the maps as a GitHub Pages site

Plan for hosting the sample-design maps (the whole-LRR map and one map per
MLRA, each as a static PNG and an interactive Leaflet page) from this repo.
Each map gets its own Markdown page with a header that links back to the
home page, the interactive map embedded in the page, and previous/next links.

## Approach in one paragraph

GitHub Pages serves the `docs/` folder of the `main` branch, running it
through Jekyll (the Markdown site generator built into GitHub Pages). A small
R script copies the finished maps from `data/sampling/maps/` into
`docs/maps/`, writes one Markdown page per map into `docs/_maps/`, and writes
the `docs/index.html` gallery that links to them. Jekyll renders each
Markdown page inside `docs/_layouts/map.html`, which adds the site header
with a link home, embeds the Leaflet page in an iframe, and adds
previous/next links. Building the maps needs the NAS data, so the build runs
locally; committing `docs/` and pushing is the deploy. No GitHub Actions and
no custom build step on GitHub's side.

Published URL, once enabled:
`https://geospatialcentroid.github.io/treesOutsideForests/`

## Why this shape

| Choice | Reason |
|---|---|
| `docs/` on `main`, not a `gh-pages` branch | One branch to maintain; the site is versioned with the code that made it. |
| Build locally, commit the output | The map inputs are ~100 GB on the NAS. A cloud build cannot reproduce them, so the artefacts are the source of truth for the site. |
| Plain generated HTML index | The landing page is written directly by the build script, so it needs no template engine. Jekyll copies it through untouched because it has no front matter. |
| Jekyll for the per-map pages | It is built into GitHub Pages, so Markdown pages with a shared layout cost nothing to host. Nothing is installed on GitHub's side. |
| Map pages are Markdown in `_maps/` | The build script rewrites the front matter (title, counts, file paths) every run but keeps the body text, so notes written by hand survive a rebuild. |
| Raw Leaflet pages stay at `maps/<name>.html` | The Markdown page renders at `maps/<name>/`, so the two never collide and the raw page still works as a full-screen view. |
| Interactive maps share one `libs/` folder per directory | Self-contained pages need `pandoc`. Without it, htmlwidgets writes the Leaflet JS/CSS once per folder (`maps/libs/`, `maps/mlra/libs/`) rather than a sidecar per page; if `pandoc` is installed later the same script produces single-file pages with no other change. |

## Layout

```text
docs/
├── _config.yml            # Jekyll settings: site title, baseurl, the _maps collection
├── _layouts/
│   ├── default.html       # site chrome: header with home link and breadcrumb, footer
│   └── map.html           # one map: title, counts, iframe, Markdown body, previous/next links
├── _maps/                 # generated front matter, hand-editable body: one .md per map
│   ├── lrr_F_sample_design.md
│   └── lrr_F_mlra_52_sample_design.md ...
├── README.md              # this plan
├── index.html             # generated landing page: project context, one card per map, build date, commit
└── maps/                  # generated: copied from data/sampling/maps/
    ├── libs/                     # Leaflet / htmlwidgets JS and CSS shared by the pages here
    ├── lrr_F_sample_design.html
    ├── lrr_F_sample_design.png
    ├── thumbs/                   # small PNGs for the gallery cards
    └── mlra/
        ├── libs/
        ├── lrr_F_mlra_52_sample_design.html
        ├── lrr_F_mlra_52_sample_design.png
        └── ...
```

The built site is about 18 MB.
GitHub's limits are 100 MB per file and about 1 GB per site, so there is
plenty of headroom for more LRRs and years.

## Steps

1. **Repository visibility.** GitHub Pages on a private repository requires a
   paid organisation plan. The other agroforestry repos are public; if the
   GeospatialCentroid org is on the free plan, make `treesOutsideForests`
   public first (Settings, General, Danger Zone, Change visibility).

2. **The build script** `sampling/03_build_site.R` (written). It:
   - sources `shared/R/setup.R` and reads `config.yml` for the map directory;
   - mirrors `data/sampling/maps/` into `docs/maps/`, deleting stale files so
     a renamed map does not leave an orphan behind;
   - writes 640 px thumbnails into `docs/maps/thumbs/` by block-averaging
     the map PNGs with the `png` package (no ImageMagick needed);
   - writes `docs/_maps/<name>.md` for every map: the front matter (title,
     breadcrumb, counts, paths to the Leaflet page and PNG, sort order) is
     regenerated each run, the Markdown body below it is kept if the file
     exists, and pages for maps that no longer exist are deleted;
   - generates `docs/index.html`: a landing page with project context and a
     key to the map layers, then one card per map with the thumbnail, title,
     counts of sampled cells, training and validation sites, and links to the
     map page and the full PNG;
   - stamps the page with the build date and `git rev-parse --short HEAD`;
   - refuses to write if any single file exceeds 95 MB.

3. **Commit `docs/`.** Do not add a `.nojekyll` file; it would switch off the
   Jekyll pass and the map pages would not be rendered.

4. **Enable Pages.** Settings, Pages, Source: Deploy from a branch, Branch:
   `main`, Folder: `/docs`. GitHub publishes within a minute or two of every
   push that touches `docs/`.

5. **Routine.** After changing maps:

   ```r
   source("sampling/01_map_lrr_sites.R")
   source("sampling/02_map_mlra_sites.R")
   source("sampling/03_build_site.R")
   ```

   then commit and push. The index records the commit it was built from, so
   a stale site is visible at a glance.

6. **Writing about a map.** Open `docs/_maps/<name>.md`, leave the front
   matter alone, and write Markdown below it. Rebuilding keeps that text.

## Previewing locally

GitHub runs Jekyll for you, but a local render catches broken links before a
push. With Ruby installed (`rbenv` on this machine), once:

```sh
gem install jekyll
```

then from the repository root:

```sh
jekyll serve --source docs --destination /tmp/tof-site
```

and open `http://localhost:4000/treesOutsideForests/`. Jekyll writes nothing
into `docs/`.

## Optional later

- **Install pandoc** (`sudo apt install pandoc`, or the `pandoc` R package's
  `pandoc_install()`) to get single-file interactive maps. The build script
  needs no change.
- **A GitHub Action that only checks**, never builds: run a link checker on
  the rendered site on each push so a missing sidecar folder fails loudly.
  Worth adding once more than one person is committing maps.
- **Convert `index.html` to Markdown too.** The landing page could become
  `index.md` on the `default` layout so its prose is as easy to edit as the
  map pages; the card grid would then move into an include.
- **More LRRs.** The gallery script groups cards by LRR from the file names,
  so adding `lrr_G_...` maps needs no template edits.

## What this plan does not do

- It does not rebuild maps in the cloud. Anyone without the NAS data can view
  the site and read the code but cannot regenerate the maps.
- It does not serve the underlying rasters or the 1 km cell geometries as
  downloadable data. If that is wanted, the reference GeoPackages under
  `data/reference/` are small enough to copy into `docs/data/` in step 2.
