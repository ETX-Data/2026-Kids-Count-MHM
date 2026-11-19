# data-prep/build_data.R
library(tidycensus)
library(dplyr)
library(tidyr)
library(purrr)
library(sf)
library(rmapshaper) # install.packages("rmapshaper") for fast polygon simplification
library(jsonlite)

acs1_year <- 2025
acs5_year <- 2024 # Change to 2025 once it is released

# 1. Helper for Under-18 Race/Ethnicity (B01001B-I)
# NOTE: B01001B-G are race ALONE regardless of ethnicity (they include Hispanic children of that race),
# while B01001H is White alone, non-Hispanic and B01001I is Hispanic/Latino of any race.
# The resulting shares overlap and can sum to more than 100%. A note in docs/index.html explains this to users.
race_tables <- c("B", "C", "D", "E", "F", "G", "H", "I")
u18_cells   <- c("003", "004", "005", "006", "018", "019", "020", "021")
race_vars_u18 <- as.vector(outer(race_tables, u18_cells, function(t, c) paste0("B01001", t, "_", c)))

# For each group, returns the under-18 count (<group>_u18) and the 90% MOE of that count (<group>_u18_moe),
# combining the 8 age-by-sex cells (and, for "other_all", three race tables) with moe_add() (defined below).
# "other_all" = AIAN + NHPI + Some Other Race, the combined group shown in the sidebar.
race_groups <- list(black = "B", aian = "C", asian = "D", nhpi = "E", other = "F",
                    two_more = "G", whitenh = "H", hisp = "I", other_all = c("C", "E", "F"))

# Requested one race table at a time (8 variables each), with retries: one 64-variable request
# often times out on the Census API (Cloudflare error 524)
get_acs_retry <- function(..., tries = 3) {
  for (i in seq_len(tries)) {
    res <- tryCatch(get_acs(...), error = function(e) e)
    if (!inherits(res, "error")) return(res)
    message("  Census API request failed (attempt ", i, " of ", tries, "): ", conditionMessage(res))
    if (i < tries) Sys.sleep(30)
  }
  stop(res)
}

get_race_eth_u18 <- function(geography, survey, year, state = "TX") {
  df <- race_tables %>%
    map(function(t) get_acs_retry(
      survey = survey, state = state, year = year,
      geography = geography, variables = paste0("B01001", t, "_", u18_cells),
      geometry = FALSE, output = "wide"
    )) %>%
    reduce(left_join, by = c("GEOID", "NAME"))
  out <- df[, c("GEOID", "NAME")]
  for (g in names(race_groups)) {
    cells <- as.vector(outer(race_groups[[g]], u18_cells, function(t, c) paste0("B01001", t, "_", c)))
    ests  <- lapply(cells, function(v) df[[paste0(v, "E")]])
    moes  <- lapply(cells, function(v) df[[paste0(v, "M")]])
    out[[paste0(g, "_u18")]]     <- Reduce(`+`, ests)
    out[[paste0(g, "_u18_moe")]] <- moe_add(ests, moes)
  }
  out
}

# 2. Margin-of-error helpers (90% confidence, like all ACS MOEs)
# Census publishes MOEs computed from replicate weights on the full microdata. For indicators with no published
# percentage we approximate them with the formulas Census recommends for data users ("Understanding and Using
# ACS Data", Ch. 8). Checked against the published MOEs for poverty, uninsured, and disability (2020-2024):
# the median ratio is 1.00 in counties and legislative districts; school districts vary more (about 0.8-1.1x).
#
# Census publishes no MOE ("*****", NA here) for population-controlled estimates such as the under-18 count
# in large counties; those have no sampling error, so a missing MOE on a non-missing estimate is treated as 0.
fill_controlled <- function(est, moe) ifelse(is.na(moe) & !is.na(est), 0, moe)

# MOE of a sum of estimates: square root of the sum of squared MOEs. Per Census guidance, when two or more
# of the estimates are zero, only the largest of the zero-estimate MOEs is included.
# Usage: moe_add(list(est1, est2), list(moe1, moe2))
moe_add <- function(ests, moes) {
  E <- do.call(cbind, ests)
  M <- do.call(cbind, Map(fill_controlled, ests, moes))
  zero     <- !is.na(E) & E == 0
  nonzero  <- rowSums(ifelse(zero, 0, M^2))
  zero_max <- apply(ifelse(zero, M, 0), 1, max)
  ifelse(rowSums(is.na(E)) > 0, NA_real_, sqrt(nonzero + zero_max^2))
}

