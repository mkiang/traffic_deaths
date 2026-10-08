## 07_decompose_rates.R ----
##
## Kitagawa decomposition of the FARS crude rate change into a VMT-exposure
## effect and a per-mile risk effect, for each adjacent year pair.
##
## Inputs:
##   - data/panel_state_year.parquet
##   - code/utils.R
##   - config.yml
##
## Outputs:
##   - data/decomposition_chained.parquet

## Imports ----
library(tidyverse)
library(here)
source(here::here("code", "utils.R"))

## Config ----
YEAR_I <- config::get("year_i")
YEAR_J <- config::get("year_j")
PANEL_PATH <- here::here("data", "panel_state_year.parquet")
OUT_PATH <- here::here("data", "decomposition_chained.parquet")

## Read panel ----
panel_df <- arrow::read_parquet(PANEL_PATH) |>
    dplyr::select(
        state_name,
        state_abb,
        state_fips,
        year,
        deaths = fars_deaths,
        pop = population,
        vmt_mil = vm2_total
    ) |>
    dplyr::arrange(state_name, year)

## Kitagawa decomposition ----
##
## For each adjacent year pair (a, b), with exposure E = vmt / pop and
## per-mile risk R = deaths / vmt:
##
##   delta_rate = (E_b - E_a) * (R_a + R_b) / 2
##              + (E_a + E_b) / 2 * (R_b - R_a)
##
## The first term is the VMT (exposure) effect and the second is the
## per-mile risk effect. By constructon they sum to the change in the
## crude rate.
decompose_step <- function(df) {
    paired <- df |>
        dplyr::arrange(year) |>
        dplyr::transmute(
            year_a = dplyr::lag(year),
            year_b = year,
            deaths_a = dplyr::lag(deaths),
            deaths_b = deaths,
            pop_a = dplyr::lag(pop),
            pop_b = pop,
            vmt_a_mil = dplyr::lag(vmt_mil),
            vmt_b_mil = vmt_mil
        ) |>
        dplyr::filter(!is.na(year_a))
    paired |>
        dplyr::bind_cols(kitagawa_terms(
            paired$deaths_a, paired$pop_a, paired$vmt_a_mil,
            paired$deaths_b, paired$pop_b, paired$vmt_b_mil
        )) |>
        dplyr::select(year_a, year_b, rate_a, rate_b, delta_rate,
                      vmt_effect, risk_effect)
}

## State-level ----

## Per year-pair
state_steps <- panel_df |>
    dplyr::group_by(state_name, state_abb, state_fips) |>
    dplyr::group_modify(\(df, key) decompose_step(df)) |>
    dplyr::ungroup()

## Cumulative
state_cum <- state_steps |>
    dplyr::filter(year_b > YEAR_I, year_b <= YEAR_J) |>
    dplyr::group_by(state_name, state_abb, state_fips) |>
    dplyr::summarise(
        rate_a = dplyr::first(rate_a),
        rate_b = dplyr::last(rate_b),
        delta_rate = sum(delta_rate),
        vmt_effect_chained = sum(vmt_effect),
        risk_effect_chained = sum(risk_effect),
        .groups = "drop"
    ) |>
    dplyr::mutate(
        year_a = YEAR_I,
        year_b = YEAR_J
    )

## National ----

## Roll up to national totals, then run the same decomposition
nat_steps <- panel_df |>
    dplyr::group_by(year) |>
    dplyr::summarise(
        deaths = sum(deaths),
        pop = sum(pop),
        vmt_mil = sum(vmt_mil),
        .groups = "drop"
    ) |>
    decompose_step()

nat_cum <- nat_steps |>
    dplyr::filter(year_b > YEAR_I, year_b <= YEAR_J) |>
    dplyr::summarise(
        rate_a = dplyr::first(rate_a),
        rate_b = dplyr::last(rate_b),
        delta_rate = sum(delta_rate),
        vmt_effect_chained = sum(vmt_effect),
        risk_effect_chained = sum(risk_effect)
    ) |>
    dplyr::mutate(
        year_a = YEAR_I,
        year_b = YEAR_J
    )

## Combine for export ----
out_df <- dplyr::bind_rows(
    state_steps |>
        dplyr::transmute(
            geography = "state",
            state_name,
            state_abb,
            state_fips,
            year_a,
            year_b,
            rate_a,
            rate_b,
            delta_rate,
            vmt_effect,
            risk_effect,
            scope = "step"
        ),
    state_cum |>
        dplyr::transmute(
            geography = "state",
            state_name,
            state_abb,
            state_fips,
            year_a,
            year_b,
            rate_a,
            rate_b,
            delta_rate,
            vmt_effect = vmt_effect_chained,
            risk_effect = risk_effect_chained,
            scope = sprintf("cumulative_%i_%i", YEAR_I, YEAR_J)
        ),
    nat_steps |>
        dplyr::transmute(
            geography = "national",
            state_name = NA_character_,
            state_abb = NA_character_,
            state_fips = NA_integer_,
            year_a,
            year_b,
            rate_a,
            rate_b,
            delta_rate,
            vmt_effect,
            risk_effect,
            scope = "step"
        ),
    nat_cum |>
        dplyr::transmute(
            geography = "national",
            state_name = NA_character_,
            state_abb = NA_character_,
            state_fips = NA_integer_,
            year_a,
            year_b,
            rate_a,
            rate_b,
            delta_rate,
            vmt_effect = vmt_effect_chained,
            risk_effect = risk_effect_chained,
            scope = sprintf("cumulative_%i_%i", YEAR_I, YEAR_J)
        )
)

## Save ----
arrow::write_parquet(out_df, OUT_PATH)
