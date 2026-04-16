#Requires -Version 7.0
<#
.SYNOPSIS
    Diagnostic: tests the state-value parsing logic against live device data.
    Run this BEFORE debugging the dashboard so we can see exactly what each
    step produces.
#>
param(
    [string] $TargetSoftwareName = 'JP11S',
    [int]    $Samples            = 5
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../StagelinQ/StagelinQ.psd1" -Force

$paths = @(
    '/Engine/Deck1/Track/SongName',
    '/Engine/Deck1/CurrentBPM',
    '/Engine/Deck1/PlayState'
)

Write-Host "Connecting..." -ForegroundColor DarkGray
$device = Connect-StagelinQDevice -TargetSoftwareName $TargetSoftwareName -TimeoutSeconds 20
$sm     = Connect-StagelinQStateMap -Device $device
Register-StateMapPath -Connection $sm -Path $paths

Write-Host "Reading $Samples updates...`n" -ForegroundColor DarkGray
$count = 0
while ($count -lt $Samples) {
    $updates = Read-StateMapValue -Connection $sm
    foreach ($u in $updates) {
        $count++
        Write-Host "── Update $count ─────────────────────────────────" -ForegroundColor Cyan
        Write-Host "  Path      : $($u.Path)"
        Write-Host "  RawValue  : $($u.Value)"
        Write-Host "  .NET type : $($u.Value.GetType().FullName)"

        # Step 1: ConvertFrom-Json -AsHashtable
        try {
            $j = $u.Value | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            Write-Host "  Parsed OK : $($j.GetType().FullName)" -ForegroundColor Green
            Write-Host "  Keys      : $($j.Keys -join ', ')"
            Write-Host "  type key  : $($j['type'])  (.NET: $($j['type'].GetType().FullName))"

            switch ([int]$j['type']) {
                0 {
                    Write-Host "  → type 0 (numeric) → value = $($j['value'])" -ForegroundColor Yellow
                }
                1 {
                    Write-Host "  → type 1 (boolean) → state = $($j['state'])" -ForegroundColor Yellow
                }
                8 {
                    Write-Host "  → type 8 (string)  → string = $($j['string'])" -ForegroundColor Yellow
                }
                default {
                    Write-Host "  → type $([int]$j['type']) (unhandled)" -ForegroundColor Red
                }
            }
        } catch {
            Write-Host "  ConvertFrom-Json FAILED: $_" -ForegroundColor Red
        }

        Write-Host ""
        if ($count -ge $Samples) { break }
    }
}

$sm.Stream.Close()
$sm.TcpClient.Close()
Disconnect-StagelinQDevice -Device $device
Write-Host "Done." -ForegroundColor Green
