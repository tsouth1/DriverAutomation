#region Catalog (shared)
<#
    Common catalog plumbing. Each vendor file implements Find-SDA<Vendor>DriverPack which returns a
    normalised catalog entry (New-SDACatalogEntry) for a target, or $null when the vendor does not
    publish a pack for that model / OS.
#>

$script:SDACatalogCache = @{}

function New-SDACatalogEntry {
    <#
    .SYNOPSIS
        Normalised description of one vendor driver pack release.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Vendor,
        [Parameter(Mandatory)][string]$CatalogModelName,
        [string[]]$SystemIds,
        [Parameter(Mandatory)][string]$VendorVersion,
        [Parameter(Mandatory)][string]$VersionId,
        $ReleaseDate,
        [Parameter(Mandatory)][string]$Url,
        [string]$FileName,
        [string]$Hash,
        [int64]$SizeBytes = 0,
        [string]$Details
    )

    if ([string]::IsNullOrWhiteSpace($FileName)) {
        $FileName = ([Uri]$Url).Segments[-1]
    }
    $parsedDate = ConvertTo-SDADate $ReleaseDate
    [pscustomobject]@{
        Vendor           = $Vendor
        CatalogModelName = $CatalogModelName
        SystemIds        = @($SystemIds | Where-Object { $_ } | ForEach-Object { $_.Trim().ToUpperInvariant() } | Select-Object -Unique)
        VendorVersion    = $VendorVersion
        VersionId        = (ConvertTo-SDASafeName -Value ($VersionId -replace '\s+', '-'))
        ReleaseDate      = $(if ($parsedDate) { $parsedDate.ToString('yyyy-MM-dd') } else { $null })
        Url              = $Url
        FileName         = (ConvertTo-SDASafeName -Value $FileName)
        Hash             = $(if ($Hash) { $Hash.Trim() } else { $null })
        SizeBytes        = $SizeBytes
        Details          = $Details
    }
}

function Get-SDAXmlText {
    <#
    .SYNOPSIS
        Returns the text of an XML node / attribute value regardless of CDATA or element/attribute form.
    #>
    [CmdletBinding()]
    param ($Node)

    if ($null -eq $Node) { return $null }
    if ($Node -is [string]) { return $Node.Trim() }
    if ($Node -is [System.Xml.XmlNode]) { return $Node.InnerText.Trim() }
    if ($Node -is [array]) { return (Get-SDAXmlText -Node $Node[0]) }
    return ([string]$Node).Trim()
}

function Get-SDACatalogXml {
    <#
    .SYNOPSIS
        Downloads (once per run), verifies and parses a vendor catalog.
    .DESCRIPTION
        CAB catalogs (Dell, HP) are Authenticode-verified against the trusted publisher list before they
        are expanded, so the hashes they publish can be trusted to verify the driver packs themselves.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][ValidateSet('Dell', 'HP', 'Lenovo')][string]$Vendor,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )

    if ($script:SDACatalogCache.ContainsKey($Vendor)) { return $script:SDACatalogCache[$Vendor] }

    $url = [string]$Config.Catalogs[$Vendor]
    $dir = Join-Path $Config.Paths.Catalogs $Vendor
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -Path $dir -ItemType Directory -Force | Out-Null

    $fileName = ([Uri]$url).Segments[-1]
    $file = Join-Path $dir $fileName
    Write-SDALog "[$Vendor] Downloading catalog $url" -Component $Vendor
    Invoke-SDADownload -Url $url -DestinationPath $file | Out-Null

    $xmlPath = $file
    if ($file -match '\.cab$') {
        if ($Config.Security.VerifyCatalogSignature) {
            $sig = Test-SDAAuthenticode -Path $file -TrustedPublishers @($Config.Security.TrustedPublishers)
            if ($sig.Status -ne 'Valid') {
                throw "[$Vendor] Catalog signature check failed ($($sig.Status): $($sig.Message)). Set Security.VerifyCatalogSignature to false only if the vendor has stopped signing the catalog."
            }
            Write-SDALog "[$Vendor] Catalog signature verified ($($sig.Signer))." -Component $Vendor
        }
        # expand.exe refuses to expand into the folder holding the CAB ("cannot expand a file onto
        # itself") and still returns 0, so expand into a sub-folder and verify the output instead.
        $expandDir = Join-Path $dir 'Expanded'
        New-Item -Path $expandDir -ItemType Directory -Force | Out-Null
        $expand = Join-Path $env:SystemRoot 'System32\expand.exe'
        $exit = Invoke-SDAProcess -FilePath $expand -Arguments ('"{0}" -F:* "{1}"' -f $file, $expandDir) -TimeoutMinutes 10
        if ($exit -ne 0) { throw "[$Vendor] expand.exe failed with exit code $exit for $file" }
        # For single-file CABs expand.exe names the output after the CAB rather than the stored
        # file name, so take the largest extracted file whatever its extension; the XML load below
        # validates that it really is the catalog.
        $xmlPath = Get-ChildItem -LiteralPath $expandDir -File -Recurse | Sort-Object -Property Length -Descending | Select-Object -First 1 -ExpandProperty FullName
        if (-not $xmlPath) { throw "[$Vendor] Nothing was extracted from $file" }
    }

    # XmlDocument.Load with DTD processing disabled (catalogs never need it; avoids XXE-style surprises).
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($xmlPath, $settings)
    try {
        $xml = New-Object System.Xml.XmlDocument
        $xml.XmlResolver = $null
        $xml.Load($reader)
    } finally {
        $reader.Dispose()
    }

    Write-SDALog ("[{0}] Catalog loaded ({1:N1} MB XML)." -f $Vendor, ((Get-Item -LiteralPath $xmlPath).Length / 1MB)) -Component $Vendor
    $script:SDACatalogCache[$Vendor] = $xml
    return $xml
}

