function Read-BeatInfoValue {
    <#
    .SYNOPSIS
        Reads one BeatEmit frame from a BeatInfo connection and returns the
        full multi-player payload.
    .DESCRIPTION
        Matches the wire format in icedream/go-stagelinq (beatEmitMessage).
        After a 4-byte length prefix, the frame body is:

          Offset  Len     Type        Field
          ------  ------  ----------  -----
          0       4       UInt32 BE   Magic = 0x00000002
          4       8       UInt64 BE   Clock (device timebase, microseconds)
          12      4       UInt32 BE   N (player count)
          16      N*24    PlayerInfo  N records: Beat, TotalBeats, Bpm (each Double BE)
          ...     N*8     Double BE   N Timelines (per-player position in seconds)

        Returned PSCustomObject:
          Clock     — UInt64 device clock
          Players   — array of per-deck PSCustomObjects with:
                        Deck        (1-based positional index)
                        Beat        (double, cumulative beat position in track)
                        TotalBeats  (double, total beats in the loaded track — constant per track)
                        BPM         (double, hardware-reported BPM)
                        BeatPhase   (Beat - floor(Beat); convenience for UI)
                        BeatIndex   (floor(Beat); convenience for beat-edge detection)
                        Timeline    (double, timeline position in seconds)
          Timestamp — local UTC receive time
    .PARAMETER Connection
        The BeatInfo connection object returned by Connect-StagelinQBeatInfo.
    .EXAMPLE
        $frame = Read-BeatInfoValue -Connection $bi
        foreach ($p in $frame.Players) {
            Write-Host "Deck $($p.Deck)  Phase $([math]::Round($p.BeatPhase,3))  BPM $($p.BPM)"
        }
    #>
    param([PSCustomObject]$Connection)

    $stream = $Connection.Stream

    # ── 4-byte big-endian length prefix ────────────────────────────────────
    $lenBuf = [byte[]]::new(4)
    $totalRead = 0
    while ($totalRead -lt 4) {
        $n = $stream.Read($lenBuf, $totalRead, 4 - $totalRead)
        if ($n -eq 0) { throw "BeatInfo stream closed while reading length prefix." }
        $totalRead += $n
    }
    $msgLen = ([int]$lenBuf[0] -shl 24) -bor ([int]$lenBuf[1] -shl 16) `
            -bor ([int]$lenBuf[2] -shl 8)  -bor [int]$lenBuf[3]

    # ── body ───────────────────────────────────────────────────────────────
    $body = [byte[]]::new($msgLen)
    $totalRead = 0
    while ($totalRead -lt $msgLen) {
        $n = $stream.Read($body, $totalRead, $msgLen - $totalRead)
        if ($n -eq 0) { throw "BeatInfo stream closed while reading frame body." }
        $totalRead += $n
    }

    # Helpers — BitConverter is little-endian, reverse in-place on each slice
    $readDoubleBE = {
        param([byte[]]$Buf, [int]$Off)
        $tmp = [byte[]]::new(8)
        [Array]::Copy($Buf, $Off, $tmp, 0, 8)
        [Array]::Reverse($tmp)
        [BitConverter]::ToDouble($tmp, 0)
    }
    $readUInt32BE = {
        param([byte[]]$Buf, [int]$Off)
        ([uint32]$Buf[$Off] -shl 24) -bor ([uint32]$Buf[$Off+1] -shl 16) `
            -bor ([uint32]$Buf[$Off+2] -shl 8) -bor [uint32]$Buf[$Off+3]
    }
    $readUInt64BE = {
        param([byte[]]$Buf, [int]$Off)
        $tmp = [byte[]]::new(8)
        [Array]::Copy($Buf, $Off, $tmp, 0, 8)
        [Array]::Reverse($tmp)
        [BitConverter]::ToUInt64($tmp, 0)
    }

    $magic = & $readUInt32BE $body 0
    if ($magic -ne 0x00000002) {
        throw ("Unexpected BeatInfo magic 0x{0:X8} (expected 0x00000002)" -f $magic)
    }

    $clock      = & $readUInt64BE $body 4
    $numPlayers = [int](& $readUInt32BE $body 12)

    # PlayerInfo: 24 bytes each starting at offset 16
    $players = for ($i = 0; $i -lt $numPlayers; $i++) {
        $poff = 16 + ($i * 24)
        $beat       = & $readDoubleBE $body $poff
        $totalBeats = & $readDoubleBE $body ($poff + 8)
        $bpm        = & $readDoubleBE $body ($poff + 16)
        [PSCustomObject]@{
            Deck       = $i + 1
            Beat       = $beat
            TotalBeats = $totalBeats
            BPM        = $bpm
            BeatPhase  = $beat - [math]::Floor($beat)
            BeatIndex  = [uint32][math]::Floor($beat)
            Timeline   = $null  # filled in below
        }
    }

    # Timeline array: 8 bytes each, immediately after the PlayerInfo block
    $timelineOff = 16 + ($numPlayers * 24)
    for ($i = 0; $i -lt $numPlayers; $i++) {
        $players[$i].Timeline = & $readDoubleBE $body ($timelineOff + ($i * 8))
    }

    [PSCustomObject]@{
        Clock     = $clock
        Players   = $players
        Timestamp = [datetime]::UtcNow
    }
}
