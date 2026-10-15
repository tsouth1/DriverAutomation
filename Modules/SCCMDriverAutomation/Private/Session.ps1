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
