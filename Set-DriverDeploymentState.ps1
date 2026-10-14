#Requires -Version 5.1
<#
.SYNOPSIS
    Blocks / unblocks driver versions and holds / releases deployment rings for a model.

.DESCRIPTION
    Changes only the version ledger - nothing in ConfigMgr is modified, so no ConfigMgr rights are needed.

      -BlockVersion   The scheduled run will never deploy or promote this version automatically.
      -UnblockVersion Makes a blocked version eligible again (it is deployed on the next run if it is
                      still the newest release).
      -HoldRing       Freezes a ring: no automatic deployments or promotions until released.
      -ReleaseRing    Removes a hold.

    To change what devices currently receive, use Invoke-DriverRollback.ps1 or Invoke-DriverPromotion.ps1.

.EXAMPLE
    .\Set-DriverDeploymentState.ps1 -Vendor Dell -Model 'Latitude 7440' -OperatingSystem 'Windows 11' -BlockVersion A08 -Reason 'Known NIC issue (Dell advisory 123)'

.EXAMPLE
    .\Set-DriverDeploymentState.ps1 -Vendor HP -Model 'HP EliteBook 840 G10' -OperatingSystem 'Windows 11' -OSBuild 24H2 -ReleaseRing Production -Reason 'Issue resolved'
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory)][ValidateSet('Dell', 'HP', 'Lenovo')][string]$Vendor,
    [Parameter(Mandatory)][string]$Model,
    [Parameter(Mandatory)][ValidateSet('Windows 10', 'Windows 11')][string]$OperatingSystem,
    [string]$OSBuild,
    [ValidateSet('x64', 'Arm64')][string]$Architecture = 'x64',
    [Parameter(Mandatory, ParameterSetName = 'Block')][string]$BlockVersion,
    [Parameter(Mandatory, ParameterSetName = 'Unblock')][string]$UnblockVersion,
    [Parameter(Mandatory, ParameterSetName = 'Hold')][ValidateSet('Production', 'Pilot')][string]$HoldRing,
    [Parameter(Mandatory, ParameterSetName = 'Release')][ValidateSet('Production', 'Pilot')][string]$ReleaseRing,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Reason,
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Config\DriverAutomation.json')
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'Modules\SCCMDriverAutomation\SCCMDriverAutomation.psd1') -Force -DisableNameChecking

$mutex = $null
try {
    $config = Initialize-SDARun -ConfigPath $ConfigPath -Component 'DeploymentState'
    $target = Find-SDATarget -Config $config -Vendor $Vendor -Model $Model -OSName $OperatingSystem -OSBuild $OSBuild -Architecture $Architecture

    $what = switch ($PSCmdlet.ParameterSetName) {
        'Block'   { "Block version $BlockVersion" }
        'Unblock' { "Unblock version $UnblockVersion" }
        'Hold'    { "Hold $HoldRing ring" }
        'Release' { "Release $ReleaseRing ring" }
    }

    if ($PSCmdlet.ShouldProcess($target.DisplayName, $what)) {
        $mutex = Enter-SDALock -TimeoutMinutes ([int]$config.General.LockTimeoutMinutes)
        # Load after taking the lock so a concurrent run's changes are not overwritten.
        $state = Get-SDAState -Config $config -Target $target
        switch ($PSCmdlet.ParameterSetName) {
            'Block'   { Set-SDAVersionStatus -State $state -VersionId $BlockVersion -Status Blocked -Reason $Reason }
            'Unblock' { Set-SDAVersionStatus -State $state -VersionId $UnblockVersion -Status Available -Reason $Reason }
            'Hold'    { Set-SDARingHold -State $state -Ring $HoldRing -Reason $Reason }
            'Release' { Set-SDARingHold -State $state -Ring $ReleaseRing -Reason $Reason -Release }
        }
        Save-SDAState -Config $config -State $state
        Write-SDALog "$what for $($target.DisplayName) recorded by $(Get-SDAInitiator). Reason: $Reason"
        Write-SDAEvent -EventId 1102 -Message "$what for $($target.DisplayName) by $(Get-SDAInitiator). Reason: $Reason"
    }
} catch {
    Write-SDALog "Deployment state change failed: $(Format-SDAError -ErrorRecord $_)" -Severity Error
    throw
} finally {
    Exit-SDALock -Mutex $mutex
}
