## 51_supp_sensitivity_vmtnoise_worst_summarize.R ----
##
## Summarize the VMT lognormal-noise sensitivity sims into percentile UIs +
## empirical p / BH q-values, via summarize_dir() in utils.R.
##
## Inputs:
##   - temp_output/sensitivities/vmtnoise_worst/{main,partition}/*.parquet
##   - code/utils.R
##   - config.yml
##
## Outputs:
##   - data/summaries/{main,partition}_ci_vmtnoise_worst.parquet

## Imports ----
library(tidyverse)
library(here)
library(fs)
library(arrow)
library(duckdb)
source(here::here("code", "utils.R"))

## Config ----
OUT_SLUG <- "vmtnoise_worst"
## Sensitivities cover only the main decomposition and its partition.
## category_rates is a primary-analysis-only target (script 09 / eTable 1).
TARGETS <- c("main", "partition")
GROUP_COLS <- c("geography",
    "state_name",
    "state_abb",
    "state_fips",
    "year_a",
    "year_b",
    "component")

## Run ----
fs::dir_create(here::here("data", "summaries"), recurse = TRUE)
for (t in TARGETS) {
    summarize_dir(
        glob = here::here(
            "temp_output", "sensitivities", OUT_SLUG, t, "*.parquet"
        ),
        group_cols = GROUP_COLS,
        out_path = here::here(
            "data", "summaries", sprintf("%s_ci_%s.parquet", t, OUT_SLUG)
        )
    )
}
