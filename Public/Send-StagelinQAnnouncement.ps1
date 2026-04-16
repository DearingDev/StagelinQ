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

    # Send to each active interface's subnet broadcast so devices on non-default subnets
    # (e.g. a DJ controller on en0/192.168.8.x when the default route is via en8/10.x.x.x)
    # still receive our announcement. 255.255.255.255 only goes out on the default interface.
    $sentAddrs = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($ni.OperationalStatus -ne 'Up') { continue }
        foreach ($ua in $ni.GetIPProperties().UnicastAddresses) {
            if ($ua.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
            if ($ua.Address.Equals([System.Net.IPAddress]::Loopback)) { continue }
            $ipBytes   = $ua.Address.GetAddressBytes()
            $maskBytes = $ua.IPv4Mask.GetAddressBytes()
            $bcast     = [byte[]]::new(4)
            for ($i = 0; $i -lt 4; $i++) { $bcast[$i] = $ipBytes[$i] -bor (-bnot $maskBytes[$i] -band 0xFF) }
            $bcastStr = ([System.Net.IPAddress]::new($bcast)).ToString()
            if ($sentAddrs.Add($bcastStr)) {
                $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::new($bcast), 51337)
                try { [void]$Socket.Send($frame, $frame.Length, $ep) } catch {}
            }
        }
    }

    # macOS does not loop limited broadcast back to local sockets; also send to loopback
    # so that local listeners (including Find-StagelinQDevice) see the frame
    $loopback = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Loopback, 51337)
    try { [void]$Socket.Send($frame, $frame.Length, $loopback) } catch {}
}
