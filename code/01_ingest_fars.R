## 01_ingest_fars.R ----
##
## Read FARS National Annual Report files and build a person-level
## dataset of crash fatalites, tagged with crash behavioral flags
## (speeding, alcohol, unrestrained or no helmet), age group, weather,
## road type, and vehicle attributes (model year, safety features).
##
## Downloads missing zips from NHTSA website if they don't exist on disk.
##
## Inputs:
##   - data_raw/fars/FARS{year}NationalCSV.zip
##   - code/utils.R
##
## Outputs:
##   - data/fars_persons_2018_2024.parquet

## Imports ----
library(tidyverse)
library(here)
library(fs)
source(here::here("code", "utils.R"))

## Constants ----
YEARS <- config::get("year_start"):config::get("year_end")
RAW_DIR <- here::here("data_raw", "fars")
OUT_PATH <- here::here(
    "data",
    sprintf("fars_persons_%i_%i.parquet", min(YEARS), max(YEARS))
)

NCHS_AGE_BREAKS_18 <- c(seq(0, 85, 5), Inf)
NCHS_AGE_LABELS_18 <- c(
    "0-4",
    "5-9",
    "10-14",
    "15-19",
    "20-24",
    "25-29",
    "30-34",
    "35-39",
    "40-44",
    "45-49",
    "50-54",
    "55-59",
    "60-64",
    "65-69",
    "70-74",
    "75-79",
    "80-84",
    "85+"
)

## Download missing FARS zips ----
fs::dir_create(RAW_DIR, recurse = TRUE)
for (y in YEARS) {
    dest <- here::here(RAW_DIR, sprintf("FARS%dNationalCSV.zip", y))

    if (fs::file_exists(dest)) {
        next
    }

    url_base <- "https://static.nhtsa.gov/nhtsa/downloads"
    url <- sprintf("%s/FARS/%d/National/FARS%dNationalCSV.zip", url_base, y, y)

    tryCatch(utils::download.file(url, dest, mode = "wb", quiet = TRUE),
        error = \(e) {
            if (fs::file_exists(dest)) {
                fs::file_delete(dest)
            }
            stop(sprintf("Failed to download FARS%d from %s", y, url),
                call. = FALSE
            )
        }
    )
}

## Helpers ----

fars_zip_path <- function(year, raw_dir = NULL) {
    if (is.null(raw_dir)) {
        raw_dir <- here::here("data_raw", "fars")
    }
    here::here(raw_dir, sprintf("FARS%dNationalCSV.zip", year))
}

fars_zip_member <- function(zip_p, member_lower) {
    files <- utils::unzip(zip_p, list = TRUE)$Name
    hit <- which(tolower(basename(files)) == tolower(member_lower))
    if (length(hit) == 0) {
        stop("no member matching ", member_lower, " in ", zip_p)
    }
    files[hit[1]]
}

fars_read_member <- function(zip_p, member_lower, cols = NULL) {
    con <- unz(zip_p, fars_zip_member(zip_p, member_lower))
    df <- readr::read_csv(con, show_col_types = FALSE)
    if (!is.null(cols)) {
        df <- df |> dplyr::select(dplyr::any_of(cols))
    }
    df
}

## Flag speeding-related crashes from vehicle.csv SPEEDREL (codes 1-5)
fars_tag_speeding <- function(vehicle_df) {
    vehicle_df |>
        dplyr::group_by(STATE, ST_CASE) |>
        dplyr::summarise(
            crash_speed_flag = any(SPEEDREL %in% 1:5, na.rm = TRUE),
            .groups = "drop"
        )
}

## Flag alcohol-impaired crashes: strict majority (>= 6 of 10) of the imputed
## BAC values indicate any driver BAC >= 0.08 g/dL.
fars_tag_alcohol <- function(midrvacc_df) {
    midrvacc_df |>
        dplyr::group_by(ST_CASE) |>
        dplyr::summarise(
            dplyr::across(paste0("A", 1:10), \(x) max(x, na.rm = TRUE)),
            .groups = "drop"
        ) |>
        dplyr::mutate(
            crash_alc_p = rowMeans(
                dplyr::across(paste0("A", 1:10), \(x) as.integer(x >= 8)),
                na.rm = TRUE
            ),
            crash_alc_flag = crash_alc_p > 0.5
        ) |>
        dplyr::select(ST_CASE, crash_alc_p, crash_alc_flag)
}

