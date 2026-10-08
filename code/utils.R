## utils.R ----
## Shared helper functions sourced by the analysis scripts.

## Imports ----
library(here)
library(tidyverse)

## Bin definitions ----
return_self_driven <- function() {
    c(
        "speeding_only",
        "alcohol_only",
        "unrestrained_only",
        "speed_alc",
        "speed_unr",
        "alc_unr",
        "all_three",
        "none_flagged"
    )
}

return_nonself_driven <- function() {
    c("pedestrian", "bicyclist", "other_nonpv")
}

return_all_bins <- function() {
    c(return_self_driven(), return_nonself_driven())
}

## The 7 self-driven bins that carry an actual behavioral-risk-factor flag
## (speed / alcohol / unrestrained, alone or combined). Excludes none_flagged,
## which is a self-driven death with no flagged behavior -- displayed as its
## own category, not summed into the behavioral subtotal.
return_behavioral_flagged <- function() {
    setdiff(return_self_driven(), "none_flagged")
}

return_bin_map <- function() {
    c(
        speeding_only = "speed_only_contrib",
        alcohol_only = "alc_only_contrib",
        unrestrained_only = "unr_only_contrib",
        speed_alc = "speed_alc_contrib",
        speed_unr = "speed_unr_contrib",
        alc_unr = "alc_unr_contrib",
        all_three = "all_three_contrib",
        none_flagged = "none_contrib",
        pedestrian = "ped_contrib",
        bicyclist = "bike_contrib",
        other_nonpv = "other_nonpv_contrib"
    )
}

return_contribution_cols_partition <- function() {
    unname(return_bin_map()[return_all_bins()])
}

## State crosswalk ----

#' State name / abbreviation crosswalk (50 states + DC + US aggregate)
#' @return A tibble with `state_name` and `state_abb`.
state_info <- function() {
    tibble::tibble(
        state_name = c(
            "United States",
            datasets::state.name,
            "District of Columbia"
        ),
        state_abb = c("US", datasets::state.abb, "DC")
    )
}

## Figure export ----

#' Export a figure as vector PDF (plots/), raster JPG (plots/), and a data
#' CSV (output/). No RDS of plot objects.
#' @param plot_obj A ggplot object.
#' @param fig_name Base filename (no extension).
#' @param fig_data Tibble of the figure's underlying data.
#' @param width,height,scale,dpi Export dimensions.
#' @return Invisibly, a list of the written paths.
figure_save <- function(plot_obj, fig_name, fig_data,
                        width = 8, height = 6, scale = 1,
                        dpi = 1200) {
    pdf_path <- here::here("plots", paste0(fig_name, ".pdf"))
    jpg_path <- here::here("plots", paste0(fig_name, ".jpg"))
    csv_path <- here::here("output", paste0(fig_name, ".csv"))

    fs::dir_create(here::here("plots"), recurse = TRUE)
    fs::dir_create(here::here("output"), recurse = TRUE)

    ggplot2::ggsave(
        pdf_path,
        plot_obj,
        width = width,
        height = height,
        scale = scale,
        device = grDevices::quartz,
        type = "pdf"
    )

    ggplot2::ggsave(
        jpg_path,
        plot_obj,
        width = width,
        height = height,
        scale = scale,
        dpi = dpi
    )

    readr::write_csv(fig_data, csv_path)

    invisible(list(pdf = pdf_path, jpg = jpg_path, csv = csv_path))
}

## Kitagawa decomposition ----

