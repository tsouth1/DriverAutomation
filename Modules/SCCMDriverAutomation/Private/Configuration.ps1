#region Configuration
<#
    Configuration is a single JSON file (see Config\DriverAutomation.json). It is converted to nested
    hashtables, merged over the defaults below, validated, and the Models section is expanded into
    one "target" per model + operating system + architecture. A target is the unit that owns a
    ConfigMgr package (per ring), a version history and a set of staged content folders.
#>

function ConvertTo-SDAHashtable {
    <#
    .SYNOPSIS
        Recursively converts ConvertFrom-Json output (PSCustomObject) into ordered hashtables.
        Windows PowerShell 5.1 has no ConvertFrom-Json -AsHashtable.
    #>
    [CmdletBinding()]
    param ([Parameter(ValueFromPipeline)]$InputObject)

    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $hash = [ordered]@{}
            foreach ($key in $InputObject.Keys) { $hash[$key] = ConvertTo-SDAHashtable -InputObject $InputObject[$key] }
            return $hash
        }
        if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
            $hash = [ordered]@{}
            foreach ($prop in $InputObject.PSObject.Properties) { $hash[$prop.Name] = ConvertTo-SDAHashtable -InputObject $prop.Value }
            return $hash
        }
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            # The leading comma stops PowerShell unrolling single-element arrays on return.
            return , @(foreach ($item in $InputObject) { ConvertTo-SDAHashtable -InputObject $item })
        }
        return $InputObject
    }
}

function Merge-SDAHashtable {
    <#
    .SYNOPSIS
        Deep-merges Override over Default. Arrays and scalars in Override replace Default values.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$Default,
        [System.Collections.IDictionary]$Override
    )

    $result = [ordered]@{}
    foreach ($key in $Default.Keys) { $result[$key] = $Default[$key] }
    if ($null -eq $Override) { return $result }

    foreach ($key in $Override.Keys) {
        if ($result.Contains($key) -and $result[$key] -is [System.Collections.IDictionary] -and $Override[$key] -is [System.Collections.IDictionary]) {
            $result[$key] = Merge-SDAHashtable -Default $result[$key] -Override $Override[$key]
        } else {
            $result[$key] = $Override[$key]
        }
    }
    return $result
}

function Get-SDADefaultConfig {
    <#
    .SYNOPSIS
        Built-in defaults. Anything in the JSON file overrides these.
    #>
    [CmdletBinding()]
    param ()

    return [ordered]@{
        General   = [ordered]@{
            DataRoot           = 'D:\SCCMDriverAutomation'   # logs, state and working folders
            LogMaxSizeMB       = 10
            LogHistory         = 10
            MinimumFreeSpaceGB = 40                            # checked on the working and package drives
            KeepDownloads      = $false                        # keep vendor payloads after staging
            LockTimeoutMinutes = 30                            # wait for another run / admin action to finish
        }
        ConfigMgr = [ordered]@{
            SiteCode                     = ''                  # blank = auto-detect from the local SMS Provider
            ProviderMachine              = ''                  # blank = auto-detect
            CimProtocol                  = 'Dcom'              # Dcom (no WinRM dependency) or Wsman
            PackageSourceLocalRoot       = ''                  # e.g. E:\Sources\Drivers (local path on this server); blank = share is on another server
            PackageSourceUncRoot         = ''                  # e.g. \\CM01.corp.local\Sources$\Drivers (same folder, UNC)
            ContentFormat                = 'WIM'               # WIM (DISM-captured, compact) or Raw (extracted folders)
            ProductionNamePrefix         = 'Drivers'
            PilotNamePrefix              = 'Drivers Pilot'
            ConsoleFolder                = 'Driver Packages'   # created as <ConsoleFolder>\<Vendor>
            DistributionPointGroups      = @()
            DistributionPoints           = @()
            PilotDistributionPointGroups = @()                 # Pilot packages only; both Pilot lists empty = same as above
            PilotDistributionPoints      = @()
            DistributionPriority         = 'Normal'            # High | Normal | Low
            EnableBinaryDeltaReplication = $true
            AdoptExistingPackages        = $false              # adopt a single pre-existing package with the same name
        }
        Versioning = [ordered]@{
            RetainVersions = 3                                 # staged versions kept on disk per model/OS (min 2)
            PilotRing      = [ordered]@{
                Enabled                    = $false
                AutoPromoteAfterDays       = 0                 # 0 = manual promotion only
                SeedProductionOnFirstImport = $true            # first ever version goes to both rings
            }
        }
        Network   = [ordered]@{
            ProxyMode           = 'WinHttp'                    # None | WinHttp | System | Manual
            ProxyUrl            = ''                           # Manual mode, e.g. http://proxy.corp.local:8080
            ProxyBypass         = @()                          # Manual mode bypass list (regex-free host patterns, * allowed)
            ProxyAuthentication = 'DefaultCredentials'         # None | DefaultCredentials (computer account) | StoredCredential
            TimeoutSeconds      = 120                          # connect / headers timeout
            StallTimeoutSeconds = 120                          # abort if no bytes arrive for this long
            RetryCount          = 4
            RetryDelaySeconds   = 20
            UserAgent           = 'SCCMDriverAutomation/1.0 (+Configuration Manager driver automation)'
            AllowedDomains      = @('dell.com', 'hp.com', 'lenovo.com')
        }
        Security  = [ordered]@{
            VerifyCatalogSignature = $true                    # Dell / HP catalog CABs must carry a trusted signature
            TrustedPublishers      = @('Dell Inc*', 'Dell Technologies*', 'HP Inc*', 'Hewlett-Packard*', 'Hewlett Packard*', 'Lenovo*')
            DefenderScan           = $true                     # on-demand Microsoft Defender scan of payload + extracted content
        }
        Catalogs  = [ordered]@{
            Dell   = 'https://downloads.dell.com/catalog/DriverPackCatalog.cab'
            HP     = 'https://hpia.hpcloud.hp.com/downloads/driverpackcatalog/HPClientDriverPackCatalog.cab'
            Lenovo = 'https://download.lenovo.com/cdrt/td/catalogv2.xml'
        }
        Extraction = [ordered]@{
            TimeoutMinutes = 60
        }
        Models    = @()
    }
}

