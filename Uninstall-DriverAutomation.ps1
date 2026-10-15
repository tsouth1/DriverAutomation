#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes SCCMDriverAutomation from this server.

.DESCRIPTION
    By default:
      1. Removes the scheduled task (and a leftover preflight task) and the Start menu shortcut.
      2. Saves a copy of the installed configuration to <DataRoot>\Config-backup, so a reinstall can use
         it (Install-DriverAutomation.ps1 -ConfigFile <copy>).
      3. Removes the program folder (scripts, module, configuration).

    The data root (logs, run reports, ledgers, stored proxy credential) is kept unless -RemoveData is
    given. The ledgers are the version and rollback history of every model, so keep them if the tool
    might be reinstalled or moved to another server.

    Never touched: the ConfigMgr packages and the version folders on the package source share. Task
    sequences may still use them. Delete them in the console and on the share when they are no longer
    needed.

    It asks for confirmation before changing anything; use -Confirm:$false to skip that, or -WhatIf to
    see what would be removed.

.PARAMETER InstallPath
    Program folder. Default: the scheduled task's working folder, else C:\Program Files\SCCMDriverAutomation.

.PARAMETER RemoveData
    Also delete the data root folders this tool created (Logs, State, Work, Secrets, Config-backup) and
    the 'SCCMDriverAutomation' event log source. The data root folder itself is removed only if it is
    empty afterwards.

.PARAMETER KeepProgramFiles
    Remove only the scheduled task and the shortcut (what Install-DriverAutomation.ps1 -Uninstall does).

.PARAMETER Force
    Stop the scheduled task first if a run is in progress.

.EXAMPLE
    .\Uninstall-DriverAutomation.ps1
    Removes the task, the shortcut and the program files; keeps the data root.

.EXAMPLE
    .\Uninstall-DriverAutomation.ps1 -RemoveData -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param (
    [string]$InstallPath,
    [switch]$RemoveData,
    [switch]$KeepProgramFiles,
    [switch]$Force,
    [string]$TaskName = 'SCCM Driver Automation',
    [string]$TaskPath = '\SCCMDriverAutomation\'
)

$ErrorActionPreference = 'Stop'
$shortcutPath = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\SCCM Driver Automation.lnk'
$eventSource = 'SCCMDriverAutomation'
$dataFolders = @('Logs', 'State', 'Work', 'Secrets', 'Config-backup')