# MOE of a derived proportion (numerator is a subset of denominator), returned in percentage points.
# - When the value under the square root is negative, Census guidance is to use the ratio formula instead.
#   We also use it when the value is exactly zero (e.g., an estimate of 100%), where the proportion formula
#   collapses to an MOE of 0; Census publishes large MOEs in those cases, not 0.
# - Capped at 100 to match Census-published percentage MOEs, which never exceed 100 (they are otherwise not
#   trimmed, so estimate +/- MOE can still fall below 0% or above 100%, as in published tables).
pct_moe <- function(num, den, moe_num, moe_den) {
  moe_num <- fill_controlled(num, moe_num)
  moe_den <- fill_controlled(den, moe_den)
  p     <- num / den
  inner <- moe_num^2 - p^2 * moe_den^2
  moe   <- ifelse(inner <= 0, sqrt(moe_num^2 + p^2 * moe_den^2), sqrt(pmax(inner, 0))) / den
  out   <- pmin(round(moe * 100, 1), 100)
  ifelse(is.finite(out), out, NA_real_)
}

# Published percentage MOEs: fill controlled estimates and apply the same 100-point cap (a no-op on
# current Census data, kept so published and calculated MOEs always follow one rule)
pub_moe <- function(est, moe) pmin(fill_controlled(est, moe), 100)

