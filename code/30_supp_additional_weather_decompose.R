## 30_supp_additional_weather_decompose.R ----
##
## Additional analysis. Partition the national per-mile-risk effect by
## crash weather (good, adverse, unknown).
##
## Inputs:
##   - data/fars_persons_2018_2024.parquet (weather_cat, year)
##   - data/panel_state_year.parquet (population, vm2_total)
##   - code/utils.R
##   - config.yml
##
## Outputs:
##   - data/decomposition_weather.parquet

## Imports ----
library(tidyverse)
library(here)
library(arrow)
source(here::here("code", "utils.R"))

## Config ----
YEAR_I <- config::get("year_i")
YEAR_J <- config::get("year_j")
RATE_PER <- config::get("rate_per")
VMT_SCALE <- config::get("vmt_scale")

## National deaths by year and weather ----
deaths_w <- arrow::read_parquet(
    here::here("data", sprintf("fars_persons_%i_%i.parquet",
        config::get("year_start"),
        config::get("year_end")))
) |>
    dplyr::filter(year >= YEAR_I) |>
    dplyr::count(year,
        weather_cat,
        name = "deaths")

## National population + total VMT by year ----
nat_yr <- arrow::read_parquet(here::here("data", "panel_state_year.parquet")) |>
    dplyr::filter(year >= YEAR_I) |>
    dplyr::group_by(year) |>
    dplyr::summarise(
        pop = sum(population),
        vmt_mil = sum(vm2_total),
        .groups = "drop"
    )

## Cumulative risk contribution per weather ----
weather_cum <- deaths_w |>
    dplyr::left_join(nat_yr,
        by = "year") |>
    dplyr::arrange(weather_cat, year) |>
    dplyr::group_by(weather_cat) |>
    dplyr::mutate(
        year_b = year,
        deaths_a = dplyr::lag(deaths),
        deaths_b = deaths,
        pop_a = dplyr::lag(pop),
        pop_b = pop,
        vmt_a = dplyr::lag(vmt_mil) * VMT_SCALE,
        vmt_b = vmt_mil * VMT_SCALE,
        E_avg = (vmt_a / pop_a + vmt_b / pop_b) / 2,
        risk_contrib = RATE_PER * E_avg * (deaths_b / vmt_b - deaths_a / vmt_a)
    ) |>
    dplyr::filter(!is.na(deaths_a),
        year_b > YEAR_I,
        year_b <= YEAR_J) |>
    dplyr::summarise(
        risk_contrib = sum(risk_contrib),
        .groups = "drop"
    ) |>
    dplyr::mutate(
        geography = "national",
        year_a = YEAR_I,
        year_b = YEAR_J,
        scope = sprintf("cumulative_%i_%i", YEAR_I, YEAR_J)
    )

## Save ----
arrow::write_parquet(weather_cum,
    here::here("data", "decomposition_weather.parquet"))
