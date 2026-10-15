#Requires -Version 5.1
<#
.SYNOPSIS
    Scheduled entry point: checks Dell / HP / Lenovo catalogs, stages new driver packs and deploys them
    to Configuration Manager with versioning.

.DESCRIPTION
    Designed to run unattended as SYSTEM on the ConfigMgr site server (see Install-DriverAutomation.ps1).
    For every enabled model / OS in the configuration it:

      1. Reads the vendor's signed driver pack catalog and finds the newest pack.
      2. If that release has not been seen before: downloads it through the configured proxy, verifies
         the vendor hash and Authenticode signature, runs a Defender scan, extracts it, and builds an
         immutable version folder (WIM or raw) with a provenance manifest.
      3. Deploys it to the entry ring (Pilot when enabled, otherwise Production) by creating or
         re-pointing that ring's ConfigMgr package, then refreshes distribution points.
      4. Optionally promotes Pilot to Production after the configured soak period.
      5. Prunes staged versions beyond the retention count (never the deployed or rollback versions).

    Every change is recorded in a per-model ledger under <DataRoot>\State and in the CMTrace log
    <DataRoot>\Logs\DriverAutomation.log. A CSV run report is written to <DataRoot>\Logs\Reports.

.PARAMETER ConfigPath
    Path to the JSON configuration. Defaults to Config\DriverAutomation.json next to this script.

.PARAMETER Vendor
    Limit the run to these vendors (Dell, HP, Lenovo).

.PARAMETER Model
    Limit the run to models matching these names (wildcards allowed).

.PARAMETER DryRun
    Report what would change without downloading, changing ConfigMgr or writing ledgers.

.PARAMETER PreflightOnly
    Validate configuration, folders and package share rights, proxy / vendor connectivity, ConfigMgr
    permissions and the site server's read access to the package share, then exit.

.EXAMPLE
    .\Invoke-DriverAutomation.ps1 -DryRun

.EXAMPLE
    .\Invoke-DriverAutomation.ps1 -Vendor HP -Model 'EliteBook 8*'

.NOTES
    Exit codes: 0 = success, 1 = completed with one or more target failures, 2 = fatal error.
#>
[CmdletBinding()]
param (
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Config\DriverAutomation.json'),
    [ValidateSet('Dell', 'HP', 'Lenovo')][string[]]$Vendor,
    [string[]]$Model,
    [switch]$DryRun,
    [switch]$PreflightOnly
)

$ErrorActionPreference = 'Stop'
$exitCode = 0
$mutex = $null
$context = $null
$config = $null
$runStart = Get-Date

try {
    Import-Module -Name (Join-Path $PSScriptRoot 'Modules\SCCMDriverAutomation\SCCMDriverAutomation.psd1') -Force -DisableNameChecking
} catch {
    Write-Error "Unable to load the SCCMDriverAutomation module: $($_.Exception.Message)"
    exit 2
}

