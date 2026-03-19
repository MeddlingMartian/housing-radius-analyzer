function result = xmlParser(input, varargin)
% xmlParser  Parse XML from a URL, file path, or raw string into a
%   MATLAB struct or table — with HTTPS/HTTP and FTP protocol support.
%
%   Inputs:
%     input   – URL (https:// | http:// | ftp://)  OR  local file path
%               OR raw XML string starting with '<'
%
%   Optional Name-Value parameters:
%     'output'    – 'struct' (default) | 'table' | 'raw'
%     'xpath'     – XPath expression to extract a specific subtree
%     'encoding'  – character encoding override (default: 'UTF-8')
%     'timeout'   – HTTP request timeout in seconds (default: 30)
%     'headers'   – N×2 cell array of {'Header','Value'} pairs
%
%   Output:
%     result  – struct, table, or raw DOM node depending on 'output' param
%
%   Supported XML formats:
%     - Census.gov ACS/TIGER XML feeds
%     - HUD USPS ZIP crosswalk XML
%     - FHFA / CFPB HMDA XML exports
%     - BEA Regional GDP XML responses
%     - Generic RSS / Atom feeds
%
%   Examples:
%     % Parse Census TIGER county boundaries XML
%     url = 'https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb/State_County/MapServer/1/query?f=pxml';
%     s   = xmlParser(url);
%
%     % Parse local HUD file
%     s   = xmlParser('/data/hud_output.xml','output','table');
%
%     % FTP-fetched Census file
%     s   = xmlParser('ftp://ftp2.census.gov/pub/outgoing/geo/geo2010.xml');
%
%     % Raw string
%     s   = xmlParser('<root><val>100000</val></root>');
% -------------------------------------------------------------------------

    p = inputParser;
    addRequired(p,'input',@(x)ischar(x)||isstring(x));
    addParameter(p,'output',  'struct',  @ischar);
    addParameter(p,'xpath',   '',        @ischar);
    addParameter(p,'encoding','UTF-8',   @ischar);
    addParameter(p,'timeout', 30,        @isnumeric);
    addParameter(p,'headers', {},        @iscell);
    parse(p, input, varargin{:});

    rawXML = fetchInput(p.Results.input, p.Results.timeout, p.Results.headers);

    % Parse XML string into DOM document
    docNode = parseXMLString(rawXML);

    % Optional XPath selection
    if ~isempty(p.Results.xpath)
        docNode = xpathQuery(docNode, p.Results.xpath);
    end

    % Convert to requested output format
    switch lower(p.Results.output)
        case 'struct'
            result = domToStruct(docNode);
        case 'table'
            result = domToTable(docNode);
        case 'raw'
            result = docNode;
        otherwise
            error('xmlParser:badOutput','Unknown output type: %s', p.Results.output);
    end
end

% ===========================================================================
%  Input fetcher — handles https, http, ftp, file, raw string
% ===========================================================================

function rawXML = fetchInput(input, timeout, headers)
    input = strtrim(char(input));

    if startsWith(input,'<')
        % Raw XML string passed directly
        rawXML = input;
        return
    end

    if startsWith(input,'https://') || startsWith(input,'http://')
        % HTTP / HTTPS via webread
        opts = weboptions('Timeout', timeout, 'ContentType', 'text');
        if ~isempty(headers)
            opts.HeaderFields = headers;
        end
        rawXML = webread(input, opts);

    elseif startsWith(input,'ftp://')
        % FTP protocol — parse host and path from URL
        rest   = input(7:end);
        slashIdx = strfind(rest,'/');
        if isempty(slashIdx)
            error('xmlParser:ftpURL','FTP URL must include a path: ftp://host/path/file.xml');
        end
        host   = rest(1:slashIdx(1)-1);
        ftpPath= rest(slashIdx(1):end);
        [ftpDir, fileName, ext] = fileparts(ftpPath);
        localPath = fullfile(tempdir, [fileName ext]);

        f = ftp(host);
        cd(f, ftpDir);
        mget(f, [fileName ext], tempdir);
        close(f);

        rawXML = fileread(localPath);

    elseif isfile(input)
        rawXML = fileread(input);

    else
        error('xmlParser:unknownInput', ...
              'Input must be a URL (https/http/ftp), a file path, or a raw XML string.');
    end
end

% ===========================================================================
%  DOM parser
% ===========================================================================

function docNode = parseXMLString(rawXML)
    % Write to temp file then use xmlread (MATLAB built-in, uses Xerces)
    tmpFile = [tempname '.xml'];
    fid = fopen(tmpFile,'w','n','UTF-8');
    fprintf(fid,'%s', rawXML);
    fclose(fid);
    try
        docNode = xmlread(tmpFile);
        delete(tmpFile);
    catch ME
        delete(tmpFile);
        rethrow(ME);
    end
end

% ===========================================================================
%  XPath query (uses Java XPath engine bundled with MATLAB)
% ===========================================================================

function nodes = xpathQuery(docNode, xpathStr)
    import javax.xml.xpath.*
    factory = XPathFactory.newInstance();
    xpath   = factory.newXPath();
    expr    = xpath.compile(xpathStr);
    nodes   = expr.evaluate(docNode, XPathConstants.NODESET);
end

% ===========================================================================
%  DOM → MATLAB struct (recursive)
% ===========================================================================

function s = domToStruct(node)
    s = struct();
    if ischar(node) || isstring(node)
        s = char(node);
        return
    end

    try
        children = node.getChildNodes();
    catch
        s = char(node.getTextContent());
        return
    end

    for i = 0:children.getLength()-1
        child = children.item(i);
        nodeName  = char(child.getNodeName());
        nodeType  = child.getNodeType();

        if nodeType == 1   % ELEMENT_NODE
            fieldName = matlab.lang.makeValidName(nodeName);
            val       = domToStruct(child);

            if isfield(s, fieldName)
                % Repeated element — convert to cell array
                existing = s.(fieldName);
                if ~iscell(existing)
                    existing = {existing};
                end
                s.(fieldName) = [existing, {val}];
            else
                s.(fieldName) = val;
            end

            % Also capture attributes
            attrs = child.getAttributes();
            if ~isempty(attrs)
                for j = 0:attrs.getLength()-1
                    a    = attrs.item(j);
                    aKey = ['attr_' matlab.lang.makeValidName(char(a.getName()))];
                    s.(aKey) = char(a.getValue());
                end
            end

        elseif nodeType == 3 || nodeType == 4   % TEXT_NODE or CDATA
            txt = strtrim(char(child.getTextContent()));
            if ~isempty(txt)
                s = txt;
                return
            end
        end
    end
end

% ===========================================================================
%  DOM → MATLAB table (flattens first repeating element into rows)
% ===========================================================================

function tbl = domToTable(docNode)
    s = domToStruct(docNode);

    % Find first field that is a cell array (list of records)
    tbl   = table();
    names = fieldnames(s);
    for i = 1:numel(names)
        val = s.(names{i});
        if iscell(val) && ~isempty(val) && isstruct(val{1})
            rows  = struct2table([val{:}],'AsArray',true);
            tbl   = rows;
            return
        end
    end

    % Fallback: single struct row
    try
        tbl = struct2table(s,'AsArray',true);
    catch
        tbl = table();
        fprintf('[xmlParser] Could not convert DOM to table — returning empty.\n');
    end
end
