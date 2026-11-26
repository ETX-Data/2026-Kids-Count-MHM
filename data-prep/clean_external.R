# data-prep/clean_external.R
# Cleans non-ACS data (original_data -> clean_data/<indicator>_<geography>.csv)
# GEOID "48" = TX, "1" = US
library(dplyr)
library(tidyr)
library(readr)
library(readxl)
library(jsonlite)
library(sf)

raw <- "data-prep/original_data"

# County name matching helpers
key <- function(x) gsub("[^A-Z]", "", sub(" COUNTY$", "", toupper(x)))
tx_counties <- tidycensus::fips_codes %>%
  filter(state == "TX") %>%
  transmute(GEOID = paste0("48", county_code), NAME = sub(" County$", "", county), key = key(county))

to_num <- function(x) suppressWarnings(parse_number(ifelse(x %in% c("-1", "-2", "-3", "."), NA, x))) # Suppressed -> NA

join_counties <- function(df) {
  out <- inner_join(tx_counties, df, by = "key") %>% select(-key)
  miss <- setdiff(df$key, tx_counties$key)
  if (length(miss)) message("Unmatched county names: ", paste(miss, collapse = ", "))
  out
}

# TEA 4-yr grad rate, class of 2025 (federal calc)
tea_c <- read_excel(file.path(raw, "county-data-download-4yr-2025.xlsx"), "Comp_2025_4yr", col_types = "text") %>%
  transmute(key = key(CNTYNAME), grad_cohort = to_num(CNTY_ALLD), grad_n = to_num(CNTY_ALLN_GRAD),
            pct_grad = to_num(CNTY_ALLR_GRAD)) %>%
  join_counties()
# TX: https://rptsvr1.tea.texas.gov/acctres/completion/2025/state.html
# US (2022-23, NCES): https://www.americashealthrankings.org/explore/measures/Graduation_A
tea_c <- bind_rows(tibble(GEOID = c("1", "48"), NAME = c("United States", "Texas"), grad_cohort = c(NA, 426137),
                          grad_n = c(NA, 388460), pct_grad = c(86.7, 91.2)), tea_c)
write_csv(tea_c, "data-prep/clean_data/tea_grad_counties.csv", na = "")

# NCES <-> TEA district ID crosswalk (downloads once)
xwalk_path <-"data-prep/nces_tea_crosswalk.csv"
if (!file.exists(xwalk_path)) {
  fromJSON("https://educationdata.urban.org/api/v1/school-districts/ccd/directory/2023/?fips=48")$results %>%
    transmute(GEOID = sprintf("%07d", as.integer(leaid)), DISTRICT = sub("^TX-", "", state_leaid), lea_name) %>%
    write_csv(xwalk_path)
}
xwalk <- read_csv(xwalk_path, col_types = "ccc")

tea_d <- read_excel(file.path(raw, "district-data-download-4yr-2025.xlsx"), "Comp_2025_4yr", col_types = "text") %>%
  filter(CALC_FOR_STATE_ACCT == "No") %>%
  transmute(DISTRICT, NAME = DISTNAME, grad_cohort = to_num(DIST_ALLD), grad_n = to_num(DIST_ALLN_GRAD),
            pct_grad = to_num(DIST_ALLR_GRAD)) %>%
  inner_join(select(xwalk, GEOID, DISTRICT), by = "DISTRICT") %>%
  select(GEOID, NAME, grad_cohort, grad_n, pct_grad)
write_csv(tea_d, "data-prep/clean_data/tea_grad_schools.csv", na = "")

# Feeding America child food insecurity (MMG 2026, 2024 data)
fa_file <- unzip(file.path(raw, "MMG2026_Data_To_Share.zip"), "MMG2026_2024_Data_To_Share.xlsx", exdir = tempdir())
fa_c <- read_excel(fa_file, "County") %>%
  filter(State == "TX") %>%
  transmute(GEOID = sprintf("%05d", as.integer(FIPS)),
            pct_child_fi = round(`Child Food Insecurity Rate` * 100, 1), child_fi = `# of Food Insecure Children`)
