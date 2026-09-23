# Checks functions/replicate_estimators.R against the single-replicate
# estimators in functions/estimators.R and a hand-built case. Run:
#   Rscript estimates/test/test_replicate_estimators.R
source(here::here("shared/R/setup.R"))
pacman::p_load(dplyr, tidyr, purrr, tibble, data.table)
source(tof_root("estimates/functions/estimators.R"))
source(tof_root("estimates/functions/replicate_estimators.R"))

fails <- 0
check <- function(label, ok, detail = "") {
  cat(sprintf("%-64s %s%s\n", label, if (ok) "ok" else "FAIL", if (nzchar(detail)) paste0("  (", detail, ")") else ""))
  if (!ok) fails <<- fails + 1
}
near <- function(a, b, tol = 1e-9) isTRUE(all.equal(as.numeric(a), as.numeric(b), tolerance = tol))

# --- Hand-built: 3 AOIs x 4 replicates, MLRA A ---------------------------------
areas <- tibble::tibble(id = c("a", "b", "c"), footprint_m2 = c(1e6, 5e5, 2.5e5), eligible_m2 = c(9e5, 5e5, 1e5))
X <- matrix(c(45000, 25000, 5000,      # rep 1: 75,000 / 1,750,000 = 4.2857 % of total
              0,     0,     0,         # rep 2: zero
              90000, 50000, 10000,     # rep 3: double rep 1
              45000, 25000, 5000), nrow = 3, dimnames = list(areas$id, NULL))
r <- replicate_ratio(X, areas$footprint_m2)
check("ratio: estimate = sum(t)/sum(d) per replicate", near(r$estimate, c(75000, 0, 150000, 75000) / 1.75e6))
check("ratio: zero replicate has se 0", r$se[2] == 0)
check("ratio: doubling the replicate doubles the se", near(r$se[3], 2 * r$se[1]))

# --- Every replicate equals estimate_mlra() on that replicate alone -------------
mr <- replicate_mlra(X, areas, mlra_id = 1)
single <- purrr::map_dfr(1:4, function(k) {
  cells <- areas |> dplyr::mutate(MLRA_ID = 1, target_year = 2020L, tof_m2 = X[, k])
  estimate_mlra(cells) |> dplyr::mutate(replicate = k)
})
joined <- dplyr::inner_join(mr, single, by = c("MLRA_ID", "denominator", "replicate"), suffix = c("", ".single"))
check("mlra: 8 rows (4 replicates x 2 denominators)", nrow(mr) == 8)
check("mlra: estimates equal estimate_mlra() per replicate", near(joined$estimate, joined$estimate.single))
check("mlra: standard errors equal ratio_estimate() per replicate",
      near(joined$se, joined$se.single) && near(joined$sum_denom_m2, joined$sum_denom_m2.single))

# --- LRR: two MLRAs, equals estimate_lrr() per replicate --------------------------
areas2 <- tibble::tibble(id = c("d", "e"), footprint_m2 = c(1e6, 1e6), eligible_m2 = c(8e5, 6e5))
X2 <- matrix(c(200000, 100000,  0, 0,  200000, 100000,  50000, 50000), nrow = 2, dimnames = list(areas2$id, NULL))
mr2 <- dplyr::bind_rows(mr, replicate_mlra(X2, areas2, mlra_id = 2))
strata <- tibble::tibble(MLRA_ID = c(1, 2), total_m2 = c(6e10, 2e10), eligible_m2 = c(2.25e10, 1.6e10))
lr <- replicate_lrr(mr2, strata)
single_lrr <- purrr::map_dfr(1:4, function(k) {
  cells <- dplyr::bind_rows(areas |> dplyr::mutate(MLRA_ID = 1, tof_m2 = X[, k]),
                            areas2 |> dplyr::mutate(MLRA_ID = 2, tof_m2 = X2[, k])) |> dplyr::mutate(target_year = 2020L)
  estimate_lrr(estimate_mlra(cells), strata |> dplyr::mutate(target_year = 2020L)) |> dplyr::mutate(replicate = k)
})
jl <- dplyr::inner_join(lr, single_lrr, by = c("denominator", "replicate"), suffix = c("", ".single"))
check("lrr: 8 rows", nrow(lr) == 8)
check("lrr: estimates equal estimate_lrr() per replicate", near(jl$estimate, jl$estimate.single))
check("lrr: standard errors equal estimate_lrr() per replicate", near(jl$se, jl$se.single))

# --- Summary ------------------------------------------------------------------------
s <- summarise_replicates(mr, by = c("MLRA_ID", "denominator"))
tot <- s[s$denominator == "total", ]
check("summary: mean over the 4 replicates", near(tot$mean, mean(c(75000, 0, 150000, 75000) / 1.75e6)))
check("summary: combined se = sqrt(sd^2 + mean(se^2))",
      near(tot$se_combined, sqrt(tot$sd^2 + mean(mr$se[mr$denominator == "total"]^2))))

# --- summarise_lrr(): one call, same numbers, weights sum to one -------------------
sl <- summarise_lrr(mr2, strata)
lrr_two_step <- summarise_replicates(replicate_lrr(mr2, strata), by = "denominator")
check("summarise_lrr: LRR summary equals the two-step result",
      near(sl$lrr$mean, lrr_two_step$mean) && near(sl$lrr$se_combined, lrr_two_step$se_combined))
tot <- sl$contributions[sl$contributions$denominator == "total", ]
check("summarise_lrr: weights are the stratum area shares and sum to one",
      near(tot$weight, c(6e10, 2e10) / 8e10) && near(sum(tot$share_of_lrr_tof), 1))
check("summarise_lrr: mean TOF area = sum of MLRA contributions",
      near(sum(tot$tof_area_m2_mean), sl$lrr$tof_area_m2_mean[sl$lrr$denominator == "total"]))

# --- Matrix builders round-trip -------------------------------------------------------
long <- tibble::tibble(aoi_id = rep(rownames(X), times = 4), replicate = rep(1:4, each = 3), tof_area_m2 = as.vector(X))
check("replicate_matrix() rebuilds the matrix from the long table", identical(replicate_matrix(long), X))
tmp <- tempfile(fileext = ".csv")
data.table::fwrite(data.table::data.table(aoi_id = rownames(X), X), tmp)
check("read_wide_csv_matrix() reads the wide CSV back", near(read_wide_csv_matrix(tmp), X) && identical(rownames(read_wide_csv_matrix(tmp)), rownames(X)))

cat("\n"); if (fails > 0) { cat(fails, "check(s) FAILED\n"); quit(status = 1) } else cat("All checks passed.\n")
