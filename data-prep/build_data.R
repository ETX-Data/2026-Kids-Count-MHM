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
# NOTE: B-G incl. Hispanic kids, so shares overlap & can sum >100% (explained in index.html)
race_tables <- c("B", "C", "D", "E", "F", "G", "H", "I")
u18_cells   <- c("003", "004", "005", "006", "018", "019", "020", "021")
race_vars_u18 <- as.vector(outer(race_tables, u18_cells, function(t, c) paste0("B01001", t, "_", c)))

# Each group -> <group>_u18 count + <group>_u18_moe; other_all = AIAN + NHPI + other (sidebar group)
race_groups <- list(black = "B", aian = "C", asian = "D", nhpi = "E", other = "F",
                    two_more = "G", whitenh = "H", hisp = "I", other_all = c("C", "E", "F"))

# Retry wrapper b/c big Census API pulls sometimes time out (error 524)
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
  # Pull one race table at a time to avoid timeouts
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

# 2. MOE helpers (90% CI), using Census formulas from "Understanding and Using ACS Data" Ch. 8
# https://www.census.gov/content/dam/Census/library/publications/2020/acs/acs_general_handbook_2020.pdf 

# Controlled estimates have no MOE (NA) b/c no sampling error, so treat as 0
fill_controlled <- function(est, moe) ifelse(is.na(moe) & !is.na(est), 0, moe)

# MOE of a sum (only the largest zero-est MOE counts). Usage: moe_add(list(e1, e2), list(m1, m2))
moe_add <- function(ests, moes) {
  E <- do.call(cbind, ests)
  M <- do.call(cbind, Map(fill_controlled, ests, moes))
  zero     <- !is.na(E) & E == 0
  nonzero  <- rowSums(ifelse(zero, 0, M^2))
  zero_max <- apply(ifelse(zero, M, 0), 1, max)
  ifelse(rowSums(is.na(E)) > 0, NA_real_, sqrt(nonzero + zero_max^2))
}

# MOE of a proportion in pct pts (falls back to ratio formula if sqrt term <= 0; capped at 100)
pct_moe <- function(num, den, moe_num, moe_den) {
  moe_num <- fill_controlled(num, moe_num)
  moe_den <- fill_controlled(den, moe_den)
  p     <- num / den
  inner <- moe_num^2 - p^2 * moe_den^2
  moe   <- ifelse(inner <= 0, sqrt(moe_num^2 + p^2 * moe_den^2), sqrt(pmax(inner, 0))) / den
  out   <- pmin(round(moe * 100, 1), 100)
  ifelse(is.finite(out), out, NA_real_)
}

# Published pct MOEs, same rules as above
pub_moe <- function(est, moe) pmin(fill_controlled(est, moe), 100)

# 3. Indicators built from summed ACS cells
extra_cells <- list(
  pov50_u18    = sprintf("B17024_%03d", c(3, 16, 29)),                  # Kids < 50% FPL (extreme poverty)
  pov200_u18   = sprintf("B17024_%03d", c(3:10, 16:23, 29:36)),         # Kids < 200% FPL (low-income)
  pov_univ_b   = sprintf("B17024_%03d", c(2, 15, 28)),                  # Kids under 6 + 6-11 + 12-17 (poverty universe)
  nolf_par_u18 = sprintf("B23008_%03d", c(7, 11, 14, 20, 24, 27)),      # Own kids w/ no parent in labor force
  own_kids_lf  = "B23008_001",                                          # Own kids in families (B23008 universe)
  idle_16to19  = sprintf("B14005_%03d", c(10, 11, 14, 15, 24, 25, 28, 29)), # Teens not enrolled + unemployed/not in LF
  teens_16to19 = "B14005_001",                                          # Teens 16-19
  imm_fam_u18  = sprintf("B05009_%03d", c(7, 10, 17, 25, 28, 35)),      # Own kids w/ at least 1 foreign-born parent
  own_kids_nat = "B05009_001",                                          # Own kids in families (B05009 universe)
  grand_u18    = "B09018_006",                                          # Kids who are the householder's grandchild
  kids_hh_rel  = "B09018_001",                                          # Kids in households (B09018 universe)
  rent_hh_kids = "B25012_011",                                          # Renter HHs w/ related kids
  hh_kids_ten  = c("B25012_003", "B25012_011")                          # Owner + renter HHs w/ related kids
)
# Rate id -> c(numerator, denominator) from extra_cells
extra_rates <- list(
  pct_pov50       = c("pov50_u18", "pov_univ_b"),
  pct_pov200      = c("pov200_u18", "pov_univ_b"),
  pct_nolf_par    = c("nolf_par_u18", "own_kids_lf"),
  pct_idle_teens  = c("idle_16to19", "teens_16to19"),
  pct_imm_fam     = c("imm_fam_u18", "own_kids_nat"),
  pct_grand       = c("grand_u18", "kids_hh_rel"),
  pct_rent_hh     = c("rent_hh_kids", "hh_kids_ten")
)