fa_tx <- read_excel(fa_file, "State") %>%
  filter(State == "TX") %>%
  transmute(GEOID = "48", pct_child_fi = round(`Child Food Insecurity Rate` * 100, 1), child_fi = `# of Food Insecure Children`)
# US: https://map.feedingamerica.org/county/2024/child/
fa_us <- tibble(GEOID = "1", NAME = "United States", pct_child_fi = 19.5, child_fi = 14091000)
fa <- bind_rows(fa_us, fa_tx, inner_join(select(tx_counties, GEOID, NAME), fa_c, by = "GEOID")) %>%
  mutate(NAME = coalesce(NAME, "Texas")) %>%
  select(GEOID, NAME, pct_child_fi, child_fi)
write_csv(fa, "data-prep/clean_data/fa_child_food_insecurity_counties.csv", na = "")

# DSHS late/no prenatal care, 2024 ("--" = suppressed; TX row is 1st-trimester care, so flip it)
pnc_raw <- read_excel(file.path(raw, "dshs_prenatal_2024.xlsx"), "Sheet 1", col_names = c("pct", "area"),
                      col_types = "text", range = cellranger::cell_cols("A:B")) %>%
  fill(pct) %>%
  transmute(key = key(area), pct_late_pnc = to_num(ifelse(pct == "--", NA, pct)))
# US: NCHS Births: Final Data for 2024 (75.5% 1st-trimester care); race rows dropped
pnc <- bind_rows(
  tibble(GEOID = "1", NAME = "United States", pct_late_pnc = 100 - 75.5),
  tibble(GEOID = "48", NAME = "Texas", pct_late_pnc = round(100 - pnc_raw$pct_late_pnc[pnc_raw$key == "TEXAS"], 1)),
  pnc_raw %>% filter(key %in% tx_counties$key) %>% join_counties()
)
write_csv(pnc, "data-prep/clean_data/dshs_late_prenatal_counties.csv", na = "")

# DSHS low birthweight, 2023 (-1 = suppressed). US: NCHS Births: Final Data for 2023
lbw_raw <- read_excel(list.files(raw, "dshs_birthweight", full.names = TRUE)[1], col_types = "text") %>%
  fill(Area, Variable) %>%
  transmute(key = key(Area), cat = Category, n = to_num(.data[[names(.)[6]]])) %>%
  filter(cat %in% c("All", "Low or Very Low Birthweight")) %>%
  pivot_wider(names_from = cat, values_from = n) %>%
  transmute(key, births_n = All, lbw_n = `Low or Very Low Birthweight`, pct_lbw = round(lbw_n / births_n * 100, 1))
lbw <- bind_rows(
  tibble(GEOID = "1", NAME = "United States", pct_lbw = 8.6),
  lbw_raw %>% filter(key == "STATEWIDE") %>% transmute(GEOID = "48", NAME = "Texas", births_n, lbw_n, pct_lbw),
  lbw_raw %>% filter(key %in% tx_counties$key) %>% join_counties()
)
write_csv(lbw, "data-prep/clean_data/dshs_low_birthweight_counties.csv", na = "")

# TDC 2024 projections (mid scenario), latest yr
tdc_file <- unzip(file.path(raw, "2024_Full_Pop_Projections_Mid (1).zip"), "2024_state_county_asre_indage_mid.csv",
                  exdir = tempdir())
tdc <- read_csv(tdc_file, col_types = cols(FIPS = "c", .default = "?")) %>%
  filter(year == max(year))
tdc_yr <- unique(tdc$year)
tdc <- tdc %>%
  group_by(GEOID = paste0("48", ifelse(FIPS == "000", "", FIPS)), NAME = sub(" County$", "", area_name)) %>%
  summarise(totpop_proj = sum(total[age_in_yrs_num == -1]),
            kids_u18_proj = sum(total[age_in_yrs_num %in% 0:17]), .groups = "drop") %>%
  mutate(NAME = ifelse(GEOID == "48", "Texas", NAME), pct_u18_proj = round(kids_u18_proj / totpop_proj * 100, 1))
message("TDC projection year: ", tdc_yr)
write_csv(tdc, "data-prep/clean_data/tdc_child_pop_projection_counties.csv", na = "")

