# 2026 Texas Kids Count Interactive Map (`2026-Kids-Count-MHM`)

This repository powers Every Texan's interactive **2026 Kids Count Child Well-Being Dashboard**, hosted via GitHub Pages from the `/docs` directory.

The dashboard uses a **config-driven architecture**: - **Data Pipeline (`/data-prep/build_data.R`):** Pulls ACS 5-Year estimates via `tidycensus`, merges external state/national CSV datasets (TEA, TX HHS, Feeding America), simplifies polygon geometries, and outputs lightweight `.geojson` files to `docs/data/`. - **Indicator Dictionary (`docs/config/indicators.json`):** Controls all dropdown menus, category groupings, choropleth color palettes, legend breakpoints, and sidebar scorecard rows. **You do not need to edit `docs/index.html` to add new indicators.** - **Web Application (`docs/index.html`):** MapLibre GL JS + Tailwind CSS static frontend.

------------------------------------------------------------------------

## Data Sources

| Source | Indicators |
|----|----|
| U.S. Census Bureau, ACS 5-Year Estimates, 2020–2024 (update to 2021–2025 when released) | Demographics (total population, children under 18, age groups, race/ethnicity); children with disabilities; young children (under 5); limited English speaking households; foreign-born children; single-parent households; child poverty; households with children receiving SNAP; uninsured children; children without home internet access |
| Feeding America | TBD |
| Texas Health and Human Services Commission (HHSC) | TBD |
| Other | TBD |

## Methods Notes

- **Percentages:** Under 18 share, poverty, uninsured, and disability use Census-published percentages and MOEs (S0101, S1701, S2701, DP02). All others are calculated from counts.
- **Universes vary:** Uninsured is children under 19. Poverty covers only children whose poverty status is determined. Limited English is ages 5–17. SNAP is a share of households with children, not children. Single parent is a share of own children in families (an unmarried partner may be present, matching national KIDS COUNT).
- **Race/ethnicity:** Groups overlap and can sum to more than 100%. Race groups (B01001B–G) include Hispanic children of that race; White is non-Hispanic; Hispanic is any race. "Other" = AIAN + NHPI + Some Other Race.
- **MOEs:** All are 90%. Where Census publishes no percentage MOE, it is approximated with Census formulas (*Understanding and Using ACS Data*, Ch. 8). These closely match published MOEs for counties and legislative districts (median ratio 1.00) and less closely for school districts (about 0.8–1.1x).
- **Reliability:** Estimates with a CV above 40% (CV = (MOE / 1.645) / estimate), or 0% with a nonzero MOE, are hidden and shown in gray on the map. Missing values are also gray.
- **Geometry:** Boundaries are simplified to 5% of vertices for fast loading; data values are unaffected.
- **Texas and U.S. comparisons:** Texas and U.S. values (`docs/data/benchmarks.json`) come from the same tables and calculations as the map layers. An area is marked ▲ higher or ▼ lower than Texas only when the difference is statistically significant at the 90% confidence level, using the Census Bureau test |A − B| > √(MOE_A² + MOE_B²); otherwise it is marked ≈ (not significantly different). Comparisons are not shown for unreliable estimates. The test ignores the overlap between an area and the state, as Census guidance does for these comparisons.
- **City and ZIP search:** Uses the internal points of Texas places (cities, towns, villages, and CDPs, shown as "community") and ZIP Code Tabulation Areas from the 2024 Census Gazetteer files (`docs/data/places.json`). The dashboard selects the area that contains that point, so a city or ZIP that crosses a boundary is matched to only one area; the sidebar says so. To keep the dropdown short, it lists only the areas in the current geography; cities and ZIP codes are not listed but still work when typed (a bare name like "Austin" matches "Austin (city)").
- **"Compared with other areas" strip:** Shows every area in the current geography that has a reliable estimate, with the selected area highlighted. The label ("Lower than most counties," etc.) is based on the share of other areas with a lower value: under 10% among the lowest, 10–35% lower than most, 35–65% near the middle, 65–90% higher than most, over 90% among the highest. Exact ranks are not shown because margins of error often overlap.
- **CSV downloads:** Include every value with its 90% MOE and a reliability flag. Unlike the map and sidebar, unreliable values are included (flagged) so researchers can apply their own rules. Texas and U.S. rows are added at the bottom.
- **Shareable links:** The URL hash records the view as `#<geography>/<indicator id>/<GEOID>` (for example `#counties/pct_pov/48453` for Travis County). Geography slugs are `counties`, `house`, `senate`, and `schools`.

------------------------------------------------------------------------

## Folder Structure

``` text
2026-Kids-Count-MHM/
├── README.md
├── data-prep/
│   ├── build_data.R              # Master R script to build & simplify GeoJSON layers
│   ├── external_counties.csv     # Non-ACS county indicators (keyed by 5-digit GEOID)
│   ├── external_schools.csv      # Non-ACS school district indicators (keyed by 7-digit NCES GEOID)
│   ├── external_house.csv        # Optional non-ACS TX House indicators (keyed by 5-digit GEOID)
│   └── external_senate.csv       # Optional non-ACS TX Senate indicators (keyed by 5-digit GEOID)
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

To merge external state agency or national datasets into the map layers, save a clean CSV in `data-prep/` formatted with a character `GEOID` column matching the exact Census TIGER/Line identifier:

#### 1. Texas Counties (`data-prep/external_counties.csv`)

- **`GEOID` format:** 5-digit string (`"48"` + 3-digit county FIPS, e.g., `"48029"` for Bexar County).
- Always pad with leading zeros and store as character/text so `"48001"` is never truncated.

#### 2. Unified School Districts (`data-prep/external_schools.csv`)

- **`GEOID` format:** 7-digit **NCES District ID** (`"48"` + 5-digit NCES ID, e.g., `"4808700"` for Austin ISD).
- **CRITICAL TEA CROSSWALK NOTE:** Texas Education Agency (TEA) reports use a 6-digit state **County-District Number (CDN)** (e.g., `"227901"` for Austin ISD), whereas Census `tidycensus` geometries use the 7-digit federal **NCES ID** (`"4808700"`).
- To convert TEA 6-digit CDNs to Census 7-digit `GEOID`s in R before saving `external_schools.csv`, run:

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

write_csv(tea_clean, "data-prep/external_schools.csv")
```

#### 3. Enable the CSV Merge in `data-prep/build_data.R`

Ensure the merge block inside `export_geography_geojson()` in `data-prep/build_data.R` is uncommented:

``` r
ext_path <- paste0("data-prep/external_", file_slug, ".csv")
if (file.exists(ext_path)) {
  ext_df <- read.csv(ext_path, colClasses = c(GEOID = "character"))
  core_df <- left_join(core_df, ext_df, by = "GEOID")
}
```

------------------------------------------------------------------------

## Configuring `docs/config/indicators.json` (Colors, Breakpoints & Geography Filters)

Every map indicator is defined as an object inside `docs/config/indicators.json`:

``` json
{
  "id": "pct_staar_read3",
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

------------------------------------------------------------------------

## Updating for the 2025 5-Year ACS Release (Should be this month --December 2026)

1.  Open `data-prep/build_data.R`.
2.  Change `acs5_year <- 2024` on line 10 to `acs5_year <- 2025`.
3.  Re-run `build_data.R`, commit the updated `docs/data/*.geojson` files, and push to `main`.
