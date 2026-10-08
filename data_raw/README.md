## `data_raw/`

Contains the original (unedited) source data used for all analyses. 

### CDC WONDER — Mortality

We used four Multiple Cause of Death files downloaded from CDC WONDER, all using the same motor-vehicle-traffic ICD-10 cause-of-death set (V02-V04, V09.0, V09.2, V12-V14, V19.0-V19.2, V19.4-V19.6, V20-V79, V80.3-V80.5, V81.0-V81.1, V82.0-V82.1, V83-V86, V87.0-V87.8, V88.0-V88.8, V89.0, V89.2):

1. `Multiple Cause of Death, 1999-2020 By state.csv` — state-year counts, 1999-2020. From the Multiple Cause of Death (Detailed Mortality) database; downloaded from [this query](http://wonder.cdc.gov/controller/saved/D77/D497F562) on May 1, 2026.
2. `Multiple Cause of Death, 1999-2020.csv` — national time series, 1999-2020, same ICD-10 codes. From the Multiple Cause of Death database; downloaded from [this query](http://wonder.cdc.gov/controller/saved/D77/D497F562) on May 1, 2026.
3. `Multiple Cause of Death, 2018-2024, Single Race By State.txt` — state-year counts, 2018-2024, single-race coding (post-Bridged-Race era); used for the 2021-2024 main analysis. From the Multiple Cause of Death — Single Race (provisional 2024) database; downloaded from [this query](http://wonder.cdc.gov/controller/saved/D157/D497F558) on May 1, 2026.
4. `Multiple Cause of Death, 2018-2024, Single Race.csv` — national series, 2018-2024, same ICD-10 codes. From the Multiple Cause of Death — Single Race database; downloaded from [this query](http://wonder.cdc.gov/controller/saved/D157/D497F559) on May 1, 2026.

**Data dictionary:** WONDER variable definitions at <https://wonder.cdc.gov/wonder/help/mcd.html> (general) and <https://wonder.cdc.gov/wonder/help/mcd-provisional.html> (single-race / provisional file). ICD-10 cause-of-death classification at <https://www.cdc.gov/nchs/icd/icd10.htm>.

### CDC WONDER — Single-Race Population Estimates

Two population files, used as denominators for age-standardized rates. Both report July 1 resident population by state, by five-year age group, by year:

1. `Single-Race Population Estimates 2010-2020 by State and Single-Year Age.tsv` — 2010-2020 (Vintage 2020 postcensal estimates; released by Census June 26, 2025). Downloaded from [this query](https://wonder.cdc.gov/controller/saved/D170/D503F533) on May 9, 2026.
2. `Single-Race Population Estimates 2020-2024 by State and Single-Year Age.tsv` — 2020-2024 (Vintage 2024 postcensal estimates; Modified Blended Base in lieu of the April 1, 2020 decennial). Downloaded from [this query](http://wonder.cdc.gov/controller/saved/D203/D503F532) on May 9, 2026.

**Data dictionary:** Single-Race Population methodology at <http://wonder.cdc.gov/single-race-single-year-v2024.html> (2020-2024 file) and <http://wonder.cdc.gov/single-race-single-year-v2020.html> (2010-2020 file).

### FHWA Highway Statistics Table VM-2 — `fhwa_vm2/`

Annual state by functional-class VMT, 2018-2024. Used to compute urban-vs-rural exposure denominators for the road-type-stratified Kitagawa decomposition. These files are downloaded programmatically:

1. `vm2_{2018-2022}.xls` — 51 jurisdictions by year, 13 functional classes. From the FHWA Office of Highway Policy Information, Highway Statistics Series; downloaded from `https://www.fhwa.dot.gov/policyinformation/statistics/{year}/xls/vm2.xls` on May 5, 2026.
2. `vm2_{2023-2024}.xlsx` — same coverage. From the same source; downloaded from `https://www.fhwa.dot.gov/policyinformation/statistics/{year}/xls/vm2.xlsx` on May 5, 2026.

**Data dictionary:** Highway Statistics methodology at <https://www.fhwa.dot.gov/policyinformation/statistics/2023/>. Functional-class definitions at <https://www.fhwa.dot.gov/policy/2013cpr/chap14.cfm>.

### FARS National CSV — `fars/`

Fatality Analysis Reporting System (FARS) National Annual Report File downloads, 2018-2024. Each zip contains 30+ CSV tables describing every fatal motor-vehicle traffic crash in the United States.

1. `FARS{2018-2024}NationalCSV.zip` — all US fatal motor-vehicle traffic crashes. From NHTSA / National Center for Statistics and Analysis. Downloaded programmatically from `https://static.nhtsa.gov/nhtsa/downloads/FARS/{year}/National/FARS{year}NationalCSV.zip` on May 5, 2026. 2018-2023 are Final Files. 2024 is the (provisional) Annual Report File.

**Data dictionary:** FARS Analytical User's Manual (current edition) at <https://crashstats.nhtsa.dot.gov/Api/Public/ViewPublication/813705> (DOT HS 813 705, FARS/CRSS Analytical User's Manual 1975-2023). Defines every column and code in every table.

**FARS vs WONDER.** CDC WONDER (NCHS) counts motor vehicle deaths more inclusively than FARS (no public-trafficway, in-transport-vehicle, or 30-day-window restriction), so its counts run slightly higher, but the two are highly correlated by state-year (Pearson r > 0.99; see eFigure S3). See the manuscript eMethods for details.

### NHTSA Traffic Safety Facts and NOPUS — `nhtsa/`

The `nhtsa/` folder holds published NHTSA Traffic Safety Facts and NOPUS seat-belt-use reports. We only use them for validation of FARS counts. Not needed for analysis. 
