## 05_create_analytic_df.R ----
##
## Build the state-year analytic table by joining FARS deaths (aggregated
## to state-year 11-bin counts), FHWA VM-2 vehicle miles traveled, NCHS
## population totals, and CDC WONDER mortality (for the FARS-vs-WONDER
## comparison).
##
## Inputs:
##   - data/fars_persons_2018_2024.parquet
##   - data/fhwa_vm2_state_year_2018_2024.parquet
##   - data/nchs_pop_state_age_2018_2024.parquet
##   - data/wonder_mortality_state_year_1999_2024.parquet
##   - code/utils.R, config.yml
##
## Outputs:
##   - data/panel_state_year.parquet

## Imports ----
library(tidyverse)
library(here)
source(here::here("code", "utils.R"))

## Constants ----
YEARS <- config::get("year_start"):config::get("year_end")
OUT_PATH <- here::here("data", "panel_state_year.parquet")
RATE_PER <- config::get("rate_per")
VMT_SCALE <- config::get("vmt_scale")

## Read all ingested data ----

## FARS person-level fatalities
fars_persons <- arrow::read_parquet(
    here::here("data", sprintf("fars_persons_%i_%i.parquet",
                               config::get("year_start"),
                               config::get("year_end")))
)

## VM-2 state-year VMT
vm2 <- arrow::read_parquet(
    here::here("data", sprintf("fhwa_vm2_state_year_%i_%i.parquet",
                               config::get("year_start"),
                               config::get("year_end")))
) |>
    dplyr::rename(
        vm2_total = vmt_total,
        vm2_rural = vmt_rural,
        vm2_urban = vmt_urban
    )

## NCHS population by state-age-year
nchs_pop <- arrow::read_parquet(
    here::here("data", sprintf("nchs_pop_state_age_%i_%i.parquet",
                               config::get("year_start"),
                               config::get("year_end")))
)

## WONDER state-year mortality
wonder_year <- arrow::read_parquet(
    here::here("data", "wonder_mortality_state_year_1999_2024.parquet")
) |>
    dplyr::filter(
        year %in% YEARS,
        state_name != "United States"
    ) |>
    dplyr::select(
        state_name,
        year,
        wonder_deaths = deaths,
        wonder_asmr = asmr
    )

## Build state-year dataframe ----

## Aggregate FARS deaths to state-year totals + 11-bin counts
fars_state_year <- fars_persons |>
    dplyr::group_by(state_name, state_abb, state_fips, year) |>
    dplyr::summarise(
        fars_deaths = dplyr::n(),
        fars_pv_deaths = sum(per_typ %in% c(1L, 2L) & body_typ <= 49L),
        fars_self_driven_deaths = sum(
            bin %in% return_self_driven(), na.rm = TRUE
        ),
        n_speed = sum(crash_speed_flag),
        n_alc = sum(crash_alc_flag),
        n_unr = sum(unr_flag),
        speeding_only = sum(bin == "speeding_only", na.rm = TRUE),
        alcohol_only = sum(bin == "alcohol_only", na.rm = TRUE),
        unrestrained_only = sum(bin == "unrestrained_only", na.rm = TRUE),
        speed_alc = sum(bin == "speed_alc", na.rm = TRUE),
        speed_unr = sum(bin == "speed_unr", na.rm = TRUE),
        alc_unr = sum(bin == "alc_unr", na.rm = TRUE),
        all_three = sum(bin == "all_three", na.rm = TRUE),
        none_flagged = sum(bin == "none_flagged", na.rm = TRUE),
        pedestrian = sum(bin == "pedestrian", na.rm = TRUE),
        bicyclist = sum(bin == "bicyclist", na.rm = TRUE),
        other_nonpv = sum(bin == "other_nonpv", na.rm = TRUE),
        .groups = "drop"
    )

## Aggreate NCHS population to state-year (sum over age groups)
pop_state_year <- nchs_pop |>
    dplyr::group_by(state_name, state_fips, year) |>
    dplyr::summarise(
        population = sum(population),
        .groups = "drop"
    ) |>
    dplyr::mutate(state_fips = as.integer(state_fips))

## Join FARS aggregates with population, VM-2, and WONDER
state_year <- fars_state_year |>
    dplyr::mutate(state_fips = as.integer(state_fips)) |>
    dplyr::left_join(
        pop_state_year |> dplyr::select(-state_name),
        by = c("state_fips", "year")
    ) |>
    dplyr::left_join(vm2, by = c("state_name", "year")) |>
    dplyr::left_join(wonder_year, by = c("state_name", "year")) |>
    ## Derived rates
    dplyr::mutate(
        crude_rate_fars = RATE_PER * fars_deaths / population,
        crude_rate_wonder = RATE_PER * wonder_deaths / population,
        per_mile_risk_fars = fars_deaths / (vm2_total * VMT_SCALE),
        vmt_per_capita = (vm2_total * VMT_SCALE) / population
    ) |>
    dplyr::select(
        year,
        state_name,
        state_abb,
        state_fips,
        fars_deaths,
        fars_pv_deaths,
        fars_self_driven_deaths,
        speeding_only,
        alcohol_only,
        unrestrained_only,
        speed_alc,
        speed_unr,
        alc_unr,
        all_three,
        none_flagged,
        pedestrian,
        bicyclist,
        other_nonpv,
        n_speed,
        n_alc,
        n_unr,
        wonder_deaths,
        wonder_asmr,
        population,
        vm2_total,
        vm2_rural,
        vm2_urban,
        rural_int,
        rural_ofe,
        rural_opa,
        rural_mar,
        rural_majc,
        rural_mic,
        rural_local,
        urban_int,
        urban_ofe,
        urban_opa,
        urban_mar,
        urban_majc,
        urban_mic,
        urban_local,
        crude_rate_fars,
        crude_rate_wonder,
        per_mile_risk_fars,
        vmt_per_capita
    ) |>
    dplyr::arrange(state_name, year)

## Save ----
arrow::write_parquet(state_year, OUT_PATH)
