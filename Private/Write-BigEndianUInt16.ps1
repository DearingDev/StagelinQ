function Write-BigEndianUInt16 {
    param([System.IO.BinaryWriter]$Writer, [uint16]$Value)

    $Writer.Write([byte](($Value -shr 8) -band 0xFF))
    $Writer.Write([byte]( $Value         -band 0xFF))
}