function Import-SDAConfig {
    <#
    .SYNOPSIS
        Loads, merges and validates the JSON configuration. Throws on invalid configuration.
    .OUTPUTS
        Ordered hashtable with an extra 'Targets' key and derived 'Paths' key.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path"
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Configuration file '$Path' is not valid JSON: $($_.Exception.Message)"
    }

    $config = Merge-SDAHashtable -Default (Get-SDADefaultConfig) -Override (ConvertTo-SDAHashtable -InputObject $raw)

    # Derived working locations under DataRoot.
    $dataRoot = $config.General.DataRoot
    $config['Paths'] = [ordered]@{
        DataRoot  = $dataRoot
        Logs      = Join-Path $dataRoot 'Logs'
        Reports   = Join-Path $dataRoot 'Logs\Reports'
        State     = Join-Path $dataRoot 'State'
        Catalogs  = Join-Path $dataRoot 'Work\Catalogs'
        Downloads = Join-Path $dataRoot 'Work\Downloads'
        Extract   = Join-Path $dataRoot 'Work\X'      # deliberately short to stay clear of MAX_PATH
        Secrets   = Join-Path $dataRoot 'Secrets'
    }

    Test-SDAConfig -Config $config

    # Remote package source: with no local path (or the UNC path itself), content is written straight to
    # the share. This lets the tool run on a server other than the one hosting the package sources.
    $cm = $config.ConfigMgr
    $config.Paths['PackageSourceRemote'] = [string]::IsNullOrWhiteSpace($cm.PackageSourceLocalRoot) -or ([string]$cm.PackageSourceLocalRoot).StartsWith('\\')
    if ($config.Paths.PackageSourceRemote) { $cm.PackageSourceLocalRoot = $cm.PackageSourceUncRoot }

    $config['Targets'] = @(Get-SDATargets -Config $config)
    return $config
}

