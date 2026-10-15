#region Session
<#
    Shared start-up for every entry-point script: configuration, folders, logging, prerequisite checks.
#>

function Test-SDAAdministrator {
    [CmdletBinding()]
    param ()
    $principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-SDARun {
    <#
    .SYNOPSIS
        Loads configuration, creates working folders and starts logging.
    .OUTPUTS
        Configuration hashtable.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$LogFileName = 'DriverAutomation.log',
        [string]$Component = 'SCCMDriverAutomation'
    )

    if (-not (Test-SDAAdministrator)) {
        throw 'This script must run elevated (as SYSTEM via the scheduled task, or from an elevated PowerShell session).'
    }

    $config = Import-SDAConfig -Path $ConfigPath
    foreach ($key in @('DataRoot', 'Logs', 'Reports', 'State', 'Catalogs', 'Downloads', 'Extract')) {
        $dir = $config.Paths[$key]
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    }
    Initialize-SDALog -LogDirectory $config.Paths.Logs -FileName $LogFileName -MaxSizeMB ([int]$config.General.LogMaxSizeMB) -History ([int]$config.General.LogHistory) -Component $Component
    return $config
}

function Test-SDAPrerequisites {
    <#
    .SYNOPSIS
        Verifies the local environment. Throws a single aggregated error if anything is wrong.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    $problems = New-Object System.Collections.Generic.List[string]

    if ($PSVersionTable.PSVersion -lt [version]'5.1') { $problems.Add("PowerShell 5.1 or later is required (found $($PSVersionTable.PSVersion)).") }
    foreach ($tool in @('dism.exe', 'expand.exe', 'robocopy.exe', 'taskkill.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\$tool"))) { $problems.Add("$tool not found in System32.") }
    }

    $localRoot = $Config.ConfigMgr.PackageSourceLocalRoot
    $uncRoot = $Config.ConfigMgr.PackageSourceUncRoot
    if ($Config.Paths.PackageSourceRemote) {
        # Content goes straight to the share: prove it is reachable and writable by this account.
        try {
            $share = [System.IO.Path]::GetPathRoot($uncRoot)
            if (-not (Test-Path -LiteralPath $share)) { throw "Share $share does not exist or is not reachable." }
            if (-not (Test-Path -LiteralPath $uncRoot)) {
                New-Item -Path $uncRoot -ItemType Directory -Force | Out-Null
                Write-SDALog "Created package source root $uncRoot."
            }
            $probe = Join-Path $uncRoot ".sda-probe-$([guid]::NewGuid().ToString('N'))"
            Set-Content -LiteralPath $probe -Value $env:COMPUTERNAME -Encoding ASCII
            Remove-Item -LiteralPath $probe -Force
            Write-SDALog "Package source $uncRoot is on another server; content is written to it directly."
        } catch {
            $problems.Add("PackageSourceUncRoot '$uncRoot' is not writable by $(Get-SDAInitiator): $($_.Exception.Message) Grant this computer account Modify on the share and the folder.")
        }
    } else {
        try {
            if (-not (Test-Path -LiteralPath $localRoot)) {
                New-Item -Path $localRoot -ItemType Directory -Force | Out-Null
                Write-SDALog "Created package source root $localRoot."
            }
            # Prove the UNC path really is the local folder: write a probe locally, read it back via UNC.
            $probeName = ".sda-probe-$([guid]::NewGuid().ToString('N'))"
            $probeLocal = Join-Path $localRoot $probeName
            Set-Content -LiteralPath $probeLocal -Value $env:COMPUTERNAME -Encoding ASCII
            try {
                if (-not (Test-Path -LiteralPath (Join-Path $uncRoot $probeName))) {
                    $problems.Add("PackageSourceUncRoot '$uncRoot' does not resolve to PackageSourceLocalRoot '$localRoot' (probe file not visible via UNC, or the share denies access to $(Get-SDAInitiator)). If the share is on another server, leave PackageSourceLocalRoot blank.")
                }
            } finally {
                Remove-Item -LiteralPath $probeLocal -Force -ErrorAction SilentlyContinue
            }
        } catch {
            $problems.Add("Package source root check failed: $($_.Exception.Message)")
        }
    }

    # A real staging creates nested folders, renames the finished version folder into place and prunes
    # old ones. Rehearse exactly that, so missing rights show up here rather than halfway through a run.
    $contentRoot = if ($Config.Paths.PackageSourceRemote) { $uncRoot } else { $localRoot }
    if (Test-Path -LiteralPath $contentRoot) {
        try {
            Test-SDAFolderWorkflow -Root $contentRoot
            Write-SDALog "Folder create / rename / delete in $contentRoot works for $(Get-SDAInitiator)."
        } catch {
            $problems.Add("Cannot create, rename or delete folders in '$contentRoot' as $(Get-SDAInitiator): $($_.Exception.Message) Grant this account Modify on the folder (and Change on the share).")
        }
    }

    foreach ($path in @($Config.Paths.DataRoot, $localRoot)) {
        try {
            $free = Test-SDAFreeSpace -Path $path -MinimumGB ([int]$Config.General.MinimumFreeSpaceGB)
            Write-SDALog "Free space for ${path}: $free GB."
        } catch {
            $problems.Add($_.Exception.Message)
        }
    }

    if ($Config.ConfigMgr.ContentFormat -eq 'WIM') {
        $longPaths = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -ErrorAction SilentlyContinue).LongPathsEnabled
        if ($longPaths -ne 1) { Write-SDALog 'LongPathsEnabled is not set; packs with >260 character paths will be rejected rather than captured incompletely.' -Severity Warning }
    }

    if ($problems.Count -gt 0) {
        throw ("Prerequisite check failed:`n - " + ($problems -join "`n - "))
    }
    Write-SDALog 'Prerequisite checks passed.'
}

