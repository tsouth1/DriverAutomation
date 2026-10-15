#region ConfigMgr
<#
    All ConfigMgr operations go straight to the SMS Provider over CIM (DCOM by default). This avoids the
    ConfigurationManager PowerShell module, which needs the console installed, a per-user first-run
    initialisation and a CMSite PSDrive - none of which suit a SYSTEM scheduled task.

    Identity: running as SYSTEM on the site server, the provider sees the computer account
    (DOMAIN\SITESERVER$). That account must be a ConfigMgr administrative user (normally via an AD
    group) with rights to create/modify packages, move folder items and distribute content. See REQUIREMENTS.md.

    Package model: one standard package (SMS_Package) per target and ring:
        "<Prefix> - <Vendor> <Model> - <OS> [<Build>] <Arch>"
        Description "Models included: <SystemIds>"     (Modern Driver Management compatible)
    The PackageID never changes. A new version or a rollback re-points PkgSourcePath to the immutable
    version folder and runs RefreshPkgSource, so task sequences that reference the package directly and
    dynamic driver-selection scripts both keep working without edits.
#>

function ConvertTo-SDAWqlString {
    <#
    .SYNOPSIS
        Escapes a value for use inside a single-quoted WQL string literal.
    #>
    [CmdletBinding()]
    param ([AllowEmptyString()][string]$Value)
    return ($Value -replace '\\', '\\' -replace "'", "\'")
}

function Connect-SDASite {
    <#
    .SYNOPSIS
        Discovers the site code / SMS Provider (unless configured) and opens a CIM session.
    .OUTPUTS
        Context object: SiteCode, Provider, Namespace, Session.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    $cm = $Config.ConfigMgr
    $option = New-CimSessionOption -Protocol $cm.CimProtocol
    $siteCode = [string]$cm.SiteCode
    $provider = [string]$cm.ProviderMachine

    if ([string]::IsNullOrWhiteSpace($siteCode) -or [string]::IsNullOrWhiteSpace($provider)) {
        $local = $null
        try {
            $local = New-CimSession -ComputerName $env:COMPUTERNAME -SessionOption $option -ErrorAction Stop
            $location = Get-CimInstance -CimSession $local -Namespace 'root\SMS' -ClassName 'SMS_ProviderLocation' -ErrorAction Stop |
                Where-Object { $_.ProviderForLocalSite } | Select-Object -First 1
        } catch {
            throw "Unable to auto-detect the site from root\SMS on $env:COMPUTERNAME ($($_.Exception.Message)). Run on the site server or set ConfigMgr.SiteCode and ConfigMgr.ProviderMachine."
        } finally {
            if ($local) { Remove-CimSession -CimSession $local -ErrorAction SilentlyContinue }
        }
        if (-not $location) { throw "No SMS Provider for the local site was found in root\SMS on $env:COMPUTERNAME." }
        if ([string]::IsNullOrWhiteSpace($siteCode)) { $siteCode = $location.SiteCode }
        if ([string]::IsNullOrWhiteSpace($provider)) { $provider = $location.Machine }
    }

    $namespace = "root\SMS\site_$siteCode"
    try {
        $session = New-CimSession -ComputerName $provider -SessionOption $option -ErrorAction Stop
    } catch {
        throw "Unable to open a $($cm.CimProtocol) CIM session to SMS Provider '$provider': $($_.Exception.Message)"
    }

    try {
        $site = Get-CimInstance -CimSession $session -Namespace $namespace -Query "SELECT SiteCode, Version FROM SMS_Site WHERE SiteCode = '$(ConvertTo-SDAWqlString $siteCode)'" -ErrorAction Stop
    } catch {
        Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue
        $who = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        if ($_.Exception.Message -match 'Access is denied|0x80041003|0x80070005') {
            throw "Access denied to SMS Provider namespace $namespace on '$provider' for '$who'. Add the site server computer account (via an AD group) as a ConfigMgr administrative user - see REQUIREMENTS.md 'ConfigMgr permissions'."
        }
        throw "Unable to query $namespace on '$provider' as '$who': $($_.Exception.Message)"
    }

    Write-SDALog "Connected to site $siteCode (version $($site.Version)) via SMS Provider $provider [$($cm.CimProtocol)]." -Component 'ConfigMgr'
    return [pscustomobject]@{
        SiteCode  = $siteCode
        Provider  = $provider
        Namespace = $namespace
        Session   = $session
    }
}

function Disconnect-SDASite {
    [CmdletBinding()]
    param ($Context)
    if ($Context -and $Context.Session) { Remove-CimSession -CimSession $Context.Session -ErrorAction SilentlyContinue }
}