## Classify accident.csv WEATHERNAME into good / adverse / unknown
fars_classify_weather <- function(weathername) {
    s <- as.character(weathername)
    out <- rep("unknown", length(s))
    out[is.na(s) | s == ""] <- "unknown"
    for (p in c("Not Reported", "Unknown", "No Additional")) {
        out[grepl(p, s, ignore.case = TRUE)] <- "unknown"
    }
    adverse_pat <- c("Rain", "Snow", "Sleet", "Hail", "Fog", "Smog",
        "Smoke", "Crosswinds", "Blowing", "Freezing", "Severe", "Other")
    for (p in adverse_pat) {
        out[grepl(p, s, ignore.case = TRUE)] <- "adverse"
    }
    out[s %in% c("Clear", "Cloudy")] <- "good"
    out
}

## Flag self-driven occupants with no protectve equipment. Unrestrained
## means no seatbelt for PV occupants and no helmet for motorcyclists.
fars_is_unprotected <- function(per_typ, body_typ, rest_usename, helm_usename) {
    is_pv <- (per_typ %in% c(1L, 2L)) & (body_typ <= 49L)
    is_moto <- (per_typ %in% c(1L, 2L)) &
        (body_typ %in% c(80L, 81L, 82L, 83L, 86L, 87L))
    pv_no_belt <- is_pv & grepl("None Used", rest_usename, fixed = TRUE)
    moto_no_helm <- is_moto & (helm_usename == "No Helmet")
    moto_no_helm[is.na(moto_no_helm)] <- FALSE
    pv_no_belt | moto_no_helm
}

## TRUE when a drug test result was returned (person.csv DSTATUSNAME)
fars_is_drug_tested <- function(dstatusname) {
    not_tested <- c("Test Not Given", "Test Refused", "Not Reported",
        "Unknown if Tested", "Reported as Unknown if Tested",
        "Unknown", "None Given")
    s <- as.character(dstatusname)
    !(is.na(s) | s == "" | s %in% not_tested)
}

## Assign deaths to mutually-exclusive bins (11 total) ----
##
## Self-driven occupants (PV occupants + motorcyclists) get 8 bins for
## every combination of {speed, alcohol, unrestrained} flags, where
## unrestrained means no seatbelt (PV) or no helmet (motorcyclist).
## Everyone else is a pedestrian, bicyclist, or other victim.
assign_bin <- function(df) {
    df |>
        ## Person-level
        dplyr::mutate(
            is_pv_occupant = (per_typ %in% c(1L, 2L)) &
                (body_typ <= 49L),
            is_motorcyclist = (per_typ %in% c(1L, 2L)) &
                (body_typ %in% c(80L, 81L, 82L, 83L, 86L, 87L)),
            is_self_driven = is_pv_occupant | is_motorcyclist,
            is_pedestrian = per_typ == 5L,
            is_bicyclist = per_typ %in% c(6L, 7L)
        ) |>
        ## Count flags
        dplyr::mutate(
            n_flags = as.integer(crash_speed_flag) +
                as.integer(crash_alc_flag) +
                as.integer(unr_flag)
        ) |>
        ## Assign bins
        dplyr::mutate(
            bin = dplyr::case_when(
                is_self_driven & n_flags == 0 ~ "none_flagged",
                is_self_driven & crash_speed_flag &
                    crash_alc_flag & unr_flag ~ "all_three",
                is_self_driven & crash_speed_flag &
                    crash_alc_flag & !unr_flag ~ "speed_alc",
                is_self_driven & crash_speed_flag &
                    !crash_alc_flag & unr_flag ~ "speed_unr",
                is_self_driven & !crash_speed_flag &
                    crash_alc_flag & unr_flag ~ "alc_unr",
                is_self_driven & crash_speed_flag &
                    !crash_alc_flag & !unr_flag ~ "speeding_only",
                is_self_driven & !crash_speed_flag &
                    crash_alc_flag & !unr_flag ~ "alcohol_only",
                is_self_driven & !crash_speed_flag &
                    !crash_alc_flag & unr_flag ~ "unrestrained_only",
                !is_self_driven & is_pedestrian ~ "pedestrian",
                !is_self_driven & is_bicyclist ~ "bicyclist",
                !is_self_driven ~ "other_nonpv"
            )
        ) |>
        dplyr::select(
            -is_pv_occupant,
            -is_motorcyclist,
            -is_self_driven,
            -is_pedestrian,
            -is_bicyclist
        )
}

