function Connect-StagelinQBeatInfo {
    <#
    .SYNOPSIS
        Opens a TCP connection to the BeatInfo service on a StagelinQ device.
    .DESCRIPTION
        Looks up the BeatInfo service port via Get-StagelinQService, opens a
        TCP connection to the device, and sends the connection frame (type
        0x00000000 + token + "BeatInfo" + port 0). Returns a connection object
        for use with Read-BeatInfoValue and Watch-StagelinQBeatInfo.
    .PARAMETER Device
        The device connection object returned by Connect-StagelinQDevice.
    .EXAMPLE
        $device  = Connect-StagelinQDevice -TargetSoftwareName 'JP11S'
        $beatInfo = Connect-StagelinQBeatInfo -Device $device
    #>
    param([PSCustomObject]$Device)

    $beatInfoPort = Get-StagelinQService -Device $Device -Name 'BeatInfo'
    $deviceIp     = $Device.DeviceFrame.SourceAddress

    # Normalize IPv6-mapped IPv4 addresses (e.g. ::ffff:192.168.8.136 → 192.168.8.136)
    $parsedIp = [System.Net.IPAddress]::Parse($deviceIp)
    if ($parsedIp.IsIPv4MappedToIPv6) { $parsedIp = $parsedIp.MapToIPv4() }

    $localBindAddr = Get-LocalSubnetAddress -RemoteAddress $parsedIp.ToString()
    if ($localBindAddr) {
        $tcp = [System.Net.Sockets.TcpClient]::new(
            [System.Net.IPEndPoint]::new($localBindAddr, 0))
    } else {
        $tcp = [System.Net.Sockets.TcpClient]::new()
    }
    $tcp.Connect($parsedIp, $beatInfoPort)
    $stream = $tcp.GetStream()
    $stream.ReadTimeout = 30000

    $ms = [System.IO.MemoryStream]::new()
    $bw = [System.IO.BinaryWriter]::new($ms)

    # Message type 0x00000000 (4 bytes, big-endian)
    Write-BigEndianUInt32 -Writer $bw -Value ([uint32]0)
    # Local token (16 bytes)
    $bw.Write($Device.Token)
    # Service name "BeatInfo" (length-prefixed UTF-16BE)
    Write-PrefixedString -Writer $bw -Value 'BeatInfo'
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
        Device    = $Device
    }
}
