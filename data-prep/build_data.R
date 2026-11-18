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

# 2. Substate Pull + Simplification + Export to GeoJSON
export_geography_geojson <- function(geo_code, file_slug, year = acs5_year) {
  message("Pulling ", file_slug, "...")
  
  race_df <- get_race_eth_u18(geography = geo_code, survey = "acs5", year = year)
  
  core_df <- get_acs(
    survey    = "acs5",
    state     = "TX",
    year      = year,
    geography = geo_code,
    variables = c(
      totpop        = "B01003_001",   # Total population
      kids_u18      = "S0101_C01_022", # Children under 18
      kids_u5       = "S0101_C01_002", # Children under 5 (New!)
      dis_total     = "C18130_003",   # Children with disabilities
      dis_univ_u18  = "C18130_002",   # Children under 18, civilian noninstitutionalized (disability universe)
      pov_u18       = "S1701_C02_002", # Children below 100% FPL
      pov_univ_u18  = "S1701_C01_002", # Children under 18 for whom poverty status is determined (poverty universe)
      occ_u18       = "S0901_C01_035", # Children in occupied housing units (tenure universe)
      ownocc_pct    = "S0901_C01_036", # PERCENT of children in owner-occupied homes (S0901 reports %, not a count)
      rent_pct      = "S0901_C01_037", # PERCENT of children in rented homes (S0901 reports %, not a count)
      FB_boys       = "B05003_005",   # Foreign-born boys
      FB_girls      = "B05003_016",   # Foreign-born girls
      noHcov_u19    = "B27010_017",   # Under 19, uninsured
      total_u19     = "B27010_002",   # Total under 19 (insurance universe)
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
      pct_rent     = rent_pctE,
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
      geometry
    ) %>%
    left_join(race_df, by = c("GEOID", "NAME")) %>%
    mutate(
      pct_u18         = round((kids_u18 / totpop) * 100, 1),
      pct_u5          = round((kids_u5 / kids_u18) * 100, 1),
      pct_dis         = round((dis_total / dis_univ_u18) * 100, 1),
      pct_blacku18    = round((black_u18 / kids_u18) * 100, 1),
      pct_otheru18    = round(((AIAN_u18 + NHPI_u18 + other_u18) / kids_u18) * 100, 1),
      pct_asianu18    = round((asian_u18 / kids_u18) * 100, 1),
      pct_two_moreu18 = round((two_more_u18 / kids_u18) * 100, 1),
      pct_whiteNHu18  = round((whiteNH_u18 / kids_u18) * 100, 1),
      pct_Hispu18     = round((hisp_u18 / kids_u18) * 100, 1),
      pct_pov         = round((pov_u18 / pov_univ_u18) * 100, 1),
      pct_FB_u18      = round((FB_u18 / kids_u18) * 100, 1),
      pct_noHcov      = round((noHcov_u19 / total_u19) * 100, 1),
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
