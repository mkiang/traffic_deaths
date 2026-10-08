## 02_ingest_vmt.R ----
##
## Read FHWA Highway Statistics Table VM-2 files and produce a state-year
## panel of vehicle miles traveled (VMT). VM-2 sheet "A" reports VMT for
## 7 funcitonal classes (interstate through local) crossed with
## urban/rural. We keep the class-level columns plus rural, urban, and
## total VMT.
##
## Downloads missing files from FHWA if they don't exist on disk.
##
## Inputs:
##   - data_raw/fhwa_vm2/vm2_{year}.{xls,xlsx}
##
## Outputs:
##   - data/fhwa_vm2_state_year_2018_2024.parquet

## Imports ----
library(tidyverse)
library(here)
library(readxl)
library(fs)

## Constants ----
YEARS <- config::get("year_start"):config::get("year_end")
RAW_DIR <- here::here("data_raw", "fhwa_vm2")
OUT_PATH <- here::here(
    "data",
    sprintf("fhwa_vm2_state_year_%i_%i.parquet", min(YEARS), max(YEARS))
)

US_STATES <- c(datasets::state.name, "District of Columbia")

## Download missing VM-2 files ----
## FHWA switched VM-2 from .xls to .xlsx, so try .xlsx first, then .xls.
fs::dir_create(RAW_DIR, recurse = TRUE)
for (y in YEARS) {
    p_xlsx <- here::here(RAW_DIR, sprintf("vm2_%d.xlsx", y))
    p_xls <- here::here(RAW_DIR, sprintf("vm2_%d.xls", y))

    if (fs::file_exists(p_xlsx) || fs::file_exists(p_xls)) {
        next
    }

    ## got tracks whether a file downloaded for this year
    url_base <- "https://www.fhwa.dot.gov/policyinformation/statistics"
    got <- FALSE

    for (ext in c("xlsx", "xls")) {
        url <- sprintf("%s/%d/xls/vm2.%s", url_base, y, ext)
        dest <- here::here(RAW_DIR, sprintf("vm2_%d.%s", y, ext))

        ## ok is TRUE only if the download succeeded
        ok <- tryCatch(
            {
                utils::download.file(url, dest, mode = "wb", quiet = TRUE)
                fs::file_exists(dest)
            },
            error = \(e) FALSE
        )

        if (ok) {
            got <- TRUE
            break
        } else if (fs::file_exists(dest)) {
            fs::file_delete(dest)
        }
    }

    if (!got) {
        stop(sprintf("Failed to download VM-2 for %d", y), call. = FALSE)
    }
}

## Read one year ----
read_vm2 <- function(y) {
    p_xlsx <- here::here(RAW_DIR, sprintf("vm2_%d.xlsx", y))
    p_xls <- here::here(RAW_DIR, sprintf("vm2_%d.xls", y))
    p <- if (fs::file_exists(p_xlsx)) p_xlsx else p_xls

    if (!fs::file_exists(p)) {
        stop("Missing VM-2 file for ", y)
    }

    df <- readxl::read_excel(
        p,
        sheet = "A",
        col_names = FALSE,
        skip = 8,
        .name_repair = "minimal"
    )

    df <- df[, 1:18]

    names(df) <- c(
        "state_name",
        "rural_int",
        "rural_ofe",
        "rural_opa",
        "rural_mar",
        "rural_majc",
        "rural_mic",
        "rural_local",
        "vmt_rural",
        "urban_int",
        "urban_ofe",
        "urban_opa",
        "urban_mar",
        "urban_majc",
        "urban_mic",
        "urban_local",
        "vmt_urban",
        "vmt_total"
    )

    df |>
        ## Strip footnote markers
        dplyr::mutate(
            state_name = stringr::str_squish(
                stringr::str_remove(state_name, "\\s*\\([0-9]+\\)\\s*$")
            )
        ) |>
        ## Keep 50 states + DC
        dplyr::filter(state_name %in% US_STATES) |>
        ## Tag year and coerce VMT columns to numeric
        dplyr::mutate(year = y) |>
        dplyr::mutate(
            dplyr::across(
                -c(state_name, year),
                \(x) suppressWarnings(as.numeric(x))
            )
        ) |>
        dplyr::select(
            state_name,
            year,
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
            vmt_rural,
            vmt_urban,
            vmt_total
        )
}

## Run all years ----
panel_df <- purrr::map_dfr(YEARS, read_vm2)

## Save ----
arrow::write_parquet(panel_df, OUT_PATH)
