#Requires -Version 5.1
<#
.SYNOPSIS
    Lists the models and Windows builds the Dell, HP and Lenovo catalogs publish driver packs for.

.DESCRIPTION
    Downloads and verifies the vendor catalogs (not the driver packs) through the configured proxy and
    returns one row per model / OS / build / architecture, with the model's system IDs and the newest
    pack. The Model and SystemIds values are exactly what the Models section of the configuration
    expects. The GUI's "Add from vendor catalog" tab uses this script.

    It changes nothing in ConfigMgr or in the ledgers. The catalogs are downloaded to
    <DataRoot>\Work\CatalogBrowse, or to %TEMP% when the data root is not usable yet.

.PARAMETER Vendor
    Catalogs to read. Default: all three.

.PARAMETER OutFile
    Write the rows to this JSON file instead of the pipeline.

.EXAMPLE
    .\Get-DriverCatalogModels.ps1 -Vendor Lenovo | Where-Object Model -like 'ThinkPad T14*' | Format-Table

.EXAMPLE
    .\Get-DriverCatalogModels.ps1 -Vendor HP | Where-Object { $_.SystemIds -contains '8B41' }
#>
[CmdletBinding()]
param (
    [ValidateSet('Dell', 'HP', 'Lenovo')][string[]]$Vendor = @('Dell', 'HP', 'Lenovo'),
    [string]$OutFile,
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Config\DriverAutomation.json')
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'Modules\SCCMDriverAutomation\SCCMDriverAutomation.psd1') -Force -DisableNameChecking

try {
    $config = Import-SDAConfig -Path $ConfigPath

    # Use a folder of our own so a scheduled run reading its catalogs at the same time is not disturbed.
    $work = Join-Path $config.Paths.DataRoot 'Work\CatalogBrowse'
    $logs = $config.Paths.Logs
    try {
        foreach ($dir in @($work, $logs)) {
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        }
    } catch {
        Write-Warning "Data root '$($config.Paths.DataRoot)' is not usable ($($_.Exception.Message)). Using %TEMP% for this scan."
        $work = Join-Path $env:TEMP 'SCCMDriverAutomation\CatalogBrowse'
        $logs = Join-Path $env:TEMP 'SCCMDriverAutomation\Logs'
    }
    $config.Paths.Catalogs = $work
    Initialize-SDALog -LogDirectory $logs -FileName 'DriverAutomation-Catalog.log' -Component 'Catalog'
    Initialize-SDANetwork -Config $config

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($v in $Vendor) {
        $vendorRows = @(Get-SDACatalogModels -Vendor $v -Config $config)
        $models = @($vendorRows | Select-Object -ExpandProperty Model -Unique).Count
        Write-SDALog ("[{0}] {1} models, {2} model / OS combinations in the catalog." -f $v, $models, $vendorRows.Count) -Component $v
        $rows.AddRange([object[]]$vendorRows)
    }

    if ($OutFile) {
        $temp = "$OutFile.tmp"
        [System.IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $rows.ToArray() -Depth 4 -Compress), (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temp -Destination $OutFile -Force
        Write-SDALog "Catalog rows written to $OutFile"
    } else {
        $rows
    }
} catch {
    Write-SDALog "Catalog scan failed: $(Format-SDAError -ErrorRecord $_)" -Severity Error
    throw
} finally {
    Close-SDANetwork
}