#' Kitagawa decomp for one or more adjacent year pairs (vectorized).
#'
#' @param deaths_a,pop_a,vmt_a_mil Year-a deaths, population, VMT (millions).
#' @param deaths_b,pop_b,vmt_b_mil Year-b deaths, population, VMT (millions).
#' @param vmt_scale Miles per unit of `vmt_*_mil` (default 1000000).
#' @param rate_per Rate denominator (default 100000).
#' @return A tibble: rate_a, rate_b, delta_rate, vmt_effect, risk_effect (all
#'   per `rate_per` population).
kitagawa_terms <- function(deaths_a,
                           pop_a,
                           vmt_a_mil,
                           deaths_b,
                           pop_b,
                           vmt_b_mil,
                           vmt_scale = 1000000,
                           rate_per = 100000) {
    vmt_a <- vmt_a_mil * vmt_scale
    vmt_b <- vmt_b_mil * vmt_scale
    e_a <- vmt_a / pop_a
    e_b <- vmt_b / pop_b
    r_a <- deaths_a / vmt_a
    r_b <- deaths_b / vmt_b
    rate_a <- rate_per * deaths_a / pop_a
    rate_b <- rate_per * deaths_b / pop_b
    tibble::tibble(
        rate_a = rate_a,
        rate_b = rate_b,
        delta_rate = rate_b - rate_a,
        vmt_effect = rate_per * (e_b - e_a) * (r_a + r_b) / 2,
        risk_effect = rate_per * (e_a + e_b) / 2 * (r_b - r_a)
    )
}

## Monte Carlo helpers ----

#' Draw counts: Poisson when `use_nb` is FALSE, else NB2 (size=theta, mu=mu).
#' theta=1000000 is the Poisson limit. mu=0 gives 0.
#' @param mu Mean counts.
#' @param theta NB size (ignored when use_nb is FALSE).
#' @param use_nb Draw NB2 (TRUE) or Poisson (FALSE).
#' @return Integer draws, one per element of `mu`.
draw_counts <- function(mu, theta, use_nb) {
    if (!use_nb) {
        return(stats::rpois(length(mu), mu))
    }
    suppressWarnings(stats::rnbinom(length(mu), size = theta, mu = mu))
}

#' Draw a cell table BATCH_SIZE times and aggregate to `keep_cols` x sim.
#'
#' Lays out one independent draw of every cell per simulation, sums over the
#' dropped dimensions, and returns long draws. theta must be non-missing.
#' @param cells Tibble with `count`, `theta`, and the keep/drop key columns.
#' @param keep_cols Columns to aggregate to (the rest are summed over).
#' @param batch_size Simulations per batch.
#' @param use_nb Draw NB2 (TRUE) or Poisson (FALSE).
#' @return Long tibble: keep_cols + sim_id + count.
draw_cells_to <- function(cells, keep_cols, batch_size, use_nb) {
    draws <- draw_counts(rep(cells$count, times = batch_size),
        rep(cells$theta, times = batch_size), use_nb)
    m <- matrix(draws, nrow = nrow(cells), ncol = batch_size)
    grp <- do.call(paste, c(cells[keep_cols], sep = "\t"))
    agg <- rowsum(m, group = grp)
    colnames(agg) <- as.character(seq_len(batch_size))
    tibble::tibble(grp = rownames(agg)) |>
        tidyr::separate(grp, into = keep_cols, sep = "\t", convert = TRUE) |>
        dplyr::bind_cols(tibble::as_tibble(agg)) |>
        tidyr::pivot_longer(cols = as.character(seq_len(batch_size)),
            names_to = "sim_id", values_to = "count") |>
        dplyr::mutate(sim_id = as.integer(sim_id))
}

#' Per-functional-class VMT sampling-error sdlog (HPMS Table 6.2).
#' Classes reported at full extent (Interstate through major collector,
#' plus urban minor collector) are effectively a census, so sdlog is 0.
#' Only the sample-expanded classes (rural minor collector and local
#' roads) carry sampling error, set to `sigma_sampled` (collector 80-10
#' precision).
#' @param sigma_sampled Lognormal sdlog for the sample-expanded classes.
#' @return Named numeric vector over the 14 VMT class columns.
vmt_class_sigma <- function(sigma_sampled) {
    c(
        rural_int = 0,
        rural_ofe = 0,
        rural_opa = 0,
        rural_mar = 0,
        rural_majc = 0,
        rural_mic = sigma_sampled,
        rural_local = sigma_sampled,
        urban_int = 0,
        urban_ofe = 0,
        urban_opa = 0,
        urban_mar = 0,
        urban_majc = 0,
        urban_mic = 0,
        urban_local = sigma_sampled
    )
}

