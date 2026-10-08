## 60_supp_sensitivity_fixedvmt_simulate.R ----
##
## Sensitivity analysis with VMT held fixed. Same as the primary (09) but
## VMT stays at the FHWA point estimate with no sampling-error draw, which
## isolates the death-count contribution to the decomposition uncertainty.
##
## Inputs:
##   - data/panel_state_year.parquet
##   - data/fars_persons_2018_2024.parquet
##   - data/overdispersion_window.parquet
##   - code/utils.R
##   - config.yml
##
## Outputs:
##   - temp_output/sensitivities/fixedvmt/{main,partition}/batch{NNN}.parquet

## Imports ----
library(tidyverse)
library(here)
library(fs)
library(arrow)
library(doParallel)
library(doRNG)
library(foreach)
source(here::here("code", "utils.R"))

## Config ----
SEED <- config::get("seed")
N_BATCH <- config::get("n_batch")
BATCH_SIZE <- config::get("batch_size")
NCORES <- max(1L,
    min(config::get("max_cores"),
        parallel::detectCores(),
        na.rm = TRUE)
)
## Sensitivities cover only the main decomposition and its partition.
## category_rates is a primary-analysis-only target (script 09 / eTable 1).
TARGETS <- c("main", "partition")
YEAR_I <- config::get("year_i")
YEAR_J <- config::get("year_j")
ANALYSIS_YEARS <- YEAR_I:YEAR_J
OUT_SLUG <- "fixedvmt"
VMT_SCHEME <- "fixed"

## Draw inputs ----
disp_df <- arrow::read_parquet(
    here::here("data", "overdispersion_window.parquet")
)

agebin_cells <- arrow::read_parquet(
    here::here("data", sprintf("fars_persons_%i_%i.parquet",
        config::get("year_start"),
        config::get("year_end")))
) |>
    dplyr::mutate(
        state_fips = as.integer(state_fips),
        age_group = dplyr::if_else(is.na(age_group), "unknown", age_group)
    ) |>
    dplyr::filter(year %in% ANALYSIS_YEARS) |>
    dplyr::count(state_fips,
        age_group,
        bin,
        year,
        name = "count") |>
    tidyr::complete(tidyr::nesting(state_fips, age_group, bin),
        year = ANALYSIS_YEARS,
        fill = list(count = 0)) |>
    dplyr::inner_join(
        disp_df |>
            dplyr::filter(level == "deaths_age_bin") |>
            dplyr::select(state_fips,
                age_group,
                bin,
                theta),
        by = c("state_fips", "age_group", "bin")
    )

panel_meta <- arrow::read_parquet(
    here::here("data", "panel_state_year.parquet")
) |>
    dplyr::mutate(state_fips = as.integer(state_fips)) |>
    dplyr::filter(year %in% ANALYSIS_YEARS) |>
    dplyr::select(state_name,
        state_abb,
        state_fips,
        year,
        pop = population,
        vmt_total = vm2_total,
        urb = vm2_urban,
        rur = vm2_rural) |>
    dplyr::left_join(
        disp_df |>
            dplyr::filter(
                level %in% c("vmt_total", "vmt_urban", "vmt_rural")
            ) |>
            dplyr::select(state_fips,
                level,
                theta) |>
            tidyr::pivot_wider(names_from = level,
                values_from = theta,
                names_prefix = "theta_"),
        by = "state_fips"
    )

base_dir <- here::here("temp_output", "sensitivities", OUT_SLUG)
fs::dir_create(here::here(base_dir, TARGETS), recurse = TRUE)
main_paths <- here::here(
    base_dir, "main", sprintf("batch%03d.parquet", seq_len(N_BATCH))
)
part_paths <- here::here(
    base_dir, "partition", sprintf("batch%03d.parquet", seq_len(N_BATCH))
)
todo <- which(!(fs::file_exists(main_paths) & fs::file_exists(part_paths)))

## Run ----
if (length(todo) > 0) {
    set.seed(SEED)
    doParallel::registerDoParallel(cores = NCORES)
    foreach::foreach(bid = seq_len(N_BATCH),
        .packages = c("dplyr", "tidyr", "arrow")) %dorng% {
        if (bid %in% todo) {
            pr <- draw_bin_panel(agebin_cells,
                panel_meta,
                BATCH_SIZE,
                deaths_nb = TRUE,
                vmt_scheme = VMT_SCHEME)
            arrow::write_parquet(
                compute_main(pr, YEAR_I, YEAR_J) |>
                    dplyr::mutate(batch_id = bid),
                main_paths[bid]
            )
            arrow::write_parquet(
                compute_partition(pr, YEAR_I, YEAR_J) |>
                    dplyr::mutate(batch_id = bid),
                part_paths[bid]
            )
        }
        NULL
    }
    closeAllConnections()
    doParallel::stopImplicitCluster()
}
