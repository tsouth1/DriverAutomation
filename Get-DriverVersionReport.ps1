#Requires -Version 5.1
<#
.SYNOPSIS
    Reports which driver version is deployed to each ring for every managed model.

.DESCRIPTION
    Reads the version ledgers (no ConfigMgr access required unless -DistributionStatus is used).

.PARAMETER History
    Output the full audit history (stage / deploy / promote / rollback / block / hold / prune) instead
    of the summary.

.PARAMETER DistributionStatus
    Add per-package distribution point status (Installed / InProgress / Failed) from ConfigMgr.

.PARAMETER ExportCsv
    Also write the output to this CSV file.

.EXAMPLE
    .\Get-DriverVersionReport.ps1 | Format-Table

.EXAMPLE
    .\Get-DriverVersionReport.ps1 -Vendor Dell -History | Where-Object Action -eq 'Rollback'

.EXAMPLE
    .\Get-DriverVersionReport.ps1 -DistributionStatus -ExportCsv D:\Reports\drivers.csv
#>
[CmdletBinding()]
param (
    [ValidateSet('Dell', 'HP', 'Lenovo')][string[]]$Vendor,
    [string[]]$Model,
    [switch]$History,
    [switch]$DistributionStatus,
    [string]$ExportCsv,
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Config\DriverAutomation.json')
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'Modules\SCCMDriverAutomation\SCCMDriverAutomation.psd1') -Force -DisableNameChecking

$context = $null
try {
    $config = Initialize-SDARun -ConfigPath $ConfigPath -LogFileName 'DriverAutomation-Report.log' -Component 'Report'
    $states = @(Get-SDAAllStates -Config $config)
    if ($Vendor) { $states = @($states | Where-Object { $Vendor -contains $_.Vendor }) }
    if ($Model) { $states = @($states | Where-Object { $s = $_; [bool](@($Model | Where-Object { $s.Model -like $_ }).Count) }) }

    if ($DistributionStatus -and -not $History) { $context = Connect-SDASite -Config $config }

    $output = foreach ($s in ($states | Sort-Object Vendor, Model, OSName, OSBuild)) {
        $display = "{0} {1} - {2}{3} {4}" -f $s.Vendor, $s.Model, $s.OSName, $(if ($s.OSBuild) { " $($s.OSBuild)" } else { '' }), $s.Architecture
        if ($History) {
            foreach ($h in @($s.History)) {
                [pscustomobject]@{
                    Target       = $display
                    TimestampUtc = $h.TimestampUtc
                    Action       = $h.Action
                    Ring         = $h.Ring
                    FromVersion  = $h.FromVersion
                    ToVersion    = $h.ToVersion
                    PackageID    = $h.PackageID
                    Initiator    = $h.Initiator
                    Reason       = $h.Reason
                }
            }
            continue
        }

        $usable = @($s.Versions | Where-Object { $_.Status -eq 'Available' })
        $row = [ordered]@{
            Target              = $display
            ProductionVersion   = $s.Deployed.Production
            ProductionPackageID = $(if ($s.Packages.Production) { $s.Packages.Production.PackageID })
            PilotVersion        = $s.Deployed.Pilot
            PilotPackageID      = $(if ($s.Packages.Pilot) { $s.Packages.Pilot.PackageID })
            LatestCatalog       = $(if ($s.LastCatalog) { "$($s.LastCatalog.VendorVersion) ($($s.LastCatalog.ReleaseDate))" })
            RollbackTarget      = $(($c = Get-SDARollbackCandidate -State $s -Ring 'Production'); if ($c) { $c.VersionId })
            StagedVersions      = (@($usable.VersionId) -join ', ')
            BlockedVersions     = (@($s.Versions | Where-Object { $_.Status -eq 'Blocked' } | ForEach-Object { $_.VersionId }) -join ', ')
            Holds               = (@('Production', 'Pilot') | Where-Object { $s.Holds[$_] }) -join ', '
            LastChecked         = $s.LastChecked
        }
        if ($context) {
            foreach ($ring in @('Production', 'Pilot')) {
                $pkg = $s.Packages[$ring]
                $row["${ring}DPStatus"] = if ($pkg -and $pkg.PackageID) {
                    try {
                        $d = Get-SDADistributionStatus -Context $context -PackageID $pkg.PackageID
                        "{0}/{1} installed, {2} in progress, {3} failed" -f $d.Installed, $d.Targeted, $d.InProgress, $d.Failed
                    } catch { "error: $($_.Exception.Message)" }
                } else { '' }
            }
        }
        [pscustomobject]$row
    }

    if ($ExportCsv) {
        $output | Export-Csv -LiteralPath $ExportCsv -NoTypeInformation -Encoding UTF8
        Write-SDALog "Report exported to $ExportCsv."
    }
    $output
} finally {
    Disconnect-SDASite -Context $context
}
