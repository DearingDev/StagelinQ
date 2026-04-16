function Stop-StagelinQStreams {
    <#
    .SYNOPSIS
        Stops the background stream runspaces started by Start-StagelinQStreams.
    .DESCRIPTION
        Calls Stop() and Dispose() on both the StateMap and BeatInfo PowerShell
        instances, then closes their runspaces. Each step is wrapped in try/catch
        so the function completes even if a runspace has already terminated.
    .PARAMETER Streams
        The handle object returned by Start-StagelinQStreams.
    .EXAMPLE
        Stop-StagelinQStreams -Streams $streams
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Streams
    )

    try { $Streams.StateMapPs.Stop() }        catch {}
    try { $Streams.StateMapPs.Dispose() }     catch {}
    try { $Streams.StateMapRunspace.Close() } catch {}

    try { $Streams.BeatInfoPs.Stop() }        catch {}
    try { $Streams.BeatInfoPs.Dispose() }     catch {}
    try { $Streams.BeatInfoRunspace.Close() } catch {}
}
