#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs SCCMDriverAutomation on the site server and registers the SYSTEM scheduled task.

.DESCRIPTION
    1. Copies the scripts and module to InstallPath and locks the folder down (SYSTEM / Administrators
       full control, Users read & execute). A SYSTEM task must never run code that non-admins can edit.
    2. Deploys the configuration. If an installed configuration already exists and differs, you are
       asked whether to keep it or overwrite it (a backup is kept). -KeepConfig / -Force answer that
       question in advance; non-interactive sessions keep the existing file.
    3. Creates the data root (logs, state, working folders, secrets) with a SYSTEM / Administrators ACL.
    4. Registers the 'SCCMDriverAutomation' Application event log source.
    5. Optionally Authenticode-signs every script with your code-signing certificate, so the task can run
       with -ExecutionPolicy AllSigned (recommended where WDAC / script policies are enforced).
    6. Registers the scheduled task as SYSTEM (no service account, no stored password), and adds a
       Start menu shortcut for the management GUI (Start-DriverAutomationGUI.ps1).
    7. Optionally runs a SYSTEM-context preflight (-RunPreflight), which validates the proxy path, vendor
       catalogs and ConfigMgr permissions exactly as the scheduled task will see them.

.PARAMETER InstallPath
    Program location. Default: C:\Program Files\SCCMDriverAutomation.

.PARAMETER ConfigFile
    Configuration to deploy. Default: Config\DriverAutomation.json next to this script.

.PARAMETER At
    Daily start time (24h, local). Default 02:00. A random delay of up to 30 minutes is added.

.PARAMETER DaysOfWeek
    Run only on these days (weekly trigger). Omit for a daily schedule.

.PARAMETER SigningCertificateThumbprint
    Thumbprint of a code-signing certificate in Cert:\LocalMachine\My or Cert:\CurrentUser\My.

.PARAMETER TimestampServer
    RFC 3161 timestamp server used when signing.

.PARAMETER RunPreflight
    After installation, run Invoke-DriverAutomation.ps1 -PreflightOnly as SYSTEM and show the result.

.PARAMETER KeepConfig
    Keep an existing installed configuration without asking.

.PARAMETER Force
    Overwrite an existing installed configuration without asking. The existing file is backed up to
    Config\DriverAutomation.json.<timestamp>.bak first.

.PARAMETER Uninstall
    Remove the scheduled task and the Start menu shortcut only. To remove the program files (and
    optionally the data), use Uninstall-DriverAutomation.ps1.

.EXAMPLE
    .\Install-DriverAutomation.ps1 -At 01:30 -RunPreflight

.EXAMPLE
    .\Install-DriverAutomation.ps1 -DaysOfWeek Tuesday,Thursday -SigningCertificateThumbprint 1A2B3C... -RunPreflight
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param (
    [Parameter(ParameterSetName = 'Install')][string]$InstallPath = (Join-Path $env:ProgramFiles 'SCCMDriverAutomation'),
    [Parameter(ParameterSetName = 'Install')][string]$ConfigFile,
    [Parameter(ParameterSetName = 'Install')][ValidatePattern('^\d{2}:\d{2}$')][string]$At = '02:00',
    [Parameter(ParameterSetName = 'Install')][System.DayOfWeek[]]$DaysOfWeek,
    [Parameter(ParameterSetName = 'Install')][string]$SigningCertificateThumbprint,
    [Parameter(ParameterSetName = 'Install')][string]$TimestampServer = 'http://timestamp.digicert.com',
    [Parameter(ParameterSetName = 'Install')][switch]$RunPreflight,
    [Parameter(ParameterSetName = 'Install')][switch]$Force,
    [Parameter(ParameterSetName = 'Install')][switch]$KeepConfig,
    [Parameter(ParameterSetName = 'Uninstall')][switch]$Uninstall,
    [string]$TaskName = 'SCCM Driver Automation',
    [string]$TaskPath = '\SCCMDriverAutomation\'
)

$ErrorActionPreference = 'Stop'
# Set here rather than as a parameter default: $PSScriptRoot can be empty there under powershell.exe -File.
if (-not $ConfigFile) { $ConfigFile = Join-Path $PSScriptRoot 'Config\DriverAutomation.json' }
$shortcutPath = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\SCCM Driver Automation.lnk'

