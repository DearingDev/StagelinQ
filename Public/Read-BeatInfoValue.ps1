function Read-BeatInfoValue {
    <#
    .SYNOPSIS
        Reads one BeatInfo frame from a BeatInfo connection and returns a structured object.
    .DESCRIPTION
        Reads a fixed-length binary BeatInfo frame from the TCP stream. The frame layout
        (based on community reverse engineering of the StagelinQ protocol) is:

          Offset  Len  Type        Field
          ------  ---  ----------  -----
          0       4    UInt32 BE   Message length (bytes that follow)
          4       8    Double BE   BeatPhase [0.0, 1.0)
          12      8    Double BE   BPM (hardware clock rate)
          20      4    UInt32 BE   Beat index (monotonically increasing)
          24      4    UInt32 BE   Deck number (1-based)

        Returns a PSCustomObject with Deck, BeatPhase, BPM, BeatIndex, and Timestamp.
    .PARAMETER Connection
        The BeatInfo connection object returned by Connect-StagelinQBeatInfo.
    .EXAMPLE
        $frame = Read-BeatInfoValue -Connection $bi
        Write-Host "Deck $($frame.Deck)  Phase $($frame.BeatPhase)  BPM $($frame.BPM)"
    #>
    param([PSCustomObject]$Connection)

    $stream = $Connection.Stream

    # Read the 4-byte big-endian message length prefix
    $lenBuf = [byte[]]::new(4)
    $totalRead = 0
    while ($totalRead -lt 4) {
        $n = $stream.Read($lenBuf, $totalRead, 4 - $totalRead)
        if ($n -eq 0) { throw "BeatInfo stream closed while reading length prefix." }
        $totalRead += $n
    }
    [Array]::Reverse($lenBuf)
    $msgLen = [int][BitConverter]::ToUInt32($lenBuf, 0)

    # Read the full message body
    $body      = [byte[]]::new($msgLen)
    $totalRead = 0
    while ($totalRead -lt $msgLen) {
        $n = $stream.Read($body, $totalRead, $msgLen - $totalRead)
        if ($n -eq 0) { throw "BeatInfo stream closed while reading frame body." }
        $totalRead += $n
    }

    # Unpack fields — all big-endian
    # BeatPhase: 8-byte double at offset 0
    $phaseBytes = $body[0..7]
    [Array]::Reverse($phaseBytes)
    $beatPhase = [BitConverter]::ToDouble($phaseBytes, 0)

    # BPM: 8-byte double at offset 8
    $bpmBytes = $body[8..15]
    [Array]::Reverse($bpmBytes)
    $bpm = [BitConverter]::ToDouble($bpmBytes, 0)

    # BeatIndex: 4-byte uint32 at offset 16
    $idxBytes = $body[16..19]
    [Array]::Reverse($idxBytes)
    $beatIndex = [BitConverter]::ToUInt32($idxBytes, 0)

    # Deck: 4-byte uint32 at offset 20
    $deckBytes = $body[20..23]
    [Array]::Reverse($deckBytes)
    $deck = [BitConverter]::ToUInt32($deckBytes, 0)

    [PSCustomObject]@{
        Deck       = [int]$deck
        BeatPhase  = $beatPhase
        BPM        = $bpm
        BeatIndex  = $beatIndex
        Timestamp  = [datetime]::UtcNow
    }
}
