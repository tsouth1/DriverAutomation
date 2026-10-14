#Requires -Version 5.1
<#
.SYNOPSIS
    Promotes a driver version to the Production ring.

.DESCRIPTION
    Re-points the model's Production package to the version currently in Pilot (default) or to an
    explicit staged version, and triggers a distribution point update. Use this when the Pilot ring is
    enabled with manual promotion (Versioning.PilotRing.AutoPromoteAfterDays = 0), or to promote early.

    Run elevated on the site server with an account that has ConfigMgr rights to modify packages.

.EXAMPLE
    .\Invoke-DriverPromotion.ps1 -Vendor Lenovo -Model 'ThinkPad T14 Gen 4' -OperatingSystem 'Windows 11' -OSBuild 24H2 -Reason 'Pilot sign-off CHG0004601'

.EXAMPLE
    .\Invoke-DriverPromotion.ps1 -Vendor Dell -Model 'Latitude 7440' -OperatingSystem 'Windows 11' -Version A07 -Reason 'Vendor hotfix'
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param (
    [Parameter(Mandatory)][ValidateSet('Dell', 'HP', 'Lenovo')][string]$Vendor,
    [Parameter(Mandatory)][string]$Model,
    [Parameter(Mandatory)][ValidateSet('Windows 10', 'Windows 11')][string]$OperatingSystem,
    [string]$OSBuild,
    [ValidateSet('x64', 'Arm64')][string]$Architecture = 'x64',
    [string]$Version,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Reason,
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Config\DriverAutomation.json')
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'Modules\SCCMDriverAutomation\SCCMDriverAutomation.psd1') -Force -DisableNameChecking

$mutex = $null
$context = $null
try {
    $config = Initialize-SDARun -ConfigPath $ConfigPath -Component 'Promotion'
    $target = Find-SDATarget -Config $config -Vendor $Vendor -Model $Model -OSName $OperatingSystem -OSBuild $OSBuild -Architecture $Architecture
    $state = Get-SDAState -Config $config -Target $target
    $toVersion = if ($Version) { $Version } else { $state.Deployed.Pilot }
    $what = "$($target.DisplayName) [Production ring]: $($state.Deployed.Production) -> $toVersion"

    if ($PSCmdlet.ShouldProcess($what, 'Promote driver package')) {
        $mutex = Enter-SDALock -TimeoutMinutes ([int]$config.General.LockTimeoutMinutes)
        $context = Connect-SDASite -Config $config
        $result = Invoke-SDAPromotion -Context $context -Config $config -Target $target -Version $Version -Reason $Reason
        Write-SDALog ("Promotion complete: {0} Production {1} -> {2} (package {3})." -f $result.Target, $result.From, $result.To, $result.PackageID)
        $result
    }
} catch {
    Write-SDALog "Promotion failed: $(Format-SDAError -ErrorRecord $_)" -Severity Error
    throw
} finally {
    Disconnect-SDASite -Context $context
    Exit-SDALock -Mutex $mutex
}
