function Watch-StagelinQBeatInfo {
    <#
    .SYNOPSIS
        Continuously streams BeatInfo frames until Ctrl+C.
    .DESCRIPTION
        Loops calling Read-BeatInfoValue on the given connection, invoking
        OnUpdate for each frame (or printing to the host if OnUpdate is omitted).
        Exits cleanly on Ctrl+C. The caller is responsible for closing the
        connection afterward.
    .PARAMETER Connection
        The BeatInfo connection object returned by Connect-StagelinQBeatInfo.
    .PARAMETER OnUpdate
        An optional scriptblock called with each BeatInfo frame PSCustomObject.
        If omitted, frames are printed to the host.
    .EXAMPLE
        Watch-StagelinQBeatInfo -Connection $bi
    .EXAMPLE
        Watch-StagelinQBeatInfo -Connection $bi -OnUpdate {
            param($frame)
            Write-Host "Deck $($frame.Deck)  Phase $($frame.BeatPhase)  BPM $($frame.BPM)"
        }
    #>
    param(
        [PSCustomObject]$Connection,
        [scriptblock]$OnUpdate = $null
    )

    try {
        while ($true) {
            $frame = Read-BeatInfoValue -Connection $Connection
            if ($null -ne $OnUpdate) {
                & $OnUpdate $frame
            } else {
                Write-Host "Deck $($frame.Deck)  Phase $($frame.BeatPhase)  BPM $($frame.BPM)  BeatIndex $($frame.BeatIndex)"
            }
        }
    } finally {
        # Caller is responsible for closing connections via Disconnect-StagelinQDevice
    }
}
