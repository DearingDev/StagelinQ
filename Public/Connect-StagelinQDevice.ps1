function Connect-StagelinQDevice {
    <#
    .SYNOPSIS
        Discovers a StagelinQ device and performs the directory server handshake.
    .DESCRIPTION
        Calls Find-StagelinQDevice to locate the target hardware, opens a local
        TcpListener (so the device can connect back), then connects to the device's
        TCP directory server. After the Services Request (0x00000002) exchange it
        sends our own Service Announcement (0x00000000) frame, which prompts the
        device to reply with its own service list. A background runspace also accepts
        inbound connections from the device (it dials our listener ~1/sec) and runs
        the same handshake. UDP keepalives are sent every second on all active
        subnet broadcasts and include the real listener port, which is required for
        the device to respond on the TCP connection at all.

        Returns a device connection object that must be passed to
        Disconnect-StagelinQDevice when done.
    .PARAMETER TargetSoftwareName
        Firmware name to match during discovery. Defaults to 'JP11S' (Prime Go+).
    .PARAMETER Token
        A 16-byte local token. Auto-generated if not supplied.
    .PARAMETER SoftwareName
        The software name advertised during discovery. Defaults to 'PowerShell'.
    .PARAMETER TimeoutSeconds
        Discovery timeout in seconds. Defaults to 15.
    .EXAMPLE
        $device = Connect-StagelinQDevice -TargetSoftwareName 'JP11S' -TimeoutSeconds 20
        Get-StagelinQService -Device $device
        Disconnect-StagelinQDevice -Device $device
    #>
    param(
        [Parameter(Mandatory)]
        [string]$TargetSoftwareName,
        [byte[]]$Token = $null,
        [string]$SoftwareName = 'PowerShell',
        [int]$TimeoutSeconds = 15
    )

    if ($null -eq $Token) {
        $Token = [byte[]]::new(16)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($Token)
    }

    # Discover the device (Find-StagelinQDevice opens/closes its own sockets)
    $deviceFrame = Find-StagelinQDevice -Token $Token -TargetSoftwareName $TargetSoftwareName -TimeoutSeconds $TimeoutSeconds

    # -----------------------------------------------------------------------
    # Open a TCP listener on an ephemeral port so the device can connect back.
    # The device only sends service announcements when we advertise a non-zero
    # port in our UDP frames.
    # -----------------------------------------------------------------------
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, 0)
    $listener.Start()
    $listenerPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port

    # -----------------------------------------------------------------------
    # Helper: build a Service Announcement frame (0x00000000) in pure .NET so
    # it can be pre-computed here (Private functions are not visible in runspaces).
    #   4 bytes  BE uint32  type  = 0x00000000
    #   16 bytes            token
    #   4+N bytes           length-prefixed UTF-16BE service name (empty string)
    #   2 bytes  BE uint16  port  = 0  (we offer no services)
    # -----------------------------------------------------------------------
    function _BuildServiceAnnounceFrame {
        param([byte[]]$Tok)
        $ms     = [System.IO.MemoryStream]::new()
        # type = 0x00000000 (4 zero bytes)
        $ms.Write([byte[]]@(0,0,0,0), 0, 4)
        # token
        $ms.Write($Tok, 0, 16)
        # length-prefixed UTF-16BE empty string: length = 0 (4 bytes), no body
        $ms.Write([byte[]]@(0,0,0,0), 0, 4)
        # port = 0 (2 bytes)
        $ms.Write([byte[]]@(0,0), 0, 2)
        return $ms.ToArray()
    }

    $serviceAnnounceFrame = _BuildServiceAnnounceFrame -Tok $Token

    # -----------------------------------------------------------------------
    # Build the subnet-broadcast-aware helpers for the keepalive runspace.
    # We pre-compute the list of broadcast endpoints here (in the main runspace
    # where networking APIs are available) and share only simple objects.
    # -----------------------------------------------------------------------
    function _GetSubnetBroadcastEndpoints {
        param([int]$P)
        $eps = [System.Collections.Generic.List[System.Net.IPEndPoint]]::new()
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.OperationalStatus -ne 'Up') { continue }
            foreach ($ua in $ni.GetIPProperties().UnicastAddresses) {
                if ($ua.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
                if ($ua.Address.Equals([System.Net.IPAddress]::Loopback)) { continue }
                $ipBytes   = $ua.Address.GetAddressBytes()
                $maskBytes = $ua.IPv4Mask.GetAddressBytes()
                $bcast     = [byte[]]::new(4)
                for ($i = 0; $i -lt 4; $i++) { $bcast[$i] = $ipBytes[$i] -bor (-bnot $maskBytes[$i] -band 0xFF) }
                $eps.Add([System.Net.IPEndPoint]::new([System.Net.IPAddress]::new($bcast), $P))
            }
        }
        # Also send to loopback (macOS does not reflect limited broadcast locally)
        $eps.Add([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Loopback, $P))
        return $eps
    }

    $broadcastEndpoints = _GetSubnetBroadcastEndpoints -P 51337

    # -----------------------------------------------------------------------
    # Build announce frame advertising the real listener port.
    # -----------------------------------------------------------------------
    $announceFrame = Build-DiscoveryFrame -Token $Token -Source 'powershell' `
        -Action 'DISCOVERER_HOWDY_' -SoftwareName $SoftwareName -Version '1.0.0' `
        -Port $listenerPort

    # -----------------------------------------------------------------------
    # Background UDP keepalive runspace — sends on all subnet broadcasts
    # with the real listener port so the device knows where to connect back.
    # -----------------------------------------------------------------------
    $announceSocket = [System.Net.Sockets.UdpClient]::new()
    $announceSocket.EnableBroadcast = $true

    $announceRunspace = [runspacefactory]::CreateRunspace()
    $announceRunspace.Open()
    $announceRunspace.SessionStateProxy.SetVariable('announceSocket',    $announceSocket)
    $announceRunspace.SessionStateProxy.SetVariable('announceFrame',     $announceFrame)
    $announceRunspace.SessionStateProxy.SetVariable('broadcastEndpoints', $broadcastEndpoints)

    $announceJob = [powershell]::Create().AddScript({
        while ($true) {
            foreach ($ep in $broadcastEndpoints) {
                try { $announceSocket.Send($announceFrame, $announceFrame.Length, $ep) | Out-Null } catch {}
            }
            Start-Sleep -Milliseconds 1000
        }
    })
    $announceJob.Runspace = $announceRunspace
    $announceJob.BeginInvoke() | Out-Null

    # -----------------------------------------------------------------------
    # Helper: perform the full StagelinQ directory handshake on an open stream.
    # Returns a hashtable of { ServiceName -> Port } collected from 0x00000000
    # frames. Sends our 0x00000002 reply and then immediately follows with our
    # own 0x00000000 service announcement to prompt the device's service list.
    # -----------------------------------------------------------------------
    function _RunHandshake {
        param(
            [System.Net.Sockets.NetworkStream]$S,
            [byte[]]$Tok,
            [byte[]]$SvcAnnounceFrame
        )
        $services  = @{}
        $buffer    = [byte[]]::new(4096)
        $deadline  = [System.DateTime]::UtcNow.AddSeconds(5)
        $replySent = $false
        $lastSvcAt = $null

        while ([System.DateTime]::UtcNow -lt $deadline) {
            if ($lastSvcAt -and ([System.DateTime]::UtcNow - $lastSvcAt).TotalMilliseconds -gt 500) {
                break
            }

            $bytesRead = 0
            try {
                $bytesRead = $S.Read($buffer, 0, $buffer.Length)
            } catch {
                if ($lastSvcAt) { break }
                continue
            }
            if ($bytesRead -eq 0) { break }

            $pos = 0
            while ($pos + 4 -le $bytesRead) {
                $msgId = ([int]$buffer[$pos] -shl 24) -bor ([int]$buffer[$pos+1] -shl 16) `
                       -bor ([int]$buffer[$pos+2] -shl 8) -bor [int]$buffer[$pos+3]
                $pos += 4

                switch ($msgId) {
                    0x00000002 {
                        # Services Request — consume the 16-byte sender token, reply, then
                        # immediately send our own service announcement so the device sends
                        # back its service list.
                        $pos += 16
                        if (-not $replySent) {
                            # Reply: 0x00000002 + our token
                            $reply = [byte[]]::new(20)
                            $reply[3] = 0x02
                            [Array]::Copy($Tok, 0, $reply, 4, 16)
                            $S.Write($reply, 0, $reply.Length)
                            $S.Flush()

                            # Our service announcement (0x00000000) — empty service, port 0
                            $S.Write($SvcAnnounceFrame, 0, $SvcAnnounceFrame.Length)
                            $S.Flush()

                            $replySent = $true
                        }
                    }
                    0x00000001 {
                        # Timestamp — consume 16+16+8 = 40 bytes
                        $pos += 40
                    }
                    0x00000000 {
                        # Service Announcement — 16-byte token + length-prefixed name + 2-byte port
                        $pos += 16
                        if ($pos + 4 -le $bytesRead) {
                            $result = Read-PrefixedString -Data $buffer -Offset $pos
                            $pos    = $result.NewOffset
                            if ($pos + 2 -le $bytesRead) {
                                $svcPort = ([int]$buffer[$pos] -shl 8) -bor [int]$buffer[$pos+1]
                                $pos += 2
                                $services[$result.Text] = $svcPort
                                $lastSvcAt = [System.DateTime]::UtcNow
                            }
                        }
                    }
                    default {
                        $pos = $bytesRead
                    }
                }
            }
        }
        return $services
    }

    # -----------------------------------------------------------------------
    # Connect to the device's directory server TCP port (outbound leg).
    # -----------------------------------------------------------------------
    $tcp = [System.Net.Sockets.TcpClient]::new()
    $tcp.Connect($deviceFrame.SourceAddress, $deviceFrame.ServicePort)
    $stream = $tcp.GetStream()
    $stream.ReadTimeout = 5000

    $services = _RunHandshake -S $stream -Tok $Token -SvcAnnounceFrame $serviceAnnounceFrame

    # -----------------------------------------------------------------------
    # Accept the device's inbound connection (it dials our listener repeatedly).
    # Poll for up to 3 seconds; merge any additional services found.
    # -----------------------------------------------------------------------
    $listener.Server.ReceiveTimeout = 3000
    $deadline2 = [System.DateTime]::UtcNow.AddSeconds(3)
    while ([System.DateTime]::UtcNow -lt $deadline2) {
        if ($listener.Pending()) {
            try {
                $inboundTcp  = $listener.AcceptTcpClient()
                $inboundStream = $inboundTcp.GetStream()
                $inboundStream.ReadTimeout = 5000
                $inboundSvcs = _RunHandshake -S $inboundStream -Tok $Token -SvcAnnounceFrame $serviceAnnounceFrame
                foreach ($k in $inboundSvcs.Keys) {
                    if (-not $services.ContainsKey($k) -or $inboundSvcs[$k] -ne 0) {
                        $services[$k] = $inboundSvcs[$k]
                    }
                }
                # Keep the inbound stream open so the device can push state updates
            } catch {}
            break
        }
        Start-Sleep -Milliseconds 100
    }

    [PSCustomObject]@{
        DeviceFrame      = $deviceFrame
        Token            = $Token
        SoftwareName     = $SoftwareName
        TcpClient        = $tcp
        Stream           = $stream
        Listener         = $listener
        ListenerPort     = $listenerPort
        Services         = $services
        AnnounceSocket   = $announceSocket
        AnnounceRunspace = $announceRunspace
        AnnounceJob      = $announceJob
    }
}
