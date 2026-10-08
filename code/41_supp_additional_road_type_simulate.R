## 41_supp_additional_road_type_simulate.R ----
##
## Uncertainty for the road-type-stratified decomposition (additional
## analysis). Deaths are drawn NB2 per state, age, bin, and road type.
## Stratum VMT uses the primary class-calibrated lognormal model.
##
## Inputs:
##   - data/panel_state_year.parquet
##   - data/fars_persons_2018_2024.parquet
##   - data/overdispersion_window.parquet
##   - code/utils.R
##   - config.yml
##
## Outputs:
##   - temp_output/simulations_road_type/main/batch{NNN}.parquet
##   - data/summaries/road_type_ci.parquet

## Imports ----
library(tidyverse)
library(here)
library(fs)
library(arrow)
library(doParallel)
library(doRNG)
library(foreach)
library(duckdb)
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
YEAR_I <- config::get("year_i")
YEAR_J <- config::get("year_j")
ANALYSIS_YEARS <- YEAR_I:YEAR_J
SIGMA_CLASS <- vmt_class_sigma(config::get("sigma_vmt"))
SIM_DIR <- here::here("temp_output", "simulations_road_type", "main")

## National crude-rate decomposition per road type. The crude rate uses
## total state population, so strata sum to the known-road-type change.
compute_roadtype <- function(rt_rep) {
    nat <- rt_rep |>
        dplyr::group_by(road_type, year, sim_id) |>
        dplyr::summarise(deaths = sum(deaths),
            pop = sum(pop),
            vmt_mil = sum(vmt_mil),
            .groups = "drop")
    roadtype_a <- nat |>
        dplyr::transmute(road_type,
            sim_id,
            year,
            deaths_a = deaths,
            pop_a = pop,
            vmt_a_mil = vmt_mil)
    roadtype_b <- nat |>
        dplyr::transmute(road_type,
            sim_id,
            year_b = year,
            year_a = year - 1L,
            deaths_b = deaths,
            pop_b = pop,
            vmt_b_mil = vmt_mil)
    joined_df <- dplyr::inner_join(
        roadtype_b,
        roadtype_a,
        by = c("road_type", "sim_id", "year_a" = "year")
    )
    dplyr::bind_cols(joined_df, kitagawa_terms(
        joined_df$deaths_a,
        joined_df$pop_a,
        joined_df$vmt_a_mil,
        joined_df$deaths_b,
        joined_df$pop_b,
        joined_df$vmt_b_mil
    )) |>
        dplyr::filter(year_b > YEAR_I,
            year_b <= YEAR_J) |>
        dplyr::arrange(road_type,
            sim_id,
            year_b) |>
        dplyr::group_by(road_type, sim_id) |>
        dplyr::summarise(rate_a = dplyr::first(rate_a),
            rate_b = dplyr::last(rate_b),
            delta_rate = sum(delta_rate),
            vmt_effect = sum(vmt_effect),
            risk_effect = sum(risk_effect),
            .groups = "drop") |>
        dplyr::mutate(geography = "national",
            year_a = YEAR_I,
            year_b = YEAR_J) |>
        tidyr::pivot_longer(
            c(rate_a, rate_b, delta_rate, vmt_effect, risk_effect),
            names_to = "component",
            values_to = "value"
        )
}

## Draw inputs ----
disp_df <- arrow::read_parquet(
    here::here("data", "overdispersion_window.parquet")
)

rt_cells <- arrow::read_parquet(
    here::here("data", sprintf("fars_persons_%i_%i.parquet",
        config::get("year_start"),
        config::get("year_end")))
) |>
    dplyr::mutate(
        state_fips = as.integer(state_fips),
        age_group = dplyr::if_else(is.na(age_group), "unknown", age_group)
    ) |>
    dplyr::filter(year %in% ANALYSIS_YEARS,
        road_type %in% c("urban", "rural")) |>
    dplyr::count(state_fips,
        age_group,
        bin,
        road_type,
        year,
        name = "count") |>
    tidyr::complete(tidyr::nesting(state_fips, age_group, bin, road_type),
        year = ANALYSIS_YEARS,
        fill = list(count = 0)) |>
    dplyr::inner_join(
        disp_df |>
            dplyr::filter(level == "deaths_age_bin_roadtype") |>
            dplyr::select(state_fips,
                age_group,
                bin,
                road_type,
                theta),
        by = c("state_fips", "age_group", "bin", "road_type")
    )

panel_meta_rt <- arrow::read_parquet(
    here::here("data", "panel_state_year.parquet")
) |>
    dplyr::mutate(state_fips = as.integer(state_fips)) |>
    dplyr::filter(year %in% ANALYSIS_YEARS) |>
    dplyr::transmute(state_fips,
        year,
        pop = population,
        urban = vm2_urban,
        rural = vm2_rural,
        rural_mic,
        rural_local,
        urban_local) |>
    tidyr::pivot_longer(c(urban, rural),
        names_to = "road_type",
        values_to = "vmt_rt") |>
    dplyr::mutate(
        vmt_total = vmt_rt,
        rural_mic = dplyr::if_else(road_type == "rural", rural_mic, 0),
        rural_local = dplyr::if_else(road_type == "rural", rural_local, 0),
        urban_local = dplyr::if_else(road_type == "urban", urban_local, 0)
    )

## Draw and decompose one batch ----
run_rt_batch <- function(bid) {
    deaths_long <- draw_cells_to(rt_cells,
        c("state_fips", "year", "road_type"),
        BATCH_SIZE,
        use_nb = TRUE) |>
        dplyr::rename(deaths = count)
    rt_rep <- deaths_long |>
        dplyr::left_join(panel_meta_rt,
            by = c("state_fips", "year", "road_type"))
    vmt_draw <- rt_rep |>
        dplyr::distinct(state_fips, year, road_type, sim_id,
            vmt_total, rural_mic, rural_local, urban_local) |>
        apply_vmt("vmtclass_sigma", sigma_class = SIGMA_CLASS)
    rt_rep <- rt_rep |>
        dplyr::left_join(
            dplyr::select(
                vmt_draw, state_fips, year, road_type, sim_id, vmt_mil
            ),
            by = c("state_fips", "year", "road_type", "sim_id"))
    compute_roadtype(rt_rep) |> dplyr::mutate(batch_id = bid)
}

## Run ----
set.seed(SEED)
fs::dir_create(SIM_DIR, recurse = TRUE)
paths <- here::here(SIM_DIR, sprintf("batch%03d.parquet", seq_len(N_BATCH)))
todo <- which(!fs::file_exists(paths))

if (length(todo) > 0) {
    doParallel::registerDoParallel(cores = NCORES)
    foreach::foreach(bid = seq_len(N_BATCH),
        .packages = c("dplyr", "tidyr", "arrow")) %dorng% {
        if (bid %in% todo) {
            arrow::write_parquet(run_rt_batch(bid),
                paths[bid])
        }
        NULL
    }
    closeAllConnections()
    doParallel::stopImplicitCluster()
}

## Summarize and save ----
summarize_dir(
    glob = here::here(SIM_DIR, "*.parquet"),
    group_cols = c("geography",
        "road_type",
        "year_a",
        "year_b",
        "component"),
    out_path = here::here("data", "summaries", "road_type_ci.parquet")
)
