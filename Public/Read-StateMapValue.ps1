function Read-StateMapValue {
    <#
    .SYNOPSIS
        Reads and parses one buffer's worth of StateMap messages from a connection.
    .DESCRIPTION
        Reads up to BufferSize bytes from the StateMap TCP stream, then parses all
        complete 'smaa'-magic messages found in that buffer. Returns one PSCustomObject
        per message with Path and Value properties. Messages with an unrecognised
        magic header are silently skipped. Returns an empty result set if no complete
        messages are in the buffer.
    .PARAMETER Connection
        The StateMap connection object returned by Connect-StagelinQStateMap.
    .PARAMETER BufferSize
        The read buffer size in bytes. Defaults to 8192.
    .EXAMPLE
        $updates = Read-StateMapValue -Connection $sm
        $updates | ForEach-Object { Write-Host "$($_.Path) = $($_.Value)" }
    #>
    param(
        [PSCustomObject]$Connection,
        [int]$BufferSize = 8192
    )

    $buffer    = [byte[]]::new($BufferSize)
    $bytesRead = $Connection.Stream.Read($buffer, 0, $buffer.Length)

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $pos     = 0

    while ($pos + 4 -le $bytesRead) {
        # Read total message length (big-endian uint32)
        $lenBytes = [byte[]]@($buffer[$pos], $buffer[$pos+1], $buffer[$pos+2], $buffer[$pos+3])
        [Array]::Reverse($lenBytes)
        $msgLen = [int][BitConverter]::ToUInt32($lenBytes, 0)

        # Ensure the full message is in the buffer
        if ($pos + 4 + $msgLen -gt $bytesRead) { break }

        $msgEnd  = $pos + 4 + $msgLen
        $pos    += 4

        # Validate magic 'smaa'
        if ($msgLen -lt 4 -or [System.Text.Encoding]::ASCII.GetString($buffer, $pos, 4) -ne 'smaa') {
            $pos = $msgEnd
            continue
        }
        $pos += 4  # skip magic

        # Skip message type (4 bytes)
        if ($pos + 4 -gt $msgEnd) { $pos = $msgEnd; continue }
        $pos += 4

        # Read path (4-byte big-endian length prefix + UTF-16BE bytes)
        if ($pos + 4 -gt $msgEnd) { $pos = $msgEnd; continue }
        $pathResult = Read-PrefixedString -Data $buffer -Offset $pos
        $pos = $pathResult.NewOffset

        # Read value: 4-byte big-endian length prefix + value payload
        $remaining = $msgEnd - $pos
        if ($remaining -gt 4) {
            # Correctly read the 4-byte big-endian value length prefix
            $valLenBytes = $buffer[$pos..($pos+3)]
            [Array]::Reverse($valLenBytes)
            $valLen = [System.BitConverter]::ToUInt32($valLenBytes, 0)

            # The value payload starts after the 4-byte length prefix.
            # The protocol sends values as UTF-16BE (BigEndianUnicode), matching
            # how paths are encoded. There may be a leading null/padding byte
            # before the JSON — detect and skip it.
            $valStart = $pos + 4
            $valBytes = [int]$valLen
            $safeLen  = [Math]::Min($valBytes, $msgEnd - $valStart)

            if ($safeLen -gt 0) {
                # Try UTF-16BE first (matching how paths are encoded).
                # UTF-16BE requires an even number of bytes. Ensure we have that.
                $tryLen = $safeLen
                $tryStart = $valStart

                # If odd length, the first byte might be a padding/null byte — skip it
                if ($tryLen % 2 -ne 0) {
                    $tryStart = $valStart + 1
                    $tryLen   = $safeLen - 1
                }

                $json = $null
                if ($tryLen -ge 2) {
                    $jsonUtf16 = [System.Text.Encoding]::BigEndianUnicode.GetString(
                        $buffer, $tryStart, $tryLen).Trim("`0")
                    if ($jsonUtf16.TrimStart().StartsWith('{')) {
                        $json = $jsonUtf16
                    }
                }

                # Fallback: try UTF-8 over the original range
                if (-not $json) {
                    $json = [System.Text.Encoding]::UTF8.GetString(
                        $buffer, $valStart, $safeLen).Trim("`0")
                }

                $results.Add([PSCustomObject]@{
                    Path  = $pathResult.Text
                    Value = $json
                })
            }
        }

        $pos = $msgEnd
    }

    # Return as array; emit items into the pipeline
    foreach ($r in $results) { $r }
}
