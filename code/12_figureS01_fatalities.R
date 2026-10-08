## Imports ----
library(tidyverse)
library(arrow)
library(here)
library(ggsci)
library(geofacet)
source(here::here("code", "mk_nytimes.R"))
source(here::here("code", "utils.R"))

## Constants ----
FIG_NAME <- "02_figureS01_traffic_fatalities"
FIG_WIDTH <- 12
FIG_HEIGHT <- 9
FIG_DPI <- 300
FIG_SCALE <- .85

## Read panel ----
panel_df <- arrow::read_parquet(here::here("data", "panel_state_year.parquet"))

plot_df <- panel_df |>
    dplyr::select(year,
        state_name,
        state_abb,
        wonder_asmr,
        crude_rate_wonder,
        crude_rate_fars) |>
    tidyr::pivot_longer(
        cols = wonder_asmr:crude_rate_fars,
        names_to = "rate_type",
        values_to = "rate"
    ) |>
    dplyr::mutate(
        rate_cat = factor(rate_type,
            levels = c("crude_rate_fars",
                "crude_rate_wonder",
                "wonder_asmr"),
            labels = c("Crude rate FARS (primary)",
                "Crude rate CDC WONDER",
                "Age-adjusted CDC WONDER"),
            ordered = TRUE)
    )

p1 <- ggplot2::ggplot(plot_df,
    ggplot2::aes(x = year,
        y = rate,
        color = rate_cat,
        group = rate_cat)) +
    ggplot2::annotate("rect",
        xmin = 2020.5,
        xmax = 2024.5,
        ymin = -Inf,
        ymax = Inf,
        color = NA,
        fill = "grey60",
        alpha = .25) +
    ggplot2::geom_point(size = .75,
        alpha = .8) +
    ggplot2::geom_line(alpha = .8) +
    geofacet::facet_geo(~ state_abb) +
    ggplot2::scale_y_continuous("Mortality rate (per 100,000)") +
    ggplot2::scale_x_continuous(NULL,
        breaks = seq(2018, 2024, 2),
        labels = c("'18", "'20", "'22", "'24"),
        expand = c(0, 1)) +
    ggsci::scale_color_npg(name = "Mortality rate type/source") +
    mk_nytimes(panel.border = ggplot2::element_rect(color = "grey70"),
        legend.position = c(1, .135),
        legend.justification = c(1, 0))

## Save ----
figure_save(
    p1,
    FIG_NAME,
    plot_df |>
        dplyr::select(state = state_name,
            year,
            rate_cat,
            rate_100k = rate),
    scale = FIG_SCALE,
    width = FIG_WIDTH,
    height = FIG_HEIGHT,
    dpi = FIG_DPI
)
