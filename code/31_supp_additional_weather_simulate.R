## 31_supp_additional_weather_simulate.R ----
##
## Uncertainty for the weather risk-partition (additonal analysis).
##
## Inputs:
##   - data/panel_state_year.parquet
##   - data/fars_persons_2018_2024.parquet
##   - data/overdispersion_window.parquet
##   - code/utils.R
##   - config.yml
##
## Outputs:
##   - temp_output/simulations_weather/main/batch{NNN}.parquet
##   - data/summaries/weather_ci.parquet

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
RATE_PER <- config::get("rate_per")
VMT_SCALE <- config::get("vmt_scale")
SIGMA_CLASS <- vmt_class_sigma(config::get("sigma_vmt"))
SIM_DIR <- here::here("temp_output", "simulations_weather", "main")

## National per-mile-risk contribution per weather from a drawn
## (state, year, weather, sim) deaths panel and shared total VMT.
compute_weather <- function(rep) {
    nat_deaths <- rep |>
        dplyr::group_by(year, weather_cat, sim_id) |>
        dplyr::summarise(deaths = sum(deaths),
            .groups = "drop")
    nat_ev <- rep |>
        dplyr::distinct(state_fips, year, sim_id, pop, vmt_mil) |>
        dplyr::group_by(year, sim_id) |>
        dplyr::summarise(pop = sum(pop),
            vmt_mil = sum(vmt_mil),
            .groups = "drop")
    nat_deaths |>
        dplyr::left_join(nat_ev,
            by = c("year", "sim_id")) |>
        dplyr::arrange(weather_cat, sim_id, year) |>
        dplyr::group_by(weather_cat, sim_id) |>
        dplyr::mutate(
            year_b = year,
            deaths_a = dplyr::lag(deaths),
            deaths_b = deaths,
            pop_a = dplyr::lag(pop),
            pop_b = pop,
            vmt_a = dplyr::lag(vmt_mil) * VMT_SCALE,
            vmt_b = vmt_mil * VMT_SCALE,
            E_avg = (vmt_a / pop_a + vmt_b / pop_b) / 2,
            risk_contrib = RATE_PER * E_avg *
                (deaths_b / vmt_b - deaths_a / vmt_a)
        ) |>
        dplyr::filter(!is.na(deaths_a),
            year_b > YEAR_I,
            year_b <= YEAR_J) |>
        dplyr::summarise(value = sum(risk_contrib),
            .groups = "drop") |>
        dplyr::mutate(
            geography = "national",
            year_a = YEAR_I,
            year_b = YEAR_J,
            component = "risk_contrib"
        )
}

## Draw inputs ----
disp_df <- arrow::read_parquet(
    here::here("data", "overdispersion_window.parquet")
)

weather_cells <- arrow::read_parquet(
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
        weather_cat,
        year,
        name = "count") |>
    tidyr::complete(tidyr::nesting(state_fips, age_group, bin, weather_cat),
        year = ANALYSIS_YEARS,
        fill = list(count = 0)) |>
    dplyr::inner_join(
        disp_df |>
            dplyr::filter(level == "deaths_age_bin_weather") |>
            dplyr::select(state_fips,
                age_group,
                bin,
                weather_cat,
                theta),
        by = c("state_fips", "age_group", "bin", "weather_cat")
    )

panel_w <- arrow::read_parquet(
    here::here("data", "panel_state_year.parquet")
) |>
    dplyr::mutate(state_fips = as.integer(state_fips)) |>
    dplyr::filter(year %in% ANALYSIS_YEARS)

sy_meta <- panel_w |>
    dplyr::transmute(state_fips,
        year,
        pop = population,
        vmt_total = vm2_total,
        rural_mic,
        rural_local,
        urban_local)

## Draw and decompose one batch ----
run_weather_batch <- function(bid) {
    deaths_long <- draw_cells_to(weather_cells,
        c("state_fips", "year", "weather_cat"),
        BATCH_SIZE,
        use_nb = TRUE) |>
        dplyr::rename(deaths = count)
    rep <- deaths_long |>
        dplyr::left_join(sy_meta,
            by = c("state_fips", "year"))
    vmt_draw <- rep |>
        dplyr::distinct(state_fips, year, sim_id,
            vmt_total, rural_mic, rural_local, urban_local) |>
        apply_vmt("vmtclass_sigma", sigma_class = SIGMA_CLASS)
    rep <- rep |>
        dplyr::left_join(
            dplyr::select(vmt_draw, state_fips, year, sim_id, vmt_mil),
            by = c("state_fips", "year", "sim_id"))
    compute_weather(rep) |> dplyr::mutate(batch_id = bid)
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
            arrow::write_parquet(run_weather_batch(bid),
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
        "weather_cat",
        "year_a",
        "year_b",
        "component"),
    out_path = here::here("data", "summaries", "weather_ci.parquet")
)