## Process one year ----
process_year <- function(y) {
    zp <- fars_zip_path(y)

    accident_df <- fars_read_member(
        zp, "accident.csv",
        cols = c(
            "STATE",
            "STATENAME",
            "ST_CASE",
            "MONTH",
            "RUR_URB",
            "RUR_URBNAME",
            "WEATHER",
            "WEATHERNAME"
        )
    ) |>
        dplyr::mutate(
            weather_cat = fars_classify_weather(WEATHERNAME),
            road_type = dplyr::case_when(
                RUR_URB == 1 ~ "rural",
                RUR_URB == 2 ~ "urban",
                TRUE ~ "unknown"
            )
        )

    ## HELM_USENAME exists as a separate column starting FARS 2020.
    ## In 2018-2019, helmet codes are folded into REST_USENAME directly
    ## for motorcyclist records.
    person_df <- fars_read_member(
        zp, "person.csv",
        cols = c(
            "STATE",
            "ST_CASE",
            "VEH_NO",
            "PER_NO",
            "PER_TYP",
            "INJ_SEV",
            "BODY_TYP",
            "AGE",
            "SEX",
            "HISPANIC",
            "REST_USENAME",
            "HELM_USENAME",
            "DSTATUSNAME"
        )
    )
    if (!"HELM_USENAME" %in% names(person_df)) {
        person_df$HELM_USENAME <- person_df$REST_USENAME
    }

    vehicle_df <- fars_read_member(
        zp, "vehicle.csv",
        cols = c(
            "STATE",
            "ST_CASE",
            "VEH_NO",
            "SPEEDREL",
            "MOD_YEAR",
            "BODY_TYP"
        )
    )

    midrvacc_df <- fars_read_member(
        zp, "midrvacc.csv",
        cols = c("ST_CASE", paste0("A", 1:10))
    )

    ## vpicdecode is only present for some years (2021+)
    vpic_df <- tryCatch(
        fars_read_member(
            zp, "vpicdecode.csv",
            cols = c(
                "STATE",
                "ST_CASE",
                "VEH_NO",
                "CRASHIMMINENTBRAKING",
                "FORWARDCOLLISIONWARNING"
            )
        ),
        error = \(e) NULL
    )

    ## Crash-level flags
    crash_speeding <- fars_tag_speeding(vehicle_df)
    crash_alcohol <- fars_tag_alcohol(midrvacc_df)
    crash_weather <- accident_df |>
        dplyr::select(
            STATE,
            ST_CASE,
            weather_cat,
            road_type,
            MONTH
        )

    ## Join state lookup
    state_lookup <- accident_df |>
        dplyr::distinct(STATE, STATENAME) |>
        dplyr::left_join(state_info(),
            by = c("STATENAME" = "state_name")
        ) |>
        dplyr::rename(state_name = STATENAME)

    ## Vehicle attributes (model year + AEB)
    veh_attrs <- vehicle_df |>
        dplyr::select(STATE, ST_CASE, VEH_NO, MOD_YEAR) |>
        dplyr::mutate(
            mod_year = dplyr::case_when(
                MOD_YEAR < 1900 ~ NA_real_,
                MOD_YEAR > y + 2 ~ NA_real_,
                TRUE ~ as.numeric(MOD_YEAR)
            )
        ) |>
        dplyr::select(STATE, ST_CASE, VEH_NO, mod_year)

    if (!is.null(vpic_df) &&
        all(c("STATE", "ST_CASE", "VEH_NO") %in%
            names(vpic_df))) {
        ## Add NA columns if AEB/FCW fields don't exist for this FARS year
        if (!"CRASHIMMINENTBRAKING" %in% names(vpic_df)) {
            vpic_df$CRASHIMMINENTBRAKING <- NA_character_
        }
        if (!"FORWARDCOLLISIONWARNING" %in% names(vpic_df)) {
            vpic_df$FORWARDCOLLISIONWARNING <- NA_character_
        }
        veh_attrs <- veh_attrs |>
            dplyr::left_join(
                vpic_df |>
                    dplyr::select(STATE, ST_CASE, VEH_NO,
                        aeb_status = CRASHIMMINENTBRAKING,
                        fcw_status = FORWARDCOLLISIONWARNING
                    ),
                by = c("STATE", "ST_CASE", "VEH_NO")
            )
    } else {
        veh_attrs <- veh_attrs |>
            dplyr::mutate(
                aeb_status = NA_character_,
                fcw_status = NA_character_
            )
    }

    ## Tag fatally-injured persons
    fatal_tagged <- person_df |>
        dplyr::filter(INJ_SEV == 4) |>
        dplyr::left_join(crash_speeding, by = c("STATE", "ST_CASE")) |>
        dplyr::left_join(crash_alcohol, by = "ST_CASE") |>
        dplyr::left_join(crash_weather, by = c("STATE", "ST_CASE")) |>
        dplyr::left_join(veh_attrs, by = c("STATE", "ST_CASE", "VEH_NO")) |>
        dplyr::left_join(state_lookup, by = "STATE") |>
        dplyr::mutate(
            crash_speed_flag = dplyr::if_else(is.na(crash_speed_flag),
                FALSE, crash_speed_flag
            ),
            crash_alc_flag = dplyr::if_else(is.na(crash_alc_flag),
                FALSE, crash_alc_flag
            ),
            crash_alc_p = dplyr::if_else(is.na(crash_alc_p),
                0, crash_alc_p
            ),
            weather_cat = dplyr::if_else(is.na(weather_cat),
                "unknown", weather_cat
            ),
            road_type = dplyr::if_else(is.na(road_type),
                "unknown", road_type
            ),
            unr_flag = fars_is_unprotected(
                PER_TYP, BODY_TYP, REST_USENAME, HELM_USENAME
            ),
            drug_tested = fars_is_drug_tested(DSTATUSNAME),
            age = dplyr::if_else(AGE >= 998, NA_integer_, as.integer(AGE)),
            age_group = as.character(cut(
                age,
                breaks = NCHS_AGE_BREAKS_18,
                labels = NCHS_AGE_LABELS_18,
                right = FALSE,
                include.lowest = TRUE
            )),
            year = y
        ) |>
        dplyr::rename(
            state_fips = STATE,
            st_case = ST_CASE,
            veh_no = VEH_NO,
            per_no = PER_NO,
            per_typ = PER_TYP,
            inj_sev = INJ_SEV,
            body_typ = BODY_TYP,
            sex = SEX,
            hispanic = HISPANIC,
            rest_usename = REST_USENAME,
            helm_usename = HELM_USENAME,
            dstatusname = DSTATUSNAME,
            month = MONTH
        ) |>
        dplyr::select(-AGE) |>
        assign_bin()

    fatal_tagged
}

## Run all years ----
panel_df <- purrr::map_dfr(YEARS, process_year) |>
    dplyr::filter(!state_name %in% c("Puerto Rico", "Virgin Islands")) |>
    dplyr::select(
        year,
        state_fips,
        state_name,
        state_abb,
        st_case,
        veh_no,
        per_no,
        month,
        per_typ,
        inj_sev,
        body_typ,
        age,
        age_group,
        sex,
        hispanic,
        rest_usename,
        helm_usename,
        dstatusname,
        drug_tested,
        mod_year,
        aeb_status,
        fcw_status,
        weather_cat,
        road_type,
        crash_speed_flag,
        crash_alc_p,
        crash_alc_flag,
        unr_flag,
        n_flags,
        bin
    ) |>
    dplyr::arrange(
        year,
        state_name,
        st_case,
        veh_no,
        per_no
    )

## Save ----
arrow::write_parquet(panel_df, OUT_PATH)
