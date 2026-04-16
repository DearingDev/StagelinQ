function Connect-StagelinQDevice {
    <#
    .SYNOPSIS
        Discovers a StagelinQ device and performs the directory server handshake.
    .DESCRIPTION
        Calls Find-StagelinQDevice to locate the target hardware, then connects
        to its TCP directory server, exchanges the Services Request handshake, and
        collects all Service Announcement messages. A background runspace continues
        sending UDP announcements every second while the connection is open.
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

    # Start a background runspace to keep sending announcements every 1 second
    $announceSocket = [System.Net.Sockets.UdpClient]::new()
    $announceSocket.EnableBroadcast = $true

    $announceRunspace = [runspacefactory]::CreateRunspace()
    $announceRunspace.Open()
    $announceRunspace.SessionStateProxy.SetVariable('announceSocket', $announceSocket)
    $announceRunspace.SessionStateProxy.SetVariable('token', $Token)

    # Build the announce frame once and share it
    $announceFrame = Build-DiscoveryFrame -Token $Token -Source 'powershell' `
        -Action 'DISCOVERER_HOWDY_' -SoftwareName $SoftwareName -Version '1.0.0' -Port 0
    $announceRunspace.SessionStateProxy.SetVariable('announceFrame', $announceFrame)
    $broadcastEp = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Broadcast, 51337)
    $announceRunspace.SessionStateProxy.SetVariable('broadcastEp', $broadcastEp)

    $announceJob = [powershell]::Create().AddScript({
        while ($true) {
            try {
                $announceSocket.Send($announceFrame, $announceFrame.Length, $broadcastEp) | Out-Null
            } catch {}
            Start-Sleep -Milliseconds 1000
        }
    })
    $announceJob.Runspace = $announceRunspace
    $announceJob.BeginInvoke() | Out-Null

    # Connect to the directory server via TCP
    $tcp = [System.Net.Sockets.TcpClient]::new()
    $tcp.Connect($deviceFrame.SourceAddress, $deviceFrame.ServicePort)
    $stream = $tcp.GetStream()
    $stream.ReadTimeout = 5000

    # Directory server handshake
    $services   = @{}
    $buffer     = [byte[]]::new(4096)
    $deadline   = [System.DateTime]::UtcNow.AddSeconds(5)   # drain window after last service
    $replySent  = $false
    $lastSvcAt  = $null

    while ([System.DateTime]::UtcNow -lt $deadline) {
        # After we've seen at least one service and 500ms have passed with no new data, stop
        if ($lastSvcAt -and ([System.DateTime]::UtcNow - $lastSvcAt).TotalMilliseconds -gt 500) {
            break
        }

        $bytesRead = 0
        try {
            $bytesRead = $stream.Read($buffer, 0, $buffer.Length)
        } catch {
            # ReadTimeout — loop
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
                    # Services Request — consume the 16-byte token, then reply
                    $pos += 16
                    if (-not $replySent) {
                        $reply = [byte[]]::new(20)
                        $reply[3] = 0x02
                        [Array]::Copy($Token, 0, $reply, 4, 16)
                        $stream.Write($reply, 0, $reply.Length)
                        $stream.Flush()
                        $replySent = $true
                    }
                }
                0x00000001 {
                    # Timestamp — silently consume: 16 + 16 + 8 = 40 bytes
                    $pos += 40
                }
                0x00000000 {
                    # Service Announcement — 16-byte token + length-prefixed name + 2-byte port
                    $pos += 16
                    if ($pos + 4 -le $bytesRead) {
                        $result  = Read-PrefixedString -Data $buffer -Offset $pos
                        $pos     = $result.NewOffset
                        if ($pos + 2 -le $bytesRead) {
                            $svcPort = ([int]$buffer[$pos] -shl 8) -bor [int]$buffer[$pos+1]
                            $pos    += 2
                            $services[$result.Text] = $svcPort
                            $lastSvcAt = [System.DateTime]::UtcNow
                        }
                    }
                }
                default {
                    # Unknown — skip the rest of this read
                    $pos = $bytesRead
                }
            }
        }
    }

    [PSCustomObject]@{
        DeviceFrame      = $deviceFrame
        Token            = $Token
        SoftwareName     = $SoftwareName
        TcpClient        = $tcp
        Stream           = $stream
        Services         = $services
        AnnounceSocket   = $announceSocket
        AnnounceRunspace = $announceRunspace
        AnnounceJob      = $announceJob
    }
}
