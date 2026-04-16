function Write-PrefixedString {
    param([System.IO.BinaryWriter]$Writer, [string]$Value)

    $encoded = [System.Text.Encoding]::BigEndianUnicode.GetBytes($Value)
    Write-BigEndianUInt32 -Writer $Writer -Value ([uint32]$encoded.Length)
    $Writer.Write($encoded)
}
