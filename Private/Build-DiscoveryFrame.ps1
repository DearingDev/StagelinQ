function Build-DiscoveryFrame {
    param(
        [byte[]]$Token,
        [string]$Source,
        [string]$Action,
        [string]$SoftwareName,
        [string]$Version,
        [int]$Port
    )

    $ms     = [System.IO.MemoryStream]::new()
    $writer = [System.IO.BinaryWriter]::new($ms)

    # Magic: ASCII "airD"
    $writer.Write([System.Text.Encoding]::ASCII.GetBytes('airD'))

    # Token: 16 bytes
    $writer.Write($Token)

    # Four length-prefixed UTF-16BE strings
    Write-PrefixedString -Writer $writer -Value $Source
    Write-PrefixedString -Writer $writer -Value $Action
    Write-PrefixedString -Writer $writer -Value $SoftwareName
    Write-PrefixedString -Writer $writer -Value $Version

    # Service port: big-endian uint16
    Write-BigEndianUInt16 -Writer $writer -Value ([uint16]$Port)

    $writer.Flush()
    return $ms.ToArray()
}
