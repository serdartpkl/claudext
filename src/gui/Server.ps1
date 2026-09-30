# The only file that touches HttpListener. Everything it does is translate:
# request in, handler call, response out. Keeping HTTP here is what lets every
# handler in Api.ps1 be tested without a socket.

$script:ClaudExtRoutes = @(
    @{ Method = 'GET';  Pattern = '^/$';               Handler = 'Page' }
    @{ Method = 'GET';  Pattern = '^/api/info$';       Handler = 'Invoke-ApiInfo' }
    @{ Method = 'GET';  Pattern = '^/api/tool$';       Handler = 'Invoke-ApiTool' }
    @{ Method = 'GET';  Pattern = '^/api/sources$';    Handler = 'Invoke-ApiSources' }
    @{ Method = 'GET';  Pattern = '^/api/browse$';     Handler = 'Invoke-ApiBrowse' }
    @{ Method = 'GET';  Pattern = '^/api/archive$';    Handler = 'Invoke-ApiArchive' }
    @{ Method = 'GET';  Pattern = '^/api/job/(?<Id>[A-Za-z0-9]+)$'; Handler = 'Invoke-ApiJob' }
    @{ Method = 'POST'; Pattern = '^/api/mapping$';    Handler = 'Invoke-ApiMapping' }
    @{ Method = 'POST'; Pattern = '^/api/backup$';     Handler = 'Invoke-ApiBackup' }
    @{ Method = 'POST'; Pattern = '^/api/restore$';    Handler = 'Invoke-ApiRestore' }
    @{ Method = 'POST'; Pattern = '^/api/shutdown$';   Handler = 'Invoke-ApiShutdown' }
)

function Resolve-ApiRoute {
    <#
    .SYNOPSIS
        Maps a method and path to a handler name, or $null when nothing matches.
    .DESCRIPTION
        Anchored patterns only, and named groups become RouteParams. An unknown
        path returns $null rather than falling through to something else.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path
    )

    $clean = $Path.Split('?')[0]

    foreach ($route in $script:ClaudExtRoutes) {
        if ($Method -ne $route.Method) { continue }
        $m = [regex]::Match($clean, $route.Pattern)
        if (-not $m.Success) { continue }

        $routeParams = @{}
        foreach ($name in ([regex]$route.Pattern).GetGroupNames()) {
            if ($name -match '^\d+$') { continue }
            $routeParams[$name] = $m.Groups[$name].Value
        }
        return [pscustomobject]@{ Handler = $route.Handler; RouteParams = $routeParams }
    }
    return $null
}

function ConvertFrom-QueryString {
    <#
    .SYNOPSIS
        Parses a query string into a hashtable with PascalCase keys.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Query)

    $result = @{}
    if ([string]::IsNullOrWhiteSpace($Query)) { return $result }

    foreach ($pair in $Query.TrimStart('?').Split('&')) {
        if (-not $pair) { continue }
        $bits = $pair.Split('=', 2)
        $key = [System.Uri]::UnescapeDataString($bits[0])
        $value = if ($bits.Count -gt 1) { [System.Uri]::UnescapeDataString($bits[1].Replace('+', ' ')) } else { '' }
        if (-not $key) { continue }
        # ToUpperInvariant, not ToUpper: on a Turkish system ToUpper maps 'i'
        # to 'İ', so 'includeFiles' would arrive as 'İncludeFiles' and never
        # match the parameter the handler reads.
        $key = $key.Substring(0, 1).ToUpperInvariant() + $key.Substring(1)
        if ($value -eq 'true') { $result[$key] = $true }
        elseif ($value -eq 'false') { $result[$key] = $false }
        else { $result[$key] = $value }
    }
    return $result
}