# 3. Pull and calculate every indicator for one geography level. Used for the substate map layers
# (geometry = TRUE) and for the Texas and U.S. comparison values (geography "state" / "us", with state = NULL
# for the U.S.), so the comparison values are calculated exactly like the map values.
pull_indicators <- function(geo_code, year = acs5_year, state = "TX", geometry = FALSE) {
  race_df <- get_race_eth_u18(geography = geo_code, survey = "acs5", year = year, state = state)

  core_df <- get_acs_retry(
    survey    = "acs5",
    state     = state,
    year      = year,
    geography = geo_code,
    variables = c(
      # Published percentages: where Census publishes the indicator's percentage directly, we use it
      # and its published MOE instead of calculating them (values match our count-based calculations)
      u18_pct       = "S0101_C02_022", # PERCENT of total population under 18
      pov_pct       = "S1701_C03_002", # PERCENT of children under 18 below poverty level
      unins_pct     = "S2701_C05_011", # PERCENT of civilian noninstitutionalized children under 19 uninsured
      dis_pct       = "DP02_0074P",    # PERCENT of civilian noninstitutionalized children under 18 with a disability
      totpop        = "B01003_001",   # Total population
      kids_u18      = "S0101_C01_022", # Children under 18
      kids_u5       = "S0101_C01_002", # Children under 5 (New!)
      kids_5to9     = "S0101_C01_003", # Children 5-9 (age-group pie chart)
      kids_10to14   = "S0101_C01_004", # Children 10-14 (age-group pie chart)
      kids_15to17   = "S0101_C01_021", # Children 15-17 (age-group pie chart)
      dis_total     = "DP02_0074",    # Civilian noninstitutionalized children under 18 with a disability
      dis_univ_u18  = "DP02_0073",    # Civilian noninstitutionalized children under 18 (disability universe)
                                      # (Not C18130: its universe is limited to children whose poverty status is determined)
      pov_u18       = "S1701_C02_002", # Children below 100% FPL
      pov_univ_u18  = "S1701_C01_002", # Children under 18 for whom poverty status is determined (poverty universe)
      occ_u18       = "S0901_C01_035", # Children in occupied housing units (tenure universe)
      ownocc_pct    = "S0901_C01_036", # PERCENT of children in owner-occupied homes (S0901 reports %, not a count)
      rent_pct      = "S0901_C01_037", # PERCENT of children in rented homes (S0901 reports %, not a count)
      fb_boys       = "B05003_005",   # Foreign-born boys
      fb_girls      = "B05003_016",   # Foreign-born girls
      nohcov_u19    = "S2701_C04_011", # Under 19, uninsured
      total_u19     = "S2701_C01_011", # Civilian noninstitutionalized under 19 (insurance universe)
      snap_hh_kids  = "B22002_003",   # HHs receiving SNAP with children under 18 (New!)
      nosnap_hh_kids = "B22002_016",  # HHs NOT receiving SNAP with children under 18
                                      # (denominator = B22002_003 + B22002_016; B22002_002 is all SNAP HHs, not all HHs w/ kids)
      u18_comp_tot  = "B28005_002",   # Total under 18 (computer universe)
      u18_no_net    = "B28005_006",   # Under 18 with computer but no internet
      u18_no_comp   = "B28005_007",   # Under 18 with no computer (New!)
      kids_5to17    = "B16004_002",   # Total children 5-17 (language universe)
      lep_5to17     = "B16003_002",   # Children 5-17 in limited English speaking households
      own_kids_tot  = "B09002_001",   # Own children under 18 in families (family type universe)
      own_male_only = "B09002_009",   # Own children in male householder, no spouse present families
      own_fem_only  = "B09002_015"    # Own children in female householder, no spouse present families
    ),
    geometry = geometry,
    output   = "wide"
  ) %>%
    transmute(
      GEOID, NAME,
      totpop       = totpopE,
      kids_u18     = kids_u18E,
      kids_u5      = kids_u5E,
      kids_u18_moe = fill_controlled(kids_u18E, kids_u18M), # Needed for race/ethnicity MOEs (joined below)
      kids_5to9    = kids_5to9E,
      kids_10to14  = kids_10to14E,
      kids_15to17  = kids_15to17E,
      # Age-group shares of children under 18 (pie chart) and their calculated 90% MOEs
      pct_age_5to9       = round(kids_5to9E / kids_u18E * 100, 1),
      pct_age_10to14     = round(kids_10to14E / kids_u18E * 100, 1),
      pct_age_15to17     = round(kids_15to17E / kids_u18E * 100, 1),
      pct_age_5to9_moe   = pct_moe(kids_5to9E, kids_u18E, kids_5to9M, kids_u18M),
      pct_age_10to14_moe = pct_moe(kids_10to14E, kids_u18E, kids_10to14M, kids_u18M),
      pct_age_15to17_moe = pct_moe(kids_15to17E, kids_u18E, kids_15to17M, kids_u18M),
      dis_total    = dis_totalE,
      dis_univ_u18 = dis_univ_u18E,
      pov_u18      = pov_u18E,
      pov_univ_u18 = pov_univ_u18E,
      # Derive child counts from the S0901 percentages
      ownocc_u18   = round(ownocc_pctE / 100 * occ_u18E),
      rent_u18     = round(rent_pctE / 100 * occ_u18E),
      pct_ownocc   = ownocc_pctE,
      pct_ownocc_moe = pub_moe(ownocc_pctE, ownocc_pctM), # Published MOE (not currently displayed)
      pct_rent     = rent_pctE,
      pct_rent_moe = pub_moe(rent_pctE, rent_pctM),       # Published MOE (not currently displayed)
      fb_u18       = fb_boysE + fb_girlsE,
      nohcov_u19   = nohcov_u19E,
      total_u19    = total_u19E,
      snap_hh_kids = snap_hh_kidsE,
      tot_hh_kids  = snap_hh_kidsE + nosnap_hh_kidsE, # All HHs with children under 18
      u18_no_comp  = u18_no_compE,
      u18_no_net   = u18_no_netE + u18_no_compE,
      u18_comp_tot = u18_comp_totE,
      kids_5to17   = kids_5to17E,
      lep_5to17    = lep_5to17E,
      own_kids_tot = own_kids_totE,
      # Single-parent = own children (biological, adopted, step) of a householder with no spouse present.
      # Matches the national KIDS COUNT definition: an unmarried partner may be present.
      single_par_u18 = own_male_onlyE + own_fem_onlyE,
      # Published percentages and their published 90% MOEs (see pub_moe() above)
      pct_u18            = u18_pctE,
      pct_u18_moe        = pub_moe(u18_pctE, u18_pctM),
      pct_pov            = pov_pctE,
      pct_pov_moe        = pub_moe(pov_pctE, pov_pctM),
      pct_nohcov         = unins_pctE,
      pct_nohcov_moe     = pub_moe(unins_pctE, unins_pctM),
      pct_dis            = dis_pctE,
      pct_dis_moe        = pub_moe(dis_pctE, dis_pctM),
      # Calculated 90% MOEs (percentage points) for indicators with no published percentage, named <indicator id>_moe
      pct_snap_hh_moe    = pct_moe(snap_hh_kidsE, snap_hh_kidsE + nosnap_hh_kidsE, snap_hh_kidsM,
                                   moe_add(list(snap_hh_kidsE, nosnap_hh_kidsE), list(snap_hh_kidsM, nosnap_hh_kidsM))),
      pct_u5_moe         = pct_moe(kids_u5E, kids_u18E, kids_u5M, kids_u18M),
      pct_lep_5to17_moe  = pct_moe(lep_5to17E, kids_5to17E, lep_5to17M, kids_5to17M),
      pct_fb_u18_moe     = pct_moe(fb_boysE + fb_girlsE, kids_u18E,
                                   moe_add(list(fb_boysE, fb_girlsE), list(fb_boysM, fb_girlsM)), kids_u18M),
      pct_single_par_moe = pct_moe(own_male_onlyE + own_fem_onlyE, own_kids_totE,
                                   moe_add(list(own_male_onlyE, own_fem_onlyE), list(own_male_onlyM, own_fem_onlyM)),
                                   own_kids_totM),
      pct_no_net_moe     = pct_moe(u18_no_netE + u18_no_compE, u18_comp_totE,
                                   moe_add(list(u18_no_netE, u18_no_compE), list(u18_no_netM, u18_no_compM)),
                                   u18_comp_totM)
      # (sf keeps the geometry column automatically when geometry = TRUE)
    ) %>%
    left_join(race_df, by = c("GEOID", "NAME")) %>%
    mutate(
      # pct_u18, pct_pov, pct_nohcov, and pct_dis are published percentages (set above), not calculated here
      pct_u5          = round((kids_u5 / kids_u18) * 100, 1),
      pct_blacku18    = round((black_u18 / kids_u18) * 100, 1),
      pct_otheru18    = round(((aian_u18 + nhpi_u18 + other_u18) / kids_u18) * 100, 1),
      pct_asianu18    = round((asian_u18 / kids_u18) * 100, 1),
      pct_two_moreu18 = round((two_more_u18 / kids_u18) * 100, 1),
      pct_whitenhu18  = round((whitenh_u18 / kids_u18) * 100, 1),
      pct_hispu18     = round((hisp_u18 / kids_u18) * 100, 1),
      # Calculated 90% MOEs for the race/ethnicity shares (sidebar bar chart)
      pct_blacku18_moe    = pct_moe(black_u18, kids_u18, black_u18_moe, kids_u18_moe),
      pct_otheru18_moe    = pct_moe(other_all_u18, kids_u18, other_all_u18_moe, kids_u18_moe),
      pct_asianu18_moe    = pct_moe(asian_u18, kids_u18, asian_u18_moe, kids_u18_moe),
      pct_two_moreu18_moe = pct_moe(two_more_u18, kids_u18, two_more_u18_moe, kids_u18_moe),
      pct_whitenhu18_moe  = pct_moe(whitenh_u18, kids_u18, whitenh_u18_moe, kids_u18_moe),
      pct_hispu18_moe     = pct_moe(hisp_u18, kids_u18, hisp_u18_moe, kids_u18_moe),
      pct_fb_u18      = round((fb_u18 / kids_u18) * 100, 1),
      pct_snap_hh     = round((snap_hh_kids / tot_hh_kids) * 100, 1),
      pct_no_comp     = round((u18_no_comp / u18_comp_tot) * 100, 1),
      pct_no_net      = round((u18_no_net / u18_comp_tot) * 100, 1),
      pct_lep_5to17   = round((lep_5to17 / kids_5to17) * 100, 1),
      pct_single_par  = round((single_par_u18 / own_kids_tot) * 100, 1)
    )

  if (inherits(core_df, "sf")) st_transform(core_df, 4326) else core_df # Standard WGS84 for MapLibre web maps
}