function Write-Step ([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }

function Test-InteractiveSession {
    # False for the SYSTEM task, remote sessions without a console and powershell.exe -NonInteractive.
    if (-not [Environment]::UserInteractive) { return $false }
    foreach ($arg in [Environment]::GetCommandLineArgs()) { if ($arg -like '-noni*') { return $false } }
    return $true
}

function Get-ConfigSummary ([string]$Path) {
    # One line describing a configuration file, to help choose between two of them.
    if (-not (Test-Path -LiteralPath $Path)) { return '(file not found)' }
    $item = Get-Item -LiteralPath $Path
    try {
        $doc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $models = @($doc.Models | Where-Object { $_ })
        $names = @($models | Select-Object -First 3 | ForEach-Object { '{0} {1}' -f $_.Vendor, $_.Model })
        $more = if ($models.Count -gt 3) { ", +$($models.Count - 3) more" } else { '' }
        return 'Modified {0:yyyy-MM-dd HH:mm}; data root {1}; {2} model(s): {3}{4}' -f $item.LastWriteTime, $doc.General.DataRoot, $models.Count, ($names -join ', '), $more
    } catch {
        return 'Modified {0:yyyy-MM-dd HH:mm}; not valid JSON ({1})' -f $item.LastWriteTime, $_.Exception.Message
    }
}

if ($Uninstall) {
    # Kept for compatibility: removes the task and shortcut only. Uninstall-DriverAutomation.ps1 removes everything.
    & (Join-Path $PSScriptRoot 'Uninstall-DriverAutomation.ps1') -TaskName $TaskName -TaskPath $TaskPath -KeepProgramFiles -Confirm:$false
    return
}
if ($Force -and $KeepConfig) { throw '-Force and -KeepConfig cannot be used together.' }

# --- 1. Program files ------------------------------------------------------------------------------
Write-Step "Installing to $InstallPath"
if (-not (Test-Path -LiteralPath $InstallPath)) { New-Item -Path $InstallPath -ItemType Directory -Force | Out-Null }

$items = @(
    'Invoke-DriverAutomation.ps1', 'Invoke-DriverRollback.ps1', 'Invoke-DriverPromotion.ps1',
    'Set-DriverDeploymentState.ps1', 'Get-DriverVersionReport.ps1', 'Get-DriverCatalogModels.ps1', 'Set-DriverAutomationProxyCredential.ps1',
    'Start-DriverAutomationGUI.ps1', 'Install-DriverAutomation.ps1', 'Uninstall-DriverAutomation.ps1', 'README.md', 'REQUIREMENTS.md', 'INSTRUCTIONS.md', 'Modules'
)
$samePath = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -eq [System.IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
if (-not $samePath) {
    foreach ($item in $items) {
        $source = Join-Path $PSScriptRoot $item
        if (-not (Test-Path -LiteralPath $source)) { continue }
        Copy-Item -LiteralPath $source -Destination $InstallPath -Recurse -Force
    }
}
# Remove mark-of-the-web so RemoteSigned does not treat copied scripts as downloaded.
Get-ChildItem -LiteralPath $InstallPath -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' | Unblock-File

# Lock the program folder: SYSTEM + Administrators full control, Users read/execute, no inheritance.
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
foreach ($rule in @(
        @{ Sid = 'S-1-5-18';     Rights = 'FullControl' },
        @{ Sid = 'S-1-5-32-544'; Rights = 'FullControl' },
        @{ Sid = 'S-1-5-32-545'; Rights = 'ReadAndExecute' })) {
    $sid = New-Object System.Security.Principal.SecurityIdentifier($rule.Sid)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $rule.Rights, $inherit, 'None', 'Allow')))
}
$acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
Set-Acl -LiteralPath $InstallPath -AclObject $acl

# --- 2. Configuration ------------------------------------------------------------------------------
$configDir = Join-Path $InstallPath 'Config'
$installedConfig = Join-Path $configDir 'DriverAutomation.json'
if (-not (Test-Path -LiteralPath $configDir)) { New-Item -Path $configDir -ItemType Directory -Force | Out-Null }
$sameConfigFile = [System.IO.Path]::GetFullPath($ConfigFile) -eq [System.IO.Path]::GetFullPath($installedConfig)