function Start-ClaudExtServer {
    <#
    .SYNOPSIS
        Runs the listener loop until stopped.
    .DESCRIPTION
        Binds to 127.0.0.1 only, so nothing outside the machine can connect.
        Every request is checked for the bearer token and a same-origin Origin
        header before dispatch, because any other tab in the browser can reach
        a localhost server.

        Handler exceptions become a 500 rather than killing the loop: a restore
        that failed should leave the interface usable enough to read the error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$PagePath
    )

    $selfOrigin = "http://127.0.0.1:$Port"
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("$selfOrigin/")
    $listener.Start()

    Write-Host "ClaudExt listening on $selfOrigin" -ForegroundColor Green
    Write-Host 'Press Ctrl+C to stop.' -ForegroundColor Gray

    $script:ClaudExtServerStopping = $false
    $script:ClaudExtStopWhenIdle = $false
    $script:ClaudExtResultDelivered = $false
    $idleSince = $null
    $pending = $null

    try {
        while ($listener.IsListening -and -not $script:ClaudExtServerStopping) {
            # Stop asked for while a job ran: the server goes once the job has
            # ended and the page has fetched its outcome. A tab in the
            # background can poll only every minute or so, so without a fetch
            # it waits ten minutes before going anyway.
            if ($script:ClaudExtStopWhenIdle) {
                if (Test-ClaudExtJobRunning) { $idleSince = $null }
                elseif (-not $idleSince) { $idleSince = [DateTime]::UtcNow }
                else {
                    $idle = ([DateTime]::UtcNow - $idleSince).TotalSeconds
                    if (($script:ClaudExtResultDelivered -and $idle -ge 2) -or $idle -ge 600) { break }
                }
            }

            # GetContext() blocks inside .NET, where PowerShell cannot deliver
            # Ctrl+C — the console ignores it until a request arrives. Waiting
            # on the async version in short slices hands control back between
            # waits, so the interrupt lands.
            #
            # The pending task is kept across iterations on purpose: starting a
            # fresh GetContextAsync() on every pass would queue accept
            # operations without ever consuming them, and the server stops
            # answering after a handful of reloads.
            if (-not $pending) { $pending = $listener.GetContextAsync() }
            if (-not $pending.AsyncWaitHandle.WaitOne(200)) { continue }

            $context = $pending.GetAwaiter().GetResult()
            $pending = $null
            $request = $context.Request
            $response = $context.Response

            try {
                $path = $request.Url.AbsolutePath
                $route = Resolve-ApiRoute -Method $request.HttpMethod -Path $path

                if (-not $route) {
                    Write-HttpResponse -Response $response -StatusCode 404 `
                        -Body (@{ error = 'Not found' } | ConvertTo-Json)
                    continue
                }

                # The page itself is fetched with the token in the query string;
                # API calls carry it in a header.
                $query = ConvertFrom-QueryString -Query $request.Url.Query
                $supplied = if ($route.Handler -eq 'Page') { [string]$query['T'] }
                            else { [string]$request.Headers['X-ClaudExt-Token'] }

                if (-not (Test-ClaudExtToken -Provided $supplied -Expected $Token)) {
                    Write-HttpResponse -Response $response -StatusCode 403 `
                        -Body (@{ error = 'Forbidden' } | ConvertTo-Json)
                    continue
                }

                $origin = [string]$request.Headers['Origin']
                if (-not (Test-ClaudExtOrigin -Origin $origin -SelfOrigin $selfOrigin)) {
                    Write-HttpResponse -Response $response -StatusCode 403 `
                        -Body (@{ error = 'Bad origin' } | ConvertTo-Json)
                    continue
                }

                if ($route.Handler -eq 'Page') {
                    $html = [System.IO.File]::ReadAllText($PagePath)
                    Write-HttpResponse -Response $response -StatusCode 200 -Body $html -ContentType 'text/html; charset=utf-8'
                    continue
                }

                $parameters = @{}
                foreach ($k in $query.Keys) { $parameters[$k] = $query[$k] }
                foreach ($k in $route.RouteParams.Keys) { $parameters[$k] = $route.RouteParams[$k] }

                if ($request.HttpMethod -eq 'POST' -and $request.HasEntityBody) {
                    $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                    try { $bodyText = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    if ($bodyText) {
                        $body = $bodyText | ConvertFrom-Json -AsHashtable
                        foreach ($k in $body.Keys) {
                            $key = $k.Substring(0, 1).ToUpperInvariant() + $k.Substring(1)
                            $parameters[$key] = $body[$k]
                        }
                    }
                }

                $result = & $route.Handler -Parameters $parameters

                if ($route.Handler -eq 'Invoke-ApiShutdown' -and $result.Ok -and $result.Data.Stopping) {
                    $script:ClaudExtServerStopping = $true
                }

                $payload = if ($result.Ok) { @{ ok = $true; data = $result.Data } }
                           else { @{ ok = $false; error = $result.Error } }
                Write-HttpResponse -Response $response -StatusCode $result.StatusCode `
                    -Body ($payload | ConvertTo-Json -Depth 12)
            }
            catch {
                # One bad request must not take the server down mid-restore.
                Write-HttpResponse -Response $response -StatusCode 500 `
                    -Body (@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json)
            }
        }
    }
    finally {
        if ($listener.IsListening) { $listener.Stop() }
        $listener.Close()
        Clear-ClaudExtJobs
        Write-Host 'Server stopped.' -ForegroundColor Gray
    }
}

function Write-HttpResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Response,
        [int]$StatusCode = 200,
        [string]$Body = '',
        [string]$ContentType = 'application/json; charset=utf-8'
    )

    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $Response.StatusCode = $StatusCode
        $Response.ContentType = $ContentType
        $Response.ContentLength64 = $bytes.Length
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    }
    catch { }
    finally { try { $Response.OutputStream.Close() } catch { } }
}
