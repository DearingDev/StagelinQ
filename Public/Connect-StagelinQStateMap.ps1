function Connect-StagelinQStateMap {
    <#
    .SYNOPSIS
        Opens a TCP connection to the StateMap service on a StagelinQ device.
    .DESCRIPTION
        Looks up the StateMap service port via Get-StagelinQService, opens a
        new TCP connection to the device IP, and sends the StateMap connection
        frame (type 0x00000000 + token + "StateMap" + port 0). Returns a
        connection object to be used with Register-StateMapPath and
        Read-StateMapValue.
    .PARAMETER Device
        The device connection object returned by Connect-StagelinQDevice.
    .EXAMPLE
        $device  = Connect-StagelinQDevice -TargetSoftwareName 'JP11S'
        $stateMap = Connect-StagelinQStateMap -Device $device
        Register-StateMapPath -Connection $stateMap -Path '/Engine/Deck1/PlayState'
    #>
    param([PSCustomObject]$Device)

    $stateMapPort = Get-StagelinQService -Device $Device -Name 'StateMap'
    $deviceIp     = $Device.DeviceFrame.SourceAddress

    # Normalize IPv6-mapped IPv4 addresses (e.g. ::ffff:192.168.8.136 → 192.168.8.136)
    # macOS dual-stack often produces these, but TcpClient.Connect() can't handle them as strings.
    $parsedIp = [System.Net.IPAddress]::Parse($deviceIp)
    if ($parsedIp.IsIPv4MappedToIPv6) { $parsedIp = $parsedIp.MapToIPv4() }

    $tcp    = [System.Net.Sockets.TcpClient]::new()
    $tcp.Connect($parsedIp, $stateMapPort)
    $stream = $tcp.GetStream()
    $stream.ReadTimeout = 30000

    $ms = [System.IO.MemoryStream]::new()
    $bw = [System.IO.BinaryWriter]::new($ms)

    # Message type 0x00000000 (4 bytes, big-endian)
    Write-BigEndianUInt32 -Writer $bw -Value ([uint32]0)
    # Local token (16 bytes)
    $bw.Write($Device.Token)
    # Service name "StateMap" (length-prefixed UTF-16BE)
    Write-PrefixedString -Writer $bw -Value 'StateMap'
    # Port 0 (2 bytes, big-endian)
    Write-BigEndianUInt16 -Writer $bw -Value ([uint16]0)

    $bw.Flush()
    $connectMsg = $ms.ToArray()
    $bw.Close(); $ms.Close()

    $stream.Write($connectMsg, 0, $connectMsg.Length)
    $stream.Flush()

    [PSCustomObject]@{
        TcpClient = $tcp
        Stream    = $stream
        Token     = $Device.Token
    }
}
