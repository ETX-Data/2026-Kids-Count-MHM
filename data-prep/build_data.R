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

get_race_eth_u18 <- function(geography, survey, year) {
  get_acs(
    survey = survey, state = "TX", year = year,
    geography = geography, variables = race_vars_u18,
    geometry = FALSE, output = "wide"
  ) %>%
    mutate(
      black_u18    = B01001B_003E + B01001B_004E + B01001B_005E + B01001B_006E + B01001B_018E + B01001B_019E + B01001B_020E + B01001B_021E,
      AIAN_u18     = B01001C_003E + B01001C_004E + B01001C_005E + B01001C_006E + B01001C_018E + B01001C_019E + B01001C_020E + B01001C_021E,
      asian_u18    = B01001D_003E + B01001D_004E + B01001D_005E + B01001D_006E + B01001D_018E + B01001D_019E + B01001D_020E + B01001D_021E,
      NHPI_u18     = B01001E_003E + B01001E_004E + B01001E_005E + B01001E_006E + B01001E_018E + B01001E_019E + B01001E_020E + B01001E_021E,
      other_u18    = B01001F_003E + B01001F_004E + B01001F_005E + B01001F_006E + B01001F_018E + B01001F_019E + B01001F_020E + B01001F_021E,
      two_more_u18 = B01001G_003E + B01001G_004E + B01001G_005E + B01001G_006E + B01001G_018E + B01001G_019E + B01001G_020E + B01001G_021E,
      whiteNH_u18  = B01001H_003E + B01001H_004E + B01001H_005E + B01001H_006E + B01001H_018E + B01001H_019E + B01001H_020E + B01001H_021E,
      hisp_u18     = B01001I_003E + B01001I_004E + B01001I_005E + B01001I_006E + B01001I_018E + B01001I_019E + B01001I_020E + B01001I_021E
    ) %>%
    select(GEOID, NAME, ends_with("_u18"))
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

# 3. Substate Pull + Simplification + Export to GeoJSON
export_geography_geojson <- function(geo_code, file_slug, year = acs5_year) {
  message("Pulling ", file_slug, "...")
  
  race_df <- get_race_eth_u18(geography = geo_code, survey = "acs5", year = year)
  
  core_df <- get_acs(
    survey    = "acs5",
    state     = "TX",
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
      dis_total     = "DP02_0074",    # Civilian noninstitutionalized children under 18 with a disability
      dis_univ_u18  = "DP02_0073",    # Civilian noninstitutionalized children under 18 (disability universe)
                                      # (Not C18130: its universe is limited to children whose poverty status is determined)
      pov_u18       = "S1701_C02_002", # Children below 100% FPL
      pov_univ_u18  = "S1701_C01_002", # Children under 18 for whom poverty status is determined (poverty universe)
      occ_u18       = "S0901_C01_035", # Children in occupied housing units (tenure universe)
      ownocc_pct    = "S0901_C01_036", # PERCENT of children in owner-occupied homes (S0901 reports %, not a count)
      rent_pct      = "S0901_C01_037", # PERCENT of children in rented homes (S0901 reports %, not a count)
      FB_boys       = "B05003_005",   # Foreign-born boys
      FB_girls      = "B05003_016",   # Foreign-born girls
      noHcov_u19    = "S2701_C04_011", # Under 19, uninsured
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
    geometry = TRUE,
    output   = "wide"
  ) %>%
    transmute(
      GEOID, NAME,
      totpop       = totpopE,
      kids_u18     = kids_u18E,
      kids_u5      = kids_u5E,
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
      FB_u18       = FB_boysE + FB_girlsE,
      noHcov_u19   = noHcov_u19E,
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
      pct_noHcov         = unins_pctE,
      pct_noHcov_moe     = pub_moe(unins_pctE, unins_pctM),
      pct_dis            = dis_pctE,
      pct_dis_moe        = pub_moe(dis_pctE, dis_pctM),
      # Calculated 90% MOEs (percentage points) for indicators with no published percentage, named <indicator id>_moe
      pct_snap_hh_moe    = pct_moe(snap_hh_kidsE, snap_hh_kidsE + nosnap_hh_kidsE, snap_hh_kidsM,
                                   moe_add(list(snap_hh_kidsE, nosnap_hh_kidsE), list(snap_hh_kidsM, nosnap_hh_kidsM))),
      pct_u5_moe         = pct_moe(kids_u5E, kids_u18E, kids_u5M, kids_u18M),
      pct_lep_5to17_moe  = pct_moe(lep_5to17E, kids_5to17E, lep_5to17M, kids_5to17M),
      pct_FB_u18_moe     = pct_moe(FB_boysE + FB_girlsE, kids_u18E,
                                   moe_add(list(FB_boysE, FB_girlsE), list(FB_boysM, FB_girlsM)), kids_u18M),
      pct_single_par_moe = pct_moe(own_male_onlyE + own_fem_onlyE, own_kids_totE,
                                   moe_add(list(own_male_onlyE, own_fem_onlyE), list(own_male_onlyM, own_fem_onlyM)),
                                   own_kids_totM),
      pct_no_net_moe     = pct_moe(u18_no_netE + u18_no_compE, u18_comp_totE,
                                   moe_add(list(u18_no_netE, u18_no_compE), list(u18_no_netM, u18_no_compM)),
                                   u18_comp_totM),
      geometry
    ) %>%
    left_join(race_df, by = c("GEOID", "NAME")) %>%
    mutate(
      # pct_u18, pct_pov, pct_noHcov, and pct_dis are published percentages (set above), not calculated here
      pct_u5          = round((kids_u5 / kids_u18) * 100, 1),
      pct_blacku18    = round((black_u18 / kids_u18) * 100, 1),
      pct_otheru18    = round(((AIAN_u18 + NHPI_u18 + other_u18) / kids_u18) * 100, 1),
      pct_asianu18    = round((asian_u18 / kids_u18) * 100, 1),
      pct_two_moreu18 = round((two_more_u18 / kids_u18) * 100, 1),
      pct_whiteNHu18  = round((whiteNH_u18 / kids_u18) * 100, 1),
      pct_Hispu18     = round((hisp_u18 / kids_u18) * 100, 1),
      pct_FB_u18      = round((FB_u18 / kids_u18) * 100, 1),
      pct_snap_hh     = round((snap_hh_kids / tot_hh_kids) * 100, 1),
      pct_no_comp     = round((u18_no_comp / u18_comp_tot) * 100, 1),
      pct_no_net      = round((u18_no_net / u18_comp_tot) * 100, 1),
      pct_lep_5to17   = round((lep_5to17 / kids_5to17) * 100, 1),
      pct_single_par  = round((single_par_u18 / own_kids_tot) * 100, 1)
    ) %>%
    st_transform(4326) # Standard WGS84 for MapLibre web maps

  # OPTIONAL HOOK: Merge non-ACS CSV data (TEA STAAR, Feeding America, TX HHS) by GEOID!
  # if (file.exists(paste0("data-prep/external_", file_slug, ".csv"))) {
  #   ext_df <- read.csv(paste0("data-prep/external_", file_slug, ".csv"), colClasses = c(GEOID = "character"))
  #   core_df <- left_join(core_df, ext_df, by = "GEOID")
  # }

  # Simplify geometry to shrink file size by ~90% for instant loading on GitHub Pages
  simplified_sf <- ms_simplify(core_df, keep = 0.05, keep_shapes = TRUE)
  
  dir.create("docs/data", recursive = TRUE, showWarnings = FALSE)
  out_path <- paste0("docs/data/", file_slug, ".geojson")
  if (file.exists(out_path)) file.remove(out_path)
  st_write(simplified_sf, out_path, driver = "GeoJSON", quiet = TRUE)
}

# Run and export all 4 map layers into docs/data/
export_geography_geojson("county", "counties")
export_geography_geojson("state legislative district (lower chamber)", "house")
export_geography_geojson("state legislative district (upper chamber)", "senate")
export_geography_geojson("school district (unified)", "schools")
