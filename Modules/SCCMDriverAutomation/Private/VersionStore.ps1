#region Version store
<#
    One JSON ledger per target (model + OS + architecture) under <DataRoot>\State. It is the source of
    truth for:

        Packages   ConfigMgr PackageID per ring (Production / Pilot)
        Deployed   VersionId currently referenced by each ring's package
        Holds      Rings frozen by an administrator (no automatic changes)
        Versions   Every version ever staged: vendor version, hashes, source URL, staged path, status
                   (Available | Blocked | Pruned)
        History    Append-only audit trail of Stage / Deploy / Promote / Rollback / Block / Unblock /
                   Hold / Release / Prune actions with the initiating identity

    Writes are atomic (temp file + File.Replace with a .bak), and every process that changes state or
    ConfigMgr objects holds a machine-wide mutex so the scheduled run and an administrator's rollback
    can never interleave.
#>

$script:SDAStateSchemaVersion = 1
$script:SDAMutexName = 'Global\SCCMDriverAutomation'
$script:SDARings = @('Production', 'Pilot')

function Enter-SDALock {
    <#
    .SYNOPSIS
        Acquires the machine-wide run lock. Returns the mutex, or throws on timeout.
    #>
    [CmdletBinding()]
    param ([int]$TimeoutMinutes = 30)

    $mutex = New-Object System.Threading.Mutex($false, $script:SDAMutexName)
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes($TimeoutMinutes))
    } catch [System.Threading.AbandonedMutexException] {
        # A previous holder died without releasing. Ownership transfers to us; state writes are atomic
        # so the ledger is still consistent.
        Write-SDALog 'Previous run terminated without releasing the lock - continuing (state files are written atomically).' -Severity Warning
        $acquired = $true
    }
    if (-not $acquired) {
        $mutex.Dispose()
        throw "Another SCCMDriverAutomation process still holds the lock after $TimeoutMinutes minute(s)."
    }
    return $mutex
}

function Exit-SDALock {
    [CmdletBinding()]
    param ($Mutex)

    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch { }
    try { $Mutex.Dispose() } catch { }
}

function Get-SDAInitiator {
    [CmdletBinding()]
    param ()
    return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Get-SDAStatePath {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$Key
    )
    return (Join-Path -Path $Config.Paths.State -ChildPath "$Key.json")
}

function New-SDAState {
    [CmdletBinding()]
    param ([Parameter(Mandatory)]$Target)

    return [ordered]@{
        SchemaVersion = $script:SDAStateSchemaVersion
        Key           = $Target.Key
        Vendor        = $Target.Vendor
        Model         = $Target.Model
        OSName        = $Target.OSName
        OSBuild       = $Target.OSBuild
        Architecture  = $Target.Architecture
        Packages      = [ordered]@{ Production = $null; Pilot = $null }
        Deployed      = [ordered]@{ Production = $null; Pilot = $null }
        Holds         = [ordered]@{ Production = $null; Pilot = $null }
        Versions      = @()
        History       = @()
        LastChecked   = $null
        LastCatalog   = $null
    }
}

function Get-SDAState {
    <#
    .SYNOPSIS
        Loads the ledger for a target, creating an empty one in memory if none exists yet.
        Falls back to the .bak copy if the primary file is unreadable.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)]$Target
    )

    $path = Get-SDAStatePath -Config $Config -Key $Target.Key
    foreach ($candidate in @($path, "$path.bak")) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $state = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json | ConvertTo-SDAHashtable
            if ($candidate -ne $path) { Write-SDALog "State file '$path' unreadable - recovered from backup." -Severity Warning }
            return (Repair-SDAState -State $state -Target $Target)
        } catch {
            Write-SDALog "Unable to read state file '$candidate': $($_.Exception.Message)" -Severity Warning
        }
    }
    if (Test-Path -LiteralPath $path) {
        throw "State file '$path' exists but neither it nor its backup could be parsed. Fix or remove it manually - refusing to overwrite version history."
    }
    return (New-SDAState -Target $Target)
}

