# Housing Radius Analyzer

**A MATLAB system for pulling residential housing prices, coordinates, and regional GDP within a 35-mile geographic radius — powered by Census.gov, HUD, BEA, and FHFA data sources. Deployable via Git and Azure Pipelines.**

---

## Repository structure

```
housing_radius_analyzer/
├── HousingRadiusAnalyzer.m        ← Main class (start here)
├── fetchHousingData.m             ← Standalone housing data fetcher
├── fetchCensusGDP.m               ← BEA + Census GDP fetcher
├── locationResolver.m             ← Location → lat/lon + FIPS resolver
├── geoRadiusFilter.m              ← Haversine radius filter + mergeHistoricalData()
├── xmlParser.m                    ← HTTP/HTTPS/FTP/XML parser utility
├── config.json                    ← Live config (gitignored — never commit keys)
├── config.template.json           ← Safe template to commit instead
├── azure-pipelines.yml            ← Azure DevOps CI/CD pipeline
├── .gitignore
├── tests/
│   └── HousingRadiusAnalyzerTest.m
└── README.md
```

---

## Section 1 — MATLAB quick start

```matlab
%% Step 1: Add all files to MATLAB path
addpath(genpath('/path/to/housing_radius_analyzer'));

%% Step 2: Create analyzer and set your location
analyzer = HousingRadiusAnalyzer('config.json');

% --- Option A: city + state ---
analyzer.setLocation('city','Bartlesville','state','OK');

% --- Option B: ZIP code ---
analyzer.setLocation('zip','74003');

% --- Option C: township ---
analyzer.setLocation('township','Caney Valley','state','OK','areatype','rural');

% --- Option D: metropolitan area ---
analyzer.setLocation('metro','Tulsa-Muskogee-Bartlesville','areatype','developed');

% --- Option E: micropolitan area ---
analyzer.setLocation('micro','Bartlesville OK','areatype','suburban');

%% Step 3: Run the full pipeline
results = analyzer.run();

%% Step 4: Print summary report
analyzer.report(results);

%% Step 5: Export data
analyzer.exportData(results, 'csv',  'my_output');
analyzer.exportData(results, 'json', 'my_output');
analyzer.exportData(results, 'xml',  'my_output');
analyzer.exportData(results, 'xlsx', 'my_output');

%% Step 6: Generate browser search URL (domicile-filtered)
analyzer.searchURL();                     % Google (default)
analyzer.searchURL('engine','bing');
analyzer.searchURL('engine','duckduckgo','type','rent');
```

---

## Section 2 — API keys (required)

| Key | Source | Cost |
|-----|--------|------|
| `census_api_key` | https://api.census.gov/data/key_signup.html | Free |
| `bea_api_key`    | https://apps.bea.gov/API/signup/index.cfm   | Free |
| `hud_token`      | https://www.huduser.gov/hudapi/public/register | Free |

Add your keys to `config.json` (which is gitignored). **Never commit live keys to the repository.**

---

## Section 3 — Location input modes

| Parameter  | Resolves to | Example value |
|-----------|-------------|---------------|
| `city` + `state` | Nominatim geocode | `'Bartlesville'`, `'OK'` |
| `zip`      | Census ZIP geocode  | `'74003'` |
| `township` | Civil township centroid | `'Caney Valley'` |
| `metro`    | CBSA metropolitan area | `'Tulsa-Muskogee-Bartlesville'` |
| `micro`    | CBSA micropolitan area | `'Bartlesville OK'` |
| `areatype` | Classification tag | `'developed'` \| `'rural'` \| `'suburban'` |

---

## Section 4 — Search bar call syntax (domicile filter)

The `searchURL()` method generates precision-filtered URLs for browser use.

### Google (default)
```
https://www.google.com/search?q=residential+property+listing+Bartlesville%2C+OK+within+35+mi+site:census.gov+OR+site:hud.gov+OR+site:zillow.com%2Fresearch+OR+site:redfin.com%2Fnews%2Fdata-center+OR+site:fhfa.gov+-inurl:ad+-inurl:sponsored+-inurl:promo+-filetype:pdf+-filetype:ppt+sale&tbs=qdr:y3&num=20&filter=0
```

### Bing
```
https://www.bing.com/search?q=residential+property+listing+[LOCATION]+within+35+mi+...&filters=ex1%3a"ez2"&count=20
```

### DuckDuckGo
```
https://duckduckgo.com/?q=residential+property+listing+[LOCATION]+...&df=y&ia=web
```

**Pro tip:** Append `&tbm=nws` (Google) to restrict results to news/research reports only.

**What the filter does:**
- Pins results to `.gov` housing data portals and research subdomains
- Strips ad and sponsored pages via `-inurl:ad -inurl:sponsored -inurl:promo`
- Excludes PDFs and presentations (raw listing tables only)
- `tbs=qdr:y3` restricts Google to the past 3 years
- `filter=0` disables Google's deduplication so all sources appear

---

## Section 5 — Data sources and protocols