#' Set vmt_mil on a (state, year, sim) panel per VMT scheme.
#' @param pr A drawn panel carrying `vmt_total` (per state-year-sim).
#' @param scheme "fixed", "vmt_lognorm", or "vmtclass_sigma".
#' @param sigma_vmt Lognormal sdlog for the "vmt_lognorm" scheme (else ignored).
#' @param sigma_class Named per-class lognormal sdlog vector (VMT class name
#'   to sdlog) for the "vmtclass_sigma" scheme (else ignored). Classes with
#'   sdlog 0 are census (unperturbed). Noise is mean-corrected so
#'   E[sum] = vmt_total.
#' @return `pr` with `vmt_mil` populated.
apply_vmt <- function(pr, scheme, sigma_vmt = NULL, sigma_class = NULL) {
    pr$vmt_mil <- switch(
        scheme,
        fixed = pr$vmt_total,
        ## Independent multiplicative lognormal measurement error per
        ## state-year-sim row (no year-over-year cancellation, so worst
        ## case). Mean-corrected (E[factor] = 1) to match vmtclass_sigma.
        vmt_lognorm = {
            pr$vmt_total *
                exp(stats::rnorm(nrow(pr), 0, sigma_vmt) - sigma_vmt^2 / 2)
        },
        ## Per-functional-class measurement error. Only sample-expanded
        ## classes carry sdlog > 0. Full-extent (census) classes are
        ## unperturbed. Each active class gets an independent mean-corrected
        ## lognormal factor, so E[sum] = vmt_total (point ~= fixed).
        vmtclass_sigma = {
            active <- names(sigma_class)[sigma_class > 0]
            total <- pr$vmt_total
            for (cl in active) {
                s <- sigma_class[[cl]]
                fac <- exp(stats::rnorm(nrow(pr), 0, s) - s^2 / 2)
                total <- total + pr[[cl]] * (fac - 1)
            }
            total
        },
        stop("unknown vmt scheme: ", scheme)
    )
    pr
}

#' Draw a (state, year, sim) x 11-bin panel from a bin-bearing cell table, apply
#' the VMT scheme, and add total deaths (= row sum of bins).
#' @param cells Bin cell table (state x bin or state x age x bin).
#' @param panel_meta Per (state, year) pop + VMT components + per-state
#'   VMT thetas.
#' @param batch_size Simulations per batch.
#' @param deaths_nb Draw deaths NB2 (TRUE) or Poisson (FALSE).
#' @param vmt_scheme VMT scheme passed to apply_vmt().
#' @param vmt_sigma Lognormal sdlog for the "vmt_lognorm" scheme (else NULL).
#' @param vmt_sigma_class Named per-class sdlog vector for "vmtclass_sigma"
#'   (else NULL).
#' @return A drawn panel ready for compute_main()/compute_partition().
draw_bin_panel <- function(cells, panel_meta, batch_size, deaths_nb, vmt_scheme,
                           vmt_sigma = NULL, vmt_sigma_class = NULL) {
    bins_wide <- draw_cells_to(
        cells,
        c("state_fips", "year", "bin"),
        batch_size,
        deaths_nb
    ) |>
        tidyr::pivot_wider(
            names_from = bin,
            values_from = count,
            values_fill = 0
        )
    for (b in return_all_bins()) {
        if (!b %in% names(bins_wide)) {
            bins_wide[[b]] <- 0
        }
    }
    pr <- bins_wide |>
        dplyr::left_join(panel_meta, by = c("state_fips", "year")) |>
        dplyr::mutate(
            deaths = rowSums(dplyr::across(dplyr::all_of(return_all_bins())))
        )
    apply_vmt(
        pr,
        vmt_scheme,
        sigma_vmt = vmt_sigma,
        sigma_class = vmt_sigma_class
    )
}

