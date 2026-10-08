## 11_figure1_geographic.R ----
##
## Figure 1: state-level decomposition map (total mortality-rate change +
## behavioral-risk-factor contribution), each panel with an inset histgram.
##
## Inputs:
##   - data/decomposition_chained.parquet
##   - data/partition_cumulative.parquet
##   - temp_output/simulations/main/*.parquet
##   - temp_output/simulations/partition/*.parquet
##   - code/utils.R
##
## Outputs:
##   - plots/01_figure1_geographic.{pdf,jpg}
##   - output/01_figure1_geographic.csv

## Imports ----
library(tidyverse)
library(here)
library(arrow)
library(patchwork)
library(usmap)
library(RColorBrewer)
library(duckdb)
source(here::here("code", "utils.R"))

## Constants ----
FIG_NAME <- "01_figure1_geographic"
FIG_WIDTH <- 7
FIG_HEIGHT <- 10.5
FIG_DPI <- 1200
FIG_SCALE <- 1
N_BINS <- 11
MASK_NONSIG <- FALSE

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

## Read decomposition data ----
dec_df <- arrow::read_parquet(
    here::here("data", "decomposition_chained.parquet")
) |>
    dplyr::filter(scope == "cumulative_2021_2024",
        geography == "state") |>
    dplyr::select(
        state_name,
        state_abb,
        state_fips,
        delta_rate,
        vmt_effect,
        risk_effect
    )

part_df <- arrow::read_parquet(
    here::here("data", "partition_cumulative.parquet")
) |>
    dplyr::filter(scope == "cumulative_2021_2024",
        geography == "state") |>
    dplyr::select(
        state_name,
        state_abb,
        state_fips,
        speed_only_contrib,
        alc_only_contrib,
        unr_only_contrib,
        speed_alc_contrib,
        speed_unr_contrib,
        alc_unr_contrib,
        all_three_contrib,
        none_contrib,
        ped_contrib,
        bike_contrib,
        other_nonpv_contrib
    )

decomp_df <- dec_df |>
    dplyr::left_join(
        part_df,
        by = c("state_name", "state_abb", "state_fips")
    ) |>
    dplyr::mutate(
        driving_bins = speed_only_contrib + alc_only_contrib +
            unr_only_contrib + speed_alc_contrib + speed_unr_contrib +
            alc_unr_contrib + all_three_contrib,
        fips = sprintf("%02d", state_fips)
    )

## Per-state UIs + BH-FDR q-values from primary sims ----
per_state_ci <- function() {
    sim_dir <- here::here("temp_output", "simulations")
    con <- duckdb::dbConnect(duckdb::duckdb(), read_only = TRUE)
    on.exit(duckdb::dbDisconnect(con, shutdown = TRUE), add = TRUE)

    ## Total delta_rate
    main_sims <- dplyr::tbl(
        con,
        sprintf(
            "read_parquet('%s')",
            here::here(sim_dir, "main", "*.parquet")
        )
    )
    ci_main <- main_sims |>
        dplyr::filter(geography == "state", component == "delta_rate") |>
        dplyr::group_by(state_abb) |>
        dplyr::summarise(
            mean_total = mean(value),
            sd_total = stats::sd(value),
            n = dplyr::n(),
            n_le0 = sum(as.integer(value <= 0)),
            n_ge0 = sum(as.integer(value >= 0)),
            delta_rate_p025 = stats::quantile(value, 0.025),
            delta_rate_p975 = stats::quantile(value, 0.975),
            .groups = "drop"
        ) |>
        dplyr::collect() |>
        dplyr::mutate(
            pval_total = pmin(
                1,
                2 * pmin((n_le0 + 1) / (n + 1), (n_ge0 + 1) / (n + 1))
            ),
            qval_total = stats::p.adjust(pval_total, method = "BH")
        )

    ## Behavioral-bin sum
    part_sims <- dplyr::tbl(
        con,
        sprintf(
            "read_parquet('%s')",
            here::here(sim_dir, "partition", "*.parquet")
        )
    )
    ci_part <- part_sims |>
        dplyr::filter(geography == "state") |>
        dplyr::collect() |>
        tidyr::pivot_wider(names_from = component, values_from = value) |>
        dplyr::mutate(
            behavioral_sum = speed_only_contrib + alc_only_contrib +
                unr_only_contrib + speed_alc_contrib + speed_unr_contrib +
                alc_unr_contrib + all_three_contrib
        ) |>
        dplyr::group_by(state_abb) |>
        dplyr::summarise(
            mean_behavioral = mean(behavioral_sum),
            sd_behavioral = stats::sd(behavioral_sum),
            n = dplyr::n(),
            n_le0 = sum(behavioral_sum <= 0),
            n_ge0 = sum(behavioral_sum >= 0),
            behavioral_p025 = stats::quantile(behavioral_sum, 0.025),
            behavioral_p975 = stats::quantile(behavioral_sum, 0.975),
            .groups = "drop"
        ) |>
        dplyr::mutate(
            pval_behavioral = pmin(
                1,
                2 * pmin((n_le0 + 1) / (n + 1), (n_ge0 + 1) / (n + 1))
            ),
            qval_behavioral = stats::p.adjust(pval_behavioral, method = "BH")
        )

    list(main = ci_main, part = ci_part)
}