function Write-Step ([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }

# ---- What is installed ------------------------------------------------------------------------
$tasks = @(Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue)
$mainTask = $tasks | Where-Object { $_.TaskName -eq $TaskName } | Select-Object -First 1
if (-not $InstallPath) {
    $InstallPath = Join-Path $env:ProgramFiles 'SCCMDriverAutomation'
    if ($mainTask -and $mainTask.Actions[0].WorkingDirectory) { $InstallPath = $mainTask.Actions[0].WorkingDirectory }
}
$InstallPath = [System.IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
$configPath = Join-Path $InstallPath 'Config\DriverAutomation.json'

# Refuse to treat a drive root or a system folder as the program folder.
$protected = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE) |
    Where-Object { $_ } | ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\') }
if ($InstallPath.Length -le 3 -or $protected -contains $InstallPath) { throw "Refusing to remove '$InstallPath'." }
if (-not $KeepProgramFiles -and (Test-Path -LiteralPath $InstallPath) -and
    -not (Test-Path -LiteralPath (Join-Path $InstallPath 'Invoke-DriverAutomation.ps1'))) {
    throw "'$InstallPath' does not look like an SCCMDriverAutomation installation (Invoke-DriverAutomation.ps1 not found)."
}

# The data root comes from the installed configuration (raw JSON, so an invalid config still works).
$dataRoot = $null
if (Test-Path -LiteralPath $configPath) {
    try { $dataRoot = [string](Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).General.DataRoot } catch {
        Write-Warning "Could not read $configPath ($($_.Exception.Message)); the data root is unknown."
    }
}
$dataRootExists = $dataRoot -and (Test-Path -LiteralPath $dataRoot)

# ---- Summary and confirmation -----------------------------------------------------------------
$plan = New-Object System.Collections.Generic.List[string]
foreach ($t in $tasks) { $plan.Add("Scheduled task $($t.TaskPath)$($t.TaskName)") }
if (Test-Path -LiteralPath $shortcutPath) { $plan.Add("Start menu shortcut $shortcutPath") }
if (-not $KeepProgramFiles) {
    if ($dataRootExists -and -not $RemoveData -and (Test-Path -LiteralPath $configPath)) { $plan.Add("Copy the configuration to $(Join-Path $dataRoot 'Config-backup')") }
    if (Test-Path -LiteralPath $InstallPath) { $plan.Add("Program folder $InstallPath (scripts, module, configuration)") }
}
if ($RemoveData) {
    if ($dataRootExists) {
        foreach ($f in $dataFolders) { if (Test-Path -LiteralPath (Join-Path $dataRoot $f)) { $plan.Add("Data folder $(Join-Path $dataRoot $f)") } }
    } elseif ($dataRoot) {
        Write-Warning "Data root $dataRoot does not exist - nothing to remove there."
    } else {
        Write-Warning 'The data root is unknown (no readable installed configuration), so no data is removed.'
    }
    if ([System.Diagnostics.EventLog]::SourceExists($eventSource)) { $plan.Add("Event log source '$eventSource'") }
}

if ($plan.Count -eq 0) { Write-Step 'Nothing to remove - SCCMDriverAutomation is not installed here.'; return }

Write-Host 'This will remove:'
$plan | ForEach-Object { Write-Host "  - $_" }
if ($dataRootExists -and -not $RemoveData) { Write-Host "Kept: data root $dataRoot (logs, ledgers, stored credential). Add -RemoveData to delete it." }
Write-Host 'Not touched: ConfigMgr packages and the version folders on the package source share.'
if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Uninstall SCCMDriverAutomation')) { return }

# ---- 1. Scheduled tasks -----------------------------------------------------------------------
foreach ($t in $tasks) {
    if ($t.State -eq 'Running') {
        if (-not $Force) { throw "'$($t.TaskName)' is running. Wait for it to finish, or use -Force to stop it." }
        Stop-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath
        Write-Step "Stopped the running task '$($t.TaskName)'."
    }
    Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false
    Write-Step "Removed scheduled task '$($t.TaskPath)$($t.TaskName)'."
}
# Remove the now empty task folder.
try {
    $scheduler = New-Object -ComObject Schedule.Service
    $scheduler.Connect()
    $folder = $scheduler.GetFolder($TaskPath.TrimEnd('\'))
    if ($folder.GetTasks(1).Count -eq 0 -and $folder.GetFolders(0).Count -eq 0) {
        $scheduler.GetFolder('\').DeleteFolder($TaskPath.Trim('\'), 0)
        Write-Step "Removed task folder '$TaskPath'."
    }
} catch { }

if (Test-Path -LiteralPath $shortcutPath) {
    Remove-Item -LiteralPath $shortcutPath -Force
    Write-Step 'Removed the Start menu shortcut.'
}
if ($KeepProgramFiles) { Write-Step 'Program files, data root and package content were left in place.'; return }

# ---- 2. Configuration copy --------------------------------------------------------------------
if ($dataRootExists -and -not $RemoveData -and (Test-Path -LiteralPath $configPath)) {
    $backupDir = Join-Path $dataRoot 'Config-backup'
    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -Path $backupDir -ItemType Directory -Force | Out-Null }
    $backup = Join-Path $backupDir ('DriverAutomation.{0:yyyyMMdd-HHmmss}.json' -f (Get-Date))
    Copy-Item -LiteralPath $configPath -Destination $backup -Force
    Write-Step "Configuration saved to $backup (reinstall with -ConfigFile '$backup')."
}

# ---- 3. Program folder ------------------------------------------------------------------------
if (Test-Path -LiteralPath $InstallPath) {
    # The folder can't be removed while it is the current location (for example when this script runs from it).
    if ((Get-Location).ProviderPath.StartsWith($InstallPath, [StringComparison]::OrdinalIgnoreCase)) { Set-Location -LiteralPath $env:TEMP }
    Remove-Item -LiteralPath $InstallPath -Recurse -Force
    Write-Step "Removed $InstallPath."
}

# ---- 4. Data (only with -RemoveData) -----------------------------------------------------------
if ($RemoveData) {
    if ($dataRootExists) {
        foreach ($f in $dataFolders) {
            $dir = Join-Path $dataRoot $f
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force; Write-Step "Removed $dir." }
        }
        if (@(Get-ChildItem -LiteralPath $dataRoot -Force).Count -eq 0 -and $dataRoot.TrimEnd('\').Length -gt 3) {
            Remove-Item -LiteralPath $dataRoot -Force
            Write-Step "Removed $dataRoot."
        } else {
            Write-Step "Left $dataRoot in place: it contains other files."
        }
    }
    if ([System.Diagnostics.EventLog]::SourceExists($eventSource)) {
        [System.Diagnostics.EventLog]::DeleteEventSource($eventSource)
        Write-Step "Removed event log source '$eventSource'."
    }
}

Write-Host ''
Write-Step 'SCCMDriverAutomation was uninstalled.'
Write-Host '  ConfigMgr packages and the package source share were not changed. Delete them when task sequences no longer use them.'
if ($dataRootExists -and -not $RemoveData) { Write-Host "  Logs and ledgers are still in $dataRoot." }