#' Vectorized cumulative Kitagawa partition. One row per (group_keys, sim_id).
#' @param panel_rep A drawn (state, year, sim) panel with the 11 bins.
#' @param group_keys Grouping columns (e.g. state identifiers, empty for
#'   national).
#' @param bin_cols Bin count columns.
#' @param contrib_map Named map from bin column to contribution column.
#' @param year_i,year_j Anchor years (keeps year_b in (year_i, year_j]).
#' @param vmt_scale Miles per unit of vmt_mil (default 1000000).
#' @param rate_per Rate denominator (default 100000).
#' @return Long tibble of risk_effect and the 11 contribution components.
chain_partition_vec <- function(panel_rep,
                                group_keys,
                                bin_cols,
                                contrib_map,
                                year_i,
                                year_j,
                                vmt_scale = 1000000,
                                rate_per = 100000) {
    a_cols <- stats::setNames(c("pop", "vmt_mil", bin_cols),
        c("pop_a", "vmt_a_mil", paste0(bin_cols, "_a")))
    b_cols <- stats::setNames(c("pop", "vmt_mil", bin_cols),
        c("pop_b", "vmt_b_mil", paste0(bin_cols, "_b")))
    panel_a <- panel_rep |>
        dplyr::select(dplyr::all_of(
            c(group_keys, "sim_id", "year", "pop", "vmt_mil", bin_cols)
        )) |>
        dplyr::rename_with(
            \(x) names(a_cols)[match(x, a_cols)],
            .cols = dplyr::all_of(unname(a_cols))
        ) |>
        dplyr::rename(year_join = year)
    panel_b <- panel_rep |>
        dplyr::select(dplyr::all_of(
            c(group_keys, "sim_id", "year", "pop", "vmt_mil", bin_cols)
        )) |>
        dplyr::mutate(year_b = year, year_a = year - 1L) |>
        dplyr::select(-year) |>
        dplyr::rename_with(
            \(x) names(b_cols)[match(x, b_cols)],
            .cols = dplyr::all_of(unname(b_cols))
        )
    join_keys <- c(group_keys, "sim_id", "year_a" = "year_join")
    steps <- dplyr::inner_join(panel_b, panel_a, by = join_keys) |>
        dplyr::mutate(
            vmt_a = vmt_a_mil * vmt_scale,
            vmt_b = vmt_b_mil * vmt_scale,
            E_avg = (vmt_a / pop_a + vmt_b / pop_b) / 2
        )
    for (b in bin_cols) {
        steps[[unname(contrib_map[b])]] <- rate_per * steps$E_avg *
            (steps[[paste0(b, "_b")]] / steps$vmt_b -
                steps[[paste0(b, "_a")]] / steps$vmt_a)
    }
    contrib_cols <- unname(contrib_map[bin_cols])
    steps$risk_effect <- rowSums(as.matrix(steps[, contrib_cols, drop = FALSE]))
    steps |>
        dplyr::filter(year_b > year_i, year_b <= year_j) |>
        dplyr::group_by(
            dplyr::across(dplyr::all_of(c(group_keys, "sim_id")))
        ) |>
        dplyr::summarise(
            risk_effect = sum(risk_effect),
            dplyr::across(dplyr::all_of(contrib_cols), sum),
            .groups = "drop"
        ) |>
        dplyr::mutate(year_a = year_i, year_b = year_j)
}

## Cumulative crude-rate decomposition for a self-joined (a,b) frame
.chain_main <- function(steps_join, group_keys, year_i, year_j) {
    terms <- kitagawa_terms(
        steps_join$deaths_a,
        steps_join$pop_a,
        steps_join$vmt_a_mil,
        steps_join$deaths_b,
        steps_join$pop_b,
        steps_join$vmt_b_mil
    )
    dplyr::bind_cols(steps_join, terms) |>
        dplyr::filter(year_b > year_i, year_b <= year_j) |>
        dplyr::arrange(
            dplyr::across(dplyr::all_of(c(group_keys, "sim_id"))), year_b
        ) |>
        dplyr::group_by(
            dplyr::across(dplyr::all_of(c(group_keys, "sim_id")))
        ) |>
        dplyr::summarise(
            rate_a = dplyr::first(rate_a),
            rate_b = dplyr::last(rate_b),
            delta_rate = sum(delta_rate),
            vmt_effect = sum(vmt_effect),
            risk_effect = sum(risk_effect),
            .groups = "drop"
        ) |>
        dplyr::mutate(year_a = year_i, year_b = year_j)
}

