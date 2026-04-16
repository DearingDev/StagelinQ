function Find-StagelinQDevice {
    <#
    .SYNOPSIS
        Listens on the StagelinQ UDP discovery port and returns the first matching device.
    .DESCRIPTION
        Opens a broadcast UDP socket and a listen socket on port 51337, then
        periodically sends DISCOVERER_HOWDY_ announcements while reading incoming
        frames. Returns the first parsed frame whose SoftwareName matches
        TargetSoftwareName, with SourceAddress populated from the UDP endpoint.
        Throws a TimeoutException if no matching device is seen before TimeoutSeconds.
    .PARAMETER Token
        A 16-byte local identifier. Generated randomly if not supplied.
    .PARAMETER TargetSoftwareName
        The SoftwareName field value that identifies the target device firmware.
        Defaults to 'JP11S' (Prime Go+).
    .PARAMETER TimeoutSeconds
        How long to listen before throwing a TimeoutException. Defaults to 10.
    .PARAMETER AnnounceIntervalMs
        How often to re-send the discovery announcement, in milliseconds. Defaults to 500.
    .EXAMPLE
        $device = Find-StagelinQDevice -TargetSoftwareName 'JP11S' -TimeoutSeconds 15
        Write-Host "Found $($device.DeviceName) at $($device.SourceAddress)"
    #>
    param(
        [byte[]]$Token = $null,
        [Parameter(Mandatory)]
        [string]$TargetSoftwareName,
        [int]$TimeoutSeconds = 10,
        [int]$AnnounceIntervalMs = 500
    )

    if ($null -eq $Token) {
        $Token = [byte[]]::new(16)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($Token)
    }

    $sendSock   = [System.Net.Sockets.UdpClient]::new()
    $sendSock.EnableBroadcast = $true

    $listenSock = [System.Net.Sockets.UdpClient]::new(51337)
    $listenSock.Client.ReceiveTimeout = $AnnounceIntervalMs

    $deadline = [System.DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $ep       = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)

    try {
        while ([System.DateTime]::UtcNow -lt $deadline) {
            Send-StagelinQAnnouncement -Token $Token -Socket $sendSock

            try {
                $rawBytes = $listenSock.Receive([ref]$ep)
            } catch {
                # PowerShell wraps SocketException in MethodInvocationException;
                # any Receive failure (typically a timeout) means we loop and re-announce
                continue
            }

            try {
                $frame = Read-DiscoveryFrame -Data $rawBytes
            } catch {
                continue
            }

            if ($frame.SoftwareName -eq $TargetSoftwareName) {
                # On macOS/dual-stack, UdpClient may return IPv6-mapped IPv4 addresses
                # like ::ffff:192.168.8.136 which TcpClient.Connect() can't handle.
                # Map back to IPv4 when possible.
                $addr = $ep.Address
                if ($addr.IsIPv4MappedToIPv6) {
                    $addr = $addr.MapToIPv4()
                }
                $frame.SourceAddress = $addr.ToString()
                return $frame
            }
        }
    } finally {
        $sendSock.Close()
        $listenSock.Close()
    }

    throw [System.TimeoutException]::new("No StagelinQ device found within ${TimeoutSeconds}s")
}
