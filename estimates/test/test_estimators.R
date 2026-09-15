# Checks estimate_mlra() and estimate_lrr() against a hand-built table with
# known answers (the worked example in estimates/README.md). Run:
#   Rscript estimates/test/test_estimators.R
source(here::here("shared/R/setup.R"))
pacman::p_load(dplyr, tidyr, purrr, tibble)
source(tof_root("estimates/functions/estimators.R"))

km2 <- 1e6
cells <- dplyr::bind_rows(
  # MLRA A: four cells with unequal eligible area, one entirely masked
  tibble::tibble(MLRA_ID = "A", id = paste0("a", 1:4), footprint_m2 = 1 * km2,
                 eligible_m2 = c(0.9, 0.5, 0.1, 0) * km2, tof_m2 = c(0.045, 0.05, 0.03, 0) * km2),
  # MLRA B: two fully eligible cells, 20 % each
  tibble::tibble(MLRA_ID = "B", id = paste0("b", 1:2), footprint_m2 = 1 * km2,
                 eligible_m2 = 1 * km2, tof_m2 = 0.2 * km2),
  # MLRA C: three fully eligible cells, 4 % each, plus one with no model output
  tibble::tibble(MLRA_ID = "C", id = paste0("c", 1:4), footprint_m2 = 1 * km2,
                 eligible_m2 = 1 * km2, tof_m2 = c(0.04, 0.04, 0.04, NA) * km2)
) |> dplyr::mutate(target_year = 2020L)
strata <- tibble::tibble(MLRA_ID = c("A", "B", "C"), target_year = 2020L,
                         total_m2 = c(60000, 20000, 120000) * km2,
                         eligible_m2 = c(22500, 16000, 30000) * km2)

fails <- 0
check <- function(label, got, want, tol = 1e-6) {
  ok <- isTRUE(all.equal(got, want, tolerance = tol))
  cat(sprintf("%-52s %s  (got %s, want %s)\n", label, if (ok) "ok" else "FAIL", format(got), format(want)))
  if (!ok) fails <<- fails + 1
}
pick <- function(tbl, ...) dplyr::filter(tbl, ...)

m <- estimate_mlra(cells)
check("A eligible: 0.125 / 1.5",     pick(m, MLRA_ID == "A", denominator == "eligible")$pct, 100 * 0.125 / 1.5)
check("A total: 0.125 / 4",          pick(m, MLRA_ID == "A", denominator == "total")$pct, 100 * 0.125 / 4)
check("A eligible se (hand-computed)", pick(m, MLRA_ID == "A", denominator == "eligible")$pct_se, 2.9201, tol = 1e-4)
check("B eligible: 20 %",            pick(m, MLRA_ID == "B", denominator == "eligible")$pct, 20)
check("B se is 0 (identical cells)", pick(m, MLRA_ID == "B", denominator == "eligible")$se, 0)
check("C drops the NA cell: n = 3",  pick(m, MLRA_ID == "C", denominator == "total")$n, 3L)
check("C counts it: n_missing = 1",  pick(m, MLRA_ID == "C", denominator == "total")$n_missing, 1L)
check("C eligible: 4 %",             pick(m, MLRA_ID == "C", denominator == "eligible")$pct, 4)
check("rows: 3 MLRAs x 2 denominators", nrow(m), 6L)

l <- estimate_lrr(m, strata)
# eligible: (22500/12 + 0.2*16000 + 0.04*30000) / 68500 = 6275 / 68500
check("LRR eligible: 6275 / 68500",  pick(l, denominator == "eligible")$pct, 100 * 6275 / 68500)
check("LRR eligible TOF area km2",   pick(l, denominator == "eligible")$tof_area_m2 / km2, 6275)
# total: (0.03125*60000 + 0.2*20000 + 0.04*120000) / 200000 = 10675 / 200000
check("LRR total: 10675 / 200000",   pick(l, denominator == "total")$pct, 100 * 10675 / 200000)
check("LRR total TOF area km2",      pick(l, denominator == "total")$tof_area_m2 / km2, 10675)
# only A has a non-zero se, so the LRR se is W_A * se_A
w_a <- 22500 / 68500
check("LRR eligible se = W_A * se_A", pick(l, denominator == "eligible")$se,
      w_a * pick(m, MLRA_ID == "A", denominator == "eligible")$se)
check("LRR n_cells = 9",             pick(l, denominator == "eligible")$n_cells, 9L)

# a stratum with no areas must be an error, not a silent drop
err <- tryCatch({ estimate_lrr(m, strata[-1, ]); "no error" }, error = function(e) "error")
check("missing stratum areas -> error", err, "error")

cat(if (fails == 0) "\nAll checks passed.\n" else sprintf("\n%d check(s) FAILED.\n", fails))
quit(status = if (fails == 0) 0 else 1)
