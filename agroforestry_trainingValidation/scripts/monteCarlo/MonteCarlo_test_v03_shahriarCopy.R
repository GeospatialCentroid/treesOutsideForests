#### Monte Carlo Simulation of Carbon Gains and Losses Across Multiple Grids ####
## Developed by: Gabriel Ferreira and Shahriar Heydari
## Last modification: 10/24/2025
## Note: This script is fully operational, but it is incomplete. It simulates the process, but the real classification maps need to be inputted.
## Objective: Estimate annual biomass carbon changes across spatial grids (pilot: Nebraska) using the classified maps from NAIP imagery 
## and estimate uncertainty through a Monte Carlo simulation process
## Requirements: - Activity data: Classification maps: 2010, 2016 and 2020
## - Classification uncertainty: Positive prediction rate (PPR) and negative prediction rate (NPR); results from model evalution (ground truthing)
## - Age distribution: estimated from tree subsets by processing 3DEP (USGS) Lidar data
## - biomass carbon factors: generated through a linear mixed model after a thourough literature review



library(terra)
library(dplyr)

#### Simulation of Carbon Gains and Losses Across Multiple Grids ####

#----------------------------------------
# 1. Simulation parameters
#----------------------------------------
maturity_age <- 20
nrow <- 2000
ncol <- 2000
n_iterations <- 5
set.seed(42)

# Gain parameters (shared across grids)
gain_young  <- 1.0
gain_young_sd <- 0.2
gain_mature <- 0.6
gain_mature_sd<- 0.1
  
# Age distributions (shared across grids)
removed_trees_age  <- round(rnorm(1000, 40, 5))
existing_trees_age <- round(rnorm(1000, 20, 4))

#----------------------------------------
# 2. Flip function
#----------------------------------------
flip_binary <- function(x, ppr, npr) {
  rand <- runif(length(x))
  flip_1to0 <- (x == 1 & rand > ppr)
  flip_0to1 <- (x == 0 & rand > npr)
  x[flip_1to0 | flip_0to1] <- 1 - x[flip_1to0 | flip_0to1]
  x
}

#----------------------------------------
# 3. Grid generation (3 independent grids) # Just for testing
#----------------------------------------
generate_grid_maps <- function(prob = c(0.97, 0.03)) {
  list(
    map_2010 = sample(0:1, nrow * ncol, replace = TRUE, prob = prob),
    map_2016 = sample(0:1, nrow * ncol, replace = TRUE, prob = prob),
    map_2020 = sample(0:1, nrow * ncol, replace = TRUE, prob = prob)
  )
}

grids <- list(
  gridA = generate_grid_maps(),
  gridB = generate_grid_maps(),
  gridC = generate_grid_maps()
)

#----------------------------------------
# 4. Read PPR/NPR statistics from CSV files
#----------------------------------------
read_stats <- function(year_file) {
  read.csv(year_file, stringsAsFactors = FALSE)
}

stats_2010 <- read_stats("2010_stats.csv")
stats_2016 <- read_stats("2016_stats.csv")
stats_2020 <- read_stats("2020_stats.csv")

# Combine into a named list for access
ppr_npr_all <- list(
  `2010` = stats_2010,
  `2016` = stats_2016,
  `2020` = stats_2020
)

