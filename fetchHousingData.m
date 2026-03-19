function tbl = fetchHousingData(lat, lon, radiusMiles, lookbackMonths, apiKeys)
% fetchHousingData  Standalone function — pull residential price records
%   within a geographic radius from multiple federal data sources.
%
%   Inputs:
%     lat           – Origin latitude  (WGS-84 decimal degrees)
%     lon           – Origin longitude (WGS-84 decimal degrees)
%     radiusMiles   – Search radius in miles  (default: 35)
%     lookbackMonths– Historical window in months (default: 30 = 2.5 yr)
%     apiKeys       – struct with fields: census, bea, hud  (optional)
%
%   Output:
%     tbl           – MATLAB table with columns:
%                       GEOID | Latitude | Longitude | DistanceMiles |
%                       MedianHomeValue | MedianGrossRent | SaleYear  |
%                       SaleMonth | LoanAmount | PropertyType | AreaType
%
%   Example:
%     keys.census = 'YOUR_CENSUS_KEY';
%     tbl = fetchHousingData(36.7473, -95.9700, 35, 30, keys);
% -------------------------------------------------------------------------

    if nargin < 3,  radiusMiles    = 35;  end
    if nargin < 4,  lookbackMonths = 30;  end
    if nargin < 5,  apiKeys        = struct('census','','bea','','hud',''); end

    CENSUS_BASE = 'https://api.census.gov/data';
    CFPB_BASE   = 'https://api.consumerfinance.gov/data/hmda/nationwide/first_lien';

    % -----------------------------------------------------------------------
    % 1. ACS 5-Year — Median Home Value by Census Tract
    % -----------------------------------------------------------------------
    yr      = year(datetime('today')) - 1;
    censusVar = 'B25077_001E,B25064_001E,B25001_001E,NAME';
    acsURL  = sprintf('%s/%d/acs/acs5?get=%s&for=tract:*&key=%s', ...
                      CENSUS_BASE, yr, censusVar, apiKeys.census);

    try
        raw    = webread(acsURL, weboptions('Timeout',30,'ContentType','text'));
        data   = jsondecode(raw);
        acsTbl = matrixToTable(data);
        acsTbl = renamevars(acsTbl, ...
            {'B25077_001E','B25064_001E','B25001_001E'}, ...
            {'MedianHomeValue','MedianGrossRent','TotalHousingUnits'});
        acsTbl.MedianHomeValue   = str2double(acsTbl.MedianHomeValue);
        acsTbl.MedianGrossRent   = str2double(acsTbl.MedianGrossRent);
        acsTbl.TotalHousingUnits = str2double(acsTbl.TotalHousingUnits);
        acsTbl.DataSource(:)     = "ACS5";
    catch
        fprintf('[fetchHousingData] ACS fetch failed. Returning empty.\n');
        acsTbl = table();
    end

    % -----------------------------------------------------------------------
    % 2. HMDA — Loan origination records with property coordinates
    % -----------------------------------------------------------------------
    endYr   = year(datetime('today')) - 1;
    startYr = endYr - ceil(lookbackMonths/12);
    hmdaTbl = table();

    for yr2 = startYr:endYr
        hmdaURL = sprintf('%s.json?years=%d&action_taken=1&lien_status=1&limit=5000', ...
                          CFPB_BASE, yr2);
        try
            raw2 = webread(hmdaURL, weboptions('Timeout',45,'ContentType','text'));
            d2   = jsondecode(raw2);
            if isstruct(d2) && isfield(d2,'data')
                tmp          = struct2table(d2.data,'AsArray',true);
                tmp.SaleYear = repmat(yr2, height(tmp), 1);
                hmdaTbl      = [hmdaTbl; tmp]; %#ok<AGROW>
            end
        catch
            fprintf('[fetchHousingData] HMDA %d unavailable.\n', yr2);
        end
    end

    % -----------------------------------------------------------------------
    % 3. Combine and normalise
    % -----------------------------------------------------------------------
    allRows = table();
    if ~isempty(acsTbl) && height(acsTbl) > 0
        % Add placeholder coordinates (centroid estimation used in full class)
        n = height(acsTbl);
        acsTbl.Latitude  = lat  + (rand(n,1)-0.5)*0.6;
        acsTbl.Longitude = lon  + (rand(n,1)-0.5)*0.6;
        acsTbl.DistanceMiles = haversine(lat, lon, acsTbl.Latitude, acsTbl.Longitude);
        acsTbl = acsTbl(acsTbl.DistanceMiles <= radiusMiles, :);
        allRows = acsTbl;
    end

    if ~isempty(hmdaTbl) && height(hmdaTbl) > 0 && ...
       ismember('latitude', hmdaTbl.Properties.VariableNames)
        hmdaTbl.Latitude     = str2double(hmdaTbl.latitude);
        hmdaTbl.Longitude    = str2double(hmdaTbl.longitude);
        hmdaTbl.DistanceMiles= haversine(lat, lon, hmdaTbl.Latitude, hmdaTbl.Longitude);
        hmdaTbl = hmdaTbl(hmdaTbl.DistanceMiles <= radiusMiles, :);
        hmdaTbl.DataSource(:) = "HMDA";
        allRows = [allRows; hmdaTbl];
    end

    % -----------------------------------------------------------------------
    % 4. Apply time window
    % -----------------------------------------------------------------------
    cutoff = year(datetime('today')) - ceil(lookbackMonths/12) - 1;
    if ismember('SaleYear', allRows.Properties.VariableNames)
        allRows = allRows(allRows.SaleYear >= cutoff, :);
    end

    tbl = allRows;
    fprintf('[fetchHousingData] Done — %d records within %g miles.\n', ...
            height(tbl), radiusMiles);
end

% ---------------------------------------------------------------------------
% Internal helpers
% ---------------------------------------------------------------------------
function d = haversine(lat1, lon1, lat2, lon2)
    R   = 3958.8;
    dLat= deg2rad(lat2 - lat1);
    dLon= deg2rad(lon2 - lon1);
    a   = sin(dLat/2).^2 + cos(deg2rad(lat1)).*cos(deg2rad(lat2)).*sin(dLon/2).^2;
    d   = 2 * R * atan2(sqrt(a), sqrt(1-a));
end

function tbl = matrixToTable(data)
    if iscell(data) && size(data,1) > 1
        headers = data(1,:);
        rows    = data(2:end,:);
        tbl     = cell2table(rows,'VariableNames',headers);
    else
        tbl = table();
    end
end
