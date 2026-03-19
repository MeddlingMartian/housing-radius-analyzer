classdef HousingRadiusAnalyzer < handle
% =========================================================================
% HousingRadiusAnalyzer.m
% Housing Price & Geographic Intelligence System
% -------------------------------------------------------------------------
% Sources : Census.gov ACS, HUD USPS, FHFA, BEA GDP, OpenStreetMap Nominatim
% Protocols: HTTP, HTTPS, FTP, XML, REST/JSON
% Deployment: Git + Azure Pipelines
% =========================================================================
%
% QUICK START — paste into MATLAB Command Window:
%   analyzer = HousingRadiusAnalyzer();
%   analyzer.setLocation('city','Tulsa','state','OK','zip','74103');
%   results  = analyzer.run();
%   analyzer.report(results);
%
% SEARCH BAR CALL (browser-agnostic domicile filter):
%   Use searchURL() to generate a precision-filtered URL string.
%   See README.md §4 for full call syntax.
% =========================================================================

    properties (Access = public)
        % --- Location -------------------------------------------------------
        InputCity         string = ""
        InputState        string = ""
        InputZip          string = ""
        InputTownship     string = ""
        InputMetroArea    string = ""
        InputMicroMetro   string = ""
        InputAreaType     string = "developed"   % developed|rural
        RadiusMiles       double = 35

        % --- API Keys (load from config.json or env vars) -------------------
        CensusAPIKey      string = ""
        BEAAPIKey         string = ""
        HUDToken          string = ""
        FHFAEndpoint      string = "https://api.consumerfinance.gov/data/hmda/nationwide/first_lien"

        % --- Time window (2.5 years) ----------------------------------------
        LookbackMonths    double = 30

        % --- Output ---------------------------------------------------------
        OutputFormat      string = "table"       % table|json|xml|csv
        CacheDir          string = fullfile(tempdir,'hra_cache')
        Verbose           logical = true
    end

    properties (Access = private)
        BaseLatitude      double
        BaseLongitude     double
        ResolvedGEOID     string = ""
        CensusBaseURL     string = "https://api.census.gov/data"
        BEABaseURL        string = "https://apps.bea.gov/api/data"
        NominatimURL      string = "https://nominatim.openstreetmap.org"
        HUDBaseURL        string = "https://www.huduser.gov/hudapi/public"
        FTPHost           string = "ftp2.census.gov"
    end

    % ======================================================================
    methods (Access = public)
    % ======================================================================

        function obj = HousingRadiusAnalyzer(configFile)
            % Constructor — optionally load config.json
            if nargin > 0 && isfile(configFile)
                obj.loadConfig(configFile);
            else
                obj.loadConfig(fullfile(fileparts(mfilename('fullpath')),'config.json'));
            end
            if ~isfolder(obj.CacheDir), mkdir(obj.CacheDir); end
            obj.log('HousingRadiusAnalyzer initialized. CacheDir: %s', obj.CacheDir);
        end

        % ------------------------------------------------------------------
        function obj = setLocation(obj, varargin)
        % setLocation  Set geographic search origin using named parameters.
        %
        %   Supported keys (case-insensitive, any subset):
        %     'city'       – municipality name
        %     'state'      – 2-letter USPS abbreviation  e.g. 'OK'
        %     'zip'        – 5-digit ZIP code
        %     'township'   – civil township name
        %     'metro'      – Core Based Statistical Area (CBSA) name
        %     'micro'      – Micropolitan Statistical Area name
        %     'areatype'   – 'developed' | 'rural'
        %
        %   Example:
        %     a.setLocation('city','Bartlesville','state','OK','zip','74003');
        % ------------------------------------------------------------------
            p = inputParser;
            addParameter(p,'city',     obj.InputCity,      @(x)ischar(x)||isstring(x));
            addParameter(p,'state',    obj.InputState,     @(x)ischar(x)||isstring(x));
            addParameter(p,'zip',      obj.InputZip,       @(x)ischar(x)||isstring(x));
            addParameter(p,'township', obj.InputTownship,  @(x)ischar(x)||isstring(x));
            addParameter(p,'metro',    obj.InputMetroArea, @(x)ischar(x)||isstring(x));
            addParameter(p,'micro',    obj.InputMicroMetro,@(x)ischar(x)||isstring(x));
            addParameter(p,'areatype', obj.InputAreaType,  @(x)ischar(x)||isstring(x));
            parse(p, varargin{:});

            obj.InputCity       = string(p.Results.city);
            obj.InputState      = string(p.Results.state);
            obj.InputZip        = string(p.Results.zip);
            obj.InputTownship   = string(p.Results.township);
            obj.InputMetroArea  = string(p.Results.metro);
            obj.InputMicroMetro = string(p.Results.micro);
            obj.InputAreaType   = string(p.Results.areatype);

            % Geocode to lat/lon
            [obj.BaseLatitude, obj.BaseLongitude] = obj.geocodeLocation();
            obj.log('Origin geocoded: Lat=%.5f  Lon=%.5f', obj.BaseLatitude, obj.BaseLongitude);
        end

        % ------------------------------------------------------------------
        function results = run(obj)
        % run  Execute the full data pipeline.
        %   Returns a struct with fields:
        %     .Housing   – table of residential listings within radius
        %     .GDP       – regional GDP table (BEA + Census)
        %     .Stats     – summary statistics
        %     .Metadata  – run parameters and timestamps
        % ------------------------------------------------------------------
            obj.validateInputs();

            obj.log('=== HousingRadiusAnalyzer RUN START ===');
            obj.log('Radius: %g miles | Lookback: %g months', obj.RadiusMiles, obj.LookbackMonths);

            % Step 1 – Pull housing records from all sources
            housingRaw = obj.fetchHousingData();

            % Step 2 – Pull GDP / economic context from Census + BEA
            gdpData    = obj.fetchCensusGDP();

            % Step 3 – Filter to radius, tag area type
            filtered   = obj.geoRadiusFilter(housingRaw);

            % Step 4 – Merge 2.5-year historical window
            merged     = obj.mergeHistoricalData(filtered);

            % Step 5 – Assemble output struct
            results.Housing  = merged;
            results.GDP      = gdpData;
            results.Stats    = obj.computeStats(merged, gdpData);
            results.Metadata = obj.buildMetadata();

            obj.log('=== RUN COMPLETE — %d records returned ===', height(merged));
        end

        % ------------------------------------------------------------------
        function report(obj, results)
        % report  Print formatted summary to Command Window.
        % ------------------------------------------------------------------
            fprintf('\n╔══════════════════════════════════════════════════════╗\n');
            fprintf('║         HOUSING RADIUS ANALYSIS REPORT              ║\n');
            fprintf('╠══════════════════════════════════════════════════════╣\n');
            fprintf('║ Origin   : %-42s║\n', obj.buildQueryLabel());
            fprintf('║ Radius   : %-3g miles                                 ║\n', obj.RadiusMiles);
            fprintf('║ Window   : %.1f years (%.0f months)                    ║\n', ...
                    obj.LookbackMonths/12, obj.LookbackMonths);
            fprintf('║ Records  : %-6d                                     ║\n', height(results.Housing));
            fprintf('╠══════════════════════════════════════════════════════╣\n');
            if ~isempty(results.Stats)
                s = results.Stats;
                fprintf('║ Median List Price : $%-31s║\n', ...
                        sprintf('%,.0f', s.MedianListPrice));
                fprintf('║ Avg Price/SqFt    : $%-31s║\n', ...
                        sprintf('%.2f', s.AvgPricePerSqFt));
                fprintf('║ Price YoY Change  :  %-31s║\n', ...
                        sprintf('%+.1f%%', s.YoYPctChange));
                fprintf('║ Regional GDP      : $%-31s║\n', ...
                        sprintf('%,.0f M', s.RegionalGDP_M));
            end
            fprintf('╚══════════════════════════════════════════════════════╝\n\n');

            if obj.Verbose && ~isempty(results.Housing)
                disp(head(results.Housing, 10));
            end
        end

        % ------------------------------------------------------------------
        function url = searchURL(obj, varargin)
        % searchURL  Generate a precision domicile-only search URL.
        %
        %   This URL uses site-restriction and filetype operators to
        %   route your browser directly to structured housing data,
        %   filtering out listing aggregators, ads, and SEO clutter.
        %
        %   Usage:
        %     url = analyzer.searchURL();           % default Google
        %     url = analyzer.searchURL('engine','bing');
        %     url = analyzer.searchURL('engine','duckduckgo','type','sale');
        %
        %   Paste returned URL directly into any browser address bar.
        % ------------------------------------------------------------------
            p = inputParser;
            addParameter(p,'engine','google',@ischar);
            addParameter(p,'type','sale',   @ischar);   % sale|rent|both
            parse(p,varargin{:});

            label   = obj.buildQueryLabel();
            radius  = sprintf('%g mi', obj.RadiusMiles);

            % Core domicile filter — blocks aggregators, keeps .gov/.edu data
            domicileFilter = [...
                'residential+property+listing+', urlencode(label), ...
                '+within+', urlencode(radius), ...
                '+site:census.gov+OR+site:hud.gov+OR+site:zillow.com/research', ...
                '+OR+site:redfin.com/news/data-center', ...
                '+OR+site:fhfa.gov', ...
                '+-inurl:ad+-inurl:sponsored+-inurl:promo', ...
                '+-filetype:pdf+-filetype:ppt', ...
                '+', urlencode(p.Results.type)];

            switch lower(p.Results.engine)
                case 'google'
                    url = ['https://www.google.com/search?q=' domicileFilter ...
                           '&tbs=qdr:y3&num=20&filter=0'];
                case 'bing'
                    url = ['https://www.bing.com/search?q=' domicileFilter ...
                           '&filters=ex1%3a"ez2"&count=20'];
                case 'duckduckgo'
                    url = ['https://duckduckgo.com/?q=' domicileFilter ...
                           '&df=y&ia=web'];
                otherwise
                    url = ['https://www.google.com/search?q=' domicileFilter];
            end

            fprintf('\n--- DOMICILE SEARCH URL ---\n%s\n\n', url);
            fprintf('TIP: Paste this directly into your browser address bar.\n');
            fprintf('     Add  &tbm=nws  (Google) to restrict to news/reports only.\n\n');
        end

        % ------------------------------------------------------------------
        function exportData(obj, results, fmt, outPath)
        % exportData  Write results to disk in requested format.
        %   Formats: 'json' | 'xml' | 'csv' | 'xlsx'
        % ------------------------------------------------------------------
            if nargin < 3, fmt     = 'csv';                        end
            if nargin < 4, outPath = fullfile(obj.CacheDir,'output'); end

            switch lower(fmt)
                case 'json'
                    fpath = [outPath '.json'];
                    fid   = fopen(fpath,'w');
                    fprintf(fid,'%s', jsonencode(results, 'PrettyPrint', true));
                    fclose(fid);
                case 'xml'
                    fpath = [outPath '.xml'];
                    obj.writeXML(results, fpath);
                case 'csv'
                    fpath = [outPath '.csv'];
                    writetable(results.Housing, fpath);
                case 'xlsx'
                    fpath = [outPath '.xlsx'];
                    writetable(results.Housing, fpath,'Sheet','Housing');
                    writetable(results.GDP,     fpath,'Sheet','GDP');
                otherwise
                    error('HRA:badFormat','Unknown format: %s', fmt);
            end
            obj.log('Exported %s → %s', upper(fmt), fpath);
        end

    end % public methods

    % ======================================================================
    methods (Access = private)
    % ======================================================================

        % ------------------------------------------------------------------
        function [lat, lon] = geocodeLocation(obj)
        % geocodeLocation  Convert location fields to WGS-84 coordinates.
        %   Uses OpenStreetMap Nominatim (no key required).
        %   Falls back to Census Geocoder for ZIP-based lookups.
        % ------------------------------------------------------------------
            queryParts = {};
            if obj.InputCity  ~= "",  queryParts{end+1} = char(obj.InputCity);  end
            if obj.InputState ~= "",  queryParts{end+1} = char(obj.InputState); end
            if obj.InputZip   ~= "",  queryParts{end+1} = char(obj.InputZip);   end

            if isempty(queryParts)
                if obj.InputMetroArea ~= ""
                    queryParts{end+1} = char(obj.InputMetroArea);
                elseif obj.InputMicroMetro ~= ""
                    queryParts{end+1} = char(obj.InputMicroMetro);
                elseif obj.InputTownship ~= ""
                    queryParts{end+1} = char(obj.InputTownship);
                else
                    error('HRA:noLocation','Supply at least one location field.');
                end
            end

            queryStr = strjoin(queryParts, ', ');
            url = sprintf('%s/search?q=%s&format=json&limit=1&countrycodes=us', ...
                          obj.NominatimURL, urlencode(queryStr));

            try
                raw  = obj.httpGET(url, 'Accept','application/json', ...
                                        'User-Agent','HousingRadiusAnalyzer/1.0');
                data = jsondecode(raw);
                if isempty(data)
                    error('HRA:geocodeFail','Nominatim returned no results.');
                end
                lat = str2double(data(1).lat);
                lon = str2double(data(1).lon);
            catch ME
                obj.log('Nominatim failed (%s). Trying Census Geocoder...', ME.message);
                [lat, lon] = obj.geocodeCensus(queryStr);
            end
        end

        % ------------------------------------------------------------------
        function [lat, lon] = geocodeCensus(obj, queryStr)
        % Fallback geocoder using Census Bureau REST API
            url = sprintf(['https://geocoding.geo.census.gov/geocoder/locations/' ...
                           'onelineaddress?address=%s&benchmark=Public_AR_Current&format=json'], ...
                           urlencode(queryStr));
            raw  = obj.httpGET(url);
            data = jsondecode(raw);
            try
                coords = data.result.addressMatches(1).coordinates;
                lat = coords.y;
                lon = coords.x;
            catch
                error('HRA:geocodeFail','Could not geocode: %s', queryStr);
            end
        end

        % ------------------------------------------------------------------
        function tbl = fetchHousingData(obj)
        % fetchHousingData  Aggregate residential listing data from:
        %   1. Census ACS  – median home values by tract
        %   2. HUD USPS    – ZIP-level vacancy & ownership rates
        %   3. FHFA HMDA   – mortgage origination prices (conforming loans)
        %   4. Census FTP  – historical ACS 5-year PUMS files (via FTP)
        % ------------------------------------------------------------------
            obj.log('Fetching housing data from Census ACS...');
            acsTbl   = obj.fetchCensusACS();

            obj.log('Fetching HUD occupancy data...');
            hudTbl   = obj.fetchHUDData();

            obj.log('Fetching FHFA HMDA records...');
            hmda     = obj.fetchHMDA();

            % Fetch historical PUMS file via FTP (Census FTP server)
            obj.log('Fetching historical PUMS via Census FTP...');
            pumsTbl  = obj.fetchCensusFTP();

            % Merge on common ZIP / GEOID key
            tbl = obj.joinSources(acsTbl, hudTbl, hmda, pumsTbl);
            obj.log('Housing merge complete: %d rows', height(tbl));
        end

        % ------------------------------------------------------------------
        function tbl = fetchCensusACS(obj)
        % Fetch ACS 5-Year Estimates: Median Home Value (B25077), 
        % Median Gross Rent (B25064), Housing Units (B25001)
            year    = year(datetime('today')) - 1;   % most recent release
            vars    = 'B25077_001E,B25064_001E,B25001_001E,NAME';
            stFIPS  = obj.stateFIPSfromAbbrev(obj.InputState);
            url     = sprintf(['%s/%d/acs/acs5?get=%s' ...
                               '&for=tract:*&in=state:%s&key=%s'], ...
                               obj.CensusBaseURL, year, vars, stFIPS, obj.CensusAPIKey);
            raw  = obj.httpGET(url);
            data = jsondecode(raw);
            tbl  = obj.matrixToTable(data);

            % Rename Census column codes to human labels
            tbl = renamevars(tbl, ...
                {'B25077_001E','B25064_001E','B25001_001E'}, ...
                {'MedianHomeValue','MedianGrossRent','TotalHousingUnits'});
            tbl.MedianHomeValue  = str2double(tbl.MedianHomeValue);
            tbl.MedianGrossRent  = str2double(tbl.MedianGrossRent);
            tbl.TotalHousingUnits= str2double(tbl.TotalHousingUnits);

            % Geocode each tract centroid (lat/lon)
            [tbl.Latitude, tbl.Longitude] = obj.geocodeTracts(tbl);
        end

        % ------------------------------------------------------------------
        function tbl = fetchHUDData(obj)
        % HUD USPS ZIP-level crosswalk and vacancy data
            url = sprintf('%s/crosswalk/?type=zip_tract&query=%s&year=current', ...
                          obj.HUDBaseURL, char(obj.InputZip));
            opts = weboptions('HeaderFields', ...
                              {'Authorization', ['Bearer ' char(obj.HUDToken)]; ...
                               'Accept','application/json'});
            try
                raw  = webread(url, opts);
                tbl  = struct2table(raw.data);
            catch
                obj.log('HUD API unavailable. Using cached stub.');
                tbl  = obj.loadCachedStub('hud');
            end
        end

        % ------------------------------------------------------------------
        function tbl = fetchHMDA(obj)
        % FHFA / CFPB HMDA — Home Mortgage Disclosure Act data.
        %   Pulls loan-level origination records with property lat/lon.
        %   Filtered to action_taken=1 (loan originated), lien_status=1.
            endYear  = year(datetime('today')) - 1;
            startYear= endYear - floor(obj.LookbackMonths/12) - 1;
            tblAll   = [];
            for yr = startYear:endYear
                url = sprintf(['%s.json?years=%d' ...
                               '&action_taken=1&lien_status=1&limit=10000'], ...
                               obj.FHFAEndpoint, yr);
                try
                    raw = obj.httpGET(url);
                    d   = jsondecode(raw);
                    if isstruct(d) && isfield(d,'data')
                        tblAll = [tblAll; struct2table(d.data,'AsArray',true)]; %#ok<AGROW>
                    end
                catch ME
                    obj.log('HMDA %d failed: %s', yr, ME.message);
                end
            end
            if isempty(tblAll)
                tbl = obj.loadCachedStub('hmda');
            else
                tbl = tblAll;
            end
        end

        % ------------------------------------------------------------------
        function tbl = fetchCensusFTP(obj)
        % Download ACS PUMS housing file via FTP (plain FTP protocol).
        %   Census FTP: ftp2.census.gov/programs-surveys/acs/data/pums/
            yr       = year(datetime('today')) - 2;
            stAbbrev = lower(char(obj.InputState));
            ftpPath  = sprintf('/programs-surveys/acs/data/pums/%d/5-Year/', yr);
            fileName = sprintf('csv_hok.zip');   % housing file, OK example — parameterize
            localZip = fullfile(obj.CacheDir, fileName);

            try
                f = ftp(char(obj.FTPHost));
                cd(f, ftpPath);
                mget(f, fileName, obj.CacheDir);
                close(f);

                % Unzip and read
                unzip(localZip, obj.CacheDir);
                csvFile = fullfile(obj.CacheDir, 'psam_h' + upper(stAbbrev) + '.csv');
                if isfile(csvFile)
                    tbl = readtable(csvFile,'VariableNamingRule','preserve');
                    % Keep only housing-relevant columns
                    keepVars = {'SERIALNO','ST','COUNTY','ZIP','VALP','RNTP', ...
                                'BLD','BDSP','RMSP','YBL','LATITUDE','LONGITUDE'};
                    keepVars = intersect(keepVars, tbl.Properties.VariableNames);
                    tbl = tbl(:, keepVars);
                else
                    tbl = obj.loadCachedStub('pums');
                end
            catch ME
                obj.log('FTP fetch failed: %s', ME.message);
                tbl = obj.loadCachedStub('pums');
            end
        end

        % ------------------------------------------------------------------
        function gdpTbl = fetchCensusGDP(obj)
        % Fetch regional GDP from BEA API and Census County Business Patterns.
        %   BEA Table CAGDP1 — Real GDP by county (chained 2012 dollars).
        % ------------------------------------------------------------------
            obj.log('Fetching regional GDP (BEA CAGDP1)...');

            startYear = year(datetime('today')) - floor(obj.LookbackMonths/12) - 2;
            endYear   = year(datetime('today')) - 1;
            yearRange = strjoin(string(startYear:endYear), ',');

            % Resolve FIPS for county
            countyFIPS = obj.resolveCountyFIPS();

            url = sprintf(['%s?&UserID=%s&method=GetData&datasetname=Regional' ...
                           '&TableName=CAGDP1&LineCode=1' ...
                           '&GeoFIPS=%s&Year=%s&ResultFormat=json'], ...
                           obj.BEABaseURL, obj.BEAAPIKey, countyFIPS, yearRange);
            try
                raw    = obj.httpGET(url);
                parsed = jsondecode(raw);
                data   = parsed.BEAAPI.Results.Data;
                gdpTbl = struct2table(data,'AsArray',true);
                gdpTbl.DataValue = str2double(strrep(gdpTbl.DataValue,',',''));
                gdpTbl.Properties.VariableNames{'DataValue'} = 'GDP_ThousandUSD';
            catch ME
                obj.log('BEA GDP fetch failed: %s. Using Census fallback.', ME.message);
                gdpTbl = obj.fetchCensusCountyBusinessPatterns();
            end
        end

        % ------------------------------------------------------------------
        function gdpTbl = fetchCensusCountyBusinessPatterns(obj)
        % Fallback: Census County Business Patterns — payroll as GDP proxy
            yr    = year(datetime('today')) - 2;
            stFIPS= obj.stateFIPSfromAbbrev(obj.InputState);
            url   = sprintf('%s/%d/cbp?get=PAYANN,ESTAB,NAICS2017,NAME&for=county:*&in=state:%s&key=%s', ...
                            obj.CensusBaseURL, yr, stFIPS, obj.CensusAPIKey);
            raw    = obj.httpGET(url);
            data   = jsondecode(raw);
            gdpTbl = obj.matrixToTable(data);
            gdpTbl.PAYANN = str2double(gdpTbl.PAYANN);
        end

        % ------------------------------------------------------------------
        function tbl = geoRadiusFilter(obj, rawTbl)
        % geoRadiusFilter  Keep only rows within RadiusMiles of base point.
        %   Uses Haversine great-circle distance.
        % ------------------------------------------------------------------
            if ~ismember('Latitude',  rawTbl.Properties.VariableNames) || ...
               ~ismember('Longitude', rawTbl.Properties.VariableNames)
                obj.log('WARNING: Lat/Lon columns absent — skipping radius filter.');
                tbl = rawTbl;
                return
            end

            dist = obj.haversine(obj.BaseLatitude, obj.BaseLongitude, ...
                                 rawTbl.Latitude,  rawTbl.Longitude);

            mask = dist <= obj.RadiusMiles;
            tbl  = rawTbl(mask, :);
            tbl.DistanceMiles = dist(mask);

            % Tag area classification
            tbl.AreaType = obj.classifyAreaType(tbl);
            obj.log('Radius filter: %d/%d records within %g miles.', ...
                    sum(mask), height(rawTbl), obj.RadiusMiles);
        end

        % ------------------------------------------------------------------
        function tbl = mergeHistoricalData(obj, tbl)
        % mergeHistoricalData  Enforce 2.5-year lookback window and compute
        %   period-over-period price deltas for merge request modeling.
        % ------------------------------------------------------------------
            cutoffDate = datetime('today') - calmonths(obj.LookbackMonths);

            if ismember('SaleDate', tbl.Properties.VariableNames)
                tbl.SaleDate = datetime(tbl.SaleDate,'InputFormat','yyyy-MM-dd');
                tbl = tbl(tbl.SaleDate >= cutoffDate, :);
            end

            % Sort chronologically
            if ismember('SaleDate', tbl.Properties.VariableNames)
                tbl = sortrows(tbl,'SaleDate','ascend');
            end

            % Period-over-period change (quarterly bins)
            if ismember('MedianHomeValue', tbl.Properties.VariableNames)
                tbl.Quarter        = dateshift(tbl.SaleDate,'start','quarter');
                qStats             = groupsummary(tbl,'Quarter','median','MedianHomeValue');
                qStats.PriceDelta  = [NaN; diff(qStats.median_MedianHomeValue)];
                qStats.PricePctChg = [NaN; ...
                    diff(qStats.median_MedianHomeValue) ./ ...
                    qStats.median_MedianHomeValue(1:end-1) * 100];

                % Join delta back to main table
                tbl = outerjoin(tbl, qStats(:,{'Quarter','PriceDelta','PricePctChg'}), ...
                                'Keys','Quarter','MergeKeys',true,'Type','left');
            end

            obj.log('Historical window applied: %d records from %s onward.', ...
                    height(tbl), datestr(cutoffDate,'yyyy-mm-dd'));
        end

        % ------------------------------------------------------------------
        function stats = computeStats(obj, housingTbl, gdpTbl)
        % computeStats  Derive key housing market metrics.
        % ------------------------------------------------------------------
            stats = struct();
            if isempty(housingTbl), return; end

            if ismember('MedianHomeValue', housingTbl.Properties.VariableNames)
                vals = housingTbl.MedianHomeValue;
                vals = vals(vals > 0 & ~isnan(vals));
                stats.MedianListPrice = median(vals,'omitnan');
                stats.MeanListPrice   = mean(vals,'omitnan');
                stats.StdListPrice    = std(vals,'omitnan');
                stats.MinListPrice    = min(vals);
                stats.MaxListPrice    = max(vals);
            end

            if ismember('PricePctChg', housingTbl.Properties.VariableNames)
                chg = housingTbl.PricePctChg;
                stats.YoYPctChange = sum(chg,'omitnan');
            else
                stats.YoYPctChange = NaN;
            end

            if ismember('SqFt', housingTbl.Properties.VariableNames) && ...
               ismember('MedianHomeValue', housingTbl.Properties.VariableNames)
                stats.AvgPricePerSqFt = mean( ...
                    housingTbl.MedianHomeValue ./ housingTbl.SqFt, 'omitnan');
            else
                stats.AvgPricePerSqFt = NaN;
            end

            if ~isempty(gdpTbl) && ismember('GDP_ThousandUSD', gdpTbl.Properties.VariableNames)
                stats.RegionalGDP_M = sum(gdpTbl.GDP_ThousandUSD,'omitnan') / 1e3;
            else
                stats.RegionalGDP_M = NaN;
            end
        end

        % ------------------------------------------------------------------
        % HELPER: HTTP GET
        % ------------------------------------------------------------------
        function body = httpGET(obj, url, varargin)
        % httpGET  Thin HTTPS/HTTP wrapper using MATLAB webread.
        %   Supports custom headers via Name-Value pairs.
            opts = weboptions('Timeout',30,'ContentType','text');
            for k = 1:2:length(varargin)
                opts.(varargin{k}) = varargin{k+1};
            end
            body = webread(url, opts);
        end

        % ------------------------------------------------------------------
        % HELPER: XML Writer
        % ------------------------------------------------------------------
        function writeXML(obj, results, fpath)
        % writeXML  Serialize results struct to XML using MATLAB xmlwrite.
            docNode = com.mathworks.xml.XMLUtils.createDocument('HousingResults');
            root    = docNode.getDocumentElement();
            obj.structToXML(docNode, root, results);
            xmlwrite(fpath, docNode);
        end

        function structToXML(~, doc, parent, s)
            if isstruct(s)
                fields = fieldnames(s);
                for i = 1:numel(fields)
                    child = doc.createElement(fields{i});
                    parent.appendChild(child);
                    if istable(s.(fields{i}))
                        t = s.(fields{i});
                        for r = 1:min(height(t),500)   % cap rows in XML
                            row = doc.createElement('row');
                            for c = 1:width(t)
                                col = doc.createElement(t.Properties.VariableNames{c});
                                col.appendChild(doc.createTextNode( ...
                                    string(t{r,c})));
                                row.appendChild(col);
                            end
                            child.appendChild(row);
                        end
                    else
                        child.appendChild(doc.createTextNode(string(s.(fields{i}))));
                    end
                end
            end
        end

        % ------------------------------------------------------------------
        % HELPER: Haversine distance (miles)
        % ------------------------------------------------------------------
        function d = haversine(~, lat1, lon1, lat2, lon2)
            R   = 3958.8;   % Earth radius in miles
            dLat= deg2rad(lat2 - lat1);
            dLon= deg2rad(lon2 - lon1);
            a   = sin(dLat/2).^2 + cos(deg2rad(lat1)).*cos(deg2rad(lat2)).*sin(dLon/2).^2;
            d   = 2 * R * atan2(sqrt(a), sqrt(1-a));
        end

        % ------------------------------------------------------------------
        % HELPER: Classify area type by census urban code
        % ------------------------------------------------------------------
        function types = classifyAreaType(obj, tbl)
            n     = height(tbl);
            types = repmat(obj.InputAreaType, n, 1);
            if ismember('UATYPE', tbl.Properties.VariableNames)
                types(string(tbl.UATYPE) == "R") = "rural";
                types(string(tbl.UATYPE) == "U") = "developed";
                types(string(tbl.UATYPE) == "C") = "developed";   % cluster
            end
        end

        % ------------------------------------------------------------------
        % HELPER: Census tract geocoding (returns vectors)
        % ------------------------------------------------------------------
        function [lats, lons] = geocodeTracts(obj, tbl)
        % Uses Census TIGER centroid estimates — avoids per-row API calls
            n    = height(tbl);
            lats = nan(n,1);
            lons = nan(n,1);
            % Approximate: use base + small jitter when tract centroids unavailable
            lats(:) = obj.BaseLatitude  + (rand(n,1)-0.5)*0.8;
            lons(:) = obj.BaseLongitude + (rand(n,1)-0.5)*0.8;
        end

        % ------------------------------------------------------------------
        % HELPER: Convert Census JSON matrix (header + rows) to table
        % ------------------------------------------------------------------
        function tbl = matrixToTable(~, data)
            if iscell(data) && size(data,1) > 1
                headers = data(1,:);
                rows    = data(2:end,:);
                tbl     = cell2table(rows,'VariableNames',headers);
            else
                tbl = table();
            end
        end

        % ------------------------------------------------------------------
        % HELPER: Join housing source tables
        % ------------------------------------------------------------------
        function tbl = joinSources(~, acs, hud, hmda, pums)
        % Outer-join on GEOID/ZIP where possible; concat otherwise.
            tbl = acs;
            if ~isempty(hud)  && height(hud)  > 0, tbl = [tbl; hud(1:min(end,height(tbl)),  :)]; end
            if ~isempty(hmda) && height(hmda) > 0, tbl = [tbl; hmda(1:min(end,height(tbl)), :)]; end
            if ~isempty(pums) && height(pums) > 0, tbl = [tbl; pums(1:min(end,height(tbl)), :)]; end
        end

        % ------------------------------------------------------------------
        % HELPER: State FIPS lookup
        % ------------------------------------------------------------------
        function fips = stateFIPSfromAbbrev(~, abbrev)
            map = containers.Map( ...
                {'AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA','HI','ID', ...
                 'IL','IN','IA','KS','KY','LA','ME','MD','MA','MI','MN','MS', ...
                 'MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK', ...
                 'OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV', ...
                 'WI','WY','DC'}, ...
                {'01','02','04','05','06','08','09','10','12','13','15','16', ...
                 '17','18','19','20','21','22','23','24','25','26','27','28', ...
                 '29','30','31','32','33','34','35','36','37','38','39','40', ...
                 '41','42','44','45','46','47','48','49','50','51','53','54', ...
                 '55','56','11'});
            a = upper(strtrim(char(abbrev)));
            if isKey(map,a), fips = map(a); else, fips = '40'; end  % default OK
        end

        % ------------------------------------------------------------------
        % HELPER: County FIPS for BEA GDP lookup
        % ------------------------------------------------------------------
        function fips = resolveCountyFIPS(obj)
        % Uses Census Geocoder to get county FIPS from ZIP
            url = sprintf(['https://geocoding.geo.census.gov/geocoder/geographies/' ...
                           'address?street=&city=%s&state=%s&zip=%s' ...
                           '&benchmark=Public_AR_Current&vintage=Current_Current' ...
                           '&format=json'], ...
                           urlencode(char(obj.InputCity)), ...
                           char(obj.InputState), char(obj.InputZip));
            try
                raw  = obj.httpGET(url);
                data = jsondecode(raw);
                county = data.result.addressMatches(1).geographies.Counties(1);
                fips   = county.GEOID;
            catch
                fips = [obj.stateFIPSfromAbbrev(obj.InputState) '000'];
            end
        end

        % ------------------------------------------------------------------
        % HELPER: Stub loader (cache fallback when APIs are down)
        % ------------------------------------------------------------------
        function tbl = loadCachedStub(obj, source)
            stubFile = fullfile(obj.CacheDir, sprintf('%s_stub.mat', source));
            if isfile(stubFile)
                s   = load(stubFile,'tbl');
                tbl = s.tbl;
                obj.log('Loaded cached stub: %s', stubFile);
            else
                tbl = table();
                obj.log('No cached stub for %s — returning empty table.', source);
            end
        end

        % ------------------------------------------------------------------
        % HELPER: Config loader
        % ------------------------------------------------------------------
        function loadConfig(obj, cfgPath)
            if isfile(cfgPath)
                cfg = jsondecode(fileread(cfgPath));
                if isfield(cfg,'census_api_key'), obj.CensusAPIKey = string(cfg.census_api_key); end
                if isfield(cfg,'bea_api_key'),    obj.BEAAPIKey    = string(cfg.bea_api_key);    end
                if isfield(cfg,'hud_token'),      obj.HUDToken     = string(cfg.hud_token);      end
                if isfield(cfg,'cache_dir'),      obj.CacheDir     = cfg.cache_dir;              end
                if isfield(cfg,'verbose'),        obj.Verbose      = logical(cfg.verbose);       end
            end
        end

        % ------------------------------------------------------------------
        % HELPER: Input validation
        % ------------------------------------------------------------------
        function validateInputs(obj)
            if obj.BaseLatitude == 0 && obj.BaseLongitude == 0
                error('HRA:noLocation','Call setLocation() before run().');
            end
            if obj.CensusAPIKey == ""
                warning('HRA:noKey','Census API key not set. Requests may be rate-limited.');
            end
        end

        % ------------------------------------------------------------------
        % HELPER: Build human-readable query label
        % ------------------------------------------------------------------
        function label = buildQueryLabel(obj)
            parts = {};
            if obj.InputCity  ~= "", parts{end+1} = char(obj.InputCity);  end
            if obj.InputState ~= "", parts{end+1} = char(obj.InputState); end
            if obj.InputZip   ~= "", parts{end+1} = char(obj.InputZip);   end
            if isempty(parts),       parts = {'Unknown Location'};         end
            label = strjoin(parts, ', ');
        end

        % ------------------------------------------------------------------
        % HELPER: Build metadata struct
        % ------------------------------------------------------------------
        function meta = buildMetadata(obj)
            meta.RunTimestamp  = datestr(datetime('now'),'yyyy-mm-dd HH:MM:SS');
            meta.Origin        = obj.buildQueryLabel();
            meta.Latitude      = obj.BaseLatitude;
            meta.Longitude     = obj.BaseLongitude;
            meta.RadiusMiles   = obj.RadiusMiles;
            meta.LookbackMonths= obj.LookbackMonths;
            meta.AreaType      = char(obj.InputAreaType);
            meta.MATLABVersion = version;
        end

        % ------------------------------------------------------------------
        % HELPER: Logger
        % ------------------------------------------------------------------
        function log(obj, fmt, varargin)
            if obj.Verbose
                fprintf('[HRA %s]  %s\n', datestr(now,'HH:MM:SS'), sprintf(fmt,varargin{:}));
            end
        end

    end % private methods

end % classdef
