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

    # Send a DISCOVERER_EXIT_ announcement before closing
    try {
        $exitFrame = Build-DiscoveryFrame -Token $Device.Token -Source 'powershell' `
            -Action 'DISCOVERER_EXIT_' -SoftwareName $Device.SoftwareName -Version '1.0.0' -Port 0
        $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Broadcast, 51337)
        $Device.AnnounceSocket.Send($exitFrame, $exitFrame.Length, $ep) | Out-Null
    } catch {}

    # Stop the background announce runspace
    try { $Device.AnnounceJob.Stop() }   catch {}
    try { $Device.AnnounceRunspace.Close() } catch {}

    # Close the announce socket
    try { $Device.AnnounceSocket.Close() } catch {}

    # Close the TCP stream and client
    try { $Device.Stream.Close() }     catch {}
    try { $Device.TcpClient.Close() }  catch {}
}
