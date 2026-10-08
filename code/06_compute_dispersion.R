## 06_compute_dispersion.R ----
##
## Calculate negative-binomial dispersion using both method of moments and
## empirical Bayes.
##
## Inputs:
##   - data/panel_state_year.parquet
##   - data/fars_persons_2018_2024.parquet
##   - code/utils.R, config.yml
##
## Outputs:
##   - data/overdispersion_window.parquet

## Imports ----
library(tidyverse)
library(here)
library(edgeR)
source(here::here("code", "utils.R"))

## Config ----
THETA_POISSON <- config::get("theta_poisson")
ANALYSIS_YEARS <- config::get("year_i"):config::get("year_j")
OUT_PATH <- here::here("data", "overdispersion_window.parquet")

## Negative-binomial. If underdispersed or undefined, use Poisson
calculate_theta <- function(mu, v) {
    theta <- mu^2 / (v - mu)
    dplyr::if_else(theta <= 0 | !is.finite(theta), THETA_POISSON, theta)
}

## Load data for years of interest ----
panel_w <- arrow::read_parquet(
    here::here("data", "panel_state_year.parquet")
) |>
    dplyr::mutate(state_fips = as.integer(state_fips)) |>
    dplyr::filter(year %in% ANALYSIS_YEARS)

fars_w <- arrow::read_parquet(
    here::here("data", sprintf("fars_persons_%i_%i.parquet",
        config::get("year_start"),
        config::get("year_end")))
) |>
    dplyr::mutate(
        state_fips = as.integer(state_fips),
        age_group = dplyr::if_else(is.na(age_group), "unknown", age_group)
    ) |>
    dplyr::filter(year %in% ANALYSIS_YEARS)

xwalk_df <- panel_w |>
    dplyr::distinct(state_fips, state_name, state_abb)

## Get dispersions ----

## Deaths, state and bin
th_statebin <- panel_w |>
    dplyr::select(state_fips,
        dplyr::all_of(return_all_bins())) |>
    tidyr::pivot_longer(dplyr::all_of(return_all_bins()),
        names_to = "bin",
        values_to = "count") |>
    dplyr::group_by(state_fips, bin) |>
    dplyr::summarise(mu = mean(count),
        var = stats::var(count),
        .groups = "drop") |>
    dplyr::mutate(level = "deaths_state_bin",
        theta = calculate_theta(mu, var))

## Deaths, state, age, and bin
fine <- fars_w |>
    dplyr::count(state_fips,
        age_group,
        bin,
        year,
        name = "count") |>
    tidyr::complete(
        tidyr::nesting(state_fips, age_group, bin),
        year = ANALYSIS_YEARS,
        fill = list(count = 0))

th_agebin <- fine |>
    dplyr::group_by(state_fips, age_group, bin) |>
    dplyr::summarise(mu = mean(count),
        var = stats::var(count),
        .groups = "drop") |>
    dplyr::filter(mu > 0) |>
    dplyr::mutate(level = "deaths_age_bin",
        theta = calculate_theta(mu, var))

## Deaths, state, age, and bin -- empirical Bayes
eb_wide <- fine |>
    dplyr::group_by(state_fips, age_group, bin) |>
    dplyr::mutate(mu = mean(count)) |>
    dplyr::ungroup() |>
    dplyr::filter(mu > 0) |>
    dplyr::select(state_fips, age_group, bin, year, count) |>
    tidyr::pivot_wider(names_from = year, values_from = count) |>
    dplyr::arrange(state_fips, age_group, bin)

eb_mat <- as.matrix(eb_wide[, as.character(ANALYSIS_YEARS)])
eb_dge <- edgeR::DGEList(counts = eb_mat)
eb_dge$samples$lib.size <- 1
eb_dge$samples$norm.factors <- 1
eb_dge <- edgeR::estimateDisp(eb_dge, design = matrix(1, ncol(eb_mat), 1))

th_agebin_eb <- eb_wide |>
    dplyr::select(state_fips, age_group, bin) |>
    dplyr::mutate(
        level = "deaths_age_bin_eb",
        theta = dplyr::if_else(
            eb_dge$tagwise.dispersion <= 0 |
                !is.finite(1 / eb_dge$tagwise.dispersion),
            THETA_POISSON,
            pmin(1 / eb_dge$tagwise.dispersion, THETA_POISSON)
        )
    )

## Deaths, state, age, bin, and road type (urban / rural only)
fine_rt <- fars_w |>
    dplyr::filter(road_type %in% c("urban", "rural")) |>
    dplyr::count(state_fips,
        age_group,
        bin,
        road_type,
        year,
        name = "count") |>
    tidyr::complete(
        tidyr::nesting(state_fips, age_group, bin, road_type),
        year = ANALYSIS_YEARS,
        fill = list(count = 0))

th_agebin_rt <- fine_rt |>
    dplyr::group_by(state_fips, age_group, bin, road_type) |>
    dplyr::summarise(mu = mean(count),
        var = stats::var(count),
        .groups = "drop") |>
    dplyr::filter(mu > 0) |>
    dplyr::mutate(level = "deaths_age_bin_roadtype",
        theta = calculate_theta(mu, var))

## Deaths, state, age, bin, and weather (good / adverse / unknown)
fine_weather <- fars_w |>
    dplyr::count(state_fips,
        age_group,
        bin,
        weather_cat,
        year,
        name = "count") |>
    tidyr::complete(
        tidyr::nesting(state_fips, age_group, bin, weather_cat),
        year = ANALYSIS_YEARS,
        fill = list(count = 0))

th_agebin_weather <- fine_weather |>
    dplyr::group_by(state_fips, age_group, bin, weather_cat) |>
    dplyr::summarise(mu = mean(count),
        var = stats::var(count),
        .groups = "drop") |>
    dplyr::filter(mu > 0) |>
    dplyr::mutate(level = "deaths_age_bin_weather",
        theta = calculate_theta(mu, var))

## VMT, state-level total / urban / rural
th_vmt <- panel_w |>
    dplyr::group_by(state_fips) |>
    dplyr::summarise(
        vmt_total = calculate_theta(mean(vm2_total),
            stats::var(vm2_total)),
        vmt_urban = calculate_theta(mean(vm2_urban),
            stats::var(vm2_urban)),
        vmt_rural = calculate_theta(mean(vm2_rural),
            stats::var(vm2_rural)),
        .groups = "drop"
    ) |>
    tidyr::pivot_longer(
        c(vmt_total, vmt_urban, vmt_rural),
        names_to = "level",
        values_to = "theta"
    )

## Combine ----
out_df <- dplyr::bind_rows(
    th_statebin |>
        dplyr::select(level, state_fips, bin, theta),
    th_agebin |>
        dplyr::select(level, state_fips, age_group, bin, theta),
    th_agebin_eb |>
        dplyr::select(level, state_fips, age_group, bin, theta),
    th_agebin_rt |>
        dplyr::select(level, state_fips, age_group, bin, road_type, theta),
    th_agebin_weather |>
        dplyr::select(level, state_fips, age_group, bin, weather_cat, theta),
    th_vmt |>
        dplyr::select(level, state_fips, theta)
) |>
    dplyr::left_join(xwalk_df, by = "state_fips")

## Save ----
fs::dir_create(dirname(OUT_PATH), recurse = TRUE)
arrow::write_parquet(out_df, OUT_PATH)
