## 08_partition_behavior.R ----
##
## Kitagawa partition of the per-mile risk effect into 11
## mutually-exclusive bins. Computes per-step contribtions for each
## adjacent year pair, then sums to the cumulative partition.
##
## Bins:
##   8 self-driven bins (PV occupants + motorcyclists) -- combinations
##     of {speed, alcohol, unrestrained} flags, where "unrestrained"
##     means no seatbelt for PV occupants or no helmet for motorcyclists.
##   3 non-self-driven bins -- pedestrian, bicyclist, and other road
##     users (bus/truck/ATV/etc.).
## Bin contributions sum to the per-mile risk effect.
##
## Inputs:
##   - data/panel_state_year.parquet
##   - code/utils.R
##   - config.yml
##
## Outputs:
##   - data/partition_cumulative.parquet

## Imports ----
library(tidyverse)
library(here)
source(here::here("code", "utils.R"))

## Config ----
YEAR_I <- config::get("year_i")
YEAR_J <- config::get("year_j")
VMT_SCALE <- config::get("vmt_scale")
RATE_PER <- config::get("rate_per")
PANEL_PATH <- here::here("data", "panel_state_year.parquet")
OUT_PATH <- here::here("data", "partition_cumulative.parquet")

## 11-bin partition of the per-mile risk effect (one panel/group)
partition_step_kitagawa <- function(df) {
    df |>
        dplyr::arrange(year) |>
        dplyr::mutate(
            year_a = dplyr::lag(year),
            year_b = year,
            pop_a = dplyr::lag(pop),
            vmt_a = dplyr::lag(vmt_mil) * VMT_SCALE,
            vmt_b = vmt_mil * VMT_SCALE,
            E_avg = (vmt_a / pop_a + vmt_b / pop) / 2,
            speed_only_contrib = RATE_PER * E_avg *
                (speeding_only / vmt_b - dplyr::lag(speeding_only) / vmt_a),
            alc_only_contrib = RATE_PER * E_avg *
                (alcohol_only / vmt_b - dplyr::lag(alcohol_only) / vmt_a),
            unr_only_contrib = RATE_PER * E_avg *
                (unrestrained_only / vmt_b -
                    dplyr::lag(unrestrained_only) / vmt_a),
            speed_alc_contrib = RATE_PER * E_avg *
                (speed_alc / vmt_b - dplyr::lag(speed_alc) / vmt_a),
            speed_unr_contrib = RATE_PER * E_avg *
                (speed_unr / vmt_b - dplyr::lag(speed_unr) / vmt_a),
            alc_unr_contrib = RATE_PER * E_avg *
                (alc_unr / vmt_b - dplyr::lag(alc_unr) / vmt_a),
            all_three_contrib = RATE_PER * E_avg *
                (all_three / vmt_b - dplyr::lag(all_three) / vmt_a),
            none_contrib = RATE_PER * E_avg *
                (none_flagged / vmt_b - dplyr::lag(none_flagged) / vmt_a),
            ped_contrib = RATE_PER * E_avg *
                (pedestrian / vmt_b - dplyr::lag(pedestrian) / vmt_a),
            bike_contrib = RATE_PER * E_avg *
                (bicyclist / vmt_b - dplyr::lag(bicyclist) / vmt_a),
            other_nonpv_contrib = RATE_PER * E_avg *
                (other_nonpv / vmt_b - dplyr::lag(other_nonpv) / vmt_a),
            risk_effect = speed_only_contrib + alc_only_contrib +
                unr_only_contrib + speed_alc_contrib + speed_unr_contrib +
                alc_unr_contrib + all_three_contrib + none_contrib +
                ped_contrib + bike_contrib + other_nonpv_contrib
        ) |>
        dplyr::filter(!is.na(year_a)) |>
        dplyr::select(
            year_a,
            year_b,
            risk_effect,
            dplyr::all_of(return_contribution_cols_partition())
        )
}

## Sum to cumulative effects
chain_decomposition <- function(steps_df, anchor_a, anchor_b) {
    steps_df |>
        dplyr::filter(year_b > anchor_a, year_b <= anchor_b) |>
        dplyr::summarise(
            dplyr::across(dplyr::any_of("rate_a"), dplyr::first),
            dplyr::across(dplyr::any_of("rate_b"), dplyr::last),
            dplyr::across(
                dplyr::any_of(c(
                    "delta_rate", "vmt_effect", "risk_effect",
                    return_contribution_cols_partition()
                )),
                sum
            ),
            .groups = "drop"
        ) |>
        dplyr::mutate(year_a = anchor_a, year_b = anchor_b)
}

## Read panel ----
panel_df <- arrow::read_parquet(PANEL_PATH) |>
    dplyr::select(
        state_name,
        state_abb,
        state_fips,
        year,
        pop = population,
        vmt_mil = vm2_total,
        fars_deaths,
        dplyr::all_of(return_all_bins())
    ) |>
    dplyr::arrange(state_name, year)

## State-level cumulative partition ----

## Per year-pair
state_steps <- panel_df |>
    dplyr::group_by(state_name, state_abb, state_fips) |>
    dplyr::group_modify(\(df, key) partition_step_kitagawa(df)) |>
    dplyr::ungroup()

## Cumulative
state_cum <- state_steps |>
    dplyr::group_by(state_name, state_abb, state_fips) |>
    dplyr::group_modify(\(df, key) chain_decomposition(df, YEAR_I, YEAR_J)) |>
    dplyr::ungroup()

## National cumulative partition ----

## Roll up to national totals, then run the same partition + chain
nat_yr <- panel_df |>
    dplyr::group_by(year) |>
    dplyr::summarise(
        pop = sum(pop),
        vmt_mil = sum(vmt_mil),
        dplyr::across(dplyr::all_of(return_all_bins()), sum),
        .groups = "drop"
    )

nat_cum <- nat_yr |>
    partition_step_kitagawa() |>
    chain_decomposition(YEAR_I, YEAR_J)

## Combine for export ----
out_df <- dplyr::bind_rows(
    state_cum |>
        dplyr::transmute(
            geography = "state",
            state_name,
            state_abb,
            state_fips,
            year_a,
            year_b,
            risk_effect,
            dplyr::across(dplyr::all_of(return_contribution_cols_partition())),
            scope = sprintf("cumulative_%i_%i", YEAR_I, YEAR_J)
        ),
    nat_cum |>
        dplyr::transmute(
            geography = "national",
            state_name = NA_character_,
            state_abb = NA_character_,
            state_fips = NA_integer_,
            year_a,
            year_b,
            risk_effect,
            dplyr::across(dplyr::all_of(return_contribution_cols_partition())),
            scope = sprintf("cumulative_%i_%i", YEAR_I, YEAR_J)
        )
)

## Save ----
arrow::write_parquet(out_df, OUT_PATH)
