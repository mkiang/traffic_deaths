# `code/`

## Analysis files

1. `01_ingest_fars.R`: Reads FARS Person/Vehicle/Accident files (2018-2024), flags speeding/alcohol/restraint at the decedent level, attaches age/weather/road-type, saves long-format parquet.
    - **Inputs**: `code/utils.R`, `data_raw/fars/FARS{year}NationalCSV.zip`
    - **Outputs**: `data/fars_persons_2018_2024.parquet`
2. `02_ingest_vmt.R`: Reads FHWA Highway Statistics Table VM-2 spreadsheets (2018-2024) and intgests state-year urban, rural, and total VMT.
    - **Inputs**: `data_raw/fhwa_vm2/vm2_{year}.{xls,xlsx}`
    - **Outputs**: `data/fhwa_vm2_state_year_2018_2024.parquet`
3. `03_ingest_population_data.R`: Reads CDC WONDER single-race postcensal population estimates (V2020 + V2024 vintages), sums across age groups to state-year totals.
    - **Inputs**: `data_raw/Single-Race Population Estimates *.tsv`
    - **Outputs**: `data/nchs_pop_state_age_2018_2024.parquet`
4. `04_ingest_wonder_mortality.R`: Reads CDC WONDER multiple-cause-of-death ICD-10 motor vehicle counts for FARS-NCHS comparison.
    - **Inputs**: `data_raw/Multiple Cause of Death*.{csv,txt}`
    - **Outputs**: `data/wonder_mortality_state_year_1999_2024.parquet`
5. `05_create_analytic_df.R`: Joins FARS, VMT, and population to a state-year panel with 11-bin decedent counts.
    - **Inputs**: `code/utils.R`, `data/{fars_persons,fhwa_vm2,nchs_pop,wonder_mortality}_*.parquet`
    - **Outputs**: `data/panel_state_year.parquet`
6. `06_compute_dispersion.R`: Method-of-moments negativ binomial theta by grain (state x age x category, state x category, state x age x category x road-type, state x age x category x weather, VMT total/urban/rural). Underdispersed cells set to Poisson floor.
    - **Inputs**: `data/panel_state_year.parquet`, `data/fars_persons_2018_2024.parquet`
    - **Outputs**: `data/overdispersion_window.parquet`
7. `07_decompose_rates.R`: Deterministic Kitagawa decomposition (symmetric weighting) of crude rate into VMT-exposure and per-mile-risk effects, cumulative across 2021-2024.
    - **Inputs**: `data/panel_state_year.parquet`
    - **Outputs**: `data/decomposition_chained.parquet`
8. `08_partition_behavior.R`: Patitions the per-mile-risk effect into the 11 mutually exclusive categories (7 behavioral + 1 none-flagged + 3 non-occupant).
    - **Inputs**: `data/panel_state_year.parquet`, `data/decomposition_chained.parquet`
    - **Outputs**: `data/partition_cumulative.parquet`
9. `09_simulate_decompositions.R`: Monte Carlo (100 batches x 250 sims = 25,000) draws of deaths (VMT drawn with per-functional-class lognormal sampling error; sensitivity 60 holds it fixed); runs main decomposition, partition, and category-rate targets.
    - **Inputs**: `code/utils.R`, `data/panel_state_year.parquet`, `data/overdispersion_window.parquet`, `config.yml`
    - **Outputs**: `temp_output/simulations/{main,partition,category_rates}/batch*.parquet`
10. `10_summarize_simulations.R`: Calcualtes percentile UIs, two-sided empirical p-values (Phipson-Smyth), and BH-FDR q-values from the 25,000 sim draws.
    - **Inputs**: `code/utils.R`, `temp_output/simulations/**/*.parquet`
    - **Outputs**: `data/summaries/{main,partition,category_rates}_ci.parquet`
11. `11_figure1_geographic.R`: Figure 1 — state-level VMT effect and 7-bin behavioral-sum choropleth + inset histogram. Also exports the 200-DPI GitHub header image.
    - **Inputs**: `code/utils.R`, `data/decomposition_chained.parquet`, `data/partition_cumulative.parquet`, `temp_output/simulations/**/*.parquet`
    - **Outputs**: `plots/01_figure1_geographic.{pdf,jpg}`, `plots/99_github_header.jpg`, `output/01_figure1_geographic.csv`
12. `12_figureS01_fatalities.R`: eFigure S01 — state-year FARS fatality counts, time series facets (2018-2024).
    - **Inputs**: `code/utils.R`, `code/mk_nytimes.R`, `data/panel_state_year.parquet`
    - **Outputs**: `plots/02_figureS01_traffic_fatalities.{pdf,jpg}`, `output/02_figureS01_traffic_fatalities.csv`
13. `13_figureS02_vmt.R`: eFigure S02 — state-year FHWA VMT, time series facets (total / urban / rural).
    - **Inputs**: `code/utils.R`, `code/mk_nytimes.R`, `data/fhwa_vm2_state_year_2018_2024.parquet`
    - **Outputs**: `plots/03_figureS02_vmt.{pdf,jpg}`, `output/03_figureS02_vmt.csv`
