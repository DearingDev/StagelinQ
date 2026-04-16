function Read-PrefixedString {
    param([byte[]]$Data, [int]$Offset)

    $lengthBytes = $Data[$Offset..($Offset + 3)]
    [Array]::Reverse($lengthBytes)
    $length = [System.BitConverter]::ToUInt32($lengthBytes, 0)

    $text = [System.Text.Encoding]::BigEndianUnicode.GetString($Data, $Offset + 4, $length)

    [PSCustomObject]@{
        Text      = $text
        NewOffset = $Offset + 4 + $length
    }
}
