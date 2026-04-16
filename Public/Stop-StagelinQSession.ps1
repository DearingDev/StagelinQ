function Stop-StagelinQSession {
    <#
    .SYNOPSIS
        Cleanly shut down a StagelinQ session created by Start-StagelinQSession.
    .DESCRIPTION
        Tears down all session resources in the correct order:
          1. Stop the REST API (unblocks the HttpListener)
          2. Stop the DemoMode beat animator runspace (if present)
          3. Stop StateMap + BeatInfo stream runspaces (if present)
          4. Disconnect from the device (if present)
          5. Clear the shared state dictionary (DemoMode only)
    .PARAMETER Session
        The session handle returned by Start-StagelinQSession.
    .EXAMPLE
        Stop-StagelinQSession -Session $s
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Session
    )

    # 1. Stop the API first so the listener releases its port
    if ($null -ne $Session.Api) {
        Write-Host "  Stopping REST API on port $($Session.Api.Port)..." -ForegroundColor DarkGray
        Stop-StagelinQApi -Api $Session.Api
    }

    # 2. Stop the DemoMode beat animator
    if ($null -ne $Session.DemoPs) {
        Write-Host '  Stopping demo animator...' -ForegroundColor DarkGray
        try { $Session.DemoPs.Stop()    } catch {}
        try { $Session.DemoPs.Dispose() } catch {}
    }
    if ($null -ne $Session.DemoRunspace) {
        try { $Session.DemoRunspace.Close() } catch {}
    }

    # 3. Stop StateMap + BeatInfo stream runspaces
    if ($null -ne $Session.Streams) {
        Write-Host '  Stopping StagelinQ streams...' -ForegroundColor DarkGray
        Stop-StagelinQStreams -Streams $Session.Streams
    }

    # 4. Disconnect from hardware
    if ($null -ne $Session.Device) {
        Write-Host "  Disconnecting from $($Session.Device.DeviceFrame.SoftwareName)..." -ForegroundColor DarkGray
        Disconnect-StagelinQDevice -Device $Session.Device
    }

    # 5. Clear seeded demo state so a subsequent real session starts clean
    if ($Session.IsDemoMode) {
        try { $script:State.Clear() } catch {}
    }

    Write-Host '  Session stopped.' -ForegroundColor Green
}
