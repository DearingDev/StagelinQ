#Requires -Module Pester
<#
.SYNOPSIS
    Unit tests for the StagelinQ binary wire-format helpers.
.DESCRIPTION
    Tests Write-BigEndianUInt32, Write-BigEndianUInt16, Write-PrefixedString,
    Read-PrefixedString, and the Build-DiscoveryFrame / Read-DiscoveryFrame roundtrip.
    Private helpers are dot-sourced directly so no module import is required.
#>

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent

    . "$root/Private/Write-BigEndianUInt32.ps1"
    . "$root/Private/Write-BigEndianUInt16.ps1"
    . "$root/Private/Write-PrefixedString.ps1"
    . "$root/Private/Read-PrefixedString.ps1"
    . "$root/Private/Build-DiscoveryFrame.ps1"
    . "$root/Public/Read-DiscoveryFrame.ps1"

    # Helper: write one value and return the resulting bytes
    function Invoke-WriterBytes {
        param([scriptblock]$Script)
        $ms = [System.IO.MemoryStream]::new()
        $w  = [System.IO.BinaryWriter]::new($ms)
        & $Script $w
        $w.Flush()
        $ms.ToArray()
    }
}

Describe 'Write-BigEndianUInt32' {
    It 'encodes 0x01020304 as bytes 01 02 03 04' {
        $bytes = Invoke-WriterBytes { param($w) Write-BigEndianUInt32 -Writer $w -Value 0x01020304 }
        $bytes | Should -Be @(0x01, 0x02, 0x03, 0x04)
    }

    It 'encodes zero as four zero bytes' {
        $bytes = Invoke-WriterBytes { param($w) Write-BigEndianUInt32 -Writer $w -Value 0 }
        $bytes | Should -Be @(0x00, 0x00, 0x00, 0x00)
    }

    It 'encodes UInt32 max value (4294967295) correctly' {
        $bytes = Invoke-WriterBytes { param($w) Write-BigEndianUInt32 -Writer $w -Value ([uint32]::MaxValue) }
        $bytes | Should -Be @(0xFF, 0xFF, 0xFF, 0xFF)
    }

    It 'encodes a value that exercises all four byte positions' {
        # 256 = 0x00000100 → bytes: 00 00 01 00
        $bytes = Invoke-WriterBytes { param($w) Write-BigEndianUInt32 -Writer $w -Value 256 }
        $bytes | Should -Be @(0x00, 0x00, 0x01, 0x00)
    }
}

Describe 'Write-BigEndianUInt16' {
    It 'encodes 0x0102 as bytes 01 02' {
        $bytes = Invoke-WriterBytes { param($w) Write-BigEndianUInt16 -Writer $w -Value 0x0102 }
        $bytes | Should -Be @(0x01, 0x02)
    }

    It 'encodes port 51337 (0xC889) correctly' {
        $bytes = Invoke-WriterBytes { param($w) Write-BigEndianUInt16 -Writer $w -Value ([uint16]51337) }
        $bytes | Should -Be @(0xC8, 0x89)
    }

    It 'encodes zero as two zero bytes' {
        $bytes = Invoke-WriterBytes { param($w) Write-BigEndianUInt16 -Writer $w -Value 0 }
        $bytes | Should -Be @(0x00, 0x00)
    }
}

Describe 'Write-PrefixedString / Read-PrefixedString roundtrip' {
    It 'roundtrips a simple ASCII string' {
        $bytes  = Invoke-WriterBytes { param($w) Write-PrefixedString -Writer $w -Value 'Hello' }
        $result = Read-PrefixedString -Data $bytes -Offset 0
        $result.Text | Should -Be 'Hello'
    }

    It 'roundtrips a device name string' {
        $bytes  = Invoke-WriterBytes { param($w) Write-PrefixedString -Writer $w -Value 'SC6000' }
        $result = Read-PrefixedString -Data $bytes -Offset 0
        $result.Text | Should -Be 'SC6000'
    }

    It 'NewOffset advances by 4 (length prefix) plus encoded byte count' {
        # 'AB' is 2 chars × 2 bytes UTF-16BE = 4 payload bytes → NewOffset = 8
        $bytes  = Invoke-WriterBytes { param($w) Write-PrefixedString -Writer $w -Value 'AB' }
        $result = Read-PrefixedString -Data $bytes -Offset 0
        $result.NewOffset | Should -Be 8
    }

    It 'reads a second string at the correct offset' {
        $bytes = Invoke-WriterBytes {
            param($w)
            Write-PrefixedString -Writer $w -Value 'First'
            Write-PrefixedString -Writer $w -Value 'Second'
        }
        $r1 = Read-PrefixedString -Data $bytes -Offset 0
        $r2 = Read-PrefixedString -Data $bytes -Offset $r1.NewOffset
        $r2.Text | Should -Be 'Second'
    }

    It 'handles an empty string' {
        $bytes  = Invoke-WriterBytes { param($w) Write-PrefixedString -Writer $w -Value '' }
        $result = Read-PrefixedString -Data $bytes -Offset 0
        $result.Text     | Should -Be ''
        $result.NewOffset | Should -Be 4   # just the 4-byte length prefix
    }
}

