#Requires -Version 5.1
<#
    SCCMDriverAutomation module loader.

    The module is split into focused files under .\Private, each owning one concern:
        Logging.ps1        CMTrace-format file log + Windows event log
        Configuration.ps1  JSON configuration loading, defaults and validation
        VersionStore.ps1   Per-model version ledger (JSON), history and run lock
        Network.ps1        Proxy, TLS, HTTP downloads, hash / Authenticode / AV checks
        VendorDell.ps1     Dell DriverPackCatalog parsing
        VendorHP.ps1       HP Client Driver Pack catalog parsing
        VendorLenovo.ps1   Lenovo catalogv2 parsing
        Staging.ps1        Extraction, validation, WIM / raw content build, retention
        ConfigMgr.ps1      SMS Provider (WMI/CIM) package operations
        Deployment.ps1     Orchestration: per-model update pipeline, publish, rollback
#>

$ErrorActionPreference = 'Stop'

$privatePath = Join-Path -Path $PSScriptRoot -ChildPath 'Private'
foreach ($file in (Get-ChildItem -Path $privatePath -Filter '*.ps1' -File | Sort-Object -Property Name)) {
    try {
        . $file.FullName
    } catch {
        throw "Failed to load module component '$($file.Name)': $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function *
