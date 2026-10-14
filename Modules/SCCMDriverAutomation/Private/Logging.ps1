#region Logging
<#
    Writes CMTrace-compatible log lines so the output can be read with CMTrace / OneTrace next to
    the native ConfigMgr logs. Important outcomes are also written to the Application event log
    so they can be picked up by SCOM / Sentinel / any event forwarding already in place.
#>

$script:SDALogState = @{
    Path        = $null
    MaxBytes    = 10MB
    History     = 5
    Component   = 'SCCMDriverAutomation'
    EventSource = 'SCCMDriverAutomation'
    Identity    = $null
}

function Initialize-SDALog {
    <#
    .SYNOPSIS
        Sets the log file location and rollover policy for the current process.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$LogDirectory,
        [string]$FileName = 'DriverAutomation.log',
        [ValidateRange(1, 500)][int]$MaxSizeMB = 10,
        [ValidateRange(1, 100)][int]$History = 5,
        [string]$Component = 'SCCMDriverAutomation'
    )

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }
    $script:SDALogState.Path      = Join-Path -Path $LogDirectory -ChildPath $FileName
    $script:SDALogState.MaxBytes  = [int64]$MaxSizeMB * 1MB
    $script:SDALogState.History   = $History
    $script:SDALogState.Component = $Component
    $script:SDALogState.Identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Invoke-SDALogRollover {
    <#
    .SYNOPSIS
        Renames the active log once it exceeds the size limit and prunes old rolled logs.
    #>
    [CmdletBinding()]
    param ()

    $path = $script:SDALogState.Path
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return }

    try {
        $item = Get-Item -LiteralPath $path
        if ($item.Length -lt $script:SDALogState.MaxBytes) { return }

        $stamp   = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $rolled  = Join-Path -Path $item.DirectoryName -ChildPath ("{0}-{1}{2}" -f $item.BaseName, $stamp, $item.Extension)
        Move-Item -LiteralPath $path -Destination $rolled -Force

        $pattern = "{0}-*{1}" -f $item.BaseName, $item.Extension
        Get-ChildItem -Path $item.DirectoryName -Filter $pattern -File |
            Sort-Object -Property LastWriteTime -Descending |
            Select-Object -Skip $script:SDALogState.History |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        # Never let log housekeeping break the run.
    }
}

function Write-SDALog {
    <#
    .SYNOPSIS
        Writes a CMTrace-format log entry (and echoes it to the console when interactive).
    .PARAMETER Severity
        Info, Warning or Error (CMTrace type 1, 2, 3).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Severity = 'Info',
        [string]$Component
    )

    if ([string]::IsNullOrEmpty($Component)) { $Component = $script:SDALogState.Component }
    $type = switch ($Severity) { 'Warning' { 2 } 'Error' { 3 } default { 1 } }

    $now      = Get-Date
    # CMTrace bias is the number of minutes to ADD to local time to get UTC.
    $bias     = -[int][System.TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes
    $biasText = if ($bias -ge 0) { "+$bias" } else { "$bias" }
    $identity = if ($script:SDALogState.Identity) { $script:SDALogState.Identity } else { '' }

    $line = '<![LOG[{0}]LOG]!><time="{1}{2}" date="{3}" component="{4}" context="{5}" type="{6}" thread="{7}" file="">' -f `
        $Message, $now.ToString('HH:mm:ss.fff'), $biasText, $now.ToString('MM-dd-yyyy'), $Component, $identity, $type, $PID

    if ($script:SDALogState.Path) {
        Invoke-SDALogRollover
        # Retry briefly: an admin may have the log open in CMTrace, which can hold a share lock.
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                [System.IO.File]::AppendAllText($script:SDALogState.Path, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
                break
            } catch {
                Start-Sleep -Milliseconds 150
            }
        }
    }

    if ([Environment]::UserInteractive) {
        $colour = switch ($Severity) { 'Warning' { 'Yellow' } 'Error' { 'Red' } default { 'Gray' } }
        Write-Host ("[{0}] [{1}] {2}" -f $now.ToString('HH:mm:ss'), $Component, $Message) -ForegroundColor $colour
    }
}

function Format-SDAError {
    <#
    .SYNOPSIS
        Produces a single-line description of an ErrorRecord including the failing script line.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $message = $ErrorRecord.Exception.Message
    $inner   = $ErrorRecord.Exception.InnerException
    while ($null -ne $inner) {
        $message += " --> $($inner.Message)"
        $inner = $inner.InnerException
    }
    $position = ''
    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.ScriptName) {
        $position = " [{0}:{1}]" -f (Split-Path -Leaf $ErrorRecord.InvocationInfo.ScriptName), $ErrorRecord.InvocationInfo.ScriptLineNumber
    }
    return "$message$position"
}

function Register-SDAEventSource {
    <#
    .SYNOPSIS
        Registers the Application event log source (requires administrative rights).
    #>
    [CmdletBinding()]
    param ([string]$Source = $script:SDALogState.EventSource)

    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($Source)) {
            New-EventLog -LogName Application -Source $Source
        }
        return $true
    } catch {
        Write-SDALog "Unable to register event source '$Source': $($_.Exception.Message)" -Severity Warning
        return $false
    }
}

function Write-SDAEvent {
    <#
    .SYNOPSIS
        Writes to the Application event log. Silently degrades if the source is not registered.
    .NOTES
        Event IDs: 1000 run succeeded, 1001 run completed with warnings / partial failures,
                   1002 run failed, 1100 deployment change (deploy / promote), 1101 rollback,
                   1102 ledger control change (block / unblock / hold / release).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][int]$EventId,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Information', 'Warning', 'Error')][string]$EntryType = 'Information'
    )

    try {
        if ([System.Diagnostics.EventLog]::SourceExists($script:SDALogState.EventSource)) {
            # Event log messages are capped at ~31k characters.
            if ($Message.Length -gt 30000) { $Message = $Message.Substring(0, 30000) + '...' }
            Write-EventLog -LogName Application -Source $script:SDALogState.EventSource -EventId $EventId -EntryType $EntryType -Message $Message
        }
    } catch {
        Write-SDALog "Unable to write event log entry $EventId : $($_.Exception.Message)" -Severity Warning
    }
}

#endregion Logging
