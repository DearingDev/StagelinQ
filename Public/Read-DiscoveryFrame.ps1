function Read-DiscoveryFrame {
    <#
    .SYNOPSIS
        Parses a raw StagelinQ UDP discovery frame into a structured object.
    .DESCRIPTION
        Validates the 'airD' magic bytes and decodes the token, device name,
        connection type, software name, software version, and service port from
        the binary frame layout used by Denon DJ StagelinQ devices.
    .PARAMETER Data
        The raw byte array received from a UDP socket on port 51337.
    .EXAMPLE
        $frame = Read-DiscoveryFrame -Data $rawBytes
        Write-Host "Device: $($frame.DeviceName) on port $($frame.ServicePort)"
    #>
    param([byte[]]$Data)

    # Validate magic bytes
    $magic = [System.Text.Encoding]::ASCII.GetString($Data, 0, 4)
    if ($magic -ne 'airD') {
        throw "Not a StagelinQ discovery frame (magic: $magic)"
    }

    # Token: bytes 4-19, as uppercase hex string
    $token = [BitConverter]::ToString($Data[4..19]) -replace '-', ''

    # Four length-prefixed UTF-16BE strings starting at offset 20
    $offset = 20
    $deviceName = Read-PrefixedString -Data $Data -Offset $offset
    $offset = $deviceName.NewOffset

    $connectionType = Read-PrefixedString -Data $Data -Offset $offset
    $offset = $connectionType.NewOffset

    $softwareName = Read-PrefixedString -Data $Data -Offset $offset
    $offset = $softwareName.NewOffset

    $softwareVersion = Read-PrefixedString -Data $Data -Offset $offset
    $offset = $softwareVersion.NewOffset

    # Service port: big-endian uint16
    $port = ([int]$Data[$offset] -shl 8) + $Data[$offset + 1]

    [PSCustomObject]@{
        DeviceName      = $deviceName.Text
        ConnectionType  = $connectionType.Text
        SoftwareName    = $softwareName.Text
        SoftwareVersion = $softwareVersion.Text
        ServicePort     = $port
        Token           = $token
        SourceAddress   = $null
    }
}
