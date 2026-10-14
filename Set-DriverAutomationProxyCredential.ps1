#Requires -Version 5.1
<#
.SYNOPSIS
    Stores (or removes) the proxy credential used when Network.ProxyAuthentication = StoredCredential.

.DESCRIPTION
    The credential is encrypted with DPAPI (LocalMachine scope, so the SYSTEM scheduled task can read
    it) and written to <DataRoot>\Secrets with an ACL limited to SYSTEM and Administrators.

    Prefer ProxyAuthentication = DefaultCredentials where possible: the task then authenticates to the
    proxy as the site server's computer account via Kerberos/NTLM and no secret is stored at all. Ask
    the proxy team to allow the computer account (or an AD group containing it) for the vendor domains.

.EXAMPLE
    .\Set-DriverAutomationProxyCredential.ps1 -Credential (Get-Credential CORP\svc-proxy-drivers)

.EXAMPLE
    .\Set-DriverAutomationProxyCredential.ps1 -Remove
#>
[CmdletBinding(DefaultParameterSetName = 'Set')]
param (
    [Parameter(Mandatory, ParameterSetName = 'Set')][System.Management.Automation.PSCredential]$Credential,
    [Parameter(Mandatory, ParameterSetName = 'Remove')][switch]$Remove,
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Config\DriverAutomation.json')
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'Modules\SCCMDriverAutomation\SCCMDriverAutomation.psd1') -Force -DisableNameChecking

$config = Initialize-SDARun -ConfigPath $ConfigPath -Component 'ProxyCredential'
if ($Remove) {
    $file = Join-Path $config.Paths.Secrets 'proxy.credential'
    if (Test-Path -LiteralPath $file) {
        Remove-Item -LiteralPath $file -Force
        Write-SDALog "Stored proxy credential removed by $(Get-SDAInitiator)."
    } else {
        Write-SDALog 'No stored proxy credential found.'
    }
    return
}

Set-SDAProxyCredential -Config $config -Credential $Credential
if ($config.Network.ProxyAuthentication -ne 'StoredCredential') {
    Write-SDALog "Note: Network.ProxyAuthentication is '$($config.Network.ProxyAuthentication)'; set it to 'StoredCredential' for this credential to be used." -Severity Warning
}
