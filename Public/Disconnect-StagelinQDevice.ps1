function Disconnect-StagelinQDevice {
    <#
    .SYNOPSIS
        Cleanly disconnects from a StagelinQ device and releases all resources.
    .DESCRIPTION
        Sends a DISCOVERER_EXIT_ announcement so the device knows this host is
        leaving, stops the background UDP announce runspace, closes the announce
        socket, and closes the TCP stream and client. Each resource is wrapped in
        try/catch so the function does not throw if a resource is already disposed.
    .PARAMETER Device
        The device connection object returned by Connect-StagelinQDevice.
    .EXAMPLE
        $device = Connect-StagelinQDevice -TargetSoftwareName 'JP11S'
        # ... do work ...
        Disconnect-StagelinQDevice -Device $device
    #>
    param([PSCustomObject]$Device)

    # Send a DISCOVERER_EXIT_ announcement on all subnet broadcasts before closing
    try {
        $exitFrame = Build-DiscoveryFrame -Token $Device.Token -Source 'powershell' `
            -Action 'DISCOVERER_EXIT_' -SoftwareName $Device.SoftwareName -Version '1.0.0' -Port 0
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.OperationalStatus -ne 'Up') { continue }
            foreach ($ua in $ni.GetIPProperties().UnicastAddresses) {
                if ($ua.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
                if ($ua.Address.Equals([System.Net.IPAddress]::Loopback)) { continue }
                $ipBytes   = $ua.Address.GetAddressBytes()
                $maskBytes = $ua.IPv4Mask.GetAddressBytes()
                $bcast     = [byte[]]::new(4)
                for ($i = 0; $i -lt 4; $i++) { $bcast[$i] = $ipBytes[$i] -bor (-bnot $maskBytes[$i] -band 0xFF) }
                $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::new($bcast), 51337)
                try { $Device.AnnounceSocket.Send($exitFrame, $exitFrame.Length, $ep) | Out-Null } catch {}
            }
        }
    } catch {}

    # Stop the background announce runspace
    try { $Device.AnnounceJob.Stop() }      catch {}
    try { $Device.AnnounceRunspace.Close() } catch {}

    # Close the announce socket
    try { $Device.AnnounceSocket.Close() } catch {}

    # Stop the TCP listener (added in Fix 1)
    try { $Device.Listener.Stop() } catch {}

    # Close the TCP stream and client
    try { $Device.Stream.Close() }    catch {}
    try { $Device.TcpClient.Close() } catch {}
}