function Test-SDAFolderWorkflow {
    <#
    .SYNOPSIS
        Creates a nested probe folder, renames it and deletes it, as staging and retention do. Throws on failure.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)][string]$Root)

    # Probes left by an earlier check that could not delete them.
    Get-ChildItem -LiteralPath $Root -Directory -Force -Filter '.sda-probe-*' -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    $name = ".sda-probe-$([guid]::NewGuid().ToString('N'))"
    $building = Join-Path $Root "$name.building"
    $final = Join-Path $Root $name
    try {
        New-Item -Path (Join-Path $building 'Drivers') -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $building 'Drivers\probe.txt') -Value $env:COMPUTERNAME -Encoding ASCII
        Rename-Item -LiteralPath $building -NewName $name
        Remove-Item -LiteralPath $final -Recurse -Force
    } finally {
        foreach ($leftover in @($building, $final)) {
            if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Get-SDAComputerSids {
    <#
    .SYNOPSIS
        SIDs a computer account authenticates with on the network: its own SID and all its AD groups.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)][string]$ComputerName)

    $name = ($ComputerName -split '\.')[0]
    $searcher = New-Object System.DirectoryServices.DirectorySearcher
    $searcher.Filter = "(&(objectCategory=computer)(sAMAccountName=$name`$))"
    $result = $searcher.FindOne()
    if (-not $result) { throw "Computer account $name`$ was not found in Active Directory." }
    $entry = $result.GetDirectoryEntry()
    $entry.RefreshCache([string[]]@('objectSid', 'tokenGroups'))   # tokenGroups includes nested groups
    $sids = New-Object System.Collections.Generic.List[string]
    $sids.Add((New-Object System.Security.Principal.SecurityIdentifier([byte[]]$entry.Properties['objectSid'][0], 0)).Value)
    foreach ($bytes in $entry.Properties['tokenGroups']) {
        $sids.Add((New-Object System.Security.Principal.SecurityIdentifier([byte[]]$bytes, 0)).Value)
    }
    return $sids.ToArray()
}

function Get-SDAReadVerdict {
    <#
    .SYNOPSIS
        Decides whether a set of access rules gives an account read access.
    .PARAMETER Rules
        Objects with Sid, Name, Allow (bool) and Read (bool: the rule covers reading).
    .PARAMETER Sids
        The account's own SID and its group SIDs.
    .OUTPUTS
        Verdict (Granted, Denied, AdminsOnly, NotGranted) and Via (the names that decided it).
    #>
    [CmdletBinding()]
    param ([object[]]$Rules, [string[]]$Sids)

    # Groups every authenticated computer account is in, wherever the share is.
    $member = @($Sids) + @('S-1-1-0', 'S-1-5-11', 'S-1-5-2', 'S-1-5-15', 'S-1-5-32-545')
    $readRules = @($Rules | Where-Object { $_.Read })
    $deny = @($readRules | Where-Object { -not $_.Allow -and $member -contains $_.Sid })
    if ($deny) { return [pscustomobject]@{ Verdict = 'Denied'; Via = @($deny.Name) } }
    $allow = @($readRules | Where-Object { $_.Allow -and $member -contains $_.Sid })
    if ($allow) { return [pscustomobject]@{ Verdict = 'Granted'; Via = @($allow.Name) } }
    # Local Administrators of the file server: the site server may be a member, but that can't be seen from here.
    $admins = @($readRules | Where-Object { $_.Allow -and $_.Sid -eq 'S-1-5-32-544' })
    if ($admins) { return [pscustomobject]@{ Verdict = 'AdminsOnly'; Via = @($admins.Name) } }
    return [pscustomobject]@{ Verdict = 'NotGranted'; Via = @($Rules | Where-Object { $_.Allow -and $_.Read } | ForEach-Object { $_.Name }) }
}

