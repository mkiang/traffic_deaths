## 14_figureS04toS15_category_maps.R ----
##
## eFigures S04-S15: a Figure-1B-style state chorpleth for each piece of the
## decomposition.
##
## Inputs:
##   - data/decomposition_chained.parquet  (vmt_effect)
##   - data/partition_cumulative.parquet   (11 *_contrib columns)
##   - code/utils.R
##
## Outputs (eFigure S04 = ordinal 05, ... eFigure S15 = ordinal 16):
##   - plots/{05..16}_figureS{04..15}_{category}.{pdf,jpg} (12 maps)
##   - output/{05..16}_figureS{04..15}_{category}.csv (per-map state values)

## Imports ----
library(tidyverse)
library(here)
library(arrow)
library(patchwork)
library(usmap)
library(RColorBrewer)
source(here::here("code", "utils.R"))

## Constants ----
FIG_WIDTH <- 7
FIG_HEIGHT <- 5.5
FIG_DPI <- 300
N_BINS <- 11
TITLE_FAMILY <- "Arial Narrow"

SPECTRUM_RED_YELLOW_BLUE <- c(
    "#4A001E",
    "#751232",
    "#A52747",
    "#C65154",
    "#E47961",
    "#F0A882",
    "#FAD4AC",
    "#FFFFE0",
    "#BCE2CF",
    "#89C0C4",
    "#579EB9",
    "#397AA8",
    "#1C5796",
    "#163771",
    "#10194D"
)
DIVERGING_COLORS <- rev(
    grDevices::colorRampPalette(SPECTRUM_RED_YELLOW_BLUE)(N_BINS)
)

categories <- tibble::tribble(
    ~suffix,                 ~column,               ~title,
    "vmt_effect",            "vmt_effect",          "VMT-exposure contribution",
    "speed_only",            "speed_only_contrib",  "Speed-only contribution",
    "alcohol_only",          "alc_only_contrib",    "Alcohol-only contribution",
    "unrestrained_only",     "unr_only_contrib",    "Unrestrained-only contribution",
    "speed_alcohol",         "speed_alc_contrib",   "Speed and alcohol contribution",
    "speed_unrestrained",    "speed_unr_contrib",   "Speed and unrestrained contribution",
    "alcohol_unrestrained",  "alc_unr_contrib",     "Alcohol and unrestrained contribution",
    "all_three",             "all_three_contrib",   "All three flagged contribution",
    "none_flagged",          "none_contrib",        "No behavioral risk factor flagged contribution",
    "pedestrian",            "ped_contrib",         "Pedestrian contribution",
    "bicyclist",             "bike_contrib",        "Bicyclist contribution",
    "other_road_users",      "other_nonpv_contrib", "Other road user contribution"
)

## Read per-state point estimates ----
dec_df <- arrow::read_parquet(
    here::here("data", "decomposition_chained.parquet")
) |>
    dplyr::filter(scope == "cumulative_2021_2024", geography == "state") |>
    dplyr::select(state_name, state_abb, state_fips, vmt_effect)

part_df <- arrow::read_parquet(
    here::here("data", "partition_cumulative.parquet")
) |>
    dplyr::filter(scope == "cumulative_2021_2024", geography == "state") |>
    dplyr::select(
        state_fips,
        dplyr::all_of(categories$column[categories$column != "vmt_effect"])
    )

state_df <- dec_df |>
    dplyr::left_join(part_df, by = "state_fips") |>
    dplyr::mutate(fips = sprintf("%02d", state_fips))

## One category map (choropleth + inset histogram) ----
category_map <- function(values_col, title) {
    map_df <- state_df |>
        dplyr::transmute(fips, value = .data[[values_col]])

    lim <- max(abs(map_df$value), na.rm = TRUE) * 1.05
    breaks <- seq(-lim, lim, length.out = N_BINS + 1)

    p_map <- usmap::plot_usmap(
        data = map_df,
        values = "value",
        color = "black",
        linewidth = 0.25
    ) +
        ggplot2::scale_fill_stepsn(
            colors = DIVERGING_COLORS,
            breaks = breaks,
            limits = c(-lim, lim),
            na.value = "white",
            guide = "none"
        ) +
        ggplot2::labs(title = title) +
        ggplot2::theme(
            plot.title = ggplot2::element_text(
                family = TITLE_FAMILY,
                face = "bold",
                size = 13,
                hjust = 0.5,
                color = "grey25",
                margin = ggplot2::margin(b = 2)
            ),
            plot.margin = ggplot2::margin(t = 4, b = 0, l = 6, r = 6)
        )

    label_breaks <- pretty(c(-lim, lim), n = 4)
    label_breaks <- label_breaks[label_breaks >= -lim & label_breaks <= lim]

    p_hist <- ggplot2::ggplot(map_df, ggplot2::aes(x = value)) +
        ggplot2::geom_histogram(
            ggplot2::aes(fill = ggplot2::after_stat(factor(round(x, 6)))),
            breaks = breaks,
            color = "black",
            linewidth = 0.25
        ) +
        ggplot2::scale_fill_manual(
            values = DIVERGING_COLORS,
            guide = "none",
            drop = FALSE
        ) +
        ggplot2::scale_x_continuous(
            breaks = label_breaks,
            labels = \(x) sprintf("%g", x),
            expand = c(0, 0)
        ) +
        ggplot2::scale_y_continuous(
            expand = ggplot2::expansion(mult = c(0, 0.05))
        ) +
        ggplot2::coord_cartesian(xlim = c(-lim, lim)) +
        ggplot2::labs(x = "Deaths per 100,000") +
        ggplot2::theme_void(base_family = TITLE_FAMILY) +
        ggplot2::theme(
            axis.text.x = ggplot2::element_text(
                size = ggplot2::rel(0.75),
                color = "grey25",
                margin = ggplot2::margin(t = 1)
            ),
            axis.title.x = ggplot2::element_text(
                size = ggplot2::rel(0.85),
                color = "grey25",
                margin = ggplot2::margin(t = 2)
            ),
            axis.ticks.x = ggplot2::element_line(
                color = "grey50",
                linewidth = 0.2
            ),
            axis.ticks.length.x = grid::unit(1.5, "pt"),
            axis.line.x = ggplot2::element_line(
                color = "grey50",
                linewidth = 0.25
            ),
            plot.margin = ggplot2::margin(t = 0, b = 1, l = 0, r = 0)
        )

    p_map +
        patchwork::inset_element(
            p_hist,
            left = 0.62, bottom = 0.04, right = 0.87, top = 0.20,
            align_to = "panel"
        )
}

## Build + export each map ----
for (i in seq_len(nrow(categories))) {
    cat_i <- categories[i, ]

    fig_name <- sprintf("%02d_figureS%02d_%s", i + 4, i + 3, cat_i$suffix)

    p <- category_map(cat_i$column, cat_i$title)

    fig_data <- state_df |>
        dplyr::transmute(
            state_name,
            state_abb,
            state_fips,
            category = cat_i$suffix,
            contribution = .data[[cat_i$column]]
        )

    figure_save(
        p,
        fig_name,
        fig_data,
        width = FIG_WIDTH,
        height = FIG_HEIGHT,
        dpi = FIG_DPI
    )
}
