#region Dell
<#
    Source: https://downloads.dell.com/catalog/DriverPackCatalog.cab (Authenticode-signed by Dell).

    Relevant structure (default namespace openmanage/cm/dm - PowerShell's XML adapter ignores it):

    <DriverPackManifest>
      <DriverPackage releaseID="..." dellVersion="A05" vendorVersion="A05" dateTime="2024-05-14T..."
                     path="FOLDER0123456M/1/Latitude-7440-...-A05-ABCDE.CAB" hashMD5="..." size="1234567" type="win">
        <SupportedSystems>
          <Brand key="..." prefix="LAT"><Display>Latitude</Display>
            <Model systemID="0C1A" name="Latitude 7440"><Display>7440</Display></Model>
          </Brand>
        </SupportedSystems>
        <SupportedOperatingSystems>
          <OperatingSystem osCode="Windows11" osArch="x64" .../>
        </SupportedOperatingSystems>
      </DriverPackage>
    </DriverPackManifest>

    Dell packs are per Windows major version (not per feature update), so OSBuild is ignored for matching.
#>

$script:SDADellDownloadBase = 'https://downloads.dell.com'

function Find-SDADellDriverPack {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Xml.XmlDocument]$Catalog,
        [Parameter(Mandatory)]$Target
    )

    $osCode = $Target.OSName -replace '\s', ''                              # 'Windows11'
    $arch   = if ($Target.Architecture -eq 'Arm64') { 'ARM64' } else { 'x64' }

    $candidates = foreach ($pkg in @($Catalog.DriverPackManifest.DriverPackage)) {
        $osMatch = @($pkg.SupportedOperatingSystems.OperatingSystem) | Where-Object { $_.osCode -eq $osCode -and $_.osArch -eq $arch }
        if (-not $osMatch) { continue }

        $models = foreach ($brand in @($pkg.SupportedSystems.Brand)) {
            $brandName = Get-SDAXmlText $brand.Display
            foreach ($m in @($brand.Model)) {
                if ($null -eq $m) { continue }
                [pscustomobject]@{
                    Name     = [string]$m.name
                    Display  = ("{0} {1}" -f $brandName, (Get-SDAXmlText $m.Display)).Trim()
                    SystemId = ([string]$m.systemID).ToUpperInvariant()
                }
            }
        }
        $models = @($models)

        $idMatch = $false
        if ($Target.SystemIds.Count -gt 0) {
            $idMatch = [bool](@($models | Where-Object { $_.SystemId -and ($Target.SystemIds -contains $_.SystemId) }).Count)
        }
        $nameMatch = [bool](@($models | Where-Object {
            (Test-SDAModelNameMatch -CatalogName $_.Name -ConfiguredName $Target.Model -Vendor 'Dell') -or
            (Test-SDAModelNameMatch -CatalogName $_.Display -ConfiguredName $Target.Model -Vendor 'Dell')
        }).Count)
        if (-not ($idMatch -or $nameMatch)) { continue }

        [pscustomobject]@{
            Node      = $pkg
            Models    = $models
            IdMatch   = $idMatch
            NameMatch = $nameMatch
            Label     = (@($models | ForEach-Object { if ($_.Name) { $_.Name } else { $_.Display } } | Select-Object -Unique) -join ' / ')
            Date      = ConvertTo-SDADate $pkg.dateTime
        }
    }
    $candidates = @($candidates)

    if ($candidates.Count -eq 0) {
        Write-SDALog "[Dell] No driver pack in catalog for '$($Target.Model)' ($osCode $arch)." -Severity Warning -Component 'Dell'
        return $null
    }

    $candidates = @(Select-SDAMatchedCandidates -Candidates $candidates -Target $Target)

    $best = $candidates | Sort-Object -Property @{ Expression = { if ($_.Date) { $_.Date } else { [datetime]::MinValue } } }, @{ Expression = { [string]$_.Node.dellVersion } } -Descending | Select-Object -First 1
    $node = $best.Node

    $path = ([string]$node.path).TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($path)) { throw "[Dell] Catalog entry for '$($Target.Model)' has no download path." }

    $version = [string]$node.dellVersion
    if ([string]::IsNullOrWhiteSpace($version)) { $version = [string]$node.vendorVersion }
    $versionId = if ($version) { $version } elseif ($best.Date) { $best.Date.ToString('yyyyMMdd') } else { 'unknown' }

    $size = [int64]0
    [void][int64]::TryParse([string]$node.size, [ref]$size)

    $entry = New-SDACatalogEntry -Vendor 'Dell' `
        -CatalogModelName $best.Label `
        -SystemIds @($best.Models | ForEach-Object { $_.SystemId }) `
        -VendorVersion $(if ($version) { $version } else { $versionId }) `
        -VersionId $versionId `
        -ReleaseDate $best.Date `
        -Url "$script:SDADellDownloadBase/$path" `
        -Hash ([string]$node.hashMD5) `
        -SizeBytes $size `
        -Details ("releaseID={0}" -f $node.releaseID)

    Write-SDALog ("[Dell] Latest pack for '{0}': version {1}, released {2}, {3}" -f $Target.Model, $entry.VendorVersion, $entry.ReleaseDate, $entry.FileName) -Component 'Dell'
    return $entry
}

#endregion Dell