Describe 'Build-DiscoveryFrame / Read-DiscoveryFrame roundtrip' {
    BeforeAll {
        $script:Token = [byte[]](
            0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,
            0x09,0x0A,0x0B,0x0C,0x0D,0x0E,0x0F,0x10
        )
    }

    It 'produces a frame that starts with the airD magic bytes' {
        $frame = Build-DiscoveryFrame -Token $script:Token `
            -Source 'TestDev' -Action 'DISCOVERER_HOWDY_' `
            -SoftwareName 'JP11S' -Version '1.0' -Port 51337
        $magic = [System.Text.Encoding]::ASCII.GetString($frame, 0, 4)
        $magic | Should -Be 'airD'
    }

    It 'roundtrips DeviceName (Source)' {
        $frame  = Build-DiscoveryFrame -Token $script:Token `
            -Source 'SC6000-1' -Action 'DISCOVERER_HOWDY_' `
            -SoftwareName 'JP11S' -Version '2.0' -Port 51337
        $parsed = Read-DiscoveryFrame -Data $frame
        $parsed.DeviceName | Should -Be 'SC6000-1'
    }

    It 'roundtrips ConnectionType (Action)' {
        $frame  = Build-DiscoveryFrame -Token $script:Token `
            -Source 'Dev' -Action 'DISCOVERER_HOWDY_' `
            -SoftwareName 'JP11S' -Version '2.0' -Port 51337
        $parsed = Read-DiscoveryFrame -Data $frame
        $parsed.ConnectionType | Should -Be 'DISCOVERER_HOWDY_'
    }

    It 'roundtrips SoftwareName' {
        $frame  = Build-DiscoveryFrame -Token $script:Token `
            -Source 'Dev' -Action 'Act' -SoftwareName 'MyApp' -Version '3.1' -Port 1000
        $parsed = Read-DiscoveryFrame -Data $frame
        $parsed.SoftwareName | Should -Be 'MyApp'
    }

    It 'roundtrips SoftwareVersion' {
        $frame  = Build-DiscoveryFrame -Token $script:Token `
            -Source 'Dev' -Action 'Act' -SoftwareName 'X' -Version '9.9.9' -Port 1000
        $parsed = Read-DiscoveryFrame -Data $frame
        $parsed.SoftwareVersion | Should -Be '9.9.9'
    }

    It 'roundtrips ServicePort' {
        $frame  = Build-DiscoveryFrame -Token $script:Token `
            -Source 'Dev' -Action 'Act' -SoftwareName 'X' -Version '1' -Port 12345
        $parsed = Read-DiscoveryFrame -Data $frame
        $parsed.ServicePort | Should -Be 12345
    }

    It 'roundtrips the token as uppercase hex without dashes' {
        $token = [byte[]](
            0xDE,0xAD,0xBE,0xEF, 0x00,0x11,0x22,0x33,
            0x44,0x55,0x66,0x77, 0x88,0x99,0xAA,0xBB
        )
        $frame  = Build-DiscoveryFrame -Token $token `
            -Source 'x' -Action 'x' -SoftwareName 'x' -Version 'x' -Port 1
        $parsed = Read-DiscoveryFrame -Data $frame
        $parsed.Token | Should -Be 'DEADBEEF00112233445566778899AABB'
    }

    It 'sets SourceAddress to null (filled in by caller)' {
        $frame  = Build-DiscoveryFrame -Token $script:Token `
            -Source 'Dev' -Action 'Act' -SoftwareName 'X' -Version '1' -Port 1
        $parsed = Read-DiscoveryFrame -Data $frame
        $parsed.SourceAddress | Should -BeNullOrEmpty
    }

    It 'throws when the magic bytes are not airD' {
        $bad = [byte[]]@(0x00, 0x00, 0x00, 0x00, 0x00)
        { Read-DiscoveryFrame -Data $bad } | Should -Throw
    }

    It 'throw message mentions the bad magic value' {
        $bad = [byte[]]( [System.Text.Encoding]::ASCII.GetBytes('XXXX') + [byte[]](0x00 * 30) )
        { Read-DiscoveryFrame -Data $bad } | Should -Throw '*XXXX*'
    }
}