#----------------------------------------
# 5. Simulation function (per iteration × grid)
#----------------------------------------
simulate_iteration <- function(
    iter,
    grid_name,
    grid_data,
    ppr_npr_all,
    removed_trees_age,
    existing_trees_age,
    gain_young, 
    gain_young_sd,
    gain_mature, 
    gain_mature_sd
) {
  cat("Running iteration", iter, "for", grid_name, "...\n")
  
  # --- Extract the maps
  map_2010 <- grid_data$map_2010
  map_2016 <- grid_data$map_2016
  map_2020 <- grid_data$map_2020
  
  # --- Retrieve grid-specific PPR/NPR for each year
  get_ppr_npr <- function(year, grid_name) {
    df <- ppr_npr_all[[as.character(year)]]
    row <- df[df$GridID == grid_name, ]
    if (nrow(row) == 0)
      stop(paste("No PPR/NPR found for", grid_name, "in year", year))
    return(list(PPR = row$PPR, NPR = row$NPR))
  }
  
  s2010 <- get_ppr_npr(2010, grid_name)
  s2016 <- get_ppr_npr(2016, grid_name)
  s2020 <- get_ppr_npr(2020, grid_name)
  
  # --- Apply flipping
  m2010 <- flip_binary(map_2010, s2010$PPR, s2010$NPR)
  m2016 <- flip_binary(map_2016, s2016$PPR, s2016$NPR)
  m2020 <- flip_binary(map_2020, s2020$PPR, s2020$NPR)
  
  # --- Simulate gain factors for this iteration ---
  gain_young_iter  <- rnorm(1, mean = gain_young,  sd = gain_young_sd)
  gain_mature_iter <- rnorm(1, mean = gain_mature, sd = gain_mature_sd)
  
  # --- Transition logic
  n <- length(m2010)
  age_2010 <- rep(NA, n)
  age_2016 <- rep(NA, n)
  age_2020 <- rep(NA, n)
  
  cond_000 <- (m2010 == 0 & m2016 == 0 & m2020 == 0)
  cond_001 <- (m2010 == 0 & m2016 == 0 & m2020 == 1)
  cond_010 <- (m2010 == 0 & m2016 == 1 & m2020 == 0)
  cond_011 <- (m2010 == 0 & m2016 == 1 & m2020 == 1)
  cond_100 <- (m2010 == 1 & m2016 == 0 & m2020 == 0)
  cond_101 <- (m2010 == 1 & m2016 == 0 & m2020 == 1)
  cond_110 <- (m2010 == 1 & m2016 == 1 & m2020 == 0)
  cond_111 <- (m2010 == 1 & m2016 == 1 & m2020 == 1)
  
  # --- Assigning ages
  age_2020[cond_001] <- sample(1:4, sum(cond_001), replace = TRUE)
  age_2016[cond_010] <- sample(1:6, sum(cond_010), replace = TRUE)
  age_2016[cond_011] <- sample(1:6, sum(cond_011), replace = TRUE)
  age_2020[cond_011] <- age_2016[cond_011] + 4
  age_2010[cond_100] <- sample(removed_trees_age, sum(cond_100), replace = TRUE)
  age_2010[cond_101] <- sample(removed_trees_age, sum(cond_101), replace = TRUE)
  age_2020[cond_101] <- sample(1:4, sum(cond_101), replace = TRUE)
  age_2016[cond_110] <- sample(existing_trees_age, sum(cond_110), replace = TRUE)
  age_2010[cond_110] <- pmax(age_2016[cond_110] - 6, 1)
  age_2016[cond_111] <- sample(existing_trees_age, sum(cond_111), replace = TRUE)
  age_2010[cond_111] <- pmax(age_2016[cond_111] - 6, 1)
  
  # --- Gain rates
  gain_rate_2016 <- ifelse(!is.na(age_2016) & age_2016 < 20, gain_young_iter, gain_mature_iter)
  gain_rate_2020 <- ifelse(!is.na(age_2020) & age_2020 < 20, gain_young_iter, gain_mature_iter)
  
  carbon_change_2016 <- numeric(n)
  carbon_change_2020 <- numeric(n)
  
  # --- Gains
  carbon_change_2016[m2016 == 1] <- gain_rate_2016[m2016 == 1]
  carbon_change_2020[m2020 == 1] <- gain_rate_2020[m2020 == 1]
  
  # --- Losses (annualized)
  loss_rate_2016 <- 1 / 6
  loss_rate_2020 <- 1 / 4
  
  calc_loss <- function(ages, loss_rate) {
    ifelse(
      ages <= 20,
      ages * gain_young_iter,
      20 * gain_young_iter + (ages - 20) * gain_mature_iter
    ) * loss_rate
  }
  
  idx_loss_2016 <- which(m2010 == 1 & m2016 == 0)
  if (length(idx_loss_2016) > 0) {
    carbon_change_2016[idx_loss_2016] <- -calc_loss(age_2010[idx_loss_2016], loss_rate_2016)
  }
  
  idx_loss_2020 <- which(m2016 == 1 & m2020 == 0)
  if (length(idx_loss_2020) > 0) {
    carbon_change_2020[idx_loss_2020] <- -calc_loss(age_2016[idx_loss_2020], loss_rate_2020)
  }
  
  # --- Summaries
  gains_2016_total  <- sum(carbon_change_2016[carbon_change_2016 > 0], na.rm = TRUE)
  losses_2016_total <- -sum(carbon_change_2016[carbon_change_2016 < 0], na.rm = TRUE)
  net_2016 <- gains_2016_total - losses_2016_total
  
  gains_2020_total  <- sum(carbon_change_2020[carbon_change_2020 > 0], na.rm = TRUE)
  losses_2020_total <- -sum(carbon_change_2020[carbon_change_2020 < 0], na.rm = TRUE)
  net_2020 <- gains_2020_total - losses_2020_total
  
  # --- Per-condition breakdowns (stored, not printed) ## used for troubleshooting
  cond_list <- list(cond_000, cond_001, cond_010, cond_011,
                    cond_100, cond_101, cond_110, cond_111)
  cond_names <- c("cond_000", "cond_001", "cond_010", "cond_011",
                  "cond_100", "cond_101", "cond_110", "cond_111")
  
  per_condition_2016 <- data.frame(
    Condition = cond_names,
    Gain  = sapply(cond_list, function(cond) sum(carbon_change_2016[cond & carbon_change_2016 > 0], na.rm = TRUE)),
    Loss  = sapply(cond_list, function(cond) -sum(carbon_change_2016[cond & carbon_change_2016 < 0], na.rm = TRUE))
  )
  per_condition_2016$Net <- per_condition_2016$Gain - per_condition_2016$Loss
  
  per_condition_2020 <- data.frame(
    Condition = cond_names,
    Gain  = sapply(cond_list, function(cond) sum(carbon_change_2020[cond & carbon_change_2020 > 0], na.rm = TRUE)),
    Loss  = sapply(cond_list, function(cond) -sum(carbon_change_2020[cond & carbon_change_2020 < 0], na.rm = TRUE))
  )
  per_condition_2020$Net <- per_condition_2020$Gain - per_condition_2020$Loss
  
  per_condition <- list(
    Year2016 = per_condition_2016,
    Year2020 = per_condition_2020
  )
  
  # --- Return results
  results <- data.frame(
    Grid = grid_name,
    Iteration = iter,
    Year = c(2016, 2020),
    Gain_tC_per_year = c(gains_2016_total, gains_2020_total),
    Loss_tC_per_year = c(losses_2016_total, losses_2020_total),
    Net_tC_per_year  = c(net_2016, net_2020)
  )
  
  return(list(summary = results, per_condition = per_condition))
}