# TEA Pre-K counts (Early Ed excluded). Denom (ACS kids 3-4) gets added in build_data.R
read_tea_enr <- function(pattern) {
  read_csv(list.files(raw, pattern, full.names = TRUE)[1], skip = 4, col_types = cols(.default = "c")) %>%
    mutate(prek = ifelse(GRADE %in% "Pre-kindergarten", suppressWarnings(as.numeric(ENROLLMENT)), 0)) # Masked ("<10") -> NA
}
# Counties (incl. charters). Not in file -> NA, no Pre-K row -> 0. Some counties have 2+ rows (ESC regions)
prek_c <- read_tea_enr("^Enrollment Report_Statewide_Counties_Grade") %>%
  group_by(key = key(`COUNTY NAME`)) %>%
  summarise(prek_n = sum(prek), .groups = "drop") %>%
  join_counties()
prek_tx <- sum(read_tea_enr("^Enrollment Report_Statewide_Grade")$prek)
write_csv(bind_rows(tibble(GEOID = "48", NAME = "Texas", prek_n = prek_tx), select(prek_c, GEOID, NAME, prek_n)),
          "data-prep/clean_data/tea_prek_counties.csv", na = "")

# Districts: ISDs only (charters have no Census boundary); masked -> NA
prek_d <- read_tea_enr("^Enrollment Report_Statewide_Districts_Grade") %>%
  filter(`CHARTER STATUS` == "TRADITIONAL ISD/CSD") %>%
  group_by(DISTRICT) %>%
  summarise(prek_n = sum(prek), .groups = "drop") %>%
  inner_join(xwalk, by = "DISTRICT") %>%
  select(GEOID, NAME = lea_name, prek_n)
message("School districts with masked Pre-K counts: ", sum(is.na(prek_d$prek_n)), " of ", nrow(prek_d))
write_csv(prek_d, "data-prep/clean_data/tea_prek_schools.csv", na = "")

# Same as build_data.R (needs kids_3to4 from a full rebuild)
add_prek_rate <- function(df) {
  if (!all(c("prek_n", "kids_3to4_moe") %in% names(df))) return(df)
  df %>% mutate(
    pct_prek     = round(prek_n / kids_3to4 * 100, 1),
    pct_prek_moe = ifelse(is.finite(pct_prek) & pct_prek <= 100, pmin(round(prek_n * kids_3to4_moe / kids_3to4^2 * 100, 1), 100), NA),
    pct_prek     = ifelse(pct_prek > 100, NA, pct_prek)
  )
}

# Merge into existing docs/data files (no ACS re-pull needed)
merge_external <- function(df, slug) {
  for (f in list.files("data-prep/clean_data", paste0("_", slug, "\\.csv$"), full.names = TRUE)) {
    ext <- read.csv(f, colClasses = c(GEOID = "character")) %>% select(-any_of("NAME"))
    df <- left_join(select(df, -any_of(setdiff(names(ext), "GEOID"))), ext, by = "GEOID")
  }
  add_prek_rate(df)
}
for (slug in c("counties", "schools")) {
  path <- paste0("docs/data/", slug, ".geojson")
  geo <- merge_external(st_read(path, quiet = TRUE), slug)
  file.remove(path)
  st_write(geo, path, driver = "GeoJSON", quiet = TRUE)
}
bench <- read_json("docs/data/benchmarks.json")
for (b in list(c("texas", "48"), c("us", "1"))) {
  cur <- bench[[b[1]]]
  v <- merge_external(data.frame(GEOID = b[2], kids_3to4 = cur$kids_3to4 %||% NA, kids_3to4_moe = cur$kids_3to4_moe %||% NA),
                      "counties")
  new <- setdiff(names(v), c("GEOID", "kids_3to4", "kids_3to4_moe"))
  bench[[b[1]]][new] <- as.list(v[1, new])
}
# US Pre-K: NCES 2023, public programs only: https://usafacts.org/articles/how-many-children-attend-preschool-us/
bench$us$pct_prek <- 28.6
bench$us$pct_prek_moe <- NA
write_json(bench, "docs/data/benchmarks.json", auto_unbox = TRUE, digits = NA, na = "null", null = "null", pretty = TRUE)