function Invoke-SDAWql {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Query
    )
    return @(Get-CimInstance -CimSession $Context.Session -Namespace $Context.Namespace -Query $Query -ErrorAction Stop)
}

function Get-SDAPackageName {
    <#
    .SYNOPSIS
        Package naming convention (compatible with DAT / Modern Driver Management matching).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][ValidateSet('Production', 'Pilot')][string]$Ring
    )
    $prefix = if ($Ring -eq 'Pilot') { $Config.ConfigMgr.PilotNamePrefix } else { $Config.ConfigMgr.ProductionNamePrefix }
    $os = if ($Target.OSBuild) { "$($Target.OSName) $($Target.OSBuild)" } else { $Target.OSName }
    return ("{0} - {1} {2} - {3} {4}" -f $prefix, $Target.Vendor, $Target.Model, $os, $Target.Architecture)
}

function Get-SDAPackageById {
    [CmdletBinding()]
    param ([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$PackageID)
    return (Invoke-SDAWql -Context $Context -Query "SELECT * FROM SMS_Package WHERE PackageID = '$(ConvertTo-SDAWqlString $PackageID)'" | Select-Object -First 1)
}

function Get-SDAPackagesByName {
    [CmdletBinding()]
    param ([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    return (Invoke-SDAWql -Context $Context -Query "SELECT * FROM SMS_Package WHERE Name = '$(ConvertTo-SDAWqlString $Name)'")
}

function Get-SDAPackageDescription {
    [CmdletBinding()]
    param ([Parameter(Mandatory)]$Target, [string[]]$SystemIds)
    $ids = @($SystemIds | Where-Object { $_ } | Select-Object -Unique)
    if ($ids.Count -eq 0) { $ids = @($Target.SystemIds) }
    if ($ids.Count -eq 0) { return "Models included: $($Target.Model)" }
    return "Models included: $($ids -join ',')"
}

function Get-SDAConsoleFolderId {
    <#
    .SYNOPSIS
        Returns the ContainerNodeID of a package console folder path ("A\B\C"), creating missing levels.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$FolderPath
    )

    $parentId = [uint32]0
    foreach ($segment in ($FolderPath -split '\\' | Where-Object { $_ })) {
        $node = Invoke-SDAWql -Context $Context -Query ("SELECT * FROM SMS_ObjectContainerNode WHERE ObjectType = 2 AND ParentContainerNodeID = {0} AND Name = '{1}'" -f $parentId, (ConvertTo-SDAWqlString $segment)) | Select-Object -First 1
        if (-not $node) {
            $node = New-CimInstance -CimSession $Context.Session -Namespace $Context.Namespace -ClassName 'SMS_ObjectContainerNode' -Property @{
                Name                  = $segment
                ObjectType            = [uint32]2
                ParentContainerNodeID = $parentId
            } -ErrorAction Stop
            Write-SDALog "Created console folder '$segment' (parent $parentId)." -Component 'ConfigMgr'
            if (-not $node.ContainerNodeID) {
                $node = Invoke-SDAWql -Context $Context -Query ("SELECT * FROM SMS_ObjectContainerNode WHERE ObjectType = 2 AND ParentContainerNodeID = {0} AND Name = '{1}'" -f $parentId, (ConvertTo-SDAWqlString $segment)) | Select-Object -First 1
            }
        }
        $parentId = [uint32]$node.ContainerNodeID
    }
    return $parentId
}

function Move-SDAPackageToFolder {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$PackageID,
        [Parameter(Mandatory)][string]$FolderPath
    )

    try {
        $targetId = Get-SDAConsoleFolderId -Context $Context -FolderPath $FolderPath
        $current = Invoke-SDAWql -Context $Context -Query "SELECT * FROM SMS_ObjectContainerItem WHERE ObjectType = 2 AND InstanceKey = '$(ConvertTo-SDAWqlString $PackageID)'" | Select-Object -First 1
        $sourceId = if ($current) { [uint32]$current.ContainerNodeID } else { [uint32]0 }
        if ($sourceId -eq $targetId) { return }

        $result = Invoke-CimMethod -CimSession $Context.Session -Namespace $Context.Namespace -ClassName 'SMS_ObjectContainerItem' -MethodName 'MoveMembers' -Arguments @{
            InstanceKeys          = [string[]]@($PackageID)
            ContainerNodeID       = $sourceId
            TargetContainerNodeID = $targetId
            ObjectType            = [uint32]2
        } -ErrorAction Stop
        if ($result.ReturnValue -ne 0) { throw "MoveMembers returned $($result.ReturnValue)" }
        Write-SDALog "Moved $PackageID to console folder '$FolderPath'." -Component 'ConfigMgr'
    } catch {
        # Folder placement is cosmetic - never fail a deployment because of it.
        Write-SDALog "Could not move $PackageID to console folder '$FolderPath': $($_.Exception.Message)" -Severity Warning -Component 'ConfigMgr'
    }
}

function Get-SDADistributionTargets {
    <#
    .SYNOPSIS
        DP groups and individual DPs for a ring. Pilot uses its own lists when either is set, otherwise
        the Production lists.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [ValidateSet('Production', 'Pilot')][string]$Ring = 'Production'
    )

    $cm = $Config.ConfigMgr
    $pilotGroups = @($cm.PilotDistributionPointGroups | Where-Object { $_ })
    $pilotPoints = @($cm.PilotDistributionPoints | Where-Object { $_ })
    if ($Ring -eq 'Pilot' -and ($pilotGroups.Count -gt 0 -or $pilotPoints.Count -gt 0)) {
        return [pscustomobject]@{ Groups = $pilotGroups; Points = $pilotPoints }
    }
    return [pscustomobject]@{
        Groups = @($cm.DistributionPointGroups | Where-Object { $_ })
        Points = @($cm.DistributionPoints | Where-Object { $_ })
    }
}

