function Start-StagelinQApi {
    <#
    .SYNOPSIS
        Starts a lightweight HTTP REST API that exposes the shared StagelinQ state dictionary.
    .DESCRIPTION
        Creates a System.Net.HttpListener and spins up a background runspace to serve
        requests. The API reads from the same ConcurrentDictionary that is populated by
        Start-StagelinQStreams (or seeded manually via $script:State for offline testing).

        All responses are JSON. CORS is open (Access-Control-Allow-Origin: *) so a browser
        dashboard or curl can hit the API without extra headers.

        Endpoints:
          GET /health          {"status":"ok","uptime":<seconds>}
          GET /state           Full snapshot of all keys as JSON
          GET /state/{key}     Single key value (URL-encode the key), 404 if missing
          GET /beats           Only BeatInfo/* keys
          GET /decks           StateMap keys grouped by deck number

        Call Stop-StagelinQApi when finished to shut the listener down cleanly.
    .PARAMETER Port
        TCP port to listen on. Default: 8080.
    .PARAMETER Prefix
        Full HttpListener prefix (e.g. 'http://+:8080/'). Defaults to
        "http://localhost:<Port>/" which works on Windows without elevation.
        Use 'http://*:<Port>/' or 'http://+:<Port>/' to bind to all interfaces
        (requires admin or a netsh urlacl entry on Windows).
    .OUTPUTS
        A PSCustomObject with Listener, Ps, Runspace, Handle, StartTime, Port, Prefix,
        and BaseUrl properties. Pass this object to Stop-StagelinQApi.
    .EXAMPLE
        $api = Start-StagelinQApi -Port 8080
        Invoke-RestMethod http://localhost:8080/health
        Stop-StagelinQApi -Api $api
    .EXAMPLE
        # Bind to all interfaces (requires admin on Windows)
        $api = Start-StagelinQApi -Port 8080 -Prefix 'http://*:8080/'
        Stop-StagelinQApi -Api $api
    .EXAMPLE
        # Seed state manually for offline testing
        $script:State['/Engine/Deck1/Track/SongName'] = 'Test Track'
        $api = Start-StagelinQApi
        Invoke-RestMethod http://localhost:8080/state
        Stop-StagelinQApi -Api $api
    #>
    param(
        [int]    $Port           = 8080,
        [string] $Prefix,
        [byte[]] $DashboardBytes = $null
    )

    # Default to localhost-only binding — works on Windows without elevation.
    # Wildcard bindings (http://*:Port/ or http://+:Port/) require either admin
    # privileges or a 'netsh http add urlacl' entry on Windows.
    $explicitPrefix = [bool]$Prefix
    if (-not $Prefix) {
        $Prefix = "http://localhost:$Port/"
    }

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($Prefix)
    try {
        $listener.Start()
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'already in use') {
            throw "TCP Port $Port is already in use by another process. Use -Port to choose a different port, or ensure the previous session is stopped with Stop-StagelinQSession."
        }
        # On Windows, wildcard/+ prefixes fail without elevation or a URL ACL.
        # If the caller did not specify -Prefix explicitly, retry with localhost.
        if (-not $explicitPrefix -and ($Prefix -match '\*|\+')) {
            Write-Warning "HttpListener could not bind to '$Prefix' (may need elevation on Windows). Retrying with localhost-only binding."
            $listener.Close()
            $listener = [System.Net.HttpListener]::new()
            $Prefix   = "http://localhost:$Port/"
            $listener.Prefixes.Add($Prefix)
            $listener.Start()   # let this throw naturally if it also fails
        } else {
            throw $_
        }
    }

    $startTime   = [datetime]::UtcNow
    $sharedState = $script:State   # reference to the module-level ConcurrentDictionary

    try {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $runspace.SessionStateProxy.SetVariable('listener',       $listener)
        $runspace.SessionStateProxy.SetVariable('sharedState',   $sharedState)
        $runspace.SessionStateProxy.SetVariable('startTime',     $startTime)
        $runspace.SessionStateProxy.SetVariable('dashboardBytes', $DashboardBytes)

        $ps = [powershell]::Create()
        $ps.Runspace = $runspace
        [void]$ps.AddScript({

        # ── helpers ────────────────────────────────────────────────────────────

        function Write-JsonResponse {
            param(
                [System.Net.HttpListenerContext]$Context,
                [int]$StatusCode = 200,
                $Body
            )
            $json  = $Body | ConvertTo-Json -Compress -Depth 5
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $Context.Response.StatusCode      = $StatusCode
            $Context.Response.ContentType     = 'application/json; charset=utf-8'
            $Context.Response.ContentLength64 = $bytes.Length
            $Context.Response.Headers.Add('Access-Control-Allow-Origin', '*')
            $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $Context.Response.OutputStream.Close()
        }

        function Get-StateSnapshot {
            $snap = @{}
            foreach ($kvp in $sharedState.GetEnumerator()) {
                $snap[$kvp.Key] = $kvp.Value
            }
            $snap
        }

        # ── request loop ───────────────────────────────────────────────────────

        while ($listener.IsListening) {
            try {
                $context = $listener.GetContext()
            } catch {
                break   # listener.Stop() was called — exit cleanly
            }

            $req     = $context.Request
            # Use RawUrl so percent-encoded slashes (%2F) in key segments are preserved
            $rawPath = ($req.RawUrl -split '\?')[0].TrimEnd('/')
            if ($rawPath -eq '') { $rawPath = '/' }

            try {
                # ── /health ───────────────────────────────────────────────────
                if ($rawPath -eq '/health') {
                    $uptime = ([datetime]::UtcNow - $startTime).TotalSeconds
                    Write-JsonResponse -Context $context -Body @{
                        status = 'ok'
                        uptime = [math]::Round($uptime, 3)
                    }
                }

                # ── /state (full snapshot) ────────────────────────────────────
                elseif ($rawPath -eq '/state') {
                    Write-JsonResponse -Context $context -Body (Get-StateSnapshot)
                }

                # ── /state/{key} (single key) ─────────────────────────────────
                elseif ($rawPath -like '/state/*') {
                    $encodedKey = $rawPath.Substring('/state/'.Length)
                    $key        = [Uri]::UnescapeDataString($encodedKey)
                    $val        = $null
                    if ($sharedState.TryGetValue($key, [ref]$val)) {
                        Write-JsonResponse -Context $context -Body $val
                    } else {
                        Write-JsonResponse -Context $context -StatusCode 404 -Body @{
                            error = "Key not found: $key"
                        }
                    }
                }

                # ── /beats (BeatInfo/* keys only) ─────────────────────────────
                elseif ($rawPath -eq '/beats') {
                    $beats = @{}
                    foreach ($kvp in $sharedState.GetEnumerator()) {
                        if ($kvp.Key -like 'BeatInfo/*') {
                            $beats[$kvp.Key] = $kvp.Value
                        }
                    }
                    Write-JsonResponse -Context $context -Body $beats
                }

                # ── /decks (StateMap keys grouped by deck) ────────────────────
                elseif ($rawPath -eq '/decks') {
                    $decks = @{}
                    foreach ($kvp in $sharedState.GetEnumerator()) {
                        if ($kvp.Key -notlike 'BeatInfo/*' -and $kvp.Key -match '/Deck(\d+)/') {
                            $deckKey = "Deck$($Matches[1])"
                            if (-not $decks.ContainsKey($deckKey)) { $decks[$deckKey] = @{} }
                            $decks[$deckKey][$kvp.Key] = $kvp.Value
                        }
                    }
                    Write-JsonResponse -Context $context -Body $decks
                }

                # ── /dashboard (serve pre-loaded HTML) ───────────────────────
                elseif ($rawPath -eq '/dashboard') {
                    if ($null -ne $dashboardBytes) {
                        $context.Response.StatusCode      = 200
                        $context.Response.ContentType     = 'text/html; charset=utf-8'
                        $context.Response.ContentLength64 = $dashboardBytes.Length
                        $context.Response.Headers.Add('Access-Control-Allow-Origin', '*')
                        $context.Response.OutputStream.Write($dashboardBytes, 0, $dashboardBytes.Length)
                        $context.Response.OutputStream.Close()
                    } else {
                        Write-JsonResponse -Context $context -StatusCode 404 -Body @{
                            error = 'Dashboard HTML not found'
                        }
                    }
                }

                # ── /debug (diagnostic info) ──────────────────────────────────
                elseif ($rawPath -eq '/debug') {
                    $snap = Get-StateSnapshot
                    $keys = @($snap.Keys) | Sort-Object
                    $beatKeys  = @($keys | Where-Object { $_ -like 'BeatInfo/*' })
                    $stateKeys = @($keys | Where-Object { $_ -notlike 'BeatInfo/*' })
                    Write-JsonResponse -Context $context -Body @{
                        totalKeys    = $keys.Count
                        beatInfoKeys = $beatKeys.Count
                        stateMapKeys = $stateKeys.Count
                        keys         = $keys
                        uptime       = [math]::Round(([datetime]::UtcNow - $startTime).TotalSeconds, 3)
                    }
                }

                # ── 404 for everything else ───────────────────────────────────
                else {
                    Write-JsonResponse -Context $context -StatusCode 404 -Body @{
                        error = "Not found: $rawPath"
                    }
                }
            } catch {
                # 500 — try to send an error body; ignore if response already started
                try {
                    Write-JsonResponse -Context $context -StatusCode 500 -Body @{
                        error = $_.Exception.Message
                    }
                } catch {}
            }
        }
    })

    $handle = $ps.BeginInvoke()

    # Derive the BaseUrl that clients (browser, Invoke-RestMethod) should use.
    # Wildcard/+ prefixes are server-side ACLs; the fetch URL must use a real host.
    $baseUrl = $Prefix -replace '^http://(\*|\+):', 'http://localhost:'
    $baseUrl = $baseUrl.TrimEnd('/')

    [PSCustomObject]@{
        Listener  = $listener
        Ps        = $ps
        Runspace  = $runspace
        Handle    = $handle
        StartTime = $startTime
        Port      = $Port
        Prefix    = $Prefix
        BaseUrl   = $baseUrl
    }
    } catch {
        # If anything failed after listener.Start(), shut it down
        try { $listener.Stop() } catch {}
        try { $listener.Close() } catch {}
        if ($ps) { try { $ps.Stop(); $ps.Dispose() } catch {} }
        if ($runspace) { try { $runspace.Close(); $runspace.Dispose() } catch {} }
        throw $_
    }
}
