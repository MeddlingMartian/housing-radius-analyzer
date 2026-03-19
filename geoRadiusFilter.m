function filteredTbl = geoRadiusFilter(tbl, originLat, originLon, radiusMiles, areaTypeFilter)
% geoRadiusFilter  Spatial filter — retain rows within a given radius.
%
%   Inputs:
%     tbl            – MATLAB table containing Latitude + Longitude columns
%     originLat      – Center point latitude  (WGS-84 decimal degrees)
%     originLon      – Center point longitude (WGS-84 decimal degrees)
%     radiusMiles    – Radius in miles  (default: 35)
%     areaTypeFilter – 'all' | 'developed' | 'rural' | 'suburban' (default:'all')
%
%   Output:
%     filteredTbl – Input table with rows outside radius removed, plus:
%                   .DistanceMiles – distance from origin to each record
%                   .AreaType      – classified area type string
%                   .BearingDeg    – bearing from origin (0=N, 90=E, ...)
%                   .GeoBin        – concentric ring label (0-10, 10-20, 20-35 mi)
%
%   Example:
%     filt = geoRadiusFilter(myTable, 36.7473, -95.9700, 35, 'all');
% -------------------------------------------------------------------------

    if nargin < 4, radiusMiles    = 35;    end
    if nargin < 5, areaTypeFilter = 'all'; end

    REQUIRED = {'Latitude','Longitude'};
    for i = 1:numel(REQUIRED)
        if ~ismember(REQUIRED{i}, tbl.Properties.VariableNames)
            error('geoRadiusFilter:missingCol', ...
                  'Table must contain column: %s', REQUIRED{i});
        end
    end

    % -----------------------------------------------------------------------
    % Haversine distance from origin to every row
    % -----------------------------------------------------------------------
    dist = haversineMiles(originLat, originLon, tbl.Latitude, tbl.Longitude);
    mask = dist <= radiusMiles & ~isnan(dist);

    filteredTbl = tbl(mask, :);
    filteredTbl.DistanceMiles = dist(mask);

    % -----------------------------------------------------------------------
    % Bearing (compass direction from origin)
    % -----------------------------------------------------------------------
    filteredTbl.BearingDeg = bearingDeg(originLat, originLon, ...
                                         filteredTbl.Latitude, filteredTbl.Longitude);

    % -----------------------------------------------------------------------
    % Concentric ring classification
    % -----------------------------------------------------------------------
    d = filteredTbl.DistanceMiles;
    bins = strings(height(filteredTbl),1);
    bins(d <= 10)               = "0-10 mi";
    bins(d > 10 & d <= 20)      = "10-20 mi";
    bins(d > 20 & d <= 30)      = "20-30 mi";
    bins(d > 30 & d <= radiusMiles) = sprintf("30-%g mi", radiusMiles);
    filteredTbl.GeoBin = bins;

    % -----------------------------------------------------------------------
    % Area type classification
    % -----------------------------------------------------------------------
    filteredTbl.AreaType = classifyAreaType(filteredTbl);

    % -----------------------------------------------------------------------
    % Apply area type filter
    % -----------------------------------------------------------------------
    if ~strcmpi(areaTypeFilter,'all')
        typeMask = strcmpi(filteredTbl.AreaType, areaTypeFilter);
        filteredTbl = filteredTbl(typeMask, :);
        fprintf('[geoRadiusFilter] Area filter "%s": %d/%d rows retained.\n', ...
                areaTypeFilter, height(filteredTbl), sum(mask));
    end

    % -----------------------------------------------------------------------
    % Sort by distance ascending
    % -----------------------------------------------------------------------
    filteredTbl = sortrows(filteredTbl,'DistanceMiles','ascend');

    fprintf('[geoRadiusFilter] %d records within %g miles of (%.4f, %.4f).\n', ...
            height(filteredTbl), radiusMiles, originLat, originLon);
