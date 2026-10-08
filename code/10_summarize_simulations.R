## 10_summarize_simulations.R ----
##
## Summarize the primary simulation batches into percentile uncertainty
## intervals plus a two-sided empirical p-value and Benjamini-Hochberg
## adjusted q-value (state-level, per component).
##
## Inputs:
##   - temp_output/simulations/{main,partition,category_rates}/*.parquet
##   - code/utils.R
##   - config.yml
##
## Outputs:
##   - data/summaries/{main,partition,category_rates}_ci.parquet

## Imports ----
library(tidyverse)
library(here)
library(fs)
library(arrow)
library(duckdb)
source(here::here("code", "utils.R"))

## Config ----
TARGETS <- unlist(config::get("targets"))
GROUP_COLS <- c(
    "geography",
    "state_name",
    "state_abb",
    "state_fips",
    "year_a",
    "year_b",
    "component",
    "metric"
)

## Run ----
fs::dir_create(here::here("data", "summaries"), recurse = TRUE)
for (t in TARGETS) {
    summarize_dir(
        glob = here::here("temp_output", "simulations", t, "*.parquet"),
        group_cols = GROUP_COLS,
        out_path = here::here("data", "summaries", sprintf("%s_ci.parquet", t))
    )
}
