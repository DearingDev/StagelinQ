function Register-StateMapPath {
    <#
    .SYNOPSIS
        Subscribes to one or more StagelinQ state paths on a StateMap connection.
    .DESCRIPTION
        Builds subscription messages for all provided paths and writes them to
        the StateMap TCP stream in a single batched write. Accepts pipeline input
        so paths can be piped in from an array or pipeline expression.
    .PARAMETER Connection
        The StateMap connection object returned by Connect-StagelinQStateMap.
    .PARAMETER Path
        One or more state paths to subscribe to (e.g. '/Engine/Deck1/PlayState').
        Accepts pipeline input.
    .EXAMPLE
        Register-StateMapPath -Connection $sm -Path '/Engine/Deck1/PlayState', '/Engine/Deck1/CurrentBPM'
    .EXAMPLE
        '/Engine/Deck1/PlayState', '/Engine/Deck2/PlayState' | Register-StateMapPath -Connection $sm
    #>
    [CmdletBinding()]
    param(
        [PSCustomObject]$Connection,
        [Parameter(ValueFromPipeline)]
        [string[]]$Path
    )

    begin {
        $allPaths = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($p in $Path) { $allPaths.Add($p) }
    }

    end {
        $ms = [System.IO.MemoryStream]::new()
        $bw = [System.IO.BinaryWriter]::new($ms)

        foreach ($p in $allPaths) {
            $pathBytes    = [System.Text.Encoding]::BigEndianUnicode.GetBytes($p)
            # Total payload: magic(4) + type(4) + pathLen(4) + pathBytes + delimiter(4)
            $payloadLength = 8 + 4 + $pathBytes.Length + 4
            Write-BigEndianUInt32 -Writer $bw -Value ([uint32]$payloadLength)
            # Magic: smaa (0x73 6D 61 61) + 0x000007D2
            $bw.Write([byte[]]@(0x73, 0x6D, 0x61, 0x61, 0x00, 0x00, 0x07, 0xD2))
            # Path byte length + path
            Write-BigEndianUInt32 -Writer $bw -Value ([uint32]$pathBytes.Length)
            $bw.Write($pathBytes)
            # Delimiter
            $bw.Write([byte[]]@(0x00, 0x00, 0x00, 0x00))
        }

        $bw.Flush()
        $data = $ms.ToArray()
        $bw.Close(); $ms.Close()

        $Connection.Stream.Write($data, 0, $data.Length)
        $Connection.Stream.Flush()
    }
}