get_extra_indicators <- function(geography, year, state = "TX") {
  df <- get_acs_retry(survey = "acs5", state = state, year = year, geography = geography,
                      variables = unique(unlist(extra_cells)), geometry = FALSE, output = "wide")
  out <- df[, c("GEOID", "NAME")]
  moes <- list()
  for (g in names(extra_cells)) {
    ests <- lapply(extra_cells[[g]], function(v) df[[paste0(v, "E")]])
    out[[g]] <- Reduce(`+`, ests)
    moes[[g]] <- moe_add(ests, lapply(extra_cells[[g]], function(v) df[[paste0(v, "M")]]))
  }
  for (r in names(extra_rates)) {
    n <- extra_rates[[r]][1]; d <- extra_rates[[r]][2]
    out[[r]] <- round(out[[n]] / out[[d]] * 100, 1)
    out[[paste0(r, "_moe")]] <- pct_moe(out[[n]], out[[d]], moes[[n]], moes[[d]])
  }
  out
}

# 4. Pull + calc all indicators for one geography (map layers, TX & US)
pull_indicators <- function(geo_code, year = acs5_year, state = "TX", geometry = FALSE) {
  race_df  <- get_race_eth_u18(geography = geo_code, survey = "acs5", year = year, state = state)
  extra_df <- get_extra_indicators(geography = geo_code, year = year, state = state)

  core_df <- get_acs_retry(
    survey    = "acs5",
    state     = state,
    year      = year,
    geography = geo_code,
    variables = c(
      # Published %s (use these + their MOEs when available)
      u18_pct       = "S0101_C02_022", # % of total pop under 18
      pov_pct       = "S1701_C03_002", # % of kids below poverty
      unins_pct     = "S2701_C05_011", # % of kids under 19 uninsured
      dis_pct       = "DP02_0074P",    # % of kids with a disability
      totpop        = "B01003_001",   # Total population
      kids_u18      = "S0101_C01_022", # Children under 18
      kids_u5       = "S0101_C01_002", # Children under 5 (New!)
      kids_5to9     = "S0101_C01_003", # Kids 5-9 (pie chart)
      kids_10to14   = "S0101_C01_004", # Kids 10-14 (pie chart)
      kids_15to17   = "S0101_C01_021", # Kids 15-17 (pie chart)
      dis_total     = "DP02_0074",    # Children with disabilities
      dis_univ_u18  = "DP02_0073",    # Disability universe (not C18130, which is poverty-limited)
      pov_u18       = "S1701_C02_002", # Children below 100% FPL
      pov_univ_u18  = "S1701_C01_002", # Poverty universe
      mcaid_pct     = "S2704_C03_007", # % of kids under 19 w/ Medicaid/means-tested coverage
      mcaid_u19     = "S2704_C02_007", # Kids under 19 w/ Medicaid/means-tested coverage
      fb_boys       = "B05003_005",   # Foreign-born boys
      fb_girls      = "B05003_016",   # Foreign-born girls
      nohcov_u19    = "S2701_C04_011", # Under 19, uninsured
      total_u19     = "S2701_C01_011", # Total under 19 (insurance universe)
      snap_hh_kids  = "B22002_003",   # HHs receiving SNAP with children under 18 (New!)
      nosnap_hh_kids = "B22002_016",  # HHs NOT receiving SNAP w/ kids (added to above for denom)
      u18_comp_tot  = "B28005_002",   # Total under 18 (computer universe)
      u18_no_net    = "B28005_006",   # Under 18 with computer but no internet
      u18_no_comp   = "B28005_007",   # Under 18 with no computer (New!)
      kids_5to17    = "B16004_002",   # Kids 5-17 (language universe)
      lep_5to17     = "B16003_002",   # Kids 5-17 in limited English HHs
      own_kids_tot  = "B09002_001",   # Own kids in families (family type universe)
      own_male_only = "B09002_009",   # Own kids, single dad HH
      own_fem_only  = "B09002_015",   # Own kids, single mom HH
      kids_3to4     = "B09001_004"    # Kids 3-4 in households (Pre-K denominator)
    ),
    geometry = geometry,
    output   = "wide"
  ) %>%
    transmute(
      GEOID, NAME,
      totpop       = totpopE,
      kids_u18     = kids_u18E,
      kids_u5      = kids_u5E,
      kids_u18_moe = fill_controlled(kids_u18E, kids_u18M), # For race/eth MOEs
      kids_5to9    = kids_5to9E,
      kids_10to14  = kids_10to14E,
      kids_15to17  = kids_15to17E,
      kids_3to4    = kids_3to4E,
      kids_3to4_moe = fill_controlled(kids_3to4E, kids_3to4M), # For Pre-K rate MOE
      # Age-group shares + MOEs (pie chart)
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
      mcaid_u19    = mcaid_u19E,
      fb_u18       = fb_boysE + fb_girlsE,
      nohcov_u19   = nohcov_u19E,
      total_u19    = total_u19E,
      snap_hh_kids = snap_hh_kidsE,
      tot_hh_kids  = snap_hh_kidsE + nosnap_hh_kidsE, # All HHs w/ kids
      u18_no_comp  = u18_no_compE,
      u18_no_net   = u18_no_netE + u18_no_compE,
      u18_comp_tot = u18_comp_totE,
      kids_5to17   = kids_5to17E,
      lep_5to17    = lep_5to17E,
      own_kids_tot = own_kids_totE,
      single_par_u18 = own_male_onlyE + own_fem_onlyE, # Same as national KIDS COUNT def
      # Published %s + MOEs
      pct_u18            = u18_pctE,
      pct_u18_moe        = pub_moe(u18_pctE, u18_pctM),
      pct_pov            = pov_pctE,
      pct_pov_moe        = pub_moe(pov_pctE, pov_pctM),
      pct_nohcov         = unins_pctE,
      pct_nohcov_moe     = pub_moe(unins_pctE, unins_pctM),
      pct_dis            = dis_pctE,
      pct_dis_moe        = pub_moe(dis_pctE, dis_pctM),
      pct_mcaid          = mcaid_pctE,
      pct_mcaid_moe      = pub_moe(mcaid_pctE, mcaid_pctM),
      # Calculated MOEs for the rest
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
    ) %>%
    left_join(race_df, by = c("GEOID", "NAME")) %>%
    left_join(extra_df, by = c("GEOID", "NAME")) %>%
    mutate(
      pct_u5         = round((kids_u5 / kids_u18) * 100, 1),
      pct_blacku18    = round((black_u18 / kids_u18) * 100, 1),
      pct_otheru18    = round(((aian_u18 + nhpi_u18 + other_u18) / kids_u18) * 100, 1),
      pct_asianu18    = round((asian_u18 / kids_u18) * 100, 1),
      pct_two_moreu18 = round((two_more_u18 / kids_u18) * 100, 1),
      pct_whitenhu18  = round((whitenh_u18 / kids_u18) * 100, 1),
      pct_hispu18     = round((hisp_u18 / kids_u18) * 100, 1),
      # Race/eth MOEs (bar chart)
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

# Pre-K rate = TEA count / ACS kids 3-4. MOE is from the ACS denom only; > 100% -> NA
add_prek_rate <- function(df) {
  if (!all(c("prek_n", "kids_3to4_moe") %in% names(df))) return(df)
  df %>% mutate(
    pct_prek     = round(prek_n / kids_3to4 * 100, 1),
    pct_prek_moe = ifelse(pct_prek > 100, NA, pct_moe(prek_n, kids_3to4, 0, kids_3to4_moe)),
    pct_prek     = ifelse(pct_prek > 100, NA, pct_prek)
  )
}

# Merge non-ACS CSVs from clean_external.R by GEOID
merge_external <- function(df, slug) {
  for (f in list.files("data-prep/clean_data", paste0("_", slug, "\\.csv$"), full.names = TRUE)) {
    ext <- read.csv(f, colClasses = c(GEOID = "character")) %>% select(-any_of("NAME"))
    df <- left_join(select(df, -any_of(setdiff(names(ext), "GEOID"))), ext, by = "GEOID")
  }
  add_prek_rate(df)
}

# 5. Substate Pull + Simplification + Export to GeoJSON
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

# 6. TX & US comparison values -> benchmarks.json
export_benchmarks <- function(year = acs5_year) {
  message("Pulling Texas and U.S. comparison values...")
  tx <- merge_external(pull_indicators("state", year = year, state = "TX"), "counties")
  us <- merge_external(pull_indicators("us", year = year, state = NULL), "counties")
  out <- list(texas = as.list(tx[1, ]), us = as.list(us[1, ]))
  write_json(out, "docs/data/benchmarks.json", auto_unbox = TRUE, digits = NA, na = "null", pretty = TRUE)
}

# 7. City & ZIP search lookup -> places.json (uses Census Gazetteer points)
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
  places <- read_gazetteer("Gaz_place_national") %>% # CDPs shown as "community"
    filter(USPS == "TX") %>%
    mutate(
      type  = sub("^.* (city|town|village|CDP)$", "\\1", NAME),
      base  = sub(" (city|town|village|CDP)$", "", NAME),
      label = paste0(base, " (", ifelse(type == "CDP", "community", type), ")"),
      lon   = round(as.numeric(INTPTLONG), 5),
      lat   = round(as.numeric(INTPTLAT), 5)
    ) %>%
    arrange(label)
  zips <- read_gazetteer("Gaz_zcta_national") %>% # TX ZIPs start w/ 75-79, 733, 885
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
