function Start-StagelinQSession {
    <#
    .SYNOPSIS
        Bootstrap the full StagelinQ pipeline in one call: discover, connect, stream, API, dashboard.
    .DESCRIPTION
        Orchestrates the complete StagelinQ workflow:
          1. Resolve and pre-load dashboard.html bytes
          2. Discover and connect to the target device (skipped in -DemoMode)
          3. Start StateMap + BeatInfo background stream runspaces (skipped in -DemoMode)
          4. In -DemoMode: seed the shared state dictionary with realistic data and start a
             beat-phase animator runspace so the dashboard is visually live without hardware
          5. Start the REST API (http://localhost:<Port>/) with a /dashboard endpoint
          6. Optionally open the browser automatically

        Returns a session handle object. Pass it to Stop-StagelinQSession when done.
    .PARAMETER TargetSoftwareName
        Software name advertised by the device in its StagelinQ discovery frame.
        Default: 'JP11S' (Denon Prime Go+).
    .PARAMETER TimeoutSeconds
        How long to wait for device discovery. Default: 15.
    .PARAMETER StateMapPath
        State paths to subscribe to. When omitted, Start-StagelinQStreams uses its own defaults
        (SongName, BPM, PlayState, Loop/Active for both decks, and Crossfader).
    .PARAMETER Port
        TCP port for the REST API. Default: 8080.
    .PARAMETER DashboardHtmlPath
        Explicit path to dashboard.html. Auto-resolved to the repo root when omitted.
    .PARAMETER OpenBrowser
        Open the default browser to http://localhost:<Port>/dashboard after startup.
    .PARAMETER DemoMode
        Skip device discovery. Seeds the shared state with realistic mock data and starts a
        beat-phase animator so the dashboard looks live. Ideal for conference demos.
    .PARAMETER Quiet
        Suppress all progress output.
    .OUTPUTS
        PSCustomObject with Device, Streams, Api, DemoPs, DemoRunspace, Port, DashboardUrl,
        IsDemoMode, and StartedAt properties. Pass to Stop-StagelinQSession.
    .EXAMPLE
        # Demo (no hardware required)
        $s = Start-StagelinQSession -DemoMode -OpenBrowser
        Stop-StagelinQSession -Session $s

    .EXAMPLE
        # Real hardware
        $s = Start-StagelinQSession -TargetSoftwareName 'JP11S' -OpenBrowser
        Stop-StagelinQSession -Session $s
    #>
    param(
        [string]   $TargetSoftwareName = 'JP11S',
        [int]      $TimeoutSeconds     = 15,
        [string[]] $StateMapPath,
        [int]      $Port               = 8080,
        [string]   $DashboardHtmlPath,
        [switch]   $OpenBrowser,
        [switch]   $DemoMode,
        [switch]   $Quiet
    )

    # ── progress helper ────────────────────────────────────────────────────────
    $writeStep = if ($Quiet) {
        { param([string]$m) }
    } else {
        { param([string]$m) Write-Host "  $m" -ForegroundColor DarkGray }
    }

    # ── Phase 0: resolve dashboard HTML ───────────────────────────────────────
    if (-not $DashboardHtmlPath) {
        $DashboardHtmlPath = Join-Path $script:ModuleRoot 'dashboard.html'
    }
    $DashboardHtmlPath = [System.IO.Path]::GetFullPath($DashboardHtmlPath)

    $dashboardBytes = $null
    if (Test-Path $DashboardHtmlPath) {
        $html = [System.IO.File]::ReadAllText($DashboardHtmlPath)
        # Patch the BASE URL to match the actual port we're using.
        # We use a script snippet that prefers the current window's origin if it matches the port,
        # otherwise falls back to the explicit localhost URL. This fixes issues when accessing by IP.
        $patch = "const BASE = window.location.port == '$Port' ? window.location.origin : 'http://localhost:$Port';"
        $html = $html -replace "const\s+BASE\s+=\s+'http://localhost:\d+';", $patch
        $dashboardBytes = [System.Text.Encoding]::UTF8.GetBytes($html)
        & $writeStep "Dashboard HTML loaded and patched for port $Port ($($dashboardBytes.Length) bytes)"
    } else {
        Write-Warning "dashboard.html not found at '$DashboardHtmlPath' — /dashboard endpoint will return 404"
    }

    $device       = $null
    $streams      = $null
    $animPs       = $null
    $animRunspace = $null

    # ── Phase 1: device discovery + connection (real hardware) ────────────────
    if (-not $DemoMode) {
        & $writeStep "Discovering '$TargetSoftwareName' on the network..."
        try {
            $connectParams = @{
                TargetSoftwareName = $TargetSoftwareName
                TimeoutSeconds     = $TimeoutSeconds
            }
            $device = Connect-StagelinQDevice @connectParams
        } catch {
            throw "Device discovery failed: $_"
        }
        & $writeStep "Connected to $($device.DeviceFrame.SoftwareName) at $($device.DeviceFrame.SourceAddress)"

        # ── Phase 2: start streams ─────────────────────────────────────────────
        & $writeStep "Starting StateMap + BeatInfo streams..."
        try {
            $streamParams = @{ Device = $device }
            if ($StateMapPath) { $streamParams['StateMapPath'] = $StateMapPath }
            $streams = Start-StagelinQStreams @streamParams
        } catch {
            try { Disconnect-StagelinQDevice -Device $device } catch {}
            throw "Failed to start streams: $_"
        }
        Start-Sleep -Milliseconds 500

        # Check for immediate background errors in stream runspaces
        $smErrors = $streams.StateMapPs.Streams.Error
        $biErrors = $streams.BeatInfoPs.Streams.Error
        if ($smErrors.Count -gt 0) {
            Write-Warning "StateMap stream error: $($smErrors[0])"
        }
        if ($biErrors.Count -gt 0) {
            Write-Warning "BeatInfo stream error: $($biErrors[0])"
        }

        if ($script:State.Count -eq 0) {
            & $writeStep "Warning: State dictionary is empty after stream startup. Streams may still be initializing..."
        } else {
            & $writeStep "Streams running. ($($script:State.Count) state keys received)"
        }
    }

    # ── Phase 2a: DemoMode — seed state + beat animator ──────────────────────
    if ($DemoMode) {
        & $writeStep "DemoMode: seeding mock state..."

        $script:State['/Engine/Deck1/Track/SongName']         = 'Midnight City (M83)'
        $script:State['/Engine/Deck1/Track/ArtistName']        = 'M83'
        $script:State['/Engine/Deck1/CurrentBPM']             = 104.998
        $script:State['/Engine/Deck1/PlayState']              = 'true'
        $script:State['/Engine/Deck1/Loop/Active']            = 'false'
        $script:State['/Engine/Deck2/Track/SongName']         = 'Strobe (deadmau5)'
        $script:State['/Engine/Deck2/Track/ArtistName']        = 'deadmau5'
        $script:State['/Engine/Deck2/CurrentBPM']             = 128.0
        $script:State['/Engine/Deck2/PlayState']              = 'true'
        $script:State['/Engine/Deck2/Loop/Active']            = 'true'
        $script:State['BeatInfo/Deck1/Phase']                 = 0.0
        $script:State['BeatInfo/Deck1/BPM']                   = 104.998
        $script:State['BeatInfo/Deck1/BeatIndex']             = 0
        $script:State['BeatInfo/Deck2/Phase']                 = 0.5   # offset so decks flash out-of-sync
        $script:State['BeatInfo/Deck2/BPM']                   = 128.0
        $script:State['BeatInfo/Deck2/BeatIndex']             = 0
        $script:State['/Engine/Master/Crossfader/Position']   = -0.2

        & $writeStep "Starting beat animator..."
        $animRunspace = [runspacefactory]::CreateRunspace()
        $animRunspace.Open()
        $animRunspace.SessionStateProxy.SetVariable('sharedState', $script:State)

        $animPs = [powershell]::Create()
        $animPs.Runspace = $animRunspace
        [void]$animPs.AddScript({
            $lastTick = [datetime]::UtcNow
            while ($true) {
                Start-Sleep -Milliseconds 50
                $now     = [datetime]::UtcNow
                $elapsed = ($now - $lastTick).TotalSeconds
                $lastTick = $now

                foreach ($deck in 1, 2) {
                    $phaseKey = "BeatInfo/Deck$deck/Phase"
                    $idxKey   = "BeatInfo/Deck$deck/BeatIndex"
                    $bpmKey   = "BeatInfo/Deck$deck/BPM"

                    $bpm   = [double]$sharedState[$bpmKey]
                    if ($bpm -le 0) { $bpm = 120.0 }
                    $phase = [double]$sharedState[$phaseKey]
                    $idx   = [int]$sharedState[$idxKey]

                    $phase += ($bpm / 60.0) * $elapsed
                    if ($phase -ge 1.0) {
                        $phase = $phase - [math]::Floor($phase)
                        $idx++
                    }
                    $sharedState[$phaseKey] = $phase
                    $sharedState[$idxKey]   = $idx
                }
            }
        })
        [void]$animPs.BeginInvoke()
        & $writeStep "Beat animator running."
    }

    # ── Phase 3: start the REST API ───────────────────────────────────────────
    & $writeStep "Starting REST API on port $Port..."
    $apiParams = @{ Port = $Port }
    if ($null -ne $dashboardBytes) { $apiParams['DashboardBytes'] = $dashboardBytes }
    try {
        $api = Start-StagelinQApi @apiParams
    } catch {
        if ($animPs)  { try { $animPs.Stop();  $animPs.Dispose()  } catch {} }
        if ($animRunspace) { try { $animRunspace.Close() } catch {} }
        if ($streams) { try { Stop-StagelinQStreams -Streams $streams } catch {} }
        if ($device)  { try { Disconnect-StagelinQDevice -Device $device } catch {} }
        throw "Failed to start API: $_"
    }
    Start-Sleep -Milliseconds 400
    & $writeStep "API listening at http://localhost:$Port/"

    # ── Phase 4: open browser ─────────────────────────────────────────────────
    if ($OpenBrowser) {
        $url = "http://localhost:$Port/dashboard"
        & $writeStep "Opening browser at $url"
        if ($IsMacOS) { & open $url }
        else          { Start-Process $url }
    }

    # ── Phase 5: build and return session handle ──────────────────────────────
    $session = [PSCustomObject]@{
        Device       = $device
        Streams      = $streams
        Api          = $api
        DemoPs       = $animPs
        DemoRunspace = $animRunspace
        Port         = $Port
        DashboardUrl = "http://localhost:$Port/dashboard"
        IsDemoMode   = $DemoMode.IsPresent
        StartedAt    = [datetime]::UtcNow
    }

    if (-not $Quiet) {
        Write-Host ''
        Write-Host '  Session ready.' -ForegroundColor Green
        Write-Host "  Dashboard : $($session.DashboardUrl)" -ForegroundColor Cyan
        Write-Host "  API state : http://localhost:$Port/state" -ForegroundColor Cyan
        Write-Host "  Stop with : Stop-StagelinQSession -Session `$session" -ForegroundColor DarkGray
        Write-Host ''
    }

    $session
}
