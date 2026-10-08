## 03_ingest_population_data.R ----
##
## Ingest CDC WONDER Single-Race Population Estimates for 2018-2024 and
## build a tidy state-age-year table of population denominators, one row
## per state, five-year age group (18 bins), and year. Two WONDER
## vintages are stiched together (2010-2020 and 2020-2024).
##
## Inputs:
##   - data_raw/Single-Race Population Estimates 2010-2020 by State and Single-Year Age.tsv
##   - data_raw/Single-Race Population Estimates 2020-2024 by State and Single-Year Age.tsv
##
## Outputs:
##   - data/nchs_pop_state_age_2018_2024.parquet

## Imports ----
library(tidyverse)
library(here)

## Constants ----
YEARS <- config::get("year_start"):config::get("year_end")

PATH_OLD <- here::here(
    "data_raw",
    "Single-Race Population Estimates 2010-2020 by State and Single-Year Age.tsv"
)
PATH_NEW <- here::here(
    "data_raw",
    "Single-Race Population Estimates 2020-2024 by State and Single-Year Age.tsv"
)
OUT_PATH <- here::here(
    "data",
    sprintf("nchs_pop_state_age_%i_%i.parquet", min(YEARS), max(YEARS))
)

## Read one WONDER export ----
read_wonder_pop <- function(path) {
    raw <- readr::read_tsv(
        path,
        show_col_types = FALSE,
        col_types = readr::cols(.default = readr::col_character()),
        na = c("", "NA", "Not Applicable")
    )

    raw |>
        ## Rename columns
        dplyr::rename(
            year = `Yearly July 1st Estimates`,
            state_name = States,
            state_fips = `States Code`,
            age_label = `Five-Year Age Groups`,
            population = Population
        ) |>
        ## Drop metadata footer rows
        dplyr::filter(
            !is.na(year),
            !is.na(as.integer(year))
        ) |>
        ## Recast types
        dplyr::transmute(
            year = as.integer(year),
            state_name = state_name,
            state_fips = state_fips,
            age_label = age_label,
            population = as.numeric(population)
        )
}

## Ingest both WONDER vintages ----
pop_old <- read_wonder_pop(PATH_OLD)
pop_new <- read_wonder_pop(PATH_NEW)

## Combine vintages ----
## Overlapping year 2020 comes from the newer 2020-2024 vintage.
combined <- dplyr::bind_rows(
    pop_old |> dplyr::filter(year < 2020),
    pop_new
)

## Restrict to 2018-2024 and US states ----
panel_df <- combined |>
    dplyr::filter(
        year %in% YEARS,
        !state_name %in% c("Puerto Rico", "Virgin Islands")
    ) |>
    ## Map WONDER 19-group labels to NCHS 18-group standard
    dplyr::mutate(
        age_label = stringr::str_squish(age_label),
        state_fips = as.integer(state_fips),
        age_group = dplyr::case_when(
            age_label %in% c("< 1 year", "1-4 years") ~ "0-4",
            age_label == "5-9 years" ~ "5-9",
            age_label == "10-14 years" ~ "10-14",
            age_label == "15-19 years" ~ "15-19",
            age_label == "20-24 years" ~ "20-24",
            age_label == "25-29 years" ~ "25-29",
            age_label == "30-34 years" ~ "30-34",
            age_label == "35-39 years" ~ "35-39",
            age_label == "40-44 years" ~ "40-44",
            age_label == "45-49 years" ~ "45-49",
            age_label == "50-54 years" ~ "50-54",
            age_label == "55-59 years" ~ "55-59",
            age_label == "60-64 years" ~ "60-64",
            age_label == "65-69 years" ~ "65-69",
            age_label == "70-74 years" ~ "70-74",
            age_label == "75-79 years" ~ "75-79",
            age_label == "80-84 years" ~ "80-84",
            age_label == "85+ years" ~ "85+",
            TRUE ~ NA_character_
        )
    )

## Collapse "< 1 year" and "1-4 years" into "0-4" ----
panel_df <- panel_df |>
    dplyr::group_by(year, state_fips, state_name, age_group) |>
    dplyr::summarise(
        population = sum(population, na.rm = TRUE),
        .groups = "drop"
    ) |>
    dplyr::filter(!is.na(age_group)) |>
    dplyr::arrange(state_name, year, age_group)

## Save ----
arrow::write_parquet(panel_df, OUT_PATH)