function Start-SDAContentDistribution {
    <#
    .SYNOPSIS
        Targets a newly created package to the ring's DP groups and individual DPs.
    .OUTPUTS
        Number of distribution targets that failed.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$PackageID,
        [ValidateSet('Production', 'Pilot')][string]$Ring = 'Production'
    )

    $targets = Get-SDADistributionTargets -Config $Config -Ring $Ring
    $failures = 0
    foreach ($groupName in $targets.Groups) {
        try {
            $group = Invoke-SDAWql -Context $Context -Query "SELECT * FROM SMS_DistributionPointGroup WHERE Name = '$(ConvertTo-SDAWqlString $groupName)'" | Select-Object -First 1
            if (-not $group) { throw 'group not found' }
            $r = Invoke-CimMethod -InputObject $group -MethodName 'AddPackages' -Arguments @{ PackageIDs = [string[]]@($PackageID) } -ErrorAction Stop
            if ($r.ReturnValue -ne 0) { throw "AddPackages returned $($r.ReturnValue)" }
            Write-SDALog "Distributed $PackageID to DP group '$groupName'." -Component 'ConfigMgr'
        } catch {
            $failures++
            Write-SDALog "Failed to distribute $PackageID to DP group '$groupName': $($_.Exception.Message)" -Severity Warning -Component 'ConfigMgr'
        }
    }

    foreach ($dpName in $targets.Points) {
        try {
            $safe = ConvertTo-SDAWqlString $dpName
            $dp = Invoke-SDAWql -Context $Context -Query "SELECT * FROM SMS_DistributionPointInfo WHERE ServerName = '$safe' OR ServerName LIKE '$safe.%'" | Select-Object -First 1
            if (-not $dp) { throw 'distribution point not found' }
            # A DP owned by a secondary site must carry that site's code (otherwise status 2302).
            $dpSite = if ($dp.SiteCode) { $dp.SiteCode } else { $Context.SiteCode }
            New-CimInstance -CimSession $Context.Session -Namespace $Context.Namespace -ClassName 'SMS_DistributionPoint' -Property @{
                PackageID     = $PackageID
                ServerNALPath = $dp.NALPath
                SiteCode      = $dpSite
            } -ErrorAction Stop | Out-Null
            Write-SDALog "Distributed $PackageID to DP '$($dp.ServerName)'." -Component 'ConfigMgr'
        } catch {
            $failures++
            Write-SDALog "Failed to distribute $PackageID to DP '$dpName': $($_.Exception.Message)" -Severity Warning -Component 'ConfigMgr'
        }
    }
    return $failures
}