ci_ls <- per_state_ci()

decomp_df <- decomp_df |>
    dplyr::left_join(ci_ls$main, by = "state_abb") |>
    dplyr::left_join(ci_ls$part, by = "state_abb") |>
    dplyr::mutate(
        sig_total = qval_total < 0.05,
        sig_behavioral = qval_behavioral < 0.05
    )

## Build panels ----
make_panel <- function(values_col, title, colors, sig_col) {
    map_df <- decomp_df |>
        dplyr::transmute(
            fips,
            value_raw = .data[[values_col]],
            is_sig = .data[[sig_col]]
        ) |>
        dplyr::mutate(
            value = if (MASK_NONSIG) {
                dplyr::if_else(is_sig, value_raw, NA_real_)
            } else {
                value_raw
            }
        )
    max_abs <- max(abs(map_df$value_raw), na.rm = TRUE)
    lim <- ceiling(max_abs * 4) / 4
    breaks <- seq(-lim, lim, length.out = N_BINS + 1)

    p_map <- usmap::plot_usmap(
        data = map_df |> dplyr::select(fips, value),
        values = "value",
        color = "black",
        linewidth = 0.25
    ) +
        ggplot2::scale_fill_stepsn(
            colors = colors,
            breaks = breaks,
            limits = c(-lim, lim),
            na.value = "white",
            guide = "none"
        ) +
        ggplot2::labs(title = title) +
        ggplot2::theme(
            plot.title = ggplot2::element_text(
                face = "bold",
                size = 11,
                hjust = 0.5,
                color = "grey25",
                margin = ggplot2::margin(b = 2)
            ),
            plot.margin = ggplot2::margin(t = 4, b = 0, l = 6, r = 6)
        )

    label_breaks <- pretty(c(-lim, lim), n = 4)
    label_breaks <- label_breaks[label_breaks >= -lim & label_breaks <= lim]

    hist_df <- if (MASK_NONSIG) {
        map_df |> dplyr::filter(is_sig)
    } else {
        map_df
    }
    p_hist <- ggplot2::ggplot(
        hist_df,
        ggplot2::aes(x = value)
    ) +
        ggplot2::geom_histogram(
            ggplot2::aes(fill = ggplot2::after_stat(factor(round(x, 6)))),
            breaks = breaks,
            color = "black",
            linewidth = 0.25
        ) +
        ggplot2::scale_fill_manual(
            values = colors,
            guide = "none",
            drop = FALSE
        ) +
        ggplot2::scale_x_continuous(
            breaks = label_breaks,
            labels = \(x) sprintf("%g", x),
            limits = c(-lim, lim),
            expand = c(0, 0)
        ) +
        ggplot2::scale_y_continuous(
            expand = ggplot2::expansion(mult = c(0, 0.05))
        ) +
        ggplot2::labs(x = "Deaths per 100,000") +
        ggplot2::theme_void() +
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
            left = 0.62,
            bottom = 0.04,
            right = 0.87,
            top = 0.20,
            align_to = "panel"
        )
}

cols_total <- rev(RColorBrewer::brewer.pal(N_BINS, "Spectral"))
cols_driving <- rev(
    grDevices::colorRampPalette(SPECTRUM_RED_YELLOW_BLUE)(N_BINS)
)

panel_total <- make_panel(
    "delta_rate",
    "Change in vehicle mortality rate from 2021 to 2024",
    cols_total,
    "sig_total"
)
panel_driving <- make_panel(
    "driving_bins",
    "Contribution of behavioral risk factors to change in vehicle mortality rate",
    cols_driving,
    "sig_behavioral"
)

p_main <- panel_total / panel_driving

## Save ----
fig_data <- decomp_df |>
    dplyr::transmute(
        state_name,
        state_abb,
        state_fips,
        total_rate_change = delta_rate,
        total_p025 = delta_rate_p025,
        total_p975 = delta_rate_p975,
        total_qval = qval_total,
        total_significant = sig_total,
        behavioral_risk_factors = driving_bins,
        behavioral_p025,
        behavioral_p975,
        behavioral_qval = qval_behavioral,
        behavioral_significant = sig_behavioral
    )

figure_save(
    p_main,
    FIG_NAME,
    fig_data,
    scale = FIG_SCALE,
    width = FIG_WIDTH,
    height = FIG_HEIGHT,
    dpi = FIG_DPI
)

## GitHub header ----
ggplot2::ggsave(
    here::here("plots", "99_github_header.jpg"),
    panel_driving,
    width = FIG_WIDTH,
    height = FIG_HEIGHT / 2,
    dpi = 200
)