#' Crude-rate (VMT-exposure vs per-mile-risk) decomposition, state + national.
#' @param panel_rep A drawn (state, year, sim) panel with deaths/pop/vmt_mil.
#' @param year_i,year_j Anchor years.
#' @return Long tibble: rate_a/rate_b/delta_rate/vmt_effect/risk_effect by sim.
compute_main <- function(panel_rep, year_i, year_j) {
    state_a <- panel_rep |>
        dplyr::transmute(
            state_fips,
            sim_id,
            year,
            deaths_a = deaths,
            pop_a = pop,
            vmt_a_mil = vmt_mil
        )
    state_b <- panel_rep |>
        dplyr::transmute(
            state_name,
            state_abb,
            state_fips,
            sim_id,
            year_b = year,
            year_a = year - 1L,
            deaths_b = deaths,
            pop_b = pop,
            vmt_b_mil = vmt_mil
        )
    state_cum <- dplyr::inner_join(state_b, state_a,
        by = c("state_fips", "sim_id", "year_a" = "year")) |>
        .chain_main(
            c("state_name", "state_abb", "state_fips"),
            year_i,
            year_j
        ) |>
        dplyr::mutate(geography = "state")

    nat_yr <- panel_rep |>
        dplyr::group_by(year, sim_id) |>
        dplyr::summarise(
            deaths = sum(deaths),
            pop = sum(pop),
            vmt_mil = sum(vmt_mil),
            .groups = "drop"
        )
    nat_a <- nat_yr |>
        dplyr::transmute(
            sim_id,
            year,
            deaths_a = deaths,
            pop_a = pop,
            vmt_a_mil = vmt_mil
        )
    nat_b <- nat_yr |>
        dplyr::transmute(
            sim_id,
            year_b = year,
            year_a = year - 1L,
            deaths_b = deaths,
            pop_b = pop,
            vmt_b_mil = vmt_mil
        )
    nat_cum <- dplyr::inner_join(nat_b, nat_a,
        by = c("sim_id", "year_a" = "year")) |>
        .chain_main(character(0), year_i, year_j) |>
        dplyr::mutate(geography = "national", state_name = NA_character_,
            state_abb = NA_character_, state_fips = NA_integer_)

    dplyr::bind_rows(state_cum, nat_cum) |>
        tidyr::pivot_longer(
            c(rate_a, rate_b, delta_rate, vmt_effect, risk_effect),
            names_to = "component",
            values_to = "value"
        )
}

#' 11-bin partition (state + national) from a drawn panel.
#' @param panel_rep A drawn (state, year, sim) panel with the 11 bins.
#' @param year_i,year_j Anchor years.
#' @return Long tibble: risk_effect + 11 contribution components by sim.
compute_partition <- function(panel_rep, year_i, year_j) {
    state_cum <- chain_partition_vec(
        panel_rep,
        c("state_name", "state_abb", "state_fips"),
        return_all_bins(),
        return_bin_map(),
        year_i,
        year_j
    ) |>
        dplyr::mutate(geography = "state")
    nat_yr <- panel_rep |>
        dplyr::group_by(year, sim_id) |>
        dplyr::summarise(
            pop = sum(pop),
            vmt_mil = sum(vmt_mil),
            dplyr::across(dplyr::all_of(return_all_bins()), sum),
            .groups = "drop"
        )
    nat_cum <- chain_partition_vec(
        nat_yr,
        character(0),
        return_all_bins(),
        return_bin_map(),
        year_i,
        year_j
    ) |>
        dplyr::mutate(geography = "national", state_name = NA_character_,
            state_abb = NA_character_, state_fips = NA_integer_)
    dplyr::bind_rows(state_cum, nat_cum) |>
        tidyr::pivot_longer(
            c(risk_effect, dplyr::all_of(return_contribution_cols_partition())),
            names_to = "component",
            values_to = "value"
        )
}

