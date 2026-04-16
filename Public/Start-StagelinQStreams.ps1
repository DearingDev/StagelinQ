function Start-StagelinQStreams {
    <#
    .SYNOPSIS
        Starts StateMap and BeatInfo streams concurrently and merges output into a shared state store.
    .DESCRIPTION
        Spins up two background PowerShell runspaces — one for the StateMap service and
        one for the BeatInfo service — and wires them both to write into the module-level
        ConcurrentDictionary ($script:State). Use Get-StagelinQSnapshot to read a
        point-in-time copy of that dictionary. Call Stop-StagelinQStreams to shut down
        cleanly when finished.

        StateMap keys are stored verbatim (e.g. '/Engine/Deck1/CurrentBPM').
        BeatInfo keys follow the pattern 'BeatInfo/Deck<N>/Phase|BPM|BeatIndex'.
    .PARAMETER Device
        The device connection object returned by Connect-StagelinQDevice.
    .PARAMETER StateMapPath
        One or more StateMap paths to subscribe to. Defaults to a standard set covering
        song name, BPM, play state, crossfader, and loop active for both decks.
    .OUTPUTS
        A handle PSCustomObject with StateMapPs, StateMapRunspace, BeatInfoPs, and
        BeatInfoRunspace properties. Pass this to Stop-StagelinQStreams when done.
    .EXAMPLE
        $device  = Connect-StagelinQDevice -TargetSoftwareName 'JP11S'
        $streams = Start-StagelinQStreams -Device $device
        Start-Sleep -Seconds 5
        Get-StagelinQSnapshot | Format-Table -AutoSize
        Stop-StagelinQStreams -Streams $streams
        Disconnect-StagelinQDevice -Device $device
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Device,

        [string[]]$StateMapPath = @(
            '/Engine/Deck1/Track/SongName',
            '/Engine/Deck1/Track/ArtistName',
            '/Engine/Deck2/Track/SongName',
            '/Engine/Deck2/Track/ArtistName',
            '/Engine/Deck1/CurrentBPM',
            '/Engine/Deck2/CurrentBPM',
            '/Engine/Deck1/PlayState',
            '/Engine/Deck2/PlayState',
            '/Engine/Master/Crossfader/Position',
            '/Engine/Deck1/Track/LoopEnableState',
            '/Engine/Deck2/Track/LoopEnableState'
        )
    )

    $manifestPath = Join-Path $script:ModuleRoot 'StagelinQ.psd1'
    $sharedState  = $script:State

    # ── StateMap runspace ─────────────────────────────────────────────────────
    $smRunspace = [runspacefactory]::CreateRunspace()
    $smRunspace.Open()
    $smRunspace.SessionStateProxy.SetVariable('sharedState',  $sharedState)
    $smRunspace.SessionStateProxy.SetVariable('manifestPath', $manifestPath)
    $smRunspace.SessionStateProxy.SetVariable('device',       $Device)
    $smRunspace.SessionStateProxy.SetVariable('paths',        $StateMapPath)

    $smPs = [powershell]::Create()
    $smPs.Runspace = $smRunspace
    [void]$smPs.AddScript({
        Import-Module $manifestPath -Force
        $smConn = Connect-StagelinQStateMap -Device $device
        Register-StateMapPath -Connection $smConn -Path $paths
        try {
            while ($true) {
                $updates = Read-StateMapValue -Connection $smConn
                foreach ($u in $updates) {
                    # StagelinQ values are JSON-wrapped:
                    #   type 0 (numeric) -> {"value": 123.5, "type": 0}
                    #   type 1 (boolean) -> {"state": true, "type": 1}
                    #   type 8 (string)  -> {"string": "Track Name", "type": 8}
                    # We attempt to parse with ConvertFrom-Json first, falling back to regex
                    # if the string contains trailing garbage (common in the protocol).
                    $stored = $u.Value
                    try {
                        $p = $u.Value | ConvertFrom-Json -ErrorAction Stop
                        if     ($null -ne $p.PSObject.Properties['string']) { $stored = [string]$p.string }
                        elseif ($null -ne $p.PSObject.Properties['value'])  { $stored = [double]$p.value }
                        elseif ($null -ne $p.PSObject.Properties['state'])  { $stored = [bool]$p.state }
                    } catch {
                        if     ($u.Value -match '"string"\s*:\s*"((?:[^"\\]|\\.)*)"') { $stored = [string]$Matches[1] }
                        elseif ($u.Value -match '"value"\s*:\s*(-?[\d.]+(?:[eE][+-]?\d+)?)') { 
                            $stored = [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture) 
                        }
                        elseif ($u.Value -match '"state"\s*:\s*(true|false)') { $stored = [bool]($Matches[1] -eq 'true') }
                    }
                    $sharedState[$u.Path] = $stored
                }
            }
        } finally {
            try { $smConn.Stream.Close() }    catch {}
            try { $smConn.TcpClient.Close() } catch {}
        }
    })
    $smHandle = $smPs.BeginInvoke()

    # ── BeatInfo runspace ─────────────────────────────────────────────────────
    # Pre-check: verify BeatInfo service was discovered
    $beatInfoPort = $null
    try { $beatInfoPort = Get-StagelinQService -Device $Device -Name 'BeatInfo' } catch {}
    if (-not $beatInfoPort -or $beatInfoPort -eq 0) {
        Write-Warning "BeatInfo service not found on device. Beat phase/index will be unavailable."
        $sharedState['_error/BeatInfo'] = 'Service not advertised by device'
    }

    $biRunspace = [runspacefactory]::CreateRunspace()
    $biRunspace.Open()
    $biRunspace.SessionStateProxy.SetVariable('sharedState',  $sharedState)
    $biRunspace.SessionStateProxy.SetVariable('manifestPath', $manifestPath)
    $biRunspace.SessionStateProxy.SetVariable('device',       $Device)

    $biPs = [powershell]::Create()
    $biPs.Runspace = $biRunspace
    [void]$biPs.AddScript({
        Import-Module $manifestPath -Force
        try {
            $biConn = Connect-StagelinQBeatInfo -Device $device
        } catch {
            $sharedState['_error/BeatInfo'] = "Connection failed: $($_.Exception.Message)"
            return
        }
        try {
            while ($true) {
                $frame = Read-BeatInfoValue -Connection $biConn
                $prefix = "BeatInfo/Deck$($frame.Deck)"
                $sharedState["$prefix/Phase"]     = $frame.BeatPhase
                $sharedState["$prefix/BPM"]       = $frame.BPM
                $sharedState["$prefix/BeatIndex"] = $frame.BeatIndex
            }
        } catch {
            $sharedState['_error/BeatInfo'] = "Stream error: $($_.Exception.Message)"
        } finally {
            try { $biConn.Stream.Close() }    catch {}
            try { $biConn.TcpClient.Close() } catch {}
        }
    })
    $biHandle = $biPs.BeginInvoke()

    [PSCustomObject]@{
        StateMapPs       = $smPs
        StateMapRunspace = $smRunspace
        StateMapHandle   = $smHandle
        BeatInfoPs       = $biPs
        BeatInfoRunspace = $biRunspace
        BeatInfoHandle   = $biHandle
    }
}
