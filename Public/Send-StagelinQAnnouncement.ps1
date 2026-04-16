function Send-StagelinQAnnouncement {
    <#
    .SYNOPSIS
        Sends a StagelinQ DISCOVERER_HOWDY_ announcement over UDP broadcast.
    .DESCRIPTION
        Builds a StagelinQ discovery frame and sends it to 255.255.255.255:51337
        so that Denon DJ devices on the local network can discover this host.
        Also sends to loopback to support local listeners on macOS.
    .PARAMETER Token
        A 16-byte identifier for this host. May be provided as a byte array or
        a 32-character hex string.
    .PARAMETER Source
        The device name string embedded in the announcement frame. Defaults to 'powershell'.
    .PARAMETER SoftwareName
        The software name embedded in the announcement frame. Defaults to 'PowerShell'.
    .PARAMETER Version
        The software version string embedded in the frame. Defaults to '1.0.0'.
    .PARAMETER Port
        The TCP service port advertised in the frame. Use 0 when not hosting a service.
    .PARAMETER Socket
        An open UdpClient with EnableBroadcast set to $true, provided by the caller.
    .EXAMPLE
        $sock = [System.Net.Sockets.UdpClient]::new()
        $sock.EnableBroadcast = $true
        $token = [byte[]]::new(16)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($token)
        Send-StagelinQAnnouncement -Token $token -Socket $sock
        $sock.Close()
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Token,
        [string]$Source = 'powershell',
        [string]$SoftwareName = 'PowerShell',
        [string]$Version = '1.0.0',
        [int]$Port = 0,
        [System.Net.Sockets.UdpClient]$Socket
    )

    if ($Token -is [string]) {
        $hex = $Token -replace '[^0-9A-Fa-f]', ''
        $tokenBytes = [byte[]]::new($hex.Length / 2)
        for ($i = 0; $i -lt $tokenBytes.Length; $i++) {
            $tokenBytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16)
        }
        $Token = $tokenBytes
    }

    $frame = Build-DiscoveryFrame -Token ([byte[]]$Token) -Source $Source -Action 'DISCOVERER_HOWDY_' `
        -SoftwareName $SoftwareName -Version $Version -Port $Port

    $broadcast = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Broadcast, 51337)
    [void]$Socket.Send($frame, $frame.Length, $broadcast)

    # macOS does not loop limited broadcast back to local sockets; also send to loopback
    # so that local listeners (including Find-StagelinQDevice) see the frame
    $loopback = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Loopback, 51337)
    try { [void]$Socket.Send($frame, $frame.Length, $loopback) } catch {}
}
