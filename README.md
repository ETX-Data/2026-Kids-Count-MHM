# 2026 Texas Kids Count Interactive Map (`2026-Kids-Count-MHM`)

This repository powers Every Texan's interactive **2026 Kids Count Child Well-Being Dashboard**, hosted via GitHub Pages from the `/docs` directory.

The dashboard uses a **config-driven architecture**: - **Data Pipeline (`/data-prep/build_data.R`):** Pulls ACS 5-Year estimates via `tidycensus`, merges external state/national CSV datasets (TEA, TX HHS, Feeding America), simplifies polygon geometries, and outputs lightweight `.geojson` files to `docs/data/`. - **Indicator Dictionary (`docs/config/indicators.json`):** Controls all dropdown menus, category groupings, choropleth color palettes, legend breakpoints, and sidebar scorecard rows. **You do not need to edit `docs/index.html` to add new indicators.** - **Web Application (`docs/index.html`):** MapLibre GL JS + Tailwind CSS static frontend.

------------------------------------------------------------------------

## Data Sources

| Source | Indicators |
|------------------------------------|------------------------------------|
| U.S. Census Bureau, ACS 5-Year Estimates, 2020–2024 (update to 2021–2025 when released) | Overall child population (children under 18 as a share of total population); demographics (total population, children under 18, age groups, race/ethnicity); children with disabilities; young children (under 5); limited English speaking households; foreign-born children; children in immigrant families; single-parent households; children living in a grandparent's home; child poverty; extreme poverty (<50% FPL); low-income (<200% FPL); children with no parent in the labor force; households with children receiving SNAP; households with children who rent; uninsured children; children with Medicaid/CHIP; children without home internet access; teens not in school and not working |
| [Texas Education Agency (TEA), Class of 2025](https://tea.texas.gov/data-reports/school-performance/accountability-research/completion-graduation-and-dropout/four-year-graduation-and-dropout-data-class-2025) | Four-year graduation rate (counties, school districts) |
| [Feeding America, Map the Meal Gap 2026 (2024 data)](https://map.feedingamerica.org/) | Child food insecurity (counties) |
| [Texas Department of State Health Services (DSHS), Center for Health Statistics, 2024](https://healthdata.dshs.texas.gov/dashboard/maternal-and-child-health/maternal-health/prenatal-delivery-and-postpartum-care) | Late or no prenatal care (counties) |
| [DSHS, Center for Health Statistics, Live Births, 2023](https://healthdata.dshs.texas.gov/dashboard/births-and-deaths/live-births) | Low birthweight (counties) |
| [Texas Demographic Center (TDC), 2024 Projections (Mid)](https://demographics.texas.gov/Projections/2024/) | Projected child share of population, 2060 (counties) |
| [TEA, PEIMS Student Enrollment Reports, 2025-26](https://rptsvr1.tea.texas.gov/adhocrpt/adste.html) (with ACS children ages 3–4 as the denominator) | Public Pre-K enrollment of children ages 3–4 (counties, school districts) |

## Methods Notes

- **ACS calculations:** Under 18 share, poverty, uninsured, Medicaid/CHIP, and disability use Census-published percentages and MOEs. All others are calculated from summed table cells, with MOEs from Census sum and proportion formulas.
- **Universes vary:** Uninsured is under 19; limited English is ages 5–17; teens not in school or working are 16–19. SNAP and renters are shares of households with children, not children. No parent in the labor force (B23008) is not the national KIDS COUNT "secure parental employment" measure.
- **Race/ethnicity:** Groups overlap. Race groups include Hispanic children of that race; White is non-Hispanic; Hispanic is any race.
- **Reliability:** All MOEs are 90%. Estimates with a CV above 40% are hidden and shown in gray, as are missing values.
- **Comparisons:** ▲/▼ mean significantly higher/lower than Texas at 90% confidence (\|A − B\| \> √(MOE_A² + MOE_B²)); otherwise ≈.
- **Non-ACS sources:** No MOEs, so no reliability flags or significance tests (▲/▼ show direction only). Suppressed or masked values are blank. U.S. values come from Feeding America, NCES EDFacts (2022-23), and NCHS final births data (2023–2024).
- **Pre-K:** TEA 2025-26 Pre-K enrollment divided by ACS children ages 3–4. School districts exclude charters; counties include them. Rates above 100% are blanked. No U.S. value.

------------------------------------------------------------------------

## Folder Structure

``` text
2026-Kids-Count-MHM/
├── README.md
├── data-prep/
│   ├── build_data.R              # Master R script to build & simplify GeoJSON layers
│   ├── clean_external.R          # Cleans original_data/ into the CSVs below
│   ├── original_data/            # Raw TEA, Feeding America, DSHS, and TDC files
│   ├── nces_tea_crosswalk.csv    # NCES ID <-> TEA district number
│   └── clean_data/               # Cleaned non-ACS data: <indicator>_<geography>.csv; GEOID "48" = Texas
└── docs/                         # Served directly by GitHub Pages
    ├── index.html                # MapLibre dashboard UI (do not edit to add data)
    ├── logo.png                  # Every Texan header logo
    ├── config/
    │   └── indicators.json       # Master configuration for all map indicators
    └── data/
        ├── benchmarks.json       # Texas and U.S. comparison values
        ├── places.json           # City and ZIP code search lookup
        ├── counties.geojson      # 254 Texas Counties
        ├── house.geojson         # 150 Texas House Districts
        ├── senate.geojson        # 31 Texas Senate Districts
        └── schools.geojson       # Unified School Districts
```

------------------------------------------------------------------------

## Workflow: How to Add New Indicators

### Case A: Adding a New Census ACS Indicator

1.  Open `data-prep/build_data.R` and locate `export_geography_geojson()`.
2.  Add the raw ACS variable code(s) to the `variables = c(...)` vector inside `get_acs()`.
3.  In `transmute()` and `mutate()`, calculate both the raw count (e.g., `pov_u18`) and the rounded percentage (e.g., `pct_pov = round((pov_u18 / kids_u18) * 100, 1)`).
    - **Rule:** Never include periods (`.`) in variable names.
4.  Run `source("data-prep/build_data.R")` to regenerate the four `.geojson` files in `docs/data/`.
5.  Register the variable in `docs/config/indicators.json` (see **Configuring `indicators.json`** below).

------------------------------------------------------------------------

### Case B: Merging External Non-ACS Data (TEA, TX HHS, Feeding America)

Add the cleaning step to `data-prep/clean_external.R` and run it: it writes `data-prep/clean_data/<indicator>_<geography>.csv` (geography = `counties`, `schools`, `house`, or `senate`) and merges them into the current `docs/data` files without re-pulling ACS data. `build_data.R` merges every such file by GEOID on a full rebuild; a `GEOID` of `"48"` in a counties file supplies the Texas value. Each CSV needs a character `GEOID` column matching the exact Census TIGER/Line identifier:

#### 1. Texas Counties (`data-prep/clean_data/<indicator>_counties.csv`)

- **`GEOID` format:** 5-digit string (`"48"` + 3-digit county FIPS, e.g., `"48029"` for Bexar County).
- Always pad with leading zeros and store as character/text so `"48001"` is never truncated.

#### 2. Unified School Districts (`data-prep/clean_data/<indicator>_schools.csv`)

- **`GEOID` format:** 7-digit **NCES District ID** (`"48"` + 5-digit NCES ID, e.g., `"4808700"` for Austin ISD).
- **CRITICAL TEA CROSSWALK NOTE:** Texas Education Agency (TEA) reports use a 6-digit state **County-District Number (CDN)** (e.g., `"227901"` for Austin ISD), whereas Census `tidycensus` geometries use the 7-digit federal **NCES ID** (`"4808700"`).
- To convert TEA 6-digit CDNs to Census 7-digit `GEOID`s in R (`clean_external.R` does this for graduation rates), run:

``` r
library(dplyr)
library(stringr)
library(readr)

# Pull NCES-to-State-Agency ID crosswalk for Texas (FIPS 48) from Urban Institute API or NCES CCD
nces_xwalk <- read_csv("[https://educationdata.urban.org/csv/ccd/school-districts_nces_directory_2022.csv](https://educationdata.urban.org/csv/ccd/school-districts_nces_directory_2022.csv)") %>%
  filter(fips == 48) %>%
  transmute(
    GEOID = as.character(leaid),
    # Extract 6-digit TEA CDN from state_leaid (e.g., "TX-227901" -> "227901")
    tea_cdn = str_extract(state_leaid, "\\d{6}")
  ) %>%
  distinct(GEOID, tea_cdn)

# Join onto your TEA STAAR / Pre-K dataframe
tea_clean <- my_tea_dataframe %>%
  mutate(tea_cdn = str_pad(as.character(DISTRICT_ID), width = 6, side = "left", pad = "0")) %>%
  inner_join(nces_xwalk, by = "tea_cdn") %>%
  select(GEOID, pct_staar_read3, count_staar_read3, pct_prek_enroll)

write_csv(tea_clean, "data-prep/clean_data/tea_example_schools.csv")
```

------------------------------------------------------------------------

## Configuring `docs/config/indicators.json` (Colors, Breakpoints & Geography Filters)

Every map indicator is defined as an object inside `docs/config/indicators.json`:

``` json
{
  "id": "pct_staar_read3",
  "slug": "staar-reading-3rd",
  "count_id": "count_staar_read3",
  "label": "3rd Grade STAAR Reading Proficiency (Meets Grade Level)",
  "category": "Education",
  "source": "Texas Education Agency (TEA), 2025-2026 STAAR Summary Report",
  "geographies": ["schools"],
  "stops": [30, 40, 50, 60, 70],
  "colors": ["#eff3ff", "#c6dbef", "#9ecae1", "#6baed6", "#3182bd", "#08519c"]   <---here we can change the colors of the chloropleth maps
}
```

### Rules for `indicators.json`:

1.  **`"slug"`:** The short, readable name used in shareable links (lowercase words joined by hyphens, e.g. `"uninsured"`). It must be unique, and once the dashboard is public it should not change, or saved links to that indicator will open the default view instead.
1.  **`"id"` & `"count_id"`:** Must match the exact column names output by `build_data.R`. If an indicator only has a percentage and no raw child count, set `"count_id": null`.

2.  **`"stops"` and `"colors"` (`N + 1` Rule):**

    - If `"stops"` has **5 numbers** (`[30, 40, 50, 60, 70]`), `"colors"` **must have 6 hex codes** (`<30%`, `30–39.9%`, `40–49.9%`, `50–59.9%`, `60–69.9%`, `70%+`).
    - Recommended Category Palettes (6-class sequential from ColorBrewer2.org):
      - **Economic Security (Warm Amber/Red):** `["#fef0d9", "#fdcc8a", "#fc8d59", "#e34a33", "#b30000", "#7f0000"]`
      - **Health (Teal/Purple):** `["#edf8fb", "#bfd3e6", "#9ebcda", "#8c96c6", "#8856a7", "#810f7c"]`
      - **Education (Blue):** `["#eff3ff", "#c6dbef", "#9ecae1", "#6baed6", "#3182bd", "#08519c"]`
      - **Demographics (Green/Teal):** `["#edf8e9", "#c7e9c0", "#a1d99b", "#74c476", "#31a354", "#006d2c"]`

3.  **`"geographies"` (Optional Filter):**

    - Omit `"geographies"` if the indicator exists for all 4 layers (`counties`, `house`, `senate`, `schools`).
    - If an indicator only exists for specific layers (e.g., TEA STAAR only exists for `"schools"`, or Feeding America only exists for `"counties"`), add `"geographies": ["schools"]` or `"geographies": ["counties"]`. The dashboard dropdown will automatically show/hide it when the user switches geographies.

4.  **`"missing_note"` (Optional):** Text shown when an area has no value for this indicator (sidebar, map tooltip, and CSV reliability column). Set it for non-ACS sources to say why data are missing, e.g. `"missing_note": "Masked by TEA to protect student privacy"`. If omitted, indicators whose `"source"` mentions Census or ACS show "No estimate: ACS estimates 0 children in this group" (every missing ACS value so far comes from a denominator of 0, such as Loving County's 0 children); all others show "No data".

5.  **`"count_label"`, `"denom_id"`, `"denom_label"` (Optional):** Sidebar count text. Default is "(N children)"; with these set, e.g. "(544 graduates of 548 students)".

------------------------------------------------------------------------

## Updating for the 2025 5-Year ACS Release (Should be this month --December 2026)

1.  Open `data-prep/build_data.R`.
2.  Change `acs5_year <- 2024` on line 10 to `acs5_year <- 2025`.
3.  Re-run `build_data.R`, commit the updated `docs/data/*.geojson` files, and push to `main`.