$deployConfig = $true
if ((Test-Path -LiteralPath $installedConfig) -and -not $sameConfigFile) {
    $identical = (Test-Path -LiteralPath $ConfigFile) -and
        (Get-FileHash -LiteralPath $ConfigFile).Hash -eq (Get-FileHash -LiteralPath $installedConfig).Hash
    if ($identical) {
        $deployConfig = $false
        Write-Step "Existing configuration $installedConfig is identical to $ConfigFile - nothing to change."
    } elseif ($Force) {
        Write-Step 'Existing configuration found; -Force was given, so it will be replaced (a backup is kept).'
    } elseif ($KeepConfig) {
        $deployConfig = $false
        Write-Step "Keeping existing configuration $installedConfig (-KeepConfig)."
    } elseif (-not (Test-InteractiveSession)) {
        $deployConfig = $false
        Write-Step "Keeping existing configuration $installedConfig (non-interactive session; use -Force to overwrite)."
    } else {
        $existing = Get-ConfigSummary -Path $installedConfig
        $incoming = Get-ConfigSummary -Path $ConfigFile
        $message = ("An existing configuration was found:`n  {0}`n  {1}`n`nThe configuration in this installation package is different:`n  {2}`n  {3}`n`n" +
            "Keep the existing configuration, or overwrite it with the package's? Overwriting saves a backup of the existing file first.") -f `
            $installedConfig, $existing, $ConfigFile, $incoming
        $choices = [System.Management.Automation.Host.ChoiceDescription[]]@(
            (New-Object System.Management.Automation.Host.ChoiceDescription '&Keep', 'Keep the existing configuration (recommended when upgrading).'),
            (New-Object System.Management.Automation.Host.ChoiceDescription '&Overwrite', "Replace it with $ConfigFile. The existing file is backed up first."))
        $deployConfig = $Host.UI.PromptForChoice('Existing configuration', $message, $choices, 0) -eq 1
        if (-not $deployConfig) { Write-Step "Keeping existing configuration $installedConfig." }
    }
}

if ($deployConfig -and -not $sameConfigFile) {
    if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "Configuration file not found: $ConfigFile" }
    if (Test-Path -LiteralPath $installedConfig) {
        $backup = '{0}.{1:yyyyMMdd-HHmmss}.bak' -f $installedConfig, (Get-Date)
        Copy-Item -LiteralPath $installedConfig -Destination $backup -Force
        Write-Step "Existing configuration backed up to $backup"
    }
    Copy-Item -LiteralPath $ConfigFile -Destination $installedConfig -Force
    Write-Step "Configuration deployed to $installedConfig"
} elseif (-not (Test-Path -LiteralPath $installedConfig)) {
    throw "Configuration file not found: $installedConfig"
}

Import-Module -Name (Join-Path $InstallPath 'Modules\SCCMDriverAutomation\SCCMDriverAutomation.psd1') -Force -DisableNameChecking
$config = Import-SDAConfig -Path $installedConfig   # validates - throws with a list of problems

# --- 3. Data root ----------------------------------------------------------------------------------
Write-Step "Preparing data root $($config.Paths.DataRoot)"
foreach ($key in @('DataRoot', 'Logs', 'Reports', 'State', 'Catalogs', 'Downloads', 'Extract', 'Secrets')) {
    $dir = $config.Paths[$key]
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
}
Set-SDAProtectedAcl -Path $config.Paths.DataRoot
Get-ChildItem -LiteralPath $config.Paths.DataRoot -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
    # Re-enable inheritance on children so the protected root ACL applies everywhere.
    try {
        $childAcl = Get-Acl -LiteralPath $_.FullName
        if ($childAcl.AreAccessRulesProtected) { $childAcl.SetAccessRuleProtection($false, $false); Set-Acl -LiteralPath $_.FullName -AclObject $childAcl }
    } catch { }
}

# --- 4. Event source -------------------------------------------------------------------------------
Write-Step 'Registering event log source'
Initialize-SDALog -LogDirectory $config.Paths.Logs -FileName 'Install.log' -Component 'Install'
[void](Register-SDAEventSource)

# --- 5. Optional code signing ----------------------------------------------------------------------
$executionPolicy = 'RemoteSigned'
if ($SigningCertificateThumbprint) {
    $thumb = $SigningCertificateThumbprint -replace '\s', ''
    $cert = Get-ChildItem -Path "Cert:\LocalMachine\My\$thumb", "Cert:\CurrentUser\My\$thumb" -ErrorAction SilentlyContinue |
        Where-Object { $_.HasPrivateKey -and ($_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.3') } | Select-Object -First 1
    if (-not $cert) { throw "Code-signing certificate $thumb with a private key was not found in LocalMachine\My or CurrentUser\My." }
    Write-Step "Signing scripts with '$($cert.Subject)'"
    Get-ChildItem -LiteralPath $InstallPath -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' | ForEach-Object {
        $sig = Set-AuthenticodeSignature -FilePath $_.FullName -Certificate $cert -TimestampServer $TimestampServer -HashAlgorithm SHA256
        if ($sig.Status -ne 'Valid') { throw "Signing failed for $($_.FullName): $($sig.StatusMessage)" }
    }
    $executionPolicy = 'AllSigned'
}

# --- 6. Scheduled task -----------------------------------------------------------------------------
Write-Step "Registering scheduled task '$TaskPath$TaskName' (SYSTEM)"
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$scriptPath = Join-Path $InstallPath 'Invoke-DriverAutomation.ps1'
# Plain, readable command line: no -EncodedCommand, no hidden window tricks, no -ExecutionPolicy Bypass.
# These are exactly the patterns EDR products flag, and none are needed here.
$arguments = '-NoProfile -NonInteractive -ExecutionPolicy {0} -File "{1}" -ConfigPath "{2}"' -f $executionPolicy, $scriptPath, $installedConfig
$action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -WorkingDirectory $InstallPath

$time = [datetime]::ParseExact($At, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
$trigger = if ($DaysOfWeek) {
    New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DaysOfWeek -At $time -RandomDelay (New-TimeSpan -Minutes 30)
} else {
    New-ScheduledTaskTrigger -Daily -At $time -RandomDelay (New-TimeSpan -Minutes 30)
}
$principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 12) -MultipleInstances IgnoreNew `
    -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Priority 7

$task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description 'Downloads Dell/HP/Lenovo driver packs, stages versioned content and updates ConfigMgr driver packages. Logs: see General.DataRoot\Logs.'
Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -InputObject $task -Force | Out-Null
Write-SDALog "Scheduled task '$TaskPath$TaskName' registered: $powershell $arguments"

# Start menu shortcut for the management GUI (all users; the GUI asks for elevation itself).
$guiScript = Join-Path $InstallPath 'Start-DriverAutomationGUI.ps1'
if (Test-Path -LiteralPath $guiScript) {
    Write-Step 'Adding Start menu shortcut for the management GUI'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $powershell
    $shortcut.Arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy {0} -File "{1}" -ConfigPath "{2}"' -f $executionPolicy, $guiScript, $installedConfig
    $shortcut.WorkingDirectory = $InstallPath
    $shortcut.IconLocation = "$powershell,0"
    $shortcut.Description = 'Manage SCCM driver automation: versions, rollback, configuration and logs'
    $shortcut.Save()
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
}

# --- 7. Optional SYSTEM preflight ------------------------------------------------------------------
if ($RunPreflight) {
    Write-Step 'Running preflight as SYSTEM (this validates proxy, catalogs and ConfigMgr rights as the task will see them)'
    $preTask = 'SCCM Driver Automation - Preflight'
    $preArgs = '-NoProfile -NonInteractive -ExecutionPolicy {0} -File "{1}" -ConfigPath "{2}" -PreflightOnly' -f $executionPolicy, $scriptPath, $installedConfig
    $pre = New-ScheduledTask -Action (New-ScheduledTaskAction -Execute $powershell -Argument $preArgs -WorkingDirectory $InstallPath) `
        -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30))
    Register-ScheduledTask -TaskName $preTask -TaskPath $TaskPath -InputObject $pre -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName $preTask -TaskPath $TaskPath
        $deadline = (Get-Date).AddMinutes(30)
        do {
            Start-Sleep -Seconds 5
            $info = Get-ScheduledTask -TaskName $preTask -TaskPath $TaskPath
        } while ($info.State -eq 'Running' -and (Get-Date) -lt $deadline)
        $lastResult = (Get-ScheduledTaskInfo -TaskName $preTask -TaskPath $TaskPath).LastTaskResult
        $logFile = Join-Path $config.Paths.Logs 'DriverAutomation.log'
        if (Test-Path -LiteralPath $logFile) {
            Write-Host "`n--- Last log entries ($logFile) ---" -ForegroundColor DarkGray
            Get-Content -LiteralPath $logFile -Tail 25 | ForEach-Object { if ($_ -match '<!\[LOG\[(.*)\]LOG\]!>') { $Matches[1] } else { $_ } } | Write-Host
        }
        if ($lastResult -eq 0) {
            Write-Step 'Preflight PASSED as SYSTEM.'
        } else {
            Write-Host "Preflight FAILED as SYSTEM (exit code $lastResult). Review the log above - typical causes: proxy 407 for the computer account, missing ConfigMgr RBAC for the computer account, share permissions on PackageSourceUncRoot." -ForegroundColor Red
        }
    } finally {
        Unregister-ScheduledTask -TaskName $preTask -TaskPath $TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Step 'Installation complete. Next steps:'
Write-Host ("  - Grant ConfigMgr rights to the computer account {0}\{1}$ (see REQUIREMENTS.md 'ConfigMgr permissions')." -f $env:USERDOMAIN, $env:COMPUTERNAME)
Write-Host ('  - Test without changes:   & "{0}" -DryRun' -f $scriptPath)
Write-Host  "  - Management GUI:         Start menu > SCCM Driver Automation"
Write-Host ("  - Run the task now:       Start-ScheduledTask -TaskPath '{0}' -TaskName '{1}'" -f $TaskPath, $TaskName)
Write-Host ("  - Logs:                   {0}" -f $config.Paths.Logs)
