function Write-BigEndianUInt32 {
    param([System.IO.BinaryWriter]$Writer, [uint32]$Value)

    $Writer.Write([byte](($Value -shr 24) -band 0xFF))
    $Writer.Write([byte](($Value -shr 16) -band 0xFF))
    $Writer.Write([byte](($Value -shr 8)  -band 0xFF))
    $Writer.Write([byte]( $Value          -band 0xFF))
}
