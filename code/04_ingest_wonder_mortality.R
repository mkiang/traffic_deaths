## 04_ingest_wonder_mortality.R ----
##
## Ingest CDC WONDER motor vehicle traffic mortality by state-year for
## 1999-2024, combining Bridged-Race exports (1999-2020) with Single-Race
## exports (2021-2024). We do not stratify by race, so the two series
## combine cleanly. These counts provide a comparison against FARS.
## Because the ICD-10 and FARS defintions of a traffic fatality
## differ, the two are not expected to match.
##
## Inputs:
##   - data_raw/Multiple Cause of Death*.{csv,txt}
##   - code/utils.R
##
## Outputs:
##   - data/wonder_mortality_state_year_1999_2024.parquet

## Imports ----
library(tidyverse)
library(here)
source(here::here("code", "utils.R"))

## Constants ----
RAW_DIR <- here::here("data_raw")
OUT_PATH <- here::here("data", "wonder_mortality_state_year_1999_2024.parquet")

NAT_COLS <- c(
    "notes",
    "cause",
    "cause_code",
    "year",
    "year_code",
    "deaths",
    "population",
    "crude_rate",
    "crude_lower",
    "crude_upper",
    "crude_se",
    "asmr",
    "asmr_lower",
    "asmr_upper",
    "asmr_se"
)

STATE_COLS <- c(
    "notes",
    "cause",
    "cause_code",
    "state_name",
    "state_fips",
    "year",
    "year_code",
    "deaths",
    "population",
    "crude_rate",
    "crude_lower",
    "crude_upper",
    "crude_se",
    "asmr",
    "asmr_lower",
    "asmr_upper",
    "asmr_se"
)

## Read one WONDER export ----
read_wonder <- function(path, delim, col_names) {
    raw <- readr::read_delim(
        path,
        delim = delim,
        skip = 1,
        col_names = col_names,
        col_types = readr::cols(.default = readr::col_character()),
        na = c(
            "", "NA", "Suppressed", "Missing", "Unreliable", "Not Applicable"
        )
    )
    raw |>
        dplyr::filter(!is.na(year), !is.na(as.integer(year))) |>
        dplyr::mutate(
            year = as.integer(year),
            dplyr::across(
                dplyr::any_of(c(
                    "deaths", "population",
                    "crude_rate", "crude_lower", "crude_upper", "crude_se",
                    "asmr", "asmr_lower", "asmr_upper", "asmr_se"
                )),
                as.numeric
            )
        ) |>
        dplyr::select(-dplyr::any_of(c(
            "notes", "cause", "cause_code", "year_code"
        )))
}

## Ingest WONDER exports ----
##
## Four files were downloaded manually (see data_raw/README.md). National
## and state exports are each split at 2020 into 1999-2020 and 2020-2024
## vintages, and the files use inconsistent delimiters (tab vs comma).

## National, 1999-2020
nat_bridged <- read_wonder(
    here::here(RAW_DIR, "Multiple Cause of Death, 1999-2020.csv"),
    delim = "\t",
    col_names = NAT_COLS
) |>
    ## Add state columns so we can bind later
    dplyr::mutate(
        state_name = "United States",
        state_fips = "99",
        .before = year
    )

## National, 2021-2024
nat_singlerace <- read_wonder(
    here::here(RAW_DIR, "Multiple Cause of Death, 2018-2024, Single Race.csv"),
    delim = ",",
    col_names = NAT_COLS
) |>
    dplyr::mutate(
        state_name = "United States",
        state_fips = "99",
        .before = year
    ) |>
    dplyr::filter(year >= 2021)

## State, 1999-2020
state_bridged <- read_wonder(
    here::here(RAW_DIR, "Multiple Cause of Death, 1999-2020 By state.csv"),
    delim = ",",
    col_names = STATE_COLS
)

## State, 2021-2024
state_singlerace <- read_wonder(
    here::here(
        RAW_DIR,
        "Multiple Cause of Death, 2018-2024, Single Race By State.txt"
    ),
    delim = "\t",
    col_names = STATE_COLS
) |>
    dplyr::filter(year >= 2021)

## Combine and tidy ----
annual_df <- dplyr::bind_rows(
    nat_bridged,
    nat_singlerace,
    state_bridged,
    state_singlerace
) |>
    dplyr::left_join(state_info(), by = "state_name") |>
    dplyr::relocate(state_name, state_fips, state_abb, year) |>
    dplyr::arrange(state_fips, year)

## Save ----
arrow::write_parquet(annual_df, OUT_PATH)