# Non-ACS data from clean_external.R: data-prep/clean_data/*_<slug>.csv, joined by GEOID
merge_external <- function(df, slug) {
  for (f in list.files("data-prep/clean_data", paste0("_", slug, "\\.csv$"), full.names = TRUE)) {
    ext <- read.csv(f, colClasses = c(GEOID = "character")) %>% select(-any_of("NAME"))
    df <- left_join(select(df, -any_of(setdiff(names(ext), "GEOID"))), ext, by = "GEOID")
  }
  df
}

# 4. Substate Pull + Simplification + Export to GeoJSON
export_geography_geojson <- function(geo_code, file_slug, year = acs5_year) {
  message("Pulling ", file_slug, "...")
  core_df <- pull_indicators(geo_code, year = year, geometry = TRUE)

  core_df <- merge_external(core_df, file_slug)

  # Simplify geometry to shrink file size by ~90% for instant loading on GitHub Pages
  simplified_sf <- ms_simplify(core_df, keep = 0.05, keep_shapes = TRUE)
  
  dir.create("docs/data", recursive = TRUE, showWarnings = FALSE)
  out_path <- paste0("docs/data/", file_slug, ".geojson")
  if (file.exists(out_path)) file.remove(out_path)
  st_write(simplified_sf, out_path, driver = "GeoJSON", quiet = TRUE)
}

