#region Catalog browsing
<#
    Lists every model / OS combination a vendor catalog publishes a driver pack for, in the form the
    Models section of the configuration expects. Used by Get-DriverCatalogModels.ps1 and the GUI to
    pick models instead of typing names and system IDs by hand.

    The names and IDs come from the same catalog fields the Find-SDA<Vendor>DriverPack resolvers match
    on, so an entry built from a row resolves to the same pack.
#>

function Get-SDACatalogModels {
    <#
    .SYNOPSIS
        Returns one row per vendor / model / OS / build / architecture with the newest pack for it.
    .OUTPUTS
        Objects with Vendor, Model, CatalogName, SystemIds, OSName, OSBuild, Architecture, Version,
        ReleaseDate. SystemIds is the union for the model across all its packs.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][ValidateSet('Dell', 'HP', 'Lenovo')][string]$Vendor,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )

    $xml = Get-SDACatalogXml -Vendor $Vendor -Config $Config
    $raw = switch ($Vendor) {
        'Dell'   { Get-SDADellCatalogRows -Catalog $xml }
        'HP'     { Get-SDAHPCatalogRows -Catalog $xml }
        'Lenovo' { Get-SDALenovoCatalogRows -Catalog $xml }
    }

    # Keep the newest pack per model / OS / build / architecture, and collect each model's IDs.
    $newest = [ordered]@{}
    $modelIds = @{}
    foreach ($row in @($raw)) {
        $modelKey = $row.Model.ToLowerInvariant()
        if (-not $modelIds.ContainsKey($modelKey)) { $modelIds[$modelKey] = New-Object System.Collections.Generic.List[string] }
        foreach ($id in @($row.SystemIds)) {
            if ($id -and -not $modelIds[$modelKey].Contains($id)) { $modelIds[$modelKey].Add($id) }
        }
        $key = '{0}|{1}|{2}|{3}' -f $modelKey, $row.OSName, $row.OSBuild, $row.Architecture
        $current = $newest[$key]
        if ($null -eq $current -or [string]$row.ReleaseDate -gt [string]$current.ReleaseDate) { $newest[$key] = $row }
    }

    $rows = foreach ($row in $newest.Values) {
        [pscustomobject]@{
            Vendor       = $Vendor
            Model        = $row.Model
            CatalogName  = $row.CatalogName
            SystemIds    = @($modelIds[$row.Model.ToLowerInvariant()] | Sort-Object)
            OSName       = $row.OSName
            OSBuild      = $row.OSBuild
            Architecture = $row.Architecture
            Version      = $row.Version
            ReleaseDate  = $row.ReleaseDate
        }
    }
    # Newest OS and build first within each model; x64 before Arm64.
    return @($rows | Sort-Object -Property Model, @{ Expression = 'OSName'; Descending = $true }, @{ Expression = 'OSBuild'; Descending = $true }, @{ Expression = { $_.Architecture -ne 'x64' } })
}

function New-SDACatalogRow {
    param ([string]$Model, [string]$CatalogName, [string[]]$SystemIds, [string]$OSName, [string]$OSBuild, [string]$Architecture, [string]$Version, $ReleaseDate)

    $date = ConvertTo-SDADate $ReleaseDate
    [pscustomobject]@{
        Model        = ($Model -replace '\s+', ' ').Trim()
        CatalogName  = $CatalogName
        SystemIds    = @($SystemIds | Where-Object { $_ } | ForEach-Object { $_.Trim().ToUpperInvariant() })
        OSName       = $OSName
        OSBuild      = $OSBuild
        Architecture = $Architecture
        Version      = $Version
        ReleaseDate  = $(if ($date) { $date.ToString('yyyy-MM-dd') } else { '' })
    }
}

