## Imports ----
library(tidyverse)
library(arrow)
library(here)
library(ggsci)
library(geofacet)
source(here::here("code", "mk_nytimes.R"))
source(here::here("code", "utils.R"))

## Constants ----
FIG_NAME <- "03_figureS02_vmt"
FIG_WIDTH <- 12
FIG_HEIGHT <- 9
FIG_DPI <- 300
FIG_SCALE <- .8

## Read panel ----
vmt_df <- arrow::read_parquet(
    here::here("data", "fhwa_vm2_state_year_2018_2024.parquet")
)

plot_df <- dplyr::bind_rows(
    vmt_df,
    vmt_df |>
        dplyr::mutate(state_name = "United States") |>
        dplyr::summarise(
            dplyr::across(dplyr::where(is.numeric), sum),
            .by = c(year, state_name)
        )
)

plot_df <- plot_df |>
    tidyr::pivot_longer(cols = tidyr::starts_with("vmt_"),
        names_to = "road_type",
        values_to = "vmt") |>
    dplyr::mutate(road_cat = factor(road_type,
        levels = c("vmt_total",
            "vmt_urban",
            "vmt_rural"),
        labels = c("Total",
            "Urban",
            "Rural"),
        ordered = TRUE))

plot_df <- plot_df |>
    dplyr::left_join(state_info(), by = "state_name")

p1 <- ggplot2::ggplot(plot_df,
    ggplot2::aes(x = year,
        y = vmt,
        color = road_cat,
        group = road_cat)) +
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
    ggplot2::scale_y_continuous("Vehicle miles traveled (in billions)",
        labels = \(x) sprintf("%i", round(x / 1000))) +
    ggplot2::scale_x_continuous(NULL,
        breaks = seq(2018, 2024, 2),
        labels = c("'18", "'20", "'22", "'24"),
        expand = c(0, 1)) +
    ggsci::scale_color_aaas(name = "Road type") +
    mk_nytimes(panel.border = ggplot2::element_rect(color = "grey70"),
        legend.position = c(.95, .05),
        legend.justification = c(1, 0))

## Save ----
figure_save(
    p1,
    FIG_NAME,
    plot_df |>
        dplyr::select(state = state_name,
            year,
            road_cat,
            vmt_millions = vmt),
    scale = FIG_SCALE,
    width = FIG_WIDTH,
    height = FIG_HEIGHT,
    dpi = FIG_DPI
)
