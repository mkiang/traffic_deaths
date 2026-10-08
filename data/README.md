# `data/`

Processed, analysis-ready parquet files produced by scripts in `./code/`. State-year long format unless noted. Rates are per 100,000 population; VMT is in millions of miles.

## `fars_persons_2018_2024.parquet`

Datframe. Decedent-level FARS records, 2018-2024, with derived flags: speeding, alcohol-impairment, restraint (decedent-level), road type (urban/rural/unknown), weather (good/adverse/unknown), 5-year age group, 11-category bin.
*From `01`. Used by `05`, `06`, `15`, `30`, `40`; qmds `etable03`, `etable04`.*

## `fhwa_vm2_state_year_2018_2024.parquet`

Dataframe. State-year FHWA Table VM-2 VMT: total, urban, rural.
*From `02`. Used by `05`, `13`.*

## `nchs_pop_state_age_2018_2024.parquet`

Dataframe. State-year-age population (V2020 + V2024 vintages); single-race postcensal estimates summed across age groups for state totals.
*From `03`. Used by `05`.*

## `wonder_mortality_state_year_1999_2024.parquet`

Dataframe. CDC WONDER multiple-cause-of-death ICD-10 motor vehicle counts (V01-V99), state-year, 1999-2024. Used only for FARS-vs-NCHS validation.
*From `04`. Used by `05`.*

## `panel_state_year.parquet`

Dataframe. The analytic panel — one row per state-year with FARS deaths, NCHS population, FHWA VMT (total/urban/rural + 14 functional-class columns), WONDER deaths, and 11-bin death counts.
*From `05`. Used by `06`, `07`, `08`, `09`, `12`, `15`, `30`, `31`, `40`, `41`, `50`, `60`, `70`, `80`, `90`; manuscript + all 6 qmds.*

## `overdispersion_window.parquet`

Dataframe. Negative binomial theta by cell grain, estimated over the 2021-2024 window (4 obs per cell). Method-of-moments levels: deaths by state x category, state x age x category, state x age x category x road-type, state x age x category x weather, plus VMT total/urban/rural; plus an edgeR empirical-Bayes level (state x age x category) used only by the ebdisp sensitivity.
*From `06`. Used by `09`, `31`, `41`, `50`, `60`, `70`, `80`, `90`.*

## `decomposition_chained.parquet`

Dataframe. Deterministic Kitagawa cumulative decomposition (2021-2024), symmetric weighting. Carries `rate_a, rate_b, delta_rate, vmt_effect, risk_effect` for national + 51 state-level rows. Identity `vmt_effect + risk_effect == delta_rate` holds to <1e-9.
*From `07`. Used by `08`, `11`, `14`, `40`; qmd `etable04`.*

## `partition_cumulative.parquet`

Dataframe. Deterministic 11-component partition of the per-mile-risk effect, 2021-2024, national + state. Components sum exactly to `risk_effect` from the decompostion file.
*From `08`. Used by `11`, `14`.*

## `decomposition_weather.parquet`

Dataframe. Deterministic weather partition of the per-mile risk effect (good/adverse/unknown). Three categories sum to the national `risk_effect`.
*From `30`. Used by qmd `etable04`.*

## `decomposition_road_type.parquet`

Dataframe. Deterministic urban + rural stratified Kitagawa decomposition. Carries `delta_rate, vmt_effect, risk_effect` per stratum; strata sum to the overall change among fatalities with known road type.
*From `40`. Used by qmd `etable03`.*

## `summaries/`

Monte Carlo simulation summries — percentile uncertainty intervals + empirical p-values + BH-FDR q-values from 25,000 sim draws. One row per (geography, component) for national + 51 state-level summaries.

- `main_ci.parquet`, `partition_ci.parquet`, `category_rates_ci.parquet`: primary specification (deaths MoM-NB + per-functional-class lognormal VMT sampling error). *From `10`. Used by manuscript + all 6 qmds.*
- `weather_ci.parquet`: A2 weather partition. *From `31`. Used by qmd `etable04`.*
- `road_type_ci.parquet`: A1 road-type strata. *From `41`. Used by qmd `etable03`.*
- `{main,partition}_ci_vmtnoise_worst.parquet`: worst-case VMT log-normal noise (sigma=0.078 on total VMT, independent per state-year). *From `51`. Used by qmd `etable02`.*
- `{main,partition}_ci_fixedvmt.parquet`: VMT fixed at the FHWA point estimate (ignores VMT uncertainty; exposure interval collapses to a near-point). *From `61`. Used by qmd `etable02`.*
- `{main,partition}_ci_stategrain.parquet`: coarser death-draw grain (state x category). *From `71`. Used by qmd `etable02`.*
- `{main,partition}_ci_ebdisp.parquet`: empirical-Bayes moderated dispersion (edgeR). *From `81`. Used by qmd `etable02`.*
- `{main,partition}_ci_poissonsim.parquet`: Poisson deaths (dispersion floor). *From `91`. Used by qmd `etable02`.*
