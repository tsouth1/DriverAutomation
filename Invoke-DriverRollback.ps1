#Requires -Version 5.1
<#
.SYNOPSIS
    Rolls a model's driver package back to an earlier staged version.

.DESCRIPTION
    Re-points the ring's ConfigMgr package (same PackageID - no task sequence edits needed) to an earlier,
    immutable version folder and triggers a distribution point update.

    By default the version being replaced is BLOCKED so the scheduled run will not re-deploy it; newer
    vendor releases continue to flow. Use -Hold to freeze the ring completely until released with
    Set-DriverDeploymentState.ps1 -ReleaseRing.

    Run elevated on the site server with an account that has ConfigMgr rights to modify packages.

.PARAMETER Vendor / Model / OperatingSystem / OSBuild / Architecture
    Identify the target exactly as in the configuration. OSBuild can be omitted when only one build of
    the model / OS is configured.

.PARAMETER Ring
    Production (default) or Pilot.

.PARAMETER ToVersion
    Specific VersionId to roll back to. Defaults to the version deployed before the current one.

.PARAMETER Reason
    Mandatory justification - stored in the ledger, the log and the event log.

.PARAMETER NoBlock
    Do not block the version being replaced (e.g. temporary rollback for troubleshooting).

.PARAMETER Hold
    Also place the ring on hold: no automatic deployments or promotions until released.

.PARAMETER ListVersions
    Show the versions available for this target and exit without changing anything.

.EXAMPLE
    .\Invoke-DriverRollback.ps1 -Vendor Dell -Model 'Latitude 7440' -OperatingSystem 'Windows 11' -ListVersions

.EXAMPLE
    .\Invoke-DriverRollback.ps1 -Vendor Dell -Model 'Latitude 7440' -OperatingSystem 'Windows 11' -Reason 'INC0012345 - audio driver BSOD'

.EXAMPLE
    .\Invoke-DriverRollback.ps1 -Vendor HP -Model 'HP EliteBook 840 G10' -OperatingSystem 'Windows 11' -OSBuild 24H2 -ToVersion '1.00-A-1' -Hold -Reason 'CHG0004567'
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Rollback')]
param (
    [Parameter(Mandatory)][ValidateSet('Dell', 'HP', 'Lenovo')][string]$Vendor,
    [Parameter(Mandatory)][string]$Model,
    [Parameter(Mandatory)][ValidateSet('Windows 10', 'Windows 11')][string]$OperatingSystem,
    [string]$OSBuild,
    [ValidateSet('x64', 'Arm64')][string]$Architecture = 'x64',
    [Parameter(ParameterSetName = 'Rollback')][ValidateSet('Production', 'Pilot')][string]$Ring = 'Production',
    [Parameter(ParameterSetName = 'Rollback')][string]$ToVersion,
    [Parameter(Mandatory, ParameterSetName = 'Rollback')][ValidateNotNullOrEmpty()][string]$Reason,
    [Parameter(ParameterSetName = 'Rollback')][switch]$NoBlock,
    [Parameter(ParameterSetName = 'Rollback')][switch]$Hold,
    [Parameter(Mandatory, ParameterSetName = 'List')][switch]$ListVersions,
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Config\DriverAutomation.json')
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'Modules\SCCMDriverAutomation\SCCMDriverAutomation.psd1') -Force -DisableNameChecking

$mutex = $null
$context = $null
try {
    $config = Initialize-SDARun -ConfigPath $ConfigPath -Component 'Rollback'
    $target = Find-SDATarget -Config $config -Vendor $Vendor -Model $Model -OSName $OperatingSystem -OSBuild $OSBuild -Architecture $Architecture
    $state = Get-SDAState -Config $config -Target $target

    if ($PSCmdlet.ParameterSetName -eq 'List') {
        $candidate = @{}
        foreach ($r in @('Production', 'Pilot')) {
            $c = Get-SDARollbackCandidate -State $state -Ring $r
            if ($c) { $candidate[$r] = $c.VersionId }
        }
        @($state.Versions) | Sort-Object -Property @{ Expression = { Get-SDAVersionSortDate $_ } } -Descending | ForEach-Object {
            $v = $_
            [pscustomobject]@{
                VersionId     = $v.VersionId
                VendorVersion = $v.VendorVersion
                ReleaseDate   = $v.ReleaseDate
                Status        = $v.Status
                DeployedTo    = (@('Production', 'Pilot') | Where-Object { $state.Deployed[$_] -eq $v.VersionId }) -join ', '
                RollbackTarget = (@('Production', 'Pilot') | Where-Object { $candidate[$_] -eq $v.VersionId }) -join ', '
                StagedUtc     = $v.StagedUtc
                Notes         = $v.BlockedReason
            }
        } | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
        $holds = @('Production', 'Pilot') | Where-Object { $state.Holds[$_] } | ForEach-Object { "$_ (since $($state.Holds[$_].SetUtc) by $($state.Holds[$_].By): $($state.Holds[$_].Reason))" }
        if ($holds) { Write-Host "Rings on hold: $($holds -join '; ')" -ForegroundColor Yellow }
        return
    }

    $current = $state.Deployed[$Ring]
    $destination = if ($ToVersion) { $ToVersion } else { $c = Get-SDARollbackCandidate -State $state -Ring $Ring; if ($c) { $c.VersionId } else { '<none available>' } }
    $what = "$($target.DisplayName) [$Ring ring]: $current -> $destination$(if (-not $NoBlock) { " (block $current)" })$(if ($Hold) { ' (hold ring)' })"

    if ($PSCmdlet.ShouldProcess($what, 'Roll back driver package')) {
        $mutex = Enter-SDALock -TimeoutMinutes ([int]$config.General.LockTimeoutMinutes)
        $context = Connect-SDASite -Config $config
        $result = Invoke-SDARollback -Context $context -Config $config -Target $target -Ring $Ring -ToVersion $ToVersion -Reason $Reason -NoBlock:$NoBlock -Hold:$Hold
        Write-SDALog ("Rollback complete: {0} {1} {2} -> {3} (package {4})." -f $result.Target, $result.Ring, $result.From, $result.To, $result.PackageID)
        Write-SDALog 'Distribution points are updating; clients receive the rolled-back content once the new content version reaches their DP.'
        $result
    }
} catch {
    Write-SDALog "Rollback failed: $(Format-SDAError -ErrorRecord $_)" -Severity Error
    throw
} finally {
    Disconnect-SDASite -Context $context
    Exit-SDALock -Mutex $mutex
}
