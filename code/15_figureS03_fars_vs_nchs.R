## 15_figureS03_fars_vs_nchs.R ----
##
## eFigure S03: state-level agreement between FARS and NCHS (CDC WONDER)
## motor-vehicle death counts, 2021-2024, faceted by year.
##
## Inputs:
##   - data/panel_state_year.parquet  (fars_deaths, wonder_deaths)
##   - code/utils.R, code/mk_nytimes.R
##
## Outputs:
##   - plots/04_figureS03_fars_vs_nchs.{pdf,jpg}
##   - output/04_figureS03_fars_vs_nchs.csv

## Imports ----
library(tidyverse)
library(here)
library(arrow)
source(here::here("code", "mk_nytimes.R"))
source(here::here("code", "utils.R"))

## Constants ----
FIG_NAME <- "04_figureS03_fars_vs_nchs"
FIG_WIDTH <- 8
FIG_HEIGHT <- 8
FIG_DPI <- 300
ANALYSIS_YEARS <- 2021:2024

## Read FARS + NCHS state-year death counts ----
scatter_df <- arrow::read_parquet(
    here::here("data", "panel_state_year.parquet")
) |>
    dplyr::filter(year %in% ANALYSIS_YEARS) |>
    dplyr::select(state_abb, year, fars_deaths, wonder_deaths)

## Per-year Pearson r (log10 counts) for facet strip labels ----
year_labels <- scatter_df |>
    dplyr::group_by(year) |>
    dplyr::summarise(
        r = stats::cor(log10(fars_deaths), log10(wonder_deaths)),
        .groups = "drop"
    ) |>
    dplyr::mutate(year_label = sprintf("%d (r = %.3f)", year, r))

plot_df <- scatter_df |>
    dplyr::left_join(year_labels, by = "year") |>
    dplyr::mutate(year_label = forcats::fct_reorder(year_label, year))

## Plot ----
p_main <- ggplot2::ggplot(
    plot_df,
    ggplot2::aes(x = wonder_deaths, y = fars_deaths)
) +
    ggplot2::geom_abline(slope = 1, intercept = 0,
        linetype = "dashed", color = "grey50") +
    ggplot2::geom_point(alpha = 0.7, size = 1.6, color = "#1C5796") +
    ggplot2::scale_x_log10() +
    ggplot2::scale_y_log10() +
    ggplot2::coord_fixed(ratio = 1) +
    ggplot2::facet_wrap(ggplot2::vars(year_label)) +
    ggplot2::labs(
        x = "NCHS (CDC WONDER) motor vehicle deaths",
        y = "FARS motor vehicle deaths"
    ) +
    mk_nytimes(legend.position = "none")

## Save ----
fig_data <- scatter_df |>
    dplyr::arrange(year, state_abb)

figure_save(
    p_main,
    FIG_NAME,
    fig_data,
    width = FIG_WIDTH,
    height = FIG_HEIGHT,
    dpi = FIG_DPI
)
