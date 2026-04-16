#Requires -Version 7.0
<#
.SYNOPSIS
    Collects raw StateMap and BeatInfo values from a live device and saves them for debugging.
.DESCRIPTION
    Connects to a StagelinQ device, collects raw wire values for all dashboard-relevant
    paths (SongName, BPM, PlayState, Loop/Active, Crossfader), and captures BeatInfo
    frames. Saves results to a JSON file so the exact formats can be inspected.

    Trigger changes on the device while this runs: load a track, press play, move the
    crossfader, adjust BPM. The script captures up to -MaxUpdates updates before stopping.
.PARAMETER MaxUpdates
    Number of StateMap updates to collect before stopping. Default: 50.
.PARAMETER BeatInfoFrames
    Number of BeatInfo frames to capture. Default: 10.
.PARAMETER OutFile
    Path to save results. Default: state-values-<timestamp>.json in the current directory.
.PARAMETER TargetSoftwareName
    Software name the device advertises. Default: JP11S (Denon Prime Go+).
.EXAMPLE
    pwsh ./scripts/Collect-StateValues.ps1
    pwsh ./scripts/Collect-StateValues.ps1 -MaxUpdates 100
#>
param(
    [int]    $MaxUpdates          = 50,
    [int]    $BeatInfoFrames      = 10,
    [string] $OutFile             = "state-values-$(Get-Date -Format 'yyyyMMdd-HHmmss').json",
    [string] $TargetSoftwareName  = 'JP11S'
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../StagelinQ/StagelinQ.psd1" -Force

$paths = @(
    '/Engine/Deck1/Track/SongName',
    '/Engine/Deck2/Track/SongName',
    '/Engine/Deck1/Track/ArtistName',
    '/Engine/Deck2/Track/ArtistName',
    '/Engine/Deck1/CurrentBPM',
    '/Engine/Deck2/CurrentBPM',
    '/Engine/Deck1/PlayState',
    '/Engine/Deck2/PlayState',
    '/Engine/Deck1/Loop/Active',
    '/Engine/Deck2/Loop/Active',
    '/Engine/Master/Crossfader/Position'
)

Write-Host "Discovering '$TargetSoftwareName'..." -ForegroundColor DarkGray
$device = Connect-StagelinQDevice -TargetSoftwareName $TargetSoftwareName -TimeoutSeconds 20
Write-Host "Connected to $($device.DeviceFrame.SoftwareName) at $($device.DeviceFrame.SourceAddress)" -ForegroundColor Green

# ── Collect StateMap updates ───────────────────────────────────────────────────
Write-Host "`nSubscribing to $($paths.Count) paths. Trigger changes on the device..." -ForegroundColor Cyan
Write-Host "(Load a track, press play, move crossfader, adjust BPM)`n" -ForegroundColor DarkGray

$sm = Connect-StagelinQStateMap -Device $device
Register-StateMapPath -Connection $sm -Path $paths

$stateUpdates = [System.Collections.Generic.List[PSCustomObject]]::new()
$seen         = @{}   # track all unique path+value combos observed

while ($stateUpdates.Count -lt $MaxUpdates) {
    $updates = Read-StateMapValue -Connection $sm
    foreach ($u in $updates) {
        $parsedKeys = try {
            $p = $u.Value | ConvertFrom-Json -ErrorAction Stop
            ($p.PSObject.Properties | Select-Object -ExpandProperty Name) -join ', '
        } catch { '(not JSON)' }

        $entry = [PSCustomObject]@{
            Path       = $u.Path
            RawValue   = $u.Value
            ValueType  = $u.Value.GetType().FullName
            ParsedKeys = $parsedKeys
            Timestamp  = [datetime]::UtcNow.ToString('o')
        }

        $key = "$($u.Path)|$($u.Value)"
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            Write-Host ("[{0,3}] {1}" -f $stateUpdates.Count, $u.Path) -ForegroundColor White -NoNewline
            Write-Host " = $($u.Value)" -ForegroundColor Yellow
        }

        $stateUpdates.Add($entry)
        if ($stateUpdates.Count -ge $MaxUpdates) { break }
    }
}

$sm.Stream.Close()
$sm.TcpClient.Close()

# ── Collect BeatInfo frames ────────────────────────────────────────────────────
Write-Host "`nCapturing $BeatInfoFrames BeatInfo frames..." -ForegroundColor Cyan
$bi = Connect-StagelinQBeatInfo -Device $device
$beatFrames = 1..$BeatInfoFrames | ForEach-Object { Read-BeatInfoValue -Connection $bi }
$bi.Stream.Close()
$bi.TcpClient.Close()

Write-Host "Captured $($beatFrames.Count) frames." -ForegroundColor Green
$beatFrames | Format-Table Deck, BeatPhase, BPM, BeatIndex -AutoSize

# ── Save results ───────────────────────────────────────────────────────────────
$report = [PSCustomObject]@{
    CollectedAt       = [datetime]::UtcNow.ToString('o')
    Device            = $device.DeviceFrame.SoftwareName
    DeviceAddress     = $device.DeviceFrame.SourceAddress
    # Deduplicated: one entry per unique path showing all distinct raw values seen
    UniqueStateValues = $stateUpdates |
        Group-Object Path |
        ForEach-Object {
            [PSCustomObject]@{
                Path        = $_.Name
                DistinctValues = ($_.Group | Select-Object -ExpandProperty RawValue | Sort-Object -Unique)
                ParsedKeys  = ($_.Group | Select-Object -ExpandProperty ParsedKeys | Sort-Object -Unique) -join ' / '
                ValueType   = ($_.Group | Select-Object -ExpandProperty ValueType  | Sort-Object -Unique) -join ', '
            }
        }
    AllStateUpdates   = $stateUpdates
    BeatInfoFrames    = $beatFrames
}

$report | ConvertTo-Json -Depth 10 | Set-Content -Path $OutFile -Encoding UTF8
Write-Host "`nResults saved to: $OutFile" -ForegroundColor Green

# ── Print a summary table ──────────────────────────────────────────────────────
Write-Host "`n── Unique Values per Path ────────────────────────────────────────────" -ForegroundColor Cyan
$report.UniqueStateValues | Format-Table Path, ParsedKeys, DistinctValues -AutoSize -Wrap

Disconnect-StagelinQDevice -Device $device
Write-Host "Done." -ForegroundColor Green
