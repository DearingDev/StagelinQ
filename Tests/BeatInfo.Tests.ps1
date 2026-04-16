#Requires -Module Pester
<#
.SYNOPSIS
    Unit tests for Read-BeatInfoValue using synthetic in-memory frames.
.DESCRIPTION
    Builds raw BeatInfo binary frames (matching the StagelinQ wire format) from known
    values using a MemoryStream, wraps them in a mock connection object, and verifies
    that Read-BeatInfoValue parses each field correctly.  No real hardware or network
    sockets required.
#>

BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'StagelinQ.psd1'
    Import-Module $modulePath -Force

    <#
        BeatInfo frame layout (big-endian throughout):
          [0..3]   UInt32  message body length (always 24)
          [4..11]  Double  BeatPhase [0.0, 1.0)
          [12..19] Double  BPM
          [20..23] UInt32  BeatIndex
          [24..27] UInt32  Deck (1-based)
    #>
    function New-BeatInfoBytes {
        param(
            [double]$BeatPhase,
            [double]$BPM,
            [uint32]$BeatIndex,
            [uint32]$Deck
        )

        $ms = [System.IO.MemoryStream]::new()
        $w  = [System.IO.BinaryWriter]::new($ms)

        # Length prefix: 24-byte body
        $bodyLen = [uint32]24
        $w.Write([byte](($bodyLen -shr 24) -band 0xFF))
        $w.Write([byte](($bodyLen -shr 16) -band 0xFF))
        $w.Write([byte](($bodyLen -shr  8) -band 0xFF))
        $w.Write([byte]( $bodyLen          -band 0xFF))

        # BeatPhase — 8-byte double, big-endian
        $b = [BitConverter]::GetBytes($BeatPhase); [Array]::Reverse($b); $w.Write($b)

        # BPM — 8-byte double, big-endian
        $b = [BitConverter]::GetBytes($BPM);       [Array]::Reverse($b); $w.Write($b)

        # BeatIndex — 4-byte uint32, big-endian
        $w.Write([byte](($BeatIndex -shr 24) -band 0xFF))
        $w.Write([byte](($BeatIndex -shr 16) -band 0xFF))
        $w.Write([byte](($BeatIndex -shr  8) -band 0xFF))
        $w.Write([byte]( $BeatIndex          -band 0xFF))

        # Deck — 4-byte uint32, big-endian
        $w.Write([byte](($Deck -shr 24) -band 0xFF))
        $w.Write([byte](($Deck -shr 16) -band 0xFF))
        $w.Write([byte](($Deck -shr  8) -band 0xFF))
        $w.Write([byte]( $Deck          -band 0xFF))

        $w.Flush()
        $ms.ToArray()
    }

    function New-BeatInfoConn {
        param([byte[]]$Bytes)
        [PSCustomObject]@{ Stream = [System.IO.MemoryStream]::new($Bytes) }
    }
}

AfterAll {
    Remove-Module StagelinQ -ErrorAction SilentlyContinue
}

Describe 'Read-BeatInfoValue' {
    It 'parses Deck 1' {
        $conn  = New-BeatInfoConn (New-BeatInfoBytes -BeatPhase 0.0 -BPM 120.0 -BeatIndex 0 -Deck 1)
        $frame = Read-BeatInfoValue -Connection $conn
        $frame.Deck | Should -Be 1
    }

    It 'parses Deck 2' {
        $conn  = New-BeatInfoConn (New-BeatInfoBytes -BeatPhase 0.0 -BPM 120.0 -BeatIndex 0 -Deck 2)
        $frame = Read-BeatInfoValue -Connection $conn
        $frame.Deck | Should -Be 2
    }

    It 'parses BeatPhase 0.0' {
        $conn  = New-BeatInfoConn (New-BeatInfoBytes -BeatPhase 0.0 -BPM 120.0 -BeatIndex 0 -Deck 1)
        $frame = Read-BeatInfoValue -Connection $conn
        $frame.BeatPhase | Should -Be 0.0
    }

    It 'parses BeatPhase 0.75' {
        $conn  = New-BeatInfoConn (New-BeatInfoBytes -BeatPhase 0.75 -BPM 120.0 -BeatIndex 0 -Deck 1)
        $frame = Read-BeatInfoValue -Connection $conn
        $frame.BeatPhase | Should -Be 0.75
    }

    It 'parses BPM 128.0' {
        $conn  = New-BeatInfoConn (New-BeatInfoBytes -BeatPhase 0.0 -BPM 128.0 -BeatIndex 0 -Deck 1)
        $frame = Read-BeatInfoValue -Connection $conn
        $frame.BPM | Should -Be 128.0
    }

    It 'parses fractional BPM (104.998)' {
        $conn  = New-BeatInfoConn (New-BeatInfoBytes -BeatPhase 0.0 -BPM 104.998 -BeatIndex 0 -Deck 1)
        $frame = Read-BeatInfoValue -Connection $conn
        $frame.BPM | Should -Be 104.998
    }

    It 'parses BeatIndex 0' {
        $conn  = New-BeatInfoConn (New-BeatInfoBytes -BeatPhase 0.0 -BPM 120.0 -BeatIndex 0 -Deck 1)
        $frame = Read-BeatInfoValue -Connection $conn
        $frame.BeatIndex | Should -Be 0
    }

    It 'parses a large BeatIndex' {
        $conn  = New-BeatInfoConn (New-BeatInfoBytes -BeatPhase 0.0 -BPM 120.0 -BeatIndex 9999 -Deck 1)
        $frame = Read-BeatInfoValue -Connection $conn
        $frame.BeatIndex | Should -Be 9999
    }

    It 'returns a Timestamp of type [datetime]' {
        $conn  = New-BeatInfoConn (New-BeatInfoBytes -BeatPhase 0.5 -BPM 128.0 -BeatIndex 1 -Deck 1)
        $frame = Read-BeatInfoValue -Connection $conn
        $frame.Timestamp | Should -BeOfType [datetime]
    }

    It 'throws when the stream is empty (closed connection)' {
        $conn = [PSCustomObject]@{ Stream = [System.IO.MemoryStream]::new([byte[]]@()) }
        { Read-BeatInfoValue -Connection $conn } | Should -Throw
    }

    It 'throws when the stream has only a partial length prefix' {
        $conn = [PSCustomObject]@{ Stream = [System.IO.MemoryStream]::new([byte[]]@(0x00, 0x00)) }
        { Read-BeatInfoValue -Connection $conn } | Should -Throw
    }
}