try {
    $config = Initialize-SDARun -ConfigPath $ConfigPath
    $mode = if ($PreflightOnly) { 'Preflight' } elseif ($DryRun) { 'DryRun' } else { 'Full' }
    Write-SDALog ("===== Driver automation run started (mode: {0}, identity: {1}, PS {2}) =====" -f $mode, (Get-SDAInitiator), $PSVersionTable.PSVersion)

    $mutex = Enter-SDALock -TimeoutMinutes ([int]$config.General.LockTimeoutMinutes)
    Test-SDAPrerequisites -Config $config
    Initialize-SDANetwork -Config $config
    Clear-SDACatalogCache

    $targets = @(Get-SDASelectedTargets -Config $config -Vendor $Vendor -Model $Model)
    if ($targets.Count -eq 0) { throw 'No enabled targets match the selection.' }
    Write-SDALog "$($targets.Count) target(s) selected."

    if ($PreflightOnly) {
        foreach ($v in @($targets.Vendor | Select-Object -Unique)) {
            Get-SDACatalogXml -Vendor $v -Config $config | Out-Null
            Write-SDALog "[$v] Catalog download and verification OK."
        }
        $context = Connect-SDASite -Config $config
        foreach ($group in @(@($config.ConfigMgr.DistributionPointGroups) + @($config.ConfigMgr.PilotDistributionPointGroups) | Where-Object { $_ } | Select-Object -Unique)) {
            $found = Invoke-SDAWql -Context $context -Query "SELECT GroupID FROM SMS_DistributionPointGroup WHERE Name = '$(ConvertTo-SDAWqlString $group)'"
            if (@($found).Count -eq 0) { throw "Distribution point group '$group' was not found." }
        }
        [void](Test-SDASourceReadAccess -Context $context -Config $config)
        Write-SDALog '===== Preflight completed successfully ====='
        Write-SDAEvent -EventId 1000 -Message "Preflight completed successfully as $(Get-SDAInitiator)."
        exit 0
    }

    if (-not $DryRun) {
        $context = Connect-SDASite -Config $config
        [void](Test-SDASourceReadAccess -Context $context -Config $config)
    } else {
        # Read-only: look up the site server so a dry run also reports whether it can read the share.
        $checkContext = $null
        try {
            $checkContext = Connect-SDASite -Config $config
            [void](Test-SDASourceReadAccess -Context $checkContext -Config $config)
        } catch {
            Write-SDALog "Site server read access to the package share was not checked: $($_.Exception.Message)" -Severity Warning
        } finally {
            Disconnect-SDASite -Context $checkContext
        }
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($target in $targets) {
        Write-SDALog "----- $($target.DisplayName) -----"
        try {
            $results.Add((Invoke-SDATargetUpdate -Context $context -Config $config -Target $target -DryRun:$DryRun))
        } catch {
            $message = Format-SDAError -ErrorRecord $_
            Write-SDALog "FAILED $($target.DisplayName): $message" -Severity Error
            $results.Add([pscustomobject]@{
                Target = $target.DisplayName; Key = $target.Key; Status = 'Failed'; CatalogVersion = $null; CatalogDate = $null
                ProductionVersion = $null; PilotVersion = $null; Actions = @(); Message = $message
            })
        }
    }

    # ---- Report ---------------------------------------------------------------------------------
    $report = $results | Select-Object Target, Status, CatalogVersion, CatalogDate, ProductionVersion, PilotVersion,
        @{ Name = 'Actions'; Expression = { @($_.Actions) -join '; ' } }, Message
    $reportFile = Join-Path $config.Paths.Reports ("Run-{0}{1}.csv" -f $runStart.ToString('yyyyMMdd-HHmmss'), $(if ($DryRun) { '-DryRun' } else { '' }))
    $report | Export-Csv -LiteralPath $reportFile -NoTypeInformation -Encoding UTF8
    Get-ChildItem -LiteralPath $config.Paths.Reports -Filter 'Run-*.csv' -File | Sort-Object LastWriteTime -Descending | Select-Object -Skip 90 | Remove-Item -Force -ErrorAction SilentlyContinue

    $failed  = @($results | Where-Object { $_.Status -eq 'Failed' })
    $changed = @($results | Where-Object { $_.Status -in 'Updated', 'Staged' })
    $summary = "Run finished in {0:N0} min: {1} target(s), {2} changed, {3} failed, {4} blocked/held, {5} not in catalog. Report: {6}" -f `
        ((Get-Date) - $runStart).TotalMinutes, $results.Count, $changed.Count, $failed.Count,
        @($results | Where-Object { $_.Status -in 'Blocked', 'Held' }).Count,
        @($results | Where-Object { $_.Status -eq 'NotInCatalog' }).Count, $reportFile

    $details = ($report | ForEach-Object { "{0}: {1} {2}" -f $_.Target, $_.Status, $(if ($_.Actions) { "($($_.Actions))" } elseif ($_.Message) { "($($_.Message))" } else { '' }) }) -join "`r`n"
    if ($failed.Count -gt 0) {
        $exitCode = 1
        Write-SDALog $summary -Severity Warning
        Write-SDAEvent -EventId 1001 -EntryType Warning -Message "$summary`r`n`r`n$details"
    } else {
        Write-SDALog $summary
        Write-SDAEvent -EventId 1000 -Message "$summary`r`n`r`n$details"
    }
} catch {
    $exitCode = 2
    $message = if ($_ -is [System.Management.Automation.ErrorRecord]) { Format-SDAError -ErrorRecord $_ } else { "$_" }
    try {
        Write-SDALog "FATAL: $message" -Severity Error
        Write-SDAEvent -EventId 1002 -EntryType Error -Message "Driver automation run failed: $message"
    } catch {
        Write-Error "FATAL: $message"
    }
} finally {
    try { Close-SDANetwork } catch { }
    try { Disconnect-SDASite -Context $context } catch { }
    Exit-SDALock -Mutex $mutex
    try { Write-SDALog "===== Driver automation run ended (exit code $exitCode) =====" } catch { }
}

exit $exitCode