function Get-SDADellCatalogRows {
    # Dell packs are per Windows major version, so rows have no build (see VendorDell.ps1).
    param ([Parameter(Mandatory)][System.Xml.XmlDocument]$Catalog)

    foreach ($pkg in @($Catalog.DriverPackManifest.DriverPackage)) {
        if ($null -eq $pkg) { continue }
        $version = [string]$pkg.dellVersion
        if ([string]::IsNullOrWhiteSpace($version)) { $version = [string]$pkg.vendorVersion }

        $operatingSystems = foreach ($os in @($pkg.SupportedOperatingSystems.OperatingSystem)) {
            if ($null -eq $os) { continue }
            $name = switch ([string]$os.osCode) { 'Windows11' { 'Windows 11' } 'Windows10' { 'Windows 10' } default { $null } }
            $arch = switch ([string]$os.osArch) { 'x64' { 'x64' } 'ARM64' { 'Arm64' } default { $null } }
            if ($name -and $arch) { [pscustomobject]@{ Name = $name; Architecture = $arch } }
        }
        $operatingSystems = @($operatingSystems | Sort-Object Name, Architecture -Unique)
        if ($operatingSystems.Count -eq 0) { continue }

        foreach ($brand in @($pkg.SupportedSystems.Brand)) {
            if ($null -eq $brand) { continue }
            $brandName = Get-SDAXmlText $brand.Display
            foreach ($m in @($brand.Model)) {
                if ($null -eq $m) { continue }
                # The resolver matches the name attribute or "<brand> <display>", so either works as Model.
                $name = [string]$m.name
                if ([string]::IsNullOrWhiteSpace($name)) { $name = ('{0} {1}' -f $brandName, (Get-SDAXmlText $m.Display)).Trim() }
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                foreach ($os in $operatingSystems) {
                    New-SDACatalogRow -Model $name -CatalogName $name -SystemIds @([string]$m.systemID) -OSName $os.Name -OSBuild '' `
                        -Architecture $os.Architecture -Version $version -ReleaseDate $pkg.dateTime
                }
            }
        }
    }
}

function Get-SDAHPCatalogRows {
    # HP packs are per Windows build and x64 only (see VendorHP.ps1).
    param ([Parameter(Mandatory)][System.Xml.XmlDocument]$Catalog)

    $index = Get-SDAHPSoftPaqIndex -Catalog $Catalog
    foreach ($p in @($Catalog.NewDataSet.HPClientDriverPackCatalog.ProductOSDriverPackList.ProductOSDriverPack)) {
        if ($null -eq $p) { continue }
        # e.g. "Windows 11 64-bit, 24H2"
        $osText = Get-SDAXmlText $p.OSName
        if ($osText -notmatch '^(Windows 1[01])\b.*64-bit.*,\s*(\S+)\s*$') { continue }
        $osName = $Matches[1]
        $build = $Matches[2].ToUpperInvariant()

        $name = Get-SDAXmlText $p.SystemName
        $spId = Get-SDAXmlText $p.SoftPaqId
        if (-not $name -or -not $spId) { continue }
        $sp = $index[$spId.ToUpperInvariant()]
        if ($null -eq $sp) { continue }

        $version = Get-SDAXmlText $sp.Version
        if (-not $version) { $version = $spId }
        $ids = @((Get-SDAXmlText $p.SystemId) -split '[,;\s]+' | Where-Object { $_ })
        New-SDACatalogRow -Model $name -CatalogName $name -SystemIds $ids -OSName $osName -OSBuild $build -Architecture 'x64' `
            -Version ('{0} ({1})' -f $version, $spId) -ReleaseDate (Get-SDAXmlText $sp.DateReleased)
    }
}

function Get-SDALenovoCatalogRows {
    # Lenovo packs are per Windows build and x64 only; the pack date is the version (see VendorLenovo.ps1).
    param ([Parameter(Mandatory)][System.Xml.XmlDocument]$Catalog)

    $models = @($Catalog.ModelList.Model | Where-Object { $null -ne $_ })

    # Catalog names look like "ThinkPad X1 Carbon Gen 11 Type 21HM 21HN" (older entries put the types in
    # brackets). Use the name without the type list, unless another catalog entry shares it (Intel and
    # AMD variants often do). Then keep the full name, so the configured name only matches one entry.
    $typeSuffix = '(?i)\s*(\(\s*(Machine\s+)?Types?\b[^)]*\)|\s(Machine\s+)?Types?(\s*[,/]?\s*[0-9A-Z]{4})+)\s*$'
    $shortNames = @{}
    foreach ($m in $models) {
        $short = (([string]$m.name -replace '\s+', ' ') -replace $typeSuffix, '').Trim().ToLowerInvariant()
        $shortNames[$short] = 1 + [int]$shortNames[$short]
    }

    foreach ($m in $models) {
        $catalogName = ([string]$m.name -replace '\s+', ' ').Trim()
        if (-not $catalogName) { continue }
        $short = ($catalogName -replace $typeSuffix, '').Trim()
        $name = if ($short -and $shortNames[$short.ToLowerInvariant()] -eq 1) { $short } else { $catalogName }
        $types = @(@($m.Types.Type) | ForEach-Object { Get-SDAXmlText $_ } | Where-Object { $_ })

        foreach ($s in @($m.SCCM)) {
            if ($null -eq $s) { continue }
            $osName = switch ([string]$s.os) { 'win11' { 'Windows 11' } 'win10' { 'Windows 10' } default { $null } }
            $build = ([string]$s.version).Trim().ToUpperInvariant()
            if (-not $osName -or -not $build -or -not (Get-SDAXmlText $s)) { continue }
            New-SDACatalogRow -Model $name -CatalogName $catalogName -SystemIds $types -OSName $osName -OSBuild $build -Architecture 'x64' `
                -Version ([string]$s.date) -ReleaseDate ([string]$s.date)
        }
    }
}

#endregion Catalog browsing
