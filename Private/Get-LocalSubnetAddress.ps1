function Get-LocalSubnetAddress {
    <#
    .SYNOPSIS
        Returns an IPv4 IPAddress on the same subnet as the given remote, or $null.
    .DESCRIPTION
        Walks up, non-loopback NICs and returns the first UnicastAddress whose
        (address AND mask) equals (remote AND mask). Skips /32 masks so VPN
        pseudo-interfaces (Tailscale, WireGuard) that install host-only routes
        can't falsely match. Used to bind outbound TcpClients to the directly
        connected NIC when a VPN has installed a lower-metric route covering
        the LAN prefix.
    #>
    param([Parameter(Mandatory)][string]$RemoteAddress)

    $remote = $null
    if (-not [System.Net.IPAddress]::TryParse($RemoteAddress, [ref]$remote)) { return $null }
    if ($remote.IsIPv4MappedToIPv6) { $remote = $remote.MapToIPv4() }
    if ($remote.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $null }
    $remoteBytes = $remote.GetAddressBytes()

    foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($ni.OperationalStatus -ne 'Up') { continue }
        if ($ni.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
        foreach ($ua in $ni.GetIPProperties().UnicastAddresses) {
            if ($ua.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
            if ($null -eq $ua.IPv4Mask) { continue }
            $maskBytes = $ua.IPv4Mask.GetAddressBytes()
            # Skip /32 — VPN pseudo-interfaces advertise host-only routes
            if ($maskBytes[0] -eq 0xFF -and $maskBytes[1] -eq 0xFF -and
                $maskBytes[2] -eq 0xFF -and $maskBytes[3] -eq 0xFF) { continue }
            $localBytes = $ua.Address.GetAddressBytes()
            $match = $true
            for ($i = 0; $i -lt 4; $i++) {
                if (($localBytes[$i] -band $maskBytes[$i]) -ne ($remoteBytes[$i] -band $maskBytes[$i])) {
                    $match = $false; break
                }
            }
            if ($match) { return $ua.Address }
        }
    }
    return $null
}
