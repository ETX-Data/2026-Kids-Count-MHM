# data-prep/clean_external.R
# Cleans non-ACS data in data-prep/original_data into data-prep/clean_data/<indicator>_<geography>.csv.
# build_data.R merges every data-prep/clean_data/*_<geography>.csv by GEOID; GEOID "48" rows are the Texas values.
library(dplyr)
library(tidyr)
library(readr)
library(readxl)
library(jsonlite)
library(sf)

raw <- "data-prep/original_data"

key <- function(x) gsub("[^A-Z]", "", sub(" COUNTY$", "", toupper(x)))
tx_counties <- tidycensus::fips_codes %>%
  filter(state == "TX") %>%
  transmute(GEOID = paste0("48", county_code), NAME = sub(" County$", "", county), key = key(county))

to_num <- function(x) suppressWarnings(parse_number(ifelse(x %in% c("-1", "-2", "-3", "."), NA, x)))

join_counties <- function(df) {
  out <- inner_join(tx_counties, df, by = "key") %>% select(-key)
  miss <- setdiff(df$key, tx_counties$key)
  if (length(miss)) message("Unmatched county names: ", paste(miss, collapse = ", "))
  out
}

# TEA four-year graduation rate, class of 2025 (federal calculation: CALC_FOR_STATE_ACCT = "No")
tea_c <- read_excel(file.path(raw, "county-data-download-4yr-2025.xlsx"), "Comp_2025_4yr", col_types = "text") %>%
  transmute(key = key(CNTYNAME), grad_cohort = to_num(CNTY_ALLD), grad_n = to_num(CNTY_ALLN_GRAD),
            pct_grad = to_num(CNTY_ALLR_GRAD)) %>%
  join_counties()
# Texas: https://rptsvr1.tea.texas.gov/acctres/completion/2025/state.html
# U.S. (GEOID "1"): NCES EDFacts 4-year ACGR, 2022-23 (latest), via America's Health Rankings
# https://www.americashealthrankings.org/explore/measures/Graduation_A
tea_c <- bind_rows(tibble(GEOID = c("1", "48"), NAME = c("United States", "Texas"), grad_cohort = c(NA, 426137),
                          grad_n = c(NA, 388460), pct_grad = c(86.7, 91.2)), tea_c)
write_csv(tea_c, "data-prep/clean_data/tea_grad_counties.csv", na = "")

xwalk_path <- "data-prep/nces_tea_crosswalk.csv"
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

# Feeding America Map the Meal Gap 2026 (2024 data): child food insecurity
fa_file <- unzip(file.path(raw, "MMG2026_Data_To_Share.zip"), "MMG2026_2024_Data_To_Share.xlsx", exdir = tempdir())
fa_c <- read_excel(fa_file, "County") %>%
  filter(State == "TX") %>%
  transmute(GEOID = sprintf("%05d", as.integer(FIPS)),
            pct_child_fi = round(`Child Food Insecurity Rate` * 100, 1), child_fi = `# of Food Insecure Children`)
fa_tx <- read_excel(fa_file, "State") %>%
  filter(State == "TX") %>%
  transmute(GEOID = "48", pct_child_fi = round(`Child Food Insecurity Rate` * 100, 1), child_fi = `# of Food Insecure Children`)
# U.S.: Feeding America Map the Meal Gap 2026 website: https://map.feedingamerica.org/county/2024/child/
fa_us <- tibble(GEOID = "1", NAME = "United States", pct_child_fi = 19.5, child_fi = 14091000)
fa <- bind_rows(fa_us, fa_tx, inner_join(select(tx_counties, GEOID, NAME), fa_c, by = "GEOID")) %>%
  mutate(NAME = coalesce(NAME, "Texas")) %>%
  select(GEOID, NAME, pct_child_fi, child_fi)
write_csv(fa, "data-prep/clean_data/fa_child_food_insecurity_counties.csv", na = "")

# DSHS late (after 1st trimester) or no prenatal care, 2024. Tableau export: blank cells repeat the value above,
# "--" is suppressed. The Texas row is first-trimester care (DSHS dashboard: 64.3% in 2024), so Texas = 100 - it.
# Race rows are excluded.
pnc_raw <- read_excel(file.path(raw, "dshs_prenatal_2024.xlsx"), "Sheet 1", col_names = c("pct", "area"),
                      col_types = "text", range = cellranger::cell_cols("A:B")) %>%
  fill(pct) %>%
  transmute(key = key(area), pct_late_pnc = to_num(ifelse(pct == "--", NA, pct)))
# U.S.: NCHS Births: Final Data for 2024 (NVSR 75-2), 75.5% first-trimester care
pnc <- bind_rows(
  tibble(GEOID = "1", NAME = "United States", pct_late_pnc = 100 - 75.5),
  tibble(GEOID = "48", NAME = "Texas", pct_late_pnc = round(100 - pnc_raw$pct_late_pnc[pnc_raw$key == "TEXAS"], 1)),
  pnc_raw %>% filter(key %in% tx_counties$key) %>% join_counties()
)
write_csv(pnc, "data-prep/clean_data/dshs_late_prenatal_counties.csv", na = "")

# Texas Demographic Center 2024 projections (mid migration scenario), latest projection year
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

# Merge into the current docs/data files without re-pulling ACS data (build_data.R does the same on a full rebuild)
merge_external <- function(df, slug) {
  for (f in list.files("data-prep/clean_data", paste0("_", slug, "\\.csv$"), full.names = TRUE)) {
    ext <- read.csv(f, colClasses = c(GEOID = "character")) %>% select(-any_of("NAME"))
    df <- left_join(select(df, -any_of(setdiff(names(ext), "GEOID"))), ext, by = "GEOID")
  }
  df
}
for (slug in c("counties", "schools")) {
  path <- paste0("docs/data/", slug, ".geojson")
  geo <- merge_external(st_read(path, quiet = TRUE), slug)
  file.remove(path)
  st_write(geo, path, driver = "GeoJSON", quiet = TRUE)
}
bench <- read_json("docs/data/benchmarks.json")
for (b in list(c("texas", "48"), c("us", "1"))) {
  v <- merge_external(data.frame(GEOID = b[2]), "counties")
  bench[[b[1]]][setdiff(names(v), "GEOID")] <- as.list(v[1, setdiff(names(v), "GEOID")])
}
write_json(bench, "docs/data/benchmarks.json", auto_unbox = TRUE, digits = NA, na = "null", null = "null", pretty = TRUE)