14. `14_figureS04toS15_category_maps.R`: eFigures S04-S15 — 12 standalone Figure-1B-style state choropleths (VMT effect + 11 per-mile-risk categories), per-map symmetric color scale with inset histogram.
    - **Inputs**: `code/utils.R`, `data/decomposition_chained.parquet`, `data/partition_cumulative.parquet`
    - **Outputs**: `plots/{05..16}_figureS{04..15}_*.{pdf,jpg}`, `output/{05..16}_figureS{04..15}_*.csv`
15. `15_figureS03_fars_vs_nchs.R`: eFigure S03 — state-year FARS vs NCHS death-count scatter (log-log, y=x, Pearson r in facet strips).
    - **Inputs**: `code/utils.R`, `code/mk_nytimes.R`, `data/panel_state_year.parquet`
    - **Outputs**: `plots/04_figureS03_fars_vs_nchs.{pdf,jpg}`, `output/04_figureS03_fars_vs_nchs.csv`

## Additional analyses (online supplement)

16. `30_supp_additional_weather_decompose.R`: Deterministic partition of per-mile risk by crash weather (good/adverse/unknown); shared-VMT denominator since FHWA does not report VMT by weather.
    - **Inputs**: `code/utils.R`, `data/{panel_state_year,fars_persons_*}.parquet`
    - **Outputs**: `data/decomposition_weather.parquet`
17. `31_supp_additional_weather_simulate.R`: Monte Carlo sims of the weather partition (deaths NB2, total VMT via the primary class-calibrated lognormal model); summarized to UIs.
    - **Inputs**: `code/utils.R`, `data/panel_state_year.parquet`, `data/overdispersion_window.parquet`, `config.yml`
    - **Outputs**: `temp_output/simulations_weather/main/batch*.parquet`, `data/summaries/weather_ci.parquet`
18. `40_supp_additional_road_type_decompose.R`: Stadnard urban/rural stratified Kitagawa decomposition; urban + rural sum to overall change among the ~99.5% of fatalities with known road type.
    - **Inputs**: `code/utils.R`, `data/panel_state_year.parquet`, `data/fars_persons_2018_2024.parquet`
    - **Outputs**: `data/decomposition_road_type.parquet`
19. `41_supp_additional_road_type_simulate.R`: Monte Carlo NB sims of the road-type stratification; urban and rural VMT drawn with the primary class-calibrated lognormal model.
    - **Inputs**: `code/utils.R`, `data/panel_state_year.parquet`, `data/overdispersion_window.parquet`, `config.yml`
    - **Outputs**: `temp_output/simulations_road_type/main/batch*.parquet`, `data/summaries/road_type_ci.parquet`

## Sensitivity analyses

Each varies exactly one modeling choice from the primary. The two VMT sensitivities change the VMT treatment (fixed / worst-case) holding deaths at the primary MoM-NB draw; the three death-model sensitivities vary the death draw holding VMT at the primary's per-class sampling-error model. The per-mile-risk effect excludes zero in every one.

20. `50_supp_sensitivity_vmtnoise_worst_simulate.R` + `51_*_summarize.R`: worst-case VMT measurement error — multiplicative log-normal noise (sigma = 0.078, HPMS +/-10% at 80% confidence) on total VMT, independent per state-year (no year-over-year cancellation). Upper bound on VMT uncertainty.
    - **Inputs**: `code/utils.R`, `data/panel_state_year.parquet`, `data/overdispersion_window.parquet`, `config.yml`
    - **Outputs**: `temp_output/sensitivities/vmtnoise_worst/{main,partition}/batch*.parquet`, `data/summaries/{main,partition}_ci_vmtnoise_worst.parquet`
21. `60_supp_sensitivity_fixedvmt_simulate.R` + `61_*_summarize.R`: VMT fixed at the FHWA point estimate (no VMT-error draw) — ignores VMT uncertainty; the exposure-effect interval collapses to a near-point (only death-draw noise remains). Lower bound on VMT uncertainty.
    - **Outputs**: `temp_output/sensitivities/fixedvmt/{main,partition}/batch*.parquet`, `data/summaries/{main,partition}_ci_fixedvmt.parquet`
22. `70_supp_sensitivity_stategrain_simulate.R` + `71_*_summarize.R`: coarser death-draw grain (state x category, no age).
    - **Outputs**: `data/summaries/{main,partition}_ci_stategrain.parquet`
23. `80_supp_sensitivity_ebdisp_simulate.R` + `81_*_summarize.R`: empirical-Bayes moderated dispersion (edgeR `estimateDisp`, intercept-only design) instead of per-cell method of moments.
    - **Outputs**: `data/summaries/{main,partition}_ci_ebdisp.parquet`
24. `90_supp_sensitivity_poissonsim_simulate.R` + `91_*_summarize.R`: Poisson deaths (no overdispersion) — the optimistic dispersion floor.
    - **Outputs**: `data/summaries/{main,partition}_ci_poissonsim.parquet`

## Utility files

- `utils.R`: Shared utility functions (bin definitions, state crosswalks, Kitagawa algebra, NB draws, formatters).
- `mk_nytimes.R`: Custom ggplot2 theme.
