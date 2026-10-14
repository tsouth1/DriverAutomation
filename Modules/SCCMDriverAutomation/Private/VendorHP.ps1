#region HP
<#
    Source: https://hpia.hpcloud.hp.com/downloads/driverpackcatalog/HPClientDriverPackCatalog.cab
    (Authenticode-signed by HP Inc.)

    <NewDataSet><HPClientDriverPackCatalog>
      <SoftPaqList>
        <SoftPaq><Id>sp150000</Id><Name>...</Name><Version>1.00 A 1</Version><DateReleased>2024-03-01</DateReleased>
                 <Url>https://ftp.hp.com/pub/softpaq/sp150001-150500/sp150000.exe</Url><Size>...</Size>
                 <MD5>...</MD5><SHA256>...</SHA256></SoftPaq>
      </SoftPaqList>
      <ProductOSDriverPackList>
        <ProductOSDriverPack><ProductType>Notebooks</ProductType><SystemId>8B41</SystemId>
          <SystemName>HP EliteBook 840 14 inch G10 Notebook PC</SystemName>
          <OSName>Windows 11 64-bit, 24H2</OSName><SoftPaqId>sp150000</SoftPaqId></ProductOSDriverPack>
      </ProductOSDriverPackList>
    </HPClientDriverPackCatalog></NewDataSet>

    HP packs are per Windows feature update, so OSBuild is mandatory. SystemId is the 4-character
    baseboard / platform ID (Win32_BaseBoard.Product), which is the most reliable match key.
#>

$script:SDAHPSoftPaqIndex = $null
$script:SDAHPSoftPaqIndexSource = $null

function Get-SDAHPSoftPaqIndex {
    [CmdletBinding()]
    param ([Parameter(Mandatory)][System.Xml.XmlDocument]$Catalog)

    if ($null -ne $script:SDAHPSoftPaqIndex -and [object]::ReferenceEquals($script:SDAHPSoftPaqIndexSource, $Catalog)) {
        return $script:SDAHPSoftPaqIndex
    }
    $index = @{}
    foreach ($sp in @($Catalog.NewDataSet.HPClientDriverPackCatalog.SoftPaqList.SoftPaq)) {
        $id = (Get-SDAXmlText $sp.Id)
        if ($id) { $index[$id.ToUpperInvariant()] = $sp }
    }
    $script:SDAHPSoftPaqIndex = $index
    $script:SDAHPSoftPaqIndexSource = $Catalog
    return $index
}

function Find-SDAHPDriverPack {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Xml.XmlDocument]$Catalog,
        [Parameter(Mandatory)]$Target
    )

    if ($Target.Architecture -ne 'x64') {
        Write-SDALog "[HP] Only x64 driver packs are published in the HP client driver pack catalog ($($Target.DisplayName))." -Severity Warning -Component 'HP'
        return $null
    }

    $index = Get-SDAHPSoftPaqIndex -Catalog $Catalog
    $buildPattern = '\b' + [regex]::Escape($Target.OSBuild) + '\b'

    $candidates = foreach ($p in @($Catalog.NewDataSet.HPClientDriverPackCatalog.ProductOSDriverPackList.ProductOSDriverPack)) {
        $osName = Get-SDAXmlText $p.OSName
        if (-not $osName -or -not $osName.StartsWith($Target.OSName, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($osName -notmatch '64-bit' -or $osName -notmatch $buildPattern) { continue }

        $ids = @((Get-SDAXmlText $p.SystemId) -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() })
        $name = Get-SDAXmlText $p.SystemName
        $idMatch = ($Target.SystemIds.Count -gt 0) -and [bool](@($ids | Where-Object { $Target.SystemIds -contains $_ }).Count)
        $nameMatch = Test-SDAModelNameMatch -CatalogName $name -ConfiguredName $Target.Model -Vendor 'HP'
        if (-not ($idMatch -or $nameMatch)) { continue }

        $spId = (Get-SDAXmlText $p.SoftPaqId)
        if (-not $spId) { continue }
        $sp = $index[$spId.ToUpperInvariant()]
        if ($null -eq $sp) {
            Write-SDALog "[HP] Pack $spId for '$name' is referenced but missing from SoftPaqList - skipped." -Severity Warning -Component 'HP'
            continue
        }

        [pscustomobject]@{
            SoftPaq    = $sp
            SoftPaqId  = $spId
            SystemName = $name
            SystemIds  = $ids
            IdMatch    = $idMatch
            NameMatch  = $nameMatch
            Label      = $name
            Date       = ConvertTo-SDADate (Get-SDAXmlText $sp.DateReleased)
        }
    }
    $candidates = @($candidates)

    if ($candidates.Count -eq 0) {
        Write-SDALog "[HP] No driver pack in catalog for '$($Target.Model)' ($($Target.OSName) $($Target.OSBuild))." -Severity Warning -Component 'HP'
        return $null
    }
    $candidates = @(Select-SDAMatchedCandidates -Candidates $candidates -Target $Target)

    $best = $candidates | Sort-Object -Property @{ Expression = { if ($_.Date) { $_.Date } else { [datetime]::MinValue } } } -Descending | Select-Object -First 1
    $sp = $best.SoftPaq

    $url = Get-SDAXmlText $sp.Url
    if (-not $url) {
        # Fall back to the well-known SoftPaq folder layout (sp150000 lives in sp150001-150500).
        $num = [int]($best.SoftPaqId -replace '^(?i)sp', '')
        $low = [int]([Math]::Floor(($num - 1) / 500) * 500 + 1)
        $url = "https://ftp.hp.com/pub/softpaq/sp$low-$($low + 499)/sp$num.exe"
    }

    $version = Get-SDAXmlText $sp.Version
    $hash = Get-SDAXmlText $sp.SHA256
    if (-not $hash) { $hash = Get-SDAXmlText $sp.MD5 }
    $size = [int64]0
    [void][int64]::TryParse((Get-SDAXmlText $sp.Size), [ref]$size)

    # All SystemIds sharing this SoftPaq (a pack often covers several baseboards).
    $allIds = @($candidates | Where-Object { $_.SoftPaqId -eq $best.SoftPaqId } | ForEach-Object { $_.SystemIds })

    $entry = New-SDACatalogEntry -Vendor 'HP' `
        -CatalogModelName $best.SystemName `
        -SystemIds $allIds `
        -VendorVersion $(if ($version) { $version } else { $best.SoftPaqId }) `
        -VersionId $(if ($version) { "$version" } else { $best.SoftPaqId }) `
        -ReleaseDate $best.Date `
        -Url $url `
        -Hash $hash `
        -SizeBytes $size `
        -Details ("SoftPaq={0}" -f $best.SoftPaqId)

    Write-SDALog ("[HP] Latest pack for '{0}': {1} version {2}, released {3}" -f $Target.Model, $best.SoftPaqId, $entry.VendorVersion, $entry.ReleaseDate) -Component 'HP'
    return $entry
}

#endregion HP