function Clear-SDACatalogCache {
    [CmdletBinding()]
    param ()
    $script:SDACatalogCache = @{}
}

function Find-SDACatalogEntry {
    <#
    .SYNOPSIS
        Dispatches to the vendor-specific resolver.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )

    $xml = Get-SDACatalogXml -Vendor $Target.Vendor -Config $Config
    switch ($Target.Vendor) {
        'Dell'   { return (Find-SDADellDriverPack   -Catalog $xml -Target $Target) }
        'HP'     { return (Find-SDAHPDriverPack     -Catalog $xml -Target $Target) }
        'Lenovo' { return (Find-SDALenovoDriverPack -Catalog $xml -Target $Target) }
    }
}

function Test-SDAModelNameMatch {
    <#
    .SYNOPSIS
        Case/whitespace-insensitive model name comparison, tolerating a leading vendor name.
    #>
    [CmdletBinding()]
    param ([string]$CatalogName, [string]$ConfiguredName, [string]$Vendor)

    if ([string]::IsNullOrWhiteSpace($CatalogName) -or [string]::IsNullOrWhiteSpace($ConfiguredName)) { return $false }
    $normalise = {
        param ($s)
        $s = ($s -replace '\s+', ' ').Trim()
        $s = $s -replace "^(?i)$([regex]::Escape($Vendor))\s+", ''
        $s.ToLowerInvariant()
    }
    return ((& $normalise $CatalogName) -eq (& $normalise $ConfiguredName))
}

function Select-SDAMatchedCandidates {
    <#
    .SYNOPSIS
        Applies the SystemId-vs-name precedence rules shared by all vendors.
    .DESCRIPTION
        SystemIds are the most precise key, so SystemId matches win over name-only matches. But a wrong
        SystemId in the configuration would then silently deploy another model's drivers, so when the
        SystemId points at one catalog model while the configured name points at a different one, the
        target fails with a configuration error instead of guessing.
        Candidates must expose IdMatch, NameMatch and Label properties.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates,
        [Parameter(Mandatory)]$Target
    )

    $byId = @($Candidates | Where-Object { $_.IdMatch })
    if ($byId.Count -eq 0) { return $Candidates }

    if (@($byId | Where-Object { $_.NameMatch }).Count -eq 0) {
        $nameOnly = @($Candidates | Where-Object { $_.NameMatch -and -not $_.IdMatch })
        $idLabels = (@($byId | ForEach-Object { $_.Label } | Select-Object -Unique) -join "', '")
        if ($nameOnly.Count -gt 0) {
            $nameLabels = (@($nameOnly | ForEach-Object { $_.Label } | Select-Object -Unique) -join "', '")
            throw ("[{0}] Configuration conflict for '{1}': SystemIds ({2}) identify '{3}' but the model name identifies '{4}'. Correct SystemIds or Model in the configuration." -f `
                $Target.Vendor, $Target.Model, ($Target.SystemIds -join ','), $idLabels, $nameLabels)
        }
        Write-SDALog ("[{0}] '{1}' matched by SystemId only (catalog name '{2}'). Verify the configuration if this is unexpected." -f $Target.Vendor, $Target.Model, $idLabels) -Severity Warning -Component $Target.Vendor
    }
    return $byId
}

#endregion Catalog (shared)