## Summarize ----

#' Summarize batched simulation parquets
#'
#' @param glob Parquet glob passed to DuckDB read_parquet.
#' @param group_cols Cell grouping columns.
#' @param out_path Output parquet path.
#' @return Invisibly NULL (writes `out_path`).
summarize_dir <- function(glob, group_cols, out_path) {
    con <- duckdb::dbConnect(duckdb::duckdb(), read_only = TRUE)
    on.exit(duckdb::dbDisconnect(con, shutdown = TRUE), add = TRUE)
    sims <- dplyr::tbl(con, sprintf("read_parquet(%s)", shQuote(glob)))
    summary_df <- sims |>
        dplyr::group_by(dplyr::across(dplyr::any_of(group_cols))) |>
        dplyr::summarise(
            n = dplyr::n(),
            mean = mean(value),
            sd = stats::sd(value),
            n_le0 = sum(as.integer(value <= 0)),
            n_ge0 = sum(as.integer(value >= 0)),
            p025 = stats::quantile(value, 0.025),
            p500 = stats::quantile(value, 0.5),
            p975 = stats::quantile(value, 0.975),
            .groups = "drop"
        ) |>
        dplyr::collect()
    summary_df |>
        dplyr::mutate(
            pval = pmin(
                1,
                2 * pmin((n_le0 + 1) / (n + 1), (n_ge0 + 1) / (n + 1))
            )
        ) |>
        dplyr::group_by(
            dplyr::across(dplyr::any_of(c("geography", "component")))
        ) |>
        dplyr::mutate(qval = dplyr::if_else(geography == "state",
            stats::p.adjust(pval, method = "BH"), NA_real_)) |>
        dplyr::ungroup() |>
        arrow::write_parquet(out_path)
    invisible(NULL)
}

## Display formatters ----
## Shared by the table QMDs so number formatting (rounding, sign, thousands
## separators) is defined in one place. Sourced from each `qmd/*.qmd`.

#' Confidence/uncertainty bounds as "(lower, upper)", bounds unsigned.
fmt_ci <- function(lower, upper, digits = 2) {
    sprintf("(%.*f, %.*f)", digits, lower, digits, upper)
}

#' "estimate (lower, upper)" with everything unsigned.
fmt_rate_ci <- function(mu, lower, upper, digits = 2) {
    sprintf("%.*f %s", digits, mu, fmt_ci(lower, upper, digits))
}

#' "estimate (lower, upper)" with the estimate signed, bounds unsigned.
fmt_val_ci <- function(mu, lower, upper, digits = 2, sign = TRUE) {
    if (sign) {
        sprintf("%+.*f %s", digits, mu, fmt_ci(lower, upper, digits))
    } else {
        sprintf("%.*f %s", digits, mu, fmt_ci(lower, upper, digits))
    }
}

#' "estimate (lower, upper)" with the estimate and both bounds signed.
fmt_ci_signed <- function(mu, lower, upper, digits = 2) {
    sprintf("%+.*f (%+.*f, %+.*f)", digits, mu, digits, lower, digits, upper)
}

#' Integer with thousands separators.
fmt_int <- function(x) {
    formatC(x, format = "d", big.mark = ",")
}

#' Percentage to one decimal, e.g. "59.6%".
fmt_pct <- function(x, digits = 1) {
    sprintf("%.*f%%", digits, x)
}

#' Crude per-capita rate (deaths / population, scaled), unsigned.
fmt_rate <- function(deaths, pop, per = 100000, digits = 2) {
    sprintf("%.*f", digits, per * deaths / pop)
}
