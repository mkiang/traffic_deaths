## 09_simulate_decompositions.R ----
##
## Primary uncertainty quantification. Monte Carlo over the Kitagawa
## decomposition. Deaths are drawn from a negatve binomial (NB2) for
## each state, age group, and bin. VMT is drawn with lognormal sampling
## error on the classes states estimate from samples (rural minor
## collectors and local roads).
##
## Inputs:
##   - data/panel_state_year.parquet, data/fars_persons_2018_2024.parquet
##   - data/overdispersion_window.parquet
##   - code/utils.R, config.yml
##
## Outputs:
##   - temp_output/simulations/{main,partition,category_rates}/batch{NNN}.parquet

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
TARGETS <- unlist(config::get("targets"))
YEAR_I <- config::get("year_i")
YEAR_J <- config::get("year_j")
ANALYSIS_YEARS <- YEAR_I:YEAR_J
SIM_DIR <- here::here("temp_output", "simulations")
SIGMA_CLASS <- vmt_class_sigma(config::get("sigma_vmt"))

## Data ----
disp_df <- arrow::read_parquet(
    here::here("data", "overdispersion_window.parquet")
)

cells <- arrow::read_parquet(
    here::here("data", sprintf("fars_persons_%i_%i.parquet",
        config::get("year_start"),
        config::get("year_end")))
) |>
    dplyr::mutate(
        state_fips = as.integer(state_fips),
        age_group = dplyr::if_else(is.na(age_group), "unknown", age_group)
    ) |>
    dplyr::filter(year %in% ANALYSIS_YEARS) |>
    dplyr::count(
        state_fips,
        age_group,
        bin,
        year,
        name = "count"
    ) |>
    tidyr::complete(
        tidyr::nesting(state_fips, age_group, bin),
        year = ANALYSIS_YEARS,
        fill = list(count = 0)
    ) |>
    dplyr::inner_join(
        disp_df |>
            dplyr::filter(level == "deaths_age_bin") |>
            dplyr::select(state_fips, age_group, bin, theta),
        by = c("state_fips", "age_group", "bin")
    )

panel_meta <- arrow::read_parquet(
    here::here("data", "panel_state_year.parquet")
) |>
    dplyr::mutate(state_fips = as.integer(state_fips)) |>
    dplyr::filter(year %in% ANALYSIS_YEARS) |>
    dplyr::select(
        state_name,
        state_abb,
        state_fips,
        year,
        pop = population,
        vmt_total = vm2_total,
        urb = vm2_urban,
        rur = vm2_rural,
        rural_mic,
        rural_local,
        urban_local
    ) |>
    dplyr::left_join(
        disp_df |>
            dplyr::filter(
                level %in% c("vmt_total", "vmt_urban", "vmt_rural")
            ) |>
            dplyr::select(state_fips, level, theta) |>
            tidyr::pivot_wider(names_from = level,
                values_from = theta,
                names_prefix = "theta_"),
        by = "state_fips"
    )

## Category rates from a drawn panel ----
compute_category_rates <- function(panel_rep,
                                   year_i,
                                   year_j,
                                   rate_per = 100000) {
    all_bins <- return_all_bins()
    behavioral_bins <- return_behavioral_flagged()
    other_bins <- return_nonself_driven()
    rate_cols <- c(all_bins, "behavioral", "other", "total_crude")

    rates_from <- function(df, geo_keys) {
        df |>
            dplyr::mutate(
                behavioral = rowSums(
                    dplyr::across(dplyr::all_of(behavioral_bins))
                ),
                other = rowSums(
                    dplyr::across(dplyr::all_of(other_bins))
                ),
                total_crude = rowSums(
                    dplyr::across(dplyr::all_of(all_bins))
                )
            ) |>
            dplyr::mutate(dplyr::across(dplyr::all_of(rate_cols),
                \(x) rate_per * x / pop)) |>
            dplyr::select(dplyr::all_of(
                c(geo_keys, "sim_id", "year", rate_cols)
            )) |>
            tidyr::pivot_longer(dplyr::all_of(rate_cols),
                names_to = "component", values_to = "rate")
    }

    state_long <- rates_from(
        panel_rep |> dplyr::filter(year %in% c(year_i, year_j)),
        c("state_name", "state_abb", "state_fips")
    ) |>
        dplyr::mutate(geography = "state")

    nat <- panel_rep |>
        dplyr::filter(year %in% c(year_i, year_j)) |>
        dplyr::group_by(year, sim_id) |>
        dplyr::summarise(pop = sum(pop),
            dplyr::across(dplyr::all_of(all_bins), sum), .groups = "drop")
    nat_long <- rates_from(nat, character(0)) |>
        dplyr::mutate(geography = "national", state_name = NA_character_,
            state_abb = NA_character_, state_fips = NA_integer_)

    dplyr::bind_rows(state_long, nat_long) |>
        dplyr::mutate(
            metric = dplyr::if_else(year == year_i, "rate_a", "rate_b")
        ) |>
        dplyr::select(-year) |>
        tidyr::pivot_wider(names_from = metric, values_from = rate) |>
        dplyr::mutate(rate_change = rate_b - rate_a) |>
        tidyr::pivot_longer(c(rate_a, rate_b, rate_change),
            names_to = "metric", values_to = "value") |>
        dplyr::mutate(year_a = year_i, year_b = year_j)
}

## Run all batches in parallel ----
set.seed(SEED)
fs::dir_create(here::here(SIM_DIR, TARGETS), recurse = TRUE)
main_paths <- here::here(SIM_DIR,
    "main",
    sprintf("batch%03d.parquet", seq_len(N_BATCH)))
part_paths <- here::here(SIM_DIR,
    "partition",
    sprintf("batch%03d.parquet", seq_len(N_BATCH)))
rate_paths <- here::here(SIM_DIR,
    "category_rates",
    sprintf("batch%03d.parquet", seq_len(N_BATCH)))
todo_mp <- which(!(fs::file_exists(main_paths) & fs::file_exists(part_paths)))
todo_rates <- which(!fs::file_exists(rate_paths))
todo <- union(todo_mp, todo_rates)

if (length(todo) > 0) {
    doParallel::registerDoParallel(cores = NCORES)

    foreach::foreach(bid = seq_len(N_BATCH),
        .packages = c("dplyr", "tidyr", "arrow")) %dorng% {

        if (bid %in% todo) {
            pr <- draw_bin_panel(cells, panel_meta, BATCH_SIZE,
                deaths_nb = TRUE, vmt_scheme = "vmtclass_sigma",
                vmt_sigma_class = SIGMA_CLASS)

            if (bid %in% todo_mp) {
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

            if (bid %in% todo_rates) {
                arrow::write_parquet(
                    compute_category_rates(pr, YEAR_I, YEAR_J) |>
                        dplyr::mutate(batch_id = bid),
                    rate_paths[bid]
                )
            }
        }

        NULL
    }

    closeAllConnections()
    doParallel::stopImplicitCluster()
}
