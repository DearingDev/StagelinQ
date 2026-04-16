function Stop-StagelinQApi {
    <#
    .SYNOPSIS
        Stops the HTTP API listener started by Start-StagelinQApi.
    .DESCRIPTION
        Calls Stop() and Close() on the HttpListener (which unblocks the GetContext() call
        in the background runspace), then stops and disposes the PowerShell instance and
        its runspace. Each step is wrapped in try/catch so the function completes cleanly
        even if the listener has already been stopped.
    .PARAMETER Api
        The handle object returned by Start-StagelinQApi.
    .EXAMPLE
        Stop-StagelinQApi -Api $api
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Api
    )

    # Stop the listener first — this unblocks GetContext() in the runspace loop
    try {
        if ($null -ne $Api.Listener -and $Api.Listener.IsListening) {
            $Api.Listener.Stop()
        }
    } catch {
        Write-Warning "Failed to stop listener: $_"
    }

    try {
        if ($null -ne $Api.Listener) {
            $Api.Listener.Close()
        }
    } catch {
        Write-Warning "Failed to close listener: $_"
    }

    # Then stop and dispose the runspace
    try {
        if ($null -ne $Api.Ps) {
            $Api.Ps.Stop()
            $Api.Ps.Dispose()
        }
    } catch {
        Write-Warning "Failed to stop/dispose PowerShell instance: $_"
    }

    try {
        if ($null -ne $Api.Runspace) {
            $Api.Runspace.Close()
            $Api.Runspace.Dispose()
        }
    } catch {
        Write-Warning "Failed to close/dispose runspace: $_"
    }
}