function Test-SDAConfig {
    <#
    .SYNOPSIS
        Validates configuration values and throws a single aggregated error describing every problem.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    $problems = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace($Config.General.DataRoot)) { $problems.Add('General.DataRoot is required.') }

    $cm = $Config.ConfigMgr
    if ([string]::IsNullOrWhiteSpace($cm.PackageSourceUncRoot) -or $cm.PackageSourceUncRoot -notmatch '^\\\\[^\\]+\\[^\\]+') {
        $problems.Add('ConfigMgr.PackageSourceUncRoot must be a UNC path (\\server\share\...).')
    }
    $localRoot = [string]$cm.PackageSourceLocalRoot
    if ($localRoot.StartsWith('\\') -and $localRoot.TrimEnd('\') -ne ([string]$cm.PackageSourceUncRoot).TrimEnd('\')) {
        $problems.Add('ConfigMgr.PackageSourceLocalRoot must be a local path on this server, or blank when the share is on another server.')
    }
    if ($cm.ContentFormat -notin @('WIM', 'Raw')) { $problems.Add("ConfigMgr.ContentFormat must be 'WIM' or 'Raw'.") }
    if ($cm.CimProtocol -notin @('Dcom', 'Wsman')) { $problems.Add("ConfigMgr.CimProtocol must be 'Dcom' or 'Wsman'.") }
    if ($cm.DistributionPriority -notin @('High', 'Normal', 'Low')) { $problems.Add("ConfigMgr.DistributionPriority must be High, Normal or Low.") }
    if ($cm.ProductionNamePrefix -eq $cm.PilotNamePrefix) { $problems.Add('ConfigMgr.ProductionNamePrefix and PilotNamePrefix must differ.') }
    if ($cm.PilotNamePrefix -notmatch 'Pilot') {
        $problems.Add("ConfigMgr.PilotNamePrefix should contain the word 'Pilot' so Modern Driver Management style task sequence scripts exclude it in Production mode.")
    }

    if ([int]$Config.Versioning.RetainVersions -lt 2) { $problems.Add('Versioning.RetainVersions must be at least 2 so a rollback target always exists.') }

    $net = $Config.Network
    if ($net.ProxyMode -notin @('None', 'WinHttp', 'System', 'Manual')) { $problems.Add('Network.ProxyMode must be None, WinHttp, System or Manual.') }
    if ($net.ProxyMode -eq 'Manual' -and [string]::IsNullOrWhiteSpace($net.ProxyUrl)) { $problems.Add('Network.ProxyUrl is required when ProxyMode is Manual.') }
    if ($net.ProxyAuthentication -notin @('None', 'DefaultCredentials', 'StoredCredential')) { $problems.Add('Network.ProxyAuthentication must be None, DefaultCredentials or StoredCredential.') }
    if (@($net.AllowedDomains).Count -eq 0) { $problems.Add('Network.AllowedDomains must list at least one domain.') }

    foreach ($vendor in @('Dell', 'HP', 'Lenovo')) {
        $url = $Config.Catalogs[$vendor]
        if ($url -and $url -notmatch '^https://') { $problems.Add("Catalogs.$vendor must be an https:// URL.") }
    }

    $models = @($Config.Models)
    if ($models.Count -eq 0) { $problems.Add('Models must contain at least one entry.') }
    $index = 0
    foreach ($m in $models) {
        $index++
        $label = "Models[$index]"
        if ($m.Vendor -notin @('Dell', 'HP', 'Lenovo')) { $problems.Add("$label.Vendor must be Dell, HP or Lenovo (was '$($m.Vendor)').") }
        if ([string]::IsNullOrWhiteSpace($m.Model)) { $problems.Add("$label.Model is required.") }
        if (@($m.OperatingSystems).Count -eq 0) { $problems.Add("$label.OperatingSystems must contain at least one entry.") }
        foreach ($os in @($m.OperatingSystems)) {
            if ($os.Name -notin @('Windows 10', 'Windows 11')) { $problems.Add("$label OperatingSystems.Name must be 'Windows 10' or 'Windows 11' (was '$($os.Name)').") }
            if ($m.Vendor -in @('HP', 'Lenovo') -and [string]::IsNullOrWhiteSpace($os.Build)) {
                $problems.Add("$label ($($m.Vendor)) requires OperatingSystems.Build (e.g. '24H2') because $($m.Vendor) publishes packs per Windows build.")
            }
            if ($os.Architecture -and $os.Architecture -notin @('x64', 'Arm64')) { $problems.Add("$label OperatingSystems.Architecture must be x64 or Arm64.") }
        }
    }

    if ($problems.Count -gt 0) {
        throw ("Configuration is invalid:`n - " + ($problems -join "`n - "))
    }
}

function Get-SDATargets {
    <#
    .SYNOPSIS
        Expands Models x OperatingSystems into individual targets.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    foreach ($m in @($Config.Models)) {
        $enabled = if ($m.Contains('Enabled')) { [bool]$m.Enabled } else { $true }
        foreach ($os in @($m.OperatingSystems)) {
            $arch  = if ($os.Architecture) { [string]$os.Architecture } else { 'x64' }
            $build = if ($os.Build) { ([string]$os.Build).ToUpperInvariant() } else { '' }
            $target = [pscustomobject]@{
                Vendor       = [string]$m.Vendor
                Model        = ([string]$m.Model).Trim()
                SystemIds    = @(@($m.SystemIds) | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() })
                OSName       = [string]$os.Name
                OSBuild      = $build
                Architecture = $arch
                Enabled      = $enabled
                Key          = $null
                DisplayName  = $null
            }
            $target.Key         = Get-SDATargetKey -Target $target
            $target.DisplayName = ("{0} {1} - {2}{3} {4}" -f $target.Vendor, $target.Model, $target.OSName, $(if ($build) { " $build" } else { '' }), $arch)
            $target
        }
    }
}

function Get-SDATargetKey {
    <#
    .SYNOPSIS
        Stable, filesystem-safe identifier for a target, used to name its state file.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)]$Target)

    $parts = @($Target.Vendor, $Target.Model, $Target.OSName, $Target.OSBuild, $Target.Architecture) | Where-Object { $_ }
    $key = ($parts -join '_') -replace '[^A-Za-z0-9\-\.]+', '-'
    return $key.Trim('-').ToLowerInvariant()
}

function ConvertTo-SDASafeName {
    <#
    .SYNOPSIS
        Makes a string safe for use as a single folder name.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $invalid = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $safe = $Value -replace "[$([regex]::Escape($invalid))]", '_'
    # Windows silently strips trailing dots/spaces from folder names, which would desync stored paths.
    $safe = $safe.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = '_' }
    return $safe
}

#endregion Configuration