| Source | Protocol | Coverage |
|--------|----------|----------|
| Census ACS 5-Year | HTTPS / REST | Median home value, rent, units by tract |
| Census FTP (PUMS) | FTP (`ftp2.census.gov`) | Individual housing unit records |
| BEA Regional GDP | HTTPS / REST | County GDP (CAGDP1, CAGDP2, CAINC1) |
| HUD USPS Crosswalk | HTTPS / Bearer token | ZIP → tract crosswalk, vacancy |
| FHFA / CFPB HMDA | HTTPS / REST | Mortgage origination prices w/ lat/lon |
| OpenStreetMap Nominatim | HTTPS / REST | Geocoding (no key required) |
| Census Geocoder | HTTPS / REST | County FIPS, address matching |
| FCC Block API | HTTPS / REST | County FIPS from lat/lon |
| Census TIGER | HTTPS / REST | CBSA classification (metro/micro/rural) |

---

## Section 6 — Git setup

```bash
# Clone
git clone https://github.com/YOUR_ORG/housing-radius-analyzer.git
cd housing-radius-analyzer

# Copy template and add your keys
cp config.template.json config.json
# Edit config.json — add census_api_key, bea_api_key, hud_token

# Branch for a new data pull
git checkout -b feature/pull-tulsa-area
# ... run your MATLAB pipeline ...
git add pipeline_outputs/
git commit -m "feat(data): Tulsa 35mi pull 2025-Q1"
git push origin feature/pull-tulsa-area
# Open pull request → merges into data/housing-pulls branch via Azure pipeline
```

---

## Section 7 — Azure Pipelines setup

1. In Azure DevOps, go to **Pipelines → New Pipeline → Azure Repos Git** (or GitHub).
2. Select `azure-pipelines.yml` from the repo root.
3. In **Library → Variable Groups**, create a group named `hra-secrets` with:
   - `CENSUS_API_KEY`
   - `BEA_API_KEY`
   - `HUD_TOKEN`
   - `AZURE_STORAGE_CONN_STRING`
4. Install the [MATLAB Azure DevOps extension](https://marketplace.visualstudio.com/items?itemName=MathWorks.matlab-azure-devops-release).
5. Create an Azure Service Connection named `HRA-Azure-ServiceConnection`.

The pipeline will:
- Run unit tests on every push and PR
- Execute the full data pull nightly at 02:00 UTC
- Export CSV / JSON / XML / XLSX to Azure Blob Storage
- Commit outputs to the `data/housing-pulls` Git branch automatically

---

## Section 8 — Required MATLAB toolboxes

| Toolbox | Used for |
|---------|----------|
| Statistics and Machine Learning | `groupsummary`, `median`, `std` |
| Mapping Toolbox *(optional)* | `deg2rad`, enhanced geo functions |
| Database Toolbox *(optional)* | Direct SQL connection to HMDA DB |

All core functions work with base MATLAB R2021b+. Mapping Toolbox adds enhanced coordinate transforms.

---

## Section 9 — Output table columns

| Column | Type | Description |
|--------|------|-------------|
| `GEOID` | string | Census tract GEOID |
| `Latitude` | double | WGS-84 latitude |
| `Longitude` | double | WGS-84 longitude |
| `DistanceMiles` | double | Distance from search origin |
| `BearingDeg` | double | Compass bearing from origin |
| `GeoBin` | string | Concentric ring (0-10, 10-20, 20-30, 30-35 mi) |
| `MedianHomeValue` | double | ACS median home value (USD) |
| `MedianGrossRent` | double | ACS median gross rent (USD/mo) |
| `TotalHousingUnits` | double | Total housing units in tract |
| `SaleYear` | double | Year of HMDA origination |
| `LoanAmount` | double | HMDA loan amount (USD) |
| `AreaType` | string | `developed` \| `rural` \| `suburban` |
| `PeriodQuarter` | datetime | Quarter bin for trend analysis |
| `QuarterlyMedian` | double | Median price for that quarter |
| `QoQPctChange` | double | Quarter-over-quarter % change |
| `YoYPctChange` | double | Year-over-year % change |
| `TrendSignal` | string | `Rising` \| `Falling` \| `Flat` \| `Volatile` |
| `MergeFlag` | logical | True = new since last pipeline pull |
| `DataSource` | string | Source API tag |

---

## Section 10 — Troubleshooting

**`HRA:noLocation` error** — Call `setLocation()` before `run()`.

**`webread` timeout** — Increase `analyzer.Verbose` and check your internet connection. Census APIs can be slow during business hours.

**Empty HUD table** — Ensure your `hud_token` is active. Tokens expire after 6 months and must be renewed at huduser.gov.

**FTP blocked** — Some networks block FTP. The system automatically falls back to cached stubs or HTTP CSV mirrors.

**BEA returns zero records** — Verify your county FIPS is correct. Use `locationResolver()` to check `loc.CountyFIPS` before calling `fetchCensusGDP()`.

---

## License

MIT — see `LICENSE.txt`