# 5. Texas and U.S. comparison values (sidebar comparison lines, significance arrows, CSV download)
# Written to docs/data/benchmarks.json as {"texas": {...}, "us": {...}} with the same field names as the map layers.
export_benchmarks <- function(year = acs5_year) {
  message("Pulling Texas and U.S. comparison values...")
  tx <- merge_external(pull_indicators("state", year = year, state = "TX"), "counties")
  us <- merge_external(pull_indicators("us", year = year, state = NULL), "counties")
  out <- list(texas = as.list(tx[1, ]), us = as.list(us[1, ]))
  write_json(out, "docs/data/benchmarks.json", auto_unbox = TRUE, digits = NA, na = "null", pretty = TRUE)
}

# 6. City and ZIP code search lookup (docs/data/places.json)
# Uses Census Gazetteer internal points: the dashboard selects the map area that contains a city's or ZIP
# code's (ZCTA's) internal point. Places are Texas incorporated places and CDPs (shown as "community").
# Texas ZCTAs are the ones starting with 75-79, 733, or 885.
gazetteer_year <- 2024
read_gazetteer <- function(file) {
  url <- sprintf("https://www2.census.gov/geo/docs/maps-data/data/gazetteer/%d_Gazetteer/%d_%s.zip",
                 gazetteer_year, gazetteer_year, file)
  zip <- tempfile(fileext = ".zip")
  download.file(url, zip, mode = "wb", quiet = TRUE)
  df <- read.delim(unz(zip, unzip(zip, list = TRUE)$Name[1]), colClasses = "character", check.names = FALSE)
  names(df) <- trimws(names(df))
  df
}

export_search_places <- function() {
  message("Building city and ZIP code search lookup...")
  places <- read_gazetteer("Gaz_place_national") %>%
    filter(USPS == "TX") %>%
    mutate(
      type  = sub("^.* (city|town|village|CDP)$", "\\1", NAME),
      base  = sub(" (city|town|village|CDP)$", "", NAME),
      label = paste0(base, " (", ifelse(type == "CDP", "community", type), ")"),
      lon   = round(as.numeric(INTPTLONG), 5),
      lat   = round(as.numeric(INTPTLAT), 5)
    ) %>%
    arrange(label)
  zips <- read_gazetteer("Gaz_zcta_national") %>%
    filter(grepl("^(7[5-9]|733|885)", GEOID)) %>%
    mutate(lon = round(as.numeric(INTPTLONG), 5), lat = round(as.numeric(INTPTLAT), 5))
  out <- list(
    places = unname(Map(function(l, x, y) list(l, x, y), places$label, places$lon, places$lat)),
    zips   = setNames(Map(function(x, y) c(x, y), zips$lon, zips$lat), zips$GEOID)
  )
  write_json(out, "docs/data/places.json", auto_unbox = TRUE, digits = NA)
}

dir.create("docs/data", recursive = TRUE, showWarnings = FALSE)
export_benchmarks()
export_search_places()

# Run and export all 4 map layers into docs/data/
export_geography_geojson("county", "counties")
export_geography_geojson("state legislative district (lower chamber)", "house")
export_geography_geojson("state legislative district (upper chamber)", "senate")
export_geography_geojson("school district (unified)", "schools")
