#!/usr/bin/env bash
# Install R and the packages the R stages need on an Ubuntu 24.04 host (ubuntu-gpu).
#
#     sudo bash shared/setup_r.sh
#
# Uses the CRAN apt repository for a current R (Ubuntu's own r-base is 4.3.3)
# and r2u, which serves every CRAN package as a prebuilt .deb, so sf, terra,
# arrow and exactextractr install in minutes with their system libraries
# resolved by apt instead of compiling for an hour. Idempotent: rerun to add
# packages. Afterwards `Rscript estimates/test/test_estimators.R` should pass.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "run with sudo"; exit 1; fi
. /etc/os-release
if [[ "${VERSION_CODENAME:-}" != "noble" ]]; then
  echo "this script is written for Ubuntu 24.04 (noble); found ${VERSION_CODENAME:-?}"; exit 1
fi
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates gnupg curl

# CRAN's Ubuntu repository: current R 4.x for noble.
curl -fsSL https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
  | gpg --dearmor -o /usr/share/keyrings/cran-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cran-archive-keyring.gpg] https://cloud.r-project.org/bin/linux/ubuntu noble-cran40/" \
  > /etc/apt/sources.list.d/cran.list

# r2u: CRAN packages as binaries for noble (https://github.com/eddelbuettel/r2u).
curl -fsSL https://eddelbuettel.github.io/r2u/assets/dirk_eddelbuettel_key.asc \
  | gpg --dearmor -o /usr/share/keyrings/r2u-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/r2u-archive-keyring.gpg] https://r2u.stat.illinois.edu/ubuntu noble main" \
  > /etc/apt/sources.list.d/r2u.list
# Prefer r2u's builds over Ubuntu's r-cran-* packages.
cat > /etc/apt/preferences.d/99r2u <<'EOF'
Package: *
Pin: release o=CRAN-Apt Project
Pin: release l=CRAN-Apt Packages
Pin-Priority: 700
EOF

apt-get update -qq
apt-get install -y -qq --no-install-recommends r-base-core r-base-dev

# Every package the stages load (grep of p_load / library / :: across the repo),
# as r2u binaries. `snic` is a GitHub package and only needed with naip.run_snic.
pkgs=(here yaml pacman sf terra exactextractr dplyr tidyr purrr readr tibble
      arrow data.table jsonlite openxlsx glue furrr future rstac tictoc
      ggplot2 ragg leaflet htmlwidgets htmltools tigris png)
apt-get install -y -qq --no-install-recommends "${pkgs[@]/#/r-cran-}"

echo
R --version | head -1
Rscript -e 'for (p in c("sf","terra","exactextractr","arrow","here","yaml","dplyr","readr","openxlsx")) cat(sprintf("%-14s %s\n", p, as.character(packageVersion(p))))'
Rscript -e 'cat("GDAL", sf::sf_extSoftVersion()[["GDAL"]], " GEOS", sf::sf_extSoftVersion()[["GEOS"]], " PROJ", sf::sf_extSoftVersion()[["PROJ"]], "\n")'
