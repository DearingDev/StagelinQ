function Watch-StagelinQState {
    <#
    .SYNOPSIS
        Subscribes to state paths and continuously streams updates until Ctrl+C.
    .DESCRIPTION
        Calls Register-StateMapPath for the given paths, then loops forever reading
        StateMap updates via Read-StateMapValue. Each update is passed to OnUpdate
        if provided, or printed to the host as "path = value". Exits cleanly on
        Ctrl+C. The caller is responsible for closing the connection afterward via
        Disconnect-StagelinQDevice.
    .PARAMETER Connection
        The StateMap connection object returned by Connect-StagelinQStateMap.
    .PARAMETER Path
        One or more state paths to subscribe to and watch.
    .PARAMETER OnUpdate
        An optional scriptblock called with each update PSCustomObject. If omitted,
        updates are printed to the host.
    .EXAMPLE
        Watch-StagelinQState -Connection $sm -Path '/Engine/Deck1/PlayState', '/Engine/Deck1/CurrentBPM'
    .EXAMPLE
        Watch-StagelinQState -Connection $sm -Path '/Engine/Deck1/Track/SongName' -OnUpdate {
            param($update)
            Write-Host "Now playing: $($update.Value)"
        }
    #>
    param(
        [PSCustomObject]$Connection,
        [string[]]$Path,
        [scriptblock]$OnUpdate = $null
    )

    Register-StateMapPath -Connection $Connection -Path $Path

    try {
        while ($true) {
            $updates = Read-StateMapValue -Connection $Connection
            foreach ($update in $updates) {
                if ($null -ne $OnUpdate) {
                    & $OnUpdate $update
                } else {
                    Write-Host "$($update.Path) = $($update.Value)"
                }
            }
        }
    } finally {
        # Caller is responsible for closing connections via Disconnect-StagelinQDevice
    }
}