function New-SDAPackage {
    <#
    .SYNOPSIS
        Creates the standard package for a target/ring, pointing at an existing version folder, then
        files it in the console folder and distributes it.
    .OUTPUTS
        PackageID.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Description,
        [ValidateSet('Production', 'Pilot')][string]$Ring = 'Production'
    )

    $priority = switch ($Config.ConfigMgr.DistributionPriority) { 'High' { 1 } 'Low' { 3 } default { 2 } }
    $os = if ($Target.OSBuild) { "$($Target.OSName) $($Target.OSBuild)" } else { $Target.OSName }

    $created = New-CimInstance -CimSession $Context.Session -Namespace $Context.Namespace -ClassName 'SMS_Package' -Property @{
        Name          = $Name
        Description   = $Description
        Manufacturer  = $Target.Vendor
        MIFName       = $Target.Model
        MIFVersion    = "$os $($Target.Architecture)"
        Version       = (Limit-SDAString -Value $Version -Length 32)
        PkgSourceFlag = [uint32]2           # STORAGE_DIRECT: use the source path as-is
        PkgSourcePath = $SourcePath
        Priority      = [uint32]$priority
        SourceDate    = (Get-Date)
    } -ErrorAction Stop

    $packageId = $created.PackageID
    if ([string]::IsNullOrEmpty($packageId)) {
        $packageId = (Invoke-SDAWql -Context $Context -Query ("SELECT PackageID FROM SMS_Package WHERE Name = '{0}' AND PkgSourcePath = '{1}'" -f (ConvertTo-SDAWqlString $Name), (ConvertTo-SDAWqlString $SourcePath)) | Select-Object -First 1).PackageID
    }
    if ([string]::IsNullOrEmpty($packageId)) { throw "Package '$Name' was created but its PackageID could not be resolved." }
    Write-SDALog "Created package $packageId '$Name' -> $SourcePath" -Component 'ConfigMgr'

    if ($Config.ConfigMgr.EnableBinaryDeltaReplication) {
        try {
            $pkg = Get-SDAPackageById -Context $Context -PackageID $packageId
            $flags = [uint32]$pkg.PkgFlags -bor [uint32]0x04000000   # USE_BINARY_DELTA_REP
            Set-CimInstance -InputObject $pkg -Property @{ PkgFlags = [uint32]$flags } -ErrorAction Stop
        } catch {
            Write-SDALog "Could not enable binary differential replication on ${packageId}: $($_.Exception.Message)" -Severity Warning -Component 'ConfigMgr'
        }
    }

    Move-SDAPackageToFolder -Context $Context -PackageID $packageId -FolderPath (Join-Path $Config.ConfigMgr.ConsoleFolder $Target.Vendor)
    $failed = Start-SDAContentDistribution -Context $Context -Config $Config -PackageID $packageId -Ring $Ring
    if ($failed -gt 0) { Write-SDALog "$failed distribution target(s) failed for $packageId - distribute manually or fix and re-run." -Severity Warning -Component 'ConfigMgr' }
    return $packageId
}

function Set-SDAPackageSource {
    <#
    .SYNOPSIS
        Re-points an existing package to a version folder and triggers a DP content update.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$PackageID,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Description
    )

    $pkg = Get-SDAPackageById -Context $Context -PackageID $PackageID
    if (-not $pkg) { throw "Package $PackageID no longer exists in ConfigMgr." }

    Set-CimInstance -InputObject $pkg -Property @{
        PkgSourcePath = $SourcePath
        PkgSourceFlag = [uint32]2
        Version       = (Limit-SDAString -Value $Version -Length 32)
        Description   = $Description
        SourceDate    = (Get-Date)
    } -ErrorAction Stop

    $pkg = Get-SDAPackageById -Context $Context -PackageID $PackageID
    $r = Invoke-CimMethod -InputObject $pkg -MethodName 'RefreshPkgSource' -ErrorAction Stop
    if ($r.ReturnValue -ne 0) { throw "RefreshPkgSource on $PackageID returned $($r.ReturnValue)." }
    Write-SDALog "Package $PackageID now points at $SourcePath (version $Version); distribution point update triggered." -Component 'ConfigMgr'
}

function Get-SDADistributionStatus {
    <#
    .SYNOPSIS
        Summarises per-DP state for a package (Installed / InProgress / Failed).
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$PackageID)

    $rows = Invoke-SDAWql -Context $Context -Query "SELECT ServerNALPath, State, SourceVersion FROM SMS_PackageStatusDistPointsSummarizer WHERE PackageID = '$(ConvertTo-SDAWqlString $PackageID)'"
    $installed  = @($rows | Where-Object { $_.State -eq 0 }).Count
    $failed     = @($rows | Where-Object { $_.State -in 3, 6 }).Count
    $inProgress = @($rows | Where-Object { $_.State -in 1, 2, 7, 8 }).Count
    return [pscustomobject]@{
        PackageID  = $PackageID
        Targeted   = @($rows).Count
        Installed  = $installed
        InProgress = $inProgress
        Failed     = $failed
    }
}

function Limit-SDAString {
    param ([string]$Value, [int]$Length)
    if ($null -eq $Value) { return '' }
    if ($Value.Length -le $Length) { return $Value }
    return $Value.Substring(0, $Length)
}

#endregion ConfigMgr