end

% ===========================================================================

function mergedTbl = mergeHistoricalData(tbl, lookbackMonths)
% mergeHistoricalData  Enforce a 2.5-year (30-month) rolling window and
%   compute period-over-period price change metrics — designed to feed a
%   "pull merge request" workflow for housing price trend analysis.
%
%   Inputs:
%     tbl            – Housing table (must have MedianHomeValue or SalePrice)
%     lookbackMonths – Lookback window in months (default: 30 = 2.5 years)
%
%   Output:
%     mergedTbl – Enriched table with additional columns:
%                 .PeriodQuarter   – quarter date bin
%                 .QuarterlyMedian – median value for that quarter
%                 .QoQDelta        – quarter-over-quarter dollar change
%                 .QoQPctChange    – quarter-over-quarter % change
%                 .YoYDelta        – year-over-year dollar change
%                 .YoYPctChange    – year-over-year % change
%                 .TrendSignal     – 'Rising'|'Falling'|'Flat'|'Volatile'
%                 .MergeFlag       – boolean, true = new data since last pull
% -------------------------------------------------------------------------

    if nargin < 2, lookbackMonths = 30; end

    cutoffDate = datetime('today') - calmonths(lookbackMonths);
    mergedTbl  = tbl;

    % -----------------------------------------------------------------------
    % 1. Apply time-window filter
    % -----------------------------------------------------------------------
    dateCol = '';
    for candidate = {'SaleDate','OriginationDate','RecordDate','YearMonth'}
        if ismember(candidate{1}, tbl.Properties.VariableNames)
            dateCol = candidate{1};
            break
        end
    end

    if ~isempty(dateCol)
        if ~isdatetime(mergedTbl.(dateCol))
            mergedTbl.(dateCol) = datetime(mergedTbl.(dateCol));
        end
        mergedTbl = mergedTbl(mergedTbl.(dateCol) >= cutoffDate, :);
        fprintf('[mergeHistoricalData] Time filter applied: %d records from %s.\n', ...
                height(mergedTbl), datestr(cutoffDate,'mmm-yyyy'));
    else
        fprintf('[mergeHistoricalData] No date column found — skipping time filter.\n');
    end

    % -----------------------------------------------------------------------
    % 2. Detect price column
    % -----------------------------------------------------------------------
    priceCol = '';
    for candidate = {'MedianHomeValue','SalePrice','LoanAmount','VALP'}
        if ismember(candidate{1}, mergedTbl.Properties.VariableNames)
            priceCol = candidate{1};
            break
        end
    end

    if isempty(priceCol)
        fprintf('[mergeHistoricalData] No price column detected. Skipping delta computation.\n');
        mergedTbl.MergeFlag = true(height(mergedTbl),1);
        return
    end

    % -----------------------------------------------------------------------
    % 3. Quarter binning & QoQ metrics
    % -----------------------------------------------------------------------
    if ~isempty(dateCol)
        mergedTbl.PeriodQuarter = dateshift(mergedTbl.(dateCol),'start','quarter');
        qSummary = groupsummary(mergedTbl, 'PeriodQuarter', ...
                                {'median','std','min','max'}, priceCol);
        qSummary = sortrows(qSummary,'PeriodQuarter','ascend');

        medCol = ['median_' priceCol];
        nQ     = height(qSummary);

        qSummary.QoQDelta    = [NaN; diff(qSummary.(medCol))];
        qSummary.QoQPctChange= [NaN; diff(qSummary.(medCol)) ./ ...
                                       qSummary.(medCol)(1:end-1) * 100];

        % YoY (4-quarter lag)
        yoyDelta = nan(nQ,1);
        yoyPct   = nan(nQ,1);
        for i = 5:nQ
            yoyDelta(i) = qSummary.(medCol)(i) - qSummary.(medCol)(i-4);
            yoyPct(i)   = yoyDelta(i) / qSummary.(medCol)(i-4) * 100;
        end
        qSummary.YoYDelta     = yoyDelta;
        qSummary.YoYPctChange = yoyPct;

        % Trend signal
        qSummary.TrendSignal = classifyTrend(qSummary.QoQPctChange);

        % Rename median column
        qSummary = renamevars(qSummary, medCol, 'QuarterlyMedian');

        % Join back to row-level table
        keepQ = {'PeriodQuarter','QuarterlyMedian','QoQDelta','QoQPctChange', ...
                 'YoYDelta','YoYPctChange','TrendSignal'};
        keepQ = intersect(keepQ, qSummary.Properties.VariableNames);

        mergedTbl = outerjoin(mergedTbl, qSummary(:,keepQ), ...
                              'Keys','PeriodQuarter','MergeKeys',true,'Type','left');

        fprintf('[mergeHistoricalData] Quarterly summary: %d quarters | Latest YoY: %+.1f%%\n', ...
                nQ, yoyPct(end));
    end

    % -----------------------------------------------------------------------
    % 4. MergeFlag — marks records newer than last known pull
    % -----------------------------------------------------------------------
    lastPullFile = fullfile(tempdir,'hra_last_pull.mat');
    if isfile(lastPullFile)
        s = load(lastPullFile,'lastPullDate');
        if ~isempty(dateCol) && isdatetime(mergedTbl.(dateCol))
            mergedTbl.MergeFlag = mergedTbl.(dateCol) > s.lastPullDate;
        else
            mergedTbl.MergeFlag = false(height(mergedTbl),1);
        end
    else
        mergedTbl.MergeFlag = true(height(mergedTbl),1);
    end

    % Save current pull timestamp
    lastPullDate = datetime('now'); %#ok<NASGU>
    save(lastPullFile, 'lastPullDate');

    fprintf('[mergeHistoricalData] MergeFlag set: %d new records since last pull.\n', ...
            sum(mergedTbl.MergeFlag));