function Test-SDASourceReadAccess {
    <#
    .SYNOPSIS
        Warns when the site server's computer account may not be able to read the package source share.
    .DESCRIPTION
        ConfigMgr reads package content as the site server's computer account when it distributes it, so
        a share the tool can write to can still fail later, at distribution. This checks the folder's
        NTFS ACL and, where the share can be queried, the share permissions. It only logs; it never fails
        the run. Returns the verdicts for testing.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    $unc = [string]$Config.ConfigMgr.PackageSourceUncRoot
    $component = 'ConfigMgr'
    try {
        $site = Invoke-SDAWql -Context $Context -Query "SELECT ServerName FROM SMS_Site WHERE SiteCode = '$(ConvertTo-SDAWqlString $Context.SiteCode)'" | Select-Object -First 1
        $siteServer = [string]$site.ServerName
    } catch {
        $siteServer = $null
    }
    if (-not $siteServer) {
        Write-SDALog "Could not find the site server name; site server read access to $unc was not checked." -Severity Warning -Component $component
        return
    }
    $account = '{0}$' -f ($siteServer -split '\.')[0].ToUpperInvariant()

    try {
        $sids = Get-SDAComputerSids -ComputerName $siteServer
    } catch {
        Write-SDALog "Could not look up the groups of $account in Active Directory ($($_.Exception.Message)); site server read access to $unc was not checked." -Severity Warning -Component $component
        return
    }

    $results = [ordered]@{}

    # NTFS permissions on the package source folder (rules that apply to the folder itself).
    try {
        $acl = Get-Acl -LiteralPath $unc
        $rules = foreach ($r in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
            if ($r.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
            $rights = [int64]$r.FileSystemRights
            $name = try { $r.IdentityReference.Translate([System.Security.Principal.NTAccount]).Value } catch { $r.IdentityReference.Value }
            [pscustomobject]@{
                Sid = $r.IdentityReference.Value; Name = $name; Allow = $r.AccessControlType -eq 'Allow'
                Read = [bool]($rights -band 0x1) -or [bool]($rights -band 0x80000000) -or [bool]($rights -band 0x10000000)   # ReadData, GENERIC_READ, GENERIC_ALL
            }
        }
        $results['NTFS'] = Get-SDAReadVerdict -Rules @($rules) -Sids $sids
    } catch {
        Write-SDALog "Could not read the NTFS permissions of $unc ($($_.Exception.Message)); site server read access was not checked there." -Severity Warning -Component $component
    }

    # Share permissions, when the file server lets this account query them (needs admin rights there).
    $server = ($unc.TrimStart('\') -split '\\')[0]
    $shareName = ($unc.TrimStart('\') -split '\\')[1]
    $session = $null
    try {
        $isLocal = @('localhost', '127.0.0.1', '.', $env:COMPUTERNAME, ("$env:COMPUTERNAME.$env:USERDNSDOMAIN")) -contains $server
        $shareAccess = if ($isLocal) {
            Get-SmbShareAccess -Name $shareName -ErrorAction Stop
        } else {
            $session = New-CimSession -ComputerName $server -SessionOption (New-CimSessionOption -Protocol $Config.ConfigMgr.CimProtocol) -ErrorAction Stop
            Get-SmbShareAccess -Name $shareName -CimSession $session -ErrorAction Stop
        }
        if (-not $shareAccess) { throw 'no share permissions were returned' }   # e.g. administrative shares
        $rules = foreach ($s in $shareAccess) {
            $sid = try { (New-Object System.Security.Principal.NTAccount($s.AccountName)).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $null }
            if (-not $sid) { continue }
            [pscustomobject]@{ Sid = $sid; Name = $s.AccountName; Allow = [string]$s.AccessControlType -eq 'Allow'; Read = [string]$s.AccessRight -in @('Full', 'Change', 'Read') }
        }
        $results['share'] = Get-SDAReadVerdict -Rules @($rules) -Sids $sids
    } catch {
        Write-SDALog "Share permissions of \\$server\$shareName were not checked ($($_.Exception.Message)). Confirm $account has at least Read on the share." -Component $component
    } finally {
        if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
    }

    foreach ($kind in $results.Keys) {
        $v = $results[$kind]
        $via = ($v.Via | Select-Object -Unique) -join "', '"
        switch ($v.Verdict) {
            'Granted' { Write-SDALog "Site server $account can read $unc ($kind permissions, via '$via')." -Component $component }
            'Denied' { Write-SDALog "Site server $account is DENIED read access to $unc by the $kind permissions (deny entry for '$via'). Distribution of packages from this share will fail." -Severity Warning -Component $component }
            'AdminsOnly' { Write-SDALog "Site server $account can read $unc ($kind permissions) only if it is a local administrator of $server ('$via'). Grant it Read explicitly to be sure." -Severity Warning -Component $component }
            default {
                $who = if ($via) { " Read is granted only to '$via'." } else { '' }
                Write-SDALog "Site server $account has no read access to $unc in the $kind permissions.$who ConfigMgr reads package content as this account, so distribution will fail. Grant $account (or a group it is in) Read on the share and the folder." -Severity Warning -Component $component
            }
        }
    }
    return $results
}

function Get-SDASelectedTargets {
    <#
    .SYNOPSIS
        Enabled targets, optionally filtered by vendor and model (wildcards allowed).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [string[]]$Vendor,
        [string[]]$Model
    )

    $targets = @($Config.Targets | Where-Object { $_.Enabled })
    if ($Vendor) { $targets = @($targets | Where-Object { $Vendor -contains $_.Vendor }) }
    if ($Model) {
        $targets = @($targets | Where-Object {
            $t = $_
            [bool](@($Model | Where-Object { $t.Model -like $_ }).Count)
        })
    }
    return $targets
}

#endregion Session