function Repair-SDAState {
    <#
    .SYNOPSIS
        Normalises a loaded ledger (missing keys, single objects that should be arrays).
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)]$State, $Target)

    $template = if ($Target) { New-SDAState -Target $Target } else { New-SDAState -Target ([pscustomobject]@{ Key = $State.Key; Vendor = $State.Vendor; Model = $State.Model; OSName = $State.OSName; OSBuild = $State.OSBuild; Architecture = $State.Architecture }) }
    foreach ($key in $template.Keys) {
        if (-not $State.Contains($key)) { $State[$key] = $template[$key] }
    }
    foreach ($dictKey in @('Packages', 'Deployed', 'Holds')) {
        if ($null -eq $State[$dictKey]) { $State[$dictKey] = [ordered]@{} }
        foreach ($ring in $script:SDARings) {
            if (-not $State[$dictKey].Contains($ring)) { $State[$dictKey][$ring] = $null }
        }
    }
    $State.Versions = @($State.Versions | Where-Object { $null -ne $_ })
    $State.History  = @($State.History  | Where-Object { $null -ne $_ })
    return $State
}

function Save-SDAState {
    <#
    .SYNOPSIS
        Atomically persists a ledger (temp file + File.Replace, keeping a .bak of the previous copy).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State
    )

    if (-not (Test-Path -LiteralPath $Config.Paths.State)) {
        New-Item -Path $Config.Paths.State -ItemType Directory -Force | Out-Null
    }
    $path = Get-SDAStatePath -Config $Config -Key $State.Key
    $tmp  = "$path.tmp"
    $json = $State | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))

    if (Test-Path -LiteralPath $path) {
        [System.IO.File]::Replace($tmp, $path, "$path.bak")
    } else {
        [System.IO.File]::Move($tmp, $path)
    }
}

function Get-SDAAllStates {
    <#
    .SYNOPSIS
        Loads every ledger in the state folder (used by reporting).
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    if (-not (Test-Path -LiteralPath $Config.Paths.State)) { return @() }
    foreach ($file in (Get-ChildItem -LiteralPath $Config.Paths.State -Filter '*.json' -File)) {
        try {
            $state = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json | ConvertTo-SDAHashtable
            Repair-SDAState -State $state
        } catch {
            Write-SDALog "Skipping unreadable state file '$($file.FullName)': $($_.Exception.Message)" -Severity Warning
        }
    }
}

function Add-SDAHistory {
    <#
    .SYNOPSIS
        Appends an audit record to the ledger.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][ValidateSet('Stage', 'Deploy', 'Promote', 'Rollback', 'Block', 'Unblock', 'Hold', 'Release', 'Prune', 'Adopt')][string]$Action,
        [string]$Ring,
        [string]$FromVersion,
        [string]$ToVersion,
        [string]$PackageID,
        [string]$Reason
    )

    $entry = [ordered]@{
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Action       = $Action
        Ring         = $Ring
        FromVersion  = $FromVersion
        ToVersion    = $ToVersion
        PackageID    = $PackageID
        Initiator    = Get-SDAInitiator
        Computer     = $env:COMPUTERNAME
        Reason       = $Reason
    }
    $State.History = @($State.History) + $entry
}

function Get-SDAVersionRecord {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$VersionId
    )
    return (@($State.Versions) | Where-Object { $_.VersionId -eq $VersionId } | Select-Object -First 1)
}

function Find-SDAKnownVersion {
    <#
    .SYNOPSIS
        Returns the ledger record matching a catalog entry, or $null if it is a new release.
    .DESCRIPTION
        Identity is the vendor-published hash when available (catches silent re-releases under the same
        version label), otherwise the download URL + vendor version.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)]$CatalogEntry
    )

    foreach ($v in @($State.Versions)) {
        if ($CatalogEntry.Hash -and $v.VendorHash) {
            if ($v.VendorHash -eq $CatalogEntry.Hash) { return $v }
            continue
        }
        if ($v.SourceUrl -eq $CatalogEntry.Url -and $v.VendorVersion -eq $CatalogEntry.VendorVersion) { return $v }
    }
    return $null
}

function Get-SDAUniqueVersionId {
    <#
    .SYNOPSIS
        Returns the catalog VersionId, suffixed with a short hash if that label was already used for a
        different payload (vendors occasionally re-publish a pack without bumping the version).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$VersionId,
        [Parameter(Mandatory)][string]$Sha256
    )

    if (-not (Get-SDAVersionRecord -State $State -VersionId $VersionId)) { return $VersionId }
    $candidate = "$VersionId-$($Sha256.Substring(0, 8).ToLowerInvariant())"
    $n = 2
    while (Get-SDAVersionRecord -State $State -VersionId $candidate) {
        $candidate = "$VersionId-$($Sha256.Substring(0, 8).ToLowerInvariant())-$n"
        $n++
    }
    return $candidate
}