#----------------------------------------
# 6. Run all simulations (all grids × iterations)
#----------------------------------------
simulation_results <- list()
per_condition_results <- list()

for (grid_name in names(grids)) {
  grid_data <- grids[[grid_name]]
  
  cat("\n=== Running simulations for", grid_name, "===\n")
  
  res <- lapply(
    1:n_iterations,
    function(i) {
      simulate_iteration(
        iter = i,
        grid_name = grid_name,
        grid_data = grid_data,
        ppr_npr_all = ppr_npr_all,
        removed_trees_age = removed_trees_age,
        existing_trees_age = existing_trees_age,
        gain_young = gain_young,
        gain_young_sd = gain_young_sd,
        gain_mature = gain_mature,
        gain_mature_sd = gain_mature_sd
      )
    })
  
  # Extract summaries and per-condition breakdowns
  simulation_results[[grid_name]] <- do.call(rbind, lapply(res, function(x) x$summary))
  
  per_condition_results[[grid_name]] <- lapply(res, function(x) x$per_condition)
}


per_condition_results[["gridA"]][[5]][["Year2016"]]

#----------------------------------------
# 7. Combine and summarize
#----------------------------------------
all_summary <- do.call(rbind, simulation_results)

summary_stats <- all_summary %>%
  group_by(Grid, Year) %>%
  summarise(
    mean_gain = mean(Gain_tC_per_year),
    mean_loss = mean(Loss_tC_per_year),
    mean_net  = mean(Net_tC_per_year),
    ci_low = quantile(Net_tC_per_year, 0.025),
    ci_high = quantile(Net_tC_per_year, 0.975),
    .groups = "drop"
  )

cat("\n===== Summary across grids =====\n")
print(summary_stats)


#----------------------------------------
# Troubleshoot for each grid
#----------------------------------------
grid <- "gridB"
year <- "Year2020"

# Function to summarize per-condition results for a given grid and year
summarize_per_condition <- function(grid_name, year_name) {
  bind_rows(per_condition_results[[grid_name]], .id = "Iteration") %>%
    mutate(Iteration = as.integer(Iteration)) %>%
    select(Iteration, all_of(year_name)) %>%
    # Extract the per-condition table
    lapply(function(x) x[[year_name]]) %>%
    bind_rows() %>%
    group_by(Condition) %>%
    summarise(
      Gain_mean = mean(Gain),
      Loss_mean = mean(Loss),
      Net_mean  = mean(Net),
      .groups = "drop"
    ) %>%
    mutate(Grid = grid_name, Year = as.integer(sub("Year", "", year_name)))
}
#----------------------------------------
# Example: 
#----------------------------------------
# summarize gridA for 2016
summary_gridA_2016 <- summarize_per_condition("gridA", "Year2016")


# Combine all grids for 2020
all_grids_2020 <- bind_rows(
  lapply(names(per_condition_results), function(g) summarize_per_condition(g, "Year2020"))
)

summary_gridA_2016
all_grids_2020