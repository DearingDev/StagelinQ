function Get-StagelinQService {
    <#
    .SYNOPSIS
        Returns services advertised by a connected StagelinQ device.
    .DESCRIPTION
        Reads from the Services hashtable on the device connection object returned
        by Connect-StagelinQDevice. When Name is specified, returns the integer
        port for that service only. When Name is omitted, returns a copy of the
        full hashtable of all discovered services.
    .PARAMETER Device
        The device connection object returned by Connect-StagelinQDevice.
    .PARAMETER Name
        The service name to look up (e.g. 'StateMap', 'BeatInfo'). If omitted,
        all services are returned as a hashtable.
    .EXAMPLE
        $port = Get-StagelinQService -Device $device -Name 'StateMap'
        Write-Host "StateMap is on port $port"
    .EXAMPLE
        $all = Get-StagelinQService -Device $device
        $all.Keys | ForEach-Object { Write-Host "$_ => $($all[$_])" }
    #>
    param(
        [PSCustomObject]$Device,
        [string]$Name = $null
    )

    if ($Name) {
        return [int]$Device.Services[$Name]
    }

    # Return a shallow copy of the hashtable
    $copy = @{}
    foreach ($key in $Device.Services.Keys) {
        $copy[$key] = $Device.Services[$key]
    }
    return $copy
}