function ConvertTo-SDADate {
    <#
    .SYNOPSIS
        Parses ISO / culture-formatted date strings into [datetime] (returns $null when unparsable).
    #>
    [CmdletBinding()]
    param ($Value)

    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value }
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if ([datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $parsed }
    if ([datetime]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-SDAVersionSortDate {
    <#
    .SYNOPSIS
        Chronological sort key for a version record: vendor release date, falling back to staging time.
    #>
    [CmdletBinding()]
    param ($Version)

    if ($null -eq $Version) { return [datetime]::MinValue }
    $d = ConvertTo-SDADate $Version.ReleaseDate
    if ($null -eq $d) { $d = ConvertTo-SDADate $Version.StagedUtc }
    if ($null -eq $d) { $d = [datetime]::MinValue }
    return $d
}

function Test-SDAVersionNewer {
    <#
    .SYNOPSIS
        $true when Candidate is chronologically newer than Current (or Current is $null).
    #>
    [CmdletBinding()]
    param ($Candidate, $Current)

    if ($null -eq $Current) { return $true }
    if ($null -eq $Candidate) { return $false }
    $c = Get-SDAVersionSortDate $Candidate
    $p = Get-SDAVersionSortDate $Current
    if ($c -ne $p) { return ($c -gt $p) }
    return ((ConvertTo-SDADate $Candidate.StagedUtc) -gt (ConvertTo-SDADate $Current.StagedUtc))
}

function Get-SDARingDeployedUtc {
    <#
    .SYNOPSIS
        When the given version was most recently put into the given ring.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$Ring,
        [Parameter(Mandatory)][string]$VersionId
    )

    $entry = @($State.History) |
        Where-Object { $_.Ring -eq $Ring -and $_.ToVersion -eq $VersionId -and $_.Action -in @('Deploy', 'Promote', 'Rollback', 'Adopt') } |
        Select-Object -Last 1
    if ($entry) { return (ConvertTo-SDADate $entry.TimestampUtc) }
    return $null
}

function Test-SDAVersionUsable {
    <#
    .SYNOPSIS
        $true when a version record is Available (not Blocked/Pruned) and its staged content still exists.
    #>
    [CmdletBinding()]
    param ($Version)

    if ($null -eq $Version) { return $false }
    if ($Version.Status -ne 'Available') { return $false }
    if ([string]::IsNullOrWhiteSpace($Version.StagedPath)) { return $false }
    if (-not (Test-Path -LiteralPath $Version.StagedPath)) { return $false }
    return (@(Get-ChildItem -LiteralPath $Version.StagedPath -Force -ErrorAction SilentlyContinue).Count -gt 0)
}

function Get-SDARollbackCandidate {
    <#
    .SYNOPSIS
        Finds the version that was deployed to a ring immediately before the current one and is still usable.
    .DESCRIPTION
        Walks the ring's deployment history newest-first, skipping the current version and anything that
        has since been blocked or pruned. Falls back to the newest usable staged version older than the
        current one if the history has no suitable entry (e.g. the ring only ever had one deployment).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][ValidateSet('Production', 'Pilot')][string]$Ring
    )

    $current = $State.Deployed[$Ring]
    $events = @(@($State.History) | Where-Object { $_.Ring -eq $Ring -and $_.Action -in @('Deploy', 'Promote', 'Rollback', 'Adopt') })
    [array]::Reverse($events)
    foreach ($e in $events) {
        if ([string]::IsNullOrEmpty($e.ToVersion) -or $e.ToVersion -eq $current) { continue }
        $record = Get-SDAVersionRecord -State $State -VersionId $e.ToVersion
        if (Test-SDAVersionUsable -Version $record) { return $record }
    }

    $currentRecord = if ($current) { Get-SDAVersionRecord -State $State -VersionId $current } else { $null }
    return (@($State.Versions) |
        Where-Object { $_.VersionId -ne $current -and (Test-SDAVersionUsable -Version $_) -and -not (Test-SDAVersionNewer -Candidate $_ -Current $currentRecord) } |
        Sort-Object -Property @{ Expression = { Get-SDAVersionSortDate $_ } } -Descending |
        Select-Object -First 1)
}

#endregion Version store
