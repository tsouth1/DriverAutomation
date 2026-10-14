#region Lenovo
<#
    Source: https://download.lenovo.com/cdrt/td/catalogv2.xml (served over HTTPS; not signed).

    <ModelList>
      <Model name="ThinkPad T14 Gen 4 (Type 21HD, 21HE)">
        <Types><Type>21HD</Type><Type>21HE</Type></Types>
        <SCCM os="win11" version="23H2" date="2024-04-17" crc="<sha256>">https://download.lenovo.com/pccbbs/mobiles/tp_t14_gen4_w1164_23h2_202404.exe</SCCM>
        ...
      </Model>
    </ModelList>

    The 4-character machine type (MTM prefix, first 4 chars of Win32_ComputerSystem.Model on Lenovo) is
    the most reliable match key. Packs are per Windows feature update, so OSBuild is mandatory. The pack
    date is the version identity (Lenovo does not publish a separate version number in this catalog).
#>

function Find-SDALenovoDriverPack {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Xml.XmlDocument]$Catalog,
        [Parameter(Mandatory)]$Target
    )

    if ($Target.Architecture -ne 'x64') {
        Write-SDALog "[Lenovo] Only x64 SCCM driver packs are handled for Lenovo ($($Target.DisplayName))." -Severity Warning -Component 'Lenovo'
        return $null
    }

    $osCode = 'win' + ($Target.OSName -replace '[^\d]', '')                # 'win11'
    $configured = ($Target.Model -replace '\s+', ' ').Trim()
    $namePrefix = '^(?i)' + [regex]::Escape($configured) + '(\s*\(|\s+type\b|$)'

    $candidates = foreach ($m in @($Catalog.ModelList.Model)) {
        $name  = [string]$m.name
        $types = @(@($m.Types.Type) | ForEach-Object { (Get-SDAXmlText $_).ToUpperInvariant() } | Where-Object { $_ })

        $idMatch   = ($Target.SystemIds.Count -gt 0) -and [bool](@($types | Where-Object { $Target.SystemIds -contains $_ }).Count)
        $nameMatch = (Test-SDAModelNameMatch -CatalogName $name -ConfiguredName $configured -Vendor 'Lenovo') -or
                     ((($name -replace '\s+', ' ').Trim()) -match $namePrefix)
        if (-not ($idMatch -or $nameMatch)) { continue }

        foreach ($s in @($m.SCCM)) {
            if ($null -eq $s) { continue }
            if ([string]$s.os -ne $osCode) { continue }
            $ver = [string]$s.version
            if ($ver -ne $Target.OSBuild -and $ver -ne '*') { continue }
            $url = Get-SDAXmlText $s
            if (-not $url) { continue }
            [pscustomobject]@{
                Name    = $name
                Types   = $types
                Url     = $url
                Hash    = [string]$s.crc
                Date    = ConvertTo-SDADate ([string]$s.date)
                RawDate = [string]$s.date
                IdMatch   = $idMatch
                NameMatch = $nameMatch
                Label     = $name
            }
        }
    }
    $candidates = @($candidates)

    if ($candidates.Count -eq 0) {
        Write-SDALog "[Lenovo] No SCCM driver pack in catalog for '$($Target.Model)' ($osCode $($Target.OSBuild))." -Severity Warning -Component 'Lenovo'
        return $null
    }
    $candidates = @(Select-SDAMatchedCandidates -Candidates $candidates -Target $Target)

    $best = $candidates | Sort-Object -Property @{ Expression = { if ($_.Date) { $_.Date } else { [datetime]::MinValue } } } -Descending | Select-Object -First 1

    $versionId = if ($best.Date) { $best.Date.ToString('yyyyMMdd') } else { [IO.Path]::GetFileNameWithoutExtension(([Uri]$best.Url).Segments[-1]) }

    $entry = New-SDACatalogEntry -Vendor 'Lenovo' `
        -CatalogModelName $best.Name `
        -SystemIds $best.Types `
        -VendorVersion $(if ($best.RawDate) { $best.RawDate } else { $versionId }) `
        -VersionId $versionId `
        -ReleaseDate $best.Date `
        -Url $best.Url `
        -Hash $best.Hash

    Write-SDALog ("[Lenovo] Latest pack for '{0}': dated {1}, {2}" -f $Target.Model, $entry.VendorVersion, $entry.FileName) -Component 'Lenovo'
    return $entry
}

#endregion Lenovo
