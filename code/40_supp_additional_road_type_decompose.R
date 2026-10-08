## 40_supp_additional_road_type_decompose.R ----
##
## Additional analysis. National Kitagawa decomposition stratfied by
## road type (urban vs rural), among deaths with a known road type.
##
## Inputs:
##   - data/fars_persons_2018_2024.parquet (road_type, year)
##   - data/panel_state_year.parquet (population, vm2_urban, vm2_rural)
##   - code/utils.R
##   - config.yml
##
## Outputs:
##   - data/decomposition_road_type.parquet

## Imports ----
library(tidyverse)
library(here)
library(arrow)
source(here::here("code", "utils.R"))

## Config ----
YEAR_I <- config::get("year_i")
YEAR_J <- config::get("year_j")

## National deaths by year and road type (urban/rural only) ----
deaths_rt <- arrow::read_parquet(
    here::here("data", sprintf("fars_persons_%i_%i.parquet",
        config::get("year_start"),
        config::get("year_end")))
) |>
    dplyr::filter(road_type %in% c("urban", "rural"),
        year >= YEAR_I) |>
    dplyr::count(year, road_type, name = "deaths")

## National population + stratum VMT by year ----
nat_yr <- arrow::read_parquet(here::here("data", "panel_state_year.parquet")) |>
    dplyr::filter(year >= YEAR_I) |>
    dplyr::group_by(year) |>
    dplyr::summarise(
        pop = sum(population),
        urban = sum(vm2_urban),
        rural = sum(vm2_rural),
        .groups = "drop"
    ) |>
    tidyr::pivot_longer(c(urban, rural),
        names_to = "road_type",
        values_to = "vmt_mil")

rt_panel <- deaths_rt |>
    dplyr::left_join(nat_yr,
        by = c("year", "road_type")) |>
    dplyr::arrange(road_type, year)

## Decomposition ----
decompose_step <- function(df) {
    paired <- df |>
        dplyr::arrange(year) |>
        dplyr::transmute(
            year_b = year,
            deaths_a = dplyr::lag(deaths),
            deaths_b = deaths,
            pop_a = dplyr::lag(pop),
            pop_b = pop,
            vmt_a_mil = dplyr::lag(vmt_mil),
            vmt_b_mil = vmt_mil
        ) |>
        dplyr::filter(!is.na(deaths_a))
    paired |>
        dplyr::bind_cols(kitagawa_terms(
            paired$deaths_a,
            paired$pop_a,
            paired$vmt_a_mil,
            paired$deaths_b,
            paired$pop_b,
            paired$vmt_b_mil
        ))
}

rt_cum <- rt_panel |>
    dplyr::group_by(road_type) |>
    dplyr::group_modify(\(df, key) decompose_step(df)) |>
    dplyr::filter(year_b > YEAR_I,
        year_b <= YEAR_J) |>
    dplyr::summarise(
        rate_a = dplyr::first(rate_a),
        rate_b = dplyr::last(rate_b),
        delta_rate = sum(delta_rate),
        vmt_effect = sum(vmt_effect),
        risk_effect = sum(risk_effect),
        .groups = "drop"
    ) |>
    dplyr::mutate(geography = "national",
        year_a = YEAR_I,
        year_b = YEAR_J,
        scope = sprintf("cumulative_%i_%i", YEAR_I, YEAR_J))

## Save ----
arrow::write_parquet(rt_cum,
    here::here("data", "decomposition_road_type.parquet"))