end

% ===========================================================================
%  Private helpers
% ===========================================================================

function d = haversineMiles(lat1, lon1, lat2, lon2)
    R    = 3958.8;
    dLat = deg2rad(lat2 - lat1);
    dLon = deg2rad(lon2 - lon1);
    a    = sin(dLat/2).^2 + cos(deg2rad(lat1)).*cos(deg2rad(lat2)).*sin(dLon/2).^2;
    d    = 2 * R * atan2(sqrt(a), sqrt(1-a));
end

function bear = bearingDeg(lat1, lon1, lat2, lon2)
    dLon  = deg2rad(lon2 - lon1);
    lat1r = deg2rad(lat1);
    lat2r = deg2rad(lat2);
    x     = sin(dLon) .* cos(lat2r);
    y     = cos(lat1r).*sin(lat2r) - sin(lat1r).*cos(lat2r).*cos(dLon);
    bear  = mod(rad2deg(atan2(x,y)), 360);
end

function types = classifyAreaType(tbl)
    n     = height(tbl);
    types = repmat("developed", n, 1);
    if ismember('UATYPE', tbl.Properties.VariableNames)
        types(string(tbl.UATYPE) == "R") = "rural";
        types(string(tbl.UATYPE) == "U") = "developed";
    end
    if ismember('DistanceMiles', tbl.Properties.VariableNames)
        types(tbl.DistanceMiles > 20 & types ~= "rural") = "suburban";
    end
end

function signals = classifyTrend(pctChanges)
    n       = numel(pctChanges);
    signals = strings(n,1);
    for i = 1:n
        v = pctChanges(i);
        if isnan(v)
            signals(i) = "N/A";
        elseif v > 2
            signals(i) = "Rising";
        elseif v < -2
            signals(i) = "Falling";
        elseif abs(v) <= 0.5
            signals(i) = "Flat";
        else
            signals(i) = "Volatile";
        end
    end
end
