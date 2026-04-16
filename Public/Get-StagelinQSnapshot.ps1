function Get-StagelinQSnapshot {
    <#
    .SYNOPSIS
        Returns a point-in-time copy of the shared StagelinQ state as a plain hashtable.
    .DESCRIPTION
        Takes a snapshot of the ConcurrentDictionary populated by Start-StagelinQStreams
        and returns it as a plain [hashtable]. The copy is safe to iterate without
        locking — any concurrent writes from the stream runspaces affect only the
        live dictionary, not the returned snapshot.
    .EXAMPLE
        $snap = Get-StagelinQSnapshot
        $snap | Format-Table -AutoSize
    .EXAMPLE
        # Watch specific keys from the snapshot
        (Get-StagelinQSnapshot).GetEnumerator() |
            Where-Object Key -like 'BeatInfo/*' |
            Sort-Object Key |
            Format-Table Key, Value -AutoSize
    #>

    $snap = @{}
    foreach ($kvp in $script:State.GetEnumerator()) {
        $snap[$kvp.Key] = $kvp.Value
    }
    $snap
}
