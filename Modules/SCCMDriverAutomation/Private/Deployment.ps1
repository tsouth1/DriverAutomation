#region Deployment
<#
    Orchestration built on the lower layers. The single primitive that changes what devices receive is
    Publish-SDAVersion: "make ring R of target T serve version V". Scheduled updates, promotions and
    rollbacks are all expressed through it, so they share the same validation, ConfigMgr calls, ledger
    update and audit trail.
#>

function Find-SDATarget {
    <#
    .SYNOPSIS
        Resolves a target from administrator-supplied values (used by the rollback / promotion scripts).
    .DESCRIPTION
        Looks in the configuration first; falls back to existing ledgers so a model that has since been
        removed from the configuration can still be rolled back.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$Vendor,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$OSName,
        [string]$OSBuild,
        [string]$Architecture = 'x64'
    )

    $found = @($Config.Targets | Where-Object {
        $_.Vendor -eq $Vendor -and $_.Model -eq $Model -and $_.OSName -eq $OSName -and $_.Architecture -eq $Architecture -and
        ([string]::IsNullOrEmpty($OSBuild) -or $_.OSBuild -eq $OSBuild)
    })
    if ($found.Count -eq 1) { return $found[0] }
    if ($found.Count -gt 1) {
        throw "Several configured targets match $Vendor $Model $OSName $Architecture (builds: $(($found.OSBuild) -join ', ')). Specify -OSBuild."
    }

    $states = @(Get-SDAAllStates -Config $Config | Where-Object {
        $_.Vendor -eq $Vendor -and $_.Model -eq $Model -and $_.OSName -eq $OSName -and $_.Architecture -eq $Architecture -and
        ([string]::IsNullOrEmpty($OSBuild) -or $_.OSBuild -eq $OSBuild)
    })
    if ($states.Count -eq 1) {
        $s = $states[0]
        $target = [pscustomobject]@{
            Vendor = $s.Vendor; Model = $s.Model; SystemIds = @(); OSName = $s.OSName; OSBuild = $s.OSBuild
            Architecture = $s.Architecture; Enabled = $false; Key = $s.Key; DisplayName = $null
        }
        $target.DisplayName = ("{0} {1} - {2}{3} {4}" -f $s.Vendor, $s.Model, $s.OSName, $(if ($s.OSBuild) { " $($s.OSBuild)" } else { '' }), $s.Architecture)
        Write-SDALog "Target $($target.DisplayName) is not in the configuration - using its existing ledger." -Severity Warning
        return $target
    }
    if ($states.Count -gt 1) { throw "Several ledgers match $Vendor $Model $OSName $Architecture. Specify -OSBuild." }
    throw "No configured target or ledger found for $Vendor '$Model' $OSName $OSBuild $Architecture."
}

function Resolve-SDARingPackage {
    <#
    .SYNOPSIS
        Returns the PackageID that a ring of a target is managed through, or $null if none exists yet.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$Ring
    )

    $known = $State.Packages[$Ring]
    if ($known -and $known.PackageID) {
        if (Get-SDAPackageById -Context $Context -PackageID $known.PackageID) { return $known.PackageID }
        Write-SDALog "Package $($known.PackageID) recorded for $Ring no longer exists in ConfigMgr - it will be recreated." -Severity Warning
        $State.Packages[$Ring] = $null
    }

    $name = Get-SDAPackageName -Config $Config -Target $Target -Ring $Ring
    $existing = @(Get-SDAPackagesByName -Context $Context -Name $name)
    if ($existing.Count -eq 0) { return $null }
    if ($existing.Count -gt 1) {
        throw "Found $($existing.Count) packages named '$name' ($(($existing.PackageID) -join ', ')). Remove the duplicates (e.g. legacy per-version packages) before this target can be managed."
    }
    if (-not $Config.ConfigMgr.AdoptExistingPackages) {
        throw "A package named '$name' ($($existing[0].PackageID)) already exists but is not managed by this tool. Rename/remove it, or set ConfigMgr.AdoptExistingPackages = true to take it over."
    }

    $State.Packages[$Ring] = [ordered]@{ PackageID = $existing[0].PackageID; Name = $name }
    Add-SDAHistory -State $State -Action 'Adopt' -Ring $Ring -PackageID $existing[0].PackageID -Reason "Adopted existing package (previous source: $($existing[0].PkgSourcePath), version: $($existing[0].Version))"
    Write-SDALog "Adopted existing package $($existing[0].PackageID) '$name' for the $Ring ring." -Severity Warning
    return $existing[0].PackageID
}

function Publish-SDAVersion {
    <#
    .SYNOPSIS
        Makes a ring of a target serve a specific staged version (creating the package if needed).
    .DESCRIPTION
        Validates the version is Available and its content exists, creates or re-points the ring's
        package, updates the ledger (Deployed + History), saves it immediately and writes an event.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][ValidateSet('Production', 'Pilot')][string]$Ring,
        [Parameter(Mandatory)][string]$VersionId,
        [Parameter(Mandatory)][ValidateSet('Deploy', 'Promote', 'Rollback')][string]$Action,
        [string]$Reason
    )

    $record = Get-SDAVersionRecord -State $State -VersionId $VersionId
    if (-not $record) { throw "Version '$VersionId' is not in the ledger for $($Target.DisplayName)." }
    if ($record.Status -eq 'Blocked') { throw "Version '$VersionId' is blocked ($($record.BlockedReason)). Unblock it first with Set-DriverDeploymentState.ps1." }
    if (-not (Test-SDAVersionUsable -Version $record)) { throw "Version '$VersionId' content is not available (status $($record.Status), path '$($record.StagedPath)')." }

    $from = $State.Deployed[$Ring]
    $name = Get-SDAPackageName -Config $Config -Target $Target -Ring $Ring
    $description = Get-SDAPackageDescription -Target $Target -SystemIds @($record.SystemIds)
    $versionLabel = $record.VersionId

    Write-SDALog ("{0}: {1} ring {2} -> {3} ({4})" -f $Action, $Target.DisplayName, $(if ($from) { $from } else { '<none>' }), $VersionId, $Ring)
    $packageId = Resolve-SDARingPackage -Context $Context -Config $Config -State $State -Target $Target -Ring $Ring
    if ($packageId) {
        Set-SDAPackageSource -Context $Context -PackageID $packageId -SourcePath $record.StagedUnc -Version $versionLabel -Description $description
    } else {
        $packageId = New-SDAPackage -Context $Context -Config $Config -Target $Target -Name $name -SourcePath $record.StagedUnc -Version $versionLabel -Description $description -Ring $Ring
    }

    $State.Packages[$Ring] = [ordered]@{ PackageID = $packageId; Name = $name }
    $State.Deployed[$Ring] = $VersionId
    Add-SDAHistory -State $State -Action $Action -Ring $Ring -FromVersion $from -ToVersion $VersionId -PackageID $packageId -Reason $Reason
    Save-SDAState -Config $Config -State $State

    $eventId = if ($Action -eq 'Rollback') { 1101 } else { 1100 }
    $entryType = if ($Action -eq 'Rollback') { 'Warning' } else { 'Information' }
    Write-SDAEvent -EventId $eventId -EntryType $entryType -Message ("{0} {1}: {2} ring of {3} changed from {4} to {5} (package {6}) by {7}. Reason: {8}" -f `
        $Action, $(if ($Action -eq 'Rollback') { 'performed' } else { 'completed' }), $Ring, $Target.DisplayName, $(if ($from) { $from } else { '<none>' }), $VersionId, $packageId, (Get-SDAInitiator), $Reason)
    return $packageId
}

function Import-SDAVersion {
    <#
    .SYNOPSIS
        Download -> verify -> scan -> extract -> validate -> build immutable version folder -> ledger.
    .OUTPUTS
        The new version record.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)]$CatalogEntry
    )

    $minFree = [int]$Config.General.MinimumFreeSpaceGB
    [void](Test-SDAFreeSpace -Path $Config.Paths.DataRoot -MinimumGB $minFree)
    [void](Test-SDAFreeSpace -Path $Config.ConfigMgr.PackageSourceLocalRoot -MinimumGB $minFree)

    $downloadDir = Join-Path $Config.Paths.Downloads (Join-Path $Target.Key $CatalogEntry.VersionId)
    $payload = Join-Path $downloadDir $CatalogEntry.FileName
    $extract = Join-Path $Config.Paths.Extract ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $succeeded = $false

    try {
        Invoke-SDADownload -Url $CatalogEntry.Url -DestinationPath $payload -ExpectedSize $CatalogEntry.SizeBytes | Out-Null

        try {
            $integrity = Assert-SDAPayloadIntegrity -Path $payload -CatalogEntry $CatalogEntry -Config $Config
        } catch {
            # Never keep (or resume from) a payload that failed verification.
            Remove-Item -LiteralPath $payload -Force -ErrorAction SilentlyContinue
            throw
        }
        if ($Config.Security.DefenderScan) { Invoke-SDADefenderScan -Path $payload }

        Expand-SDADriverPackage -Vendor $Target.Vendor -Path $payload -Destination $extract -Config $Config -TimeoutMinutes ([int]$Config.Extraction.TimeoutMinutes)
        if ($Config.Security.DefenderScan) { Invoke-SDADefenderScan -Path $extract }

        $info = Get-SDADriverContentInfo -Path $extract
        Write-SDALog ("Extracted {0:N0} files, {1:N0} INF, {2:N0} MB." -f $info.FileCount, $info.InfCount, ($info.SizeBytes / 1MB))
        if ($info.LongPathFiles -gt 0 -and $Config.ConfigMgr.ContentFormat -eq 'WIM') {
            $longPaths = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -ErrorAction SilentlyContinue).LongPathsEnabled
            if ($longPaths -ne 1) {
                throw "$($info.LongPathFiles) extracted file(s) exceed 260 characters and DISM would silently omit them. Enable LongPathsEnabled, or shorten General.DataRoot."
            }
        }

        # Choose a version id / folder that is unique for this payload. If a folder already exists with
        # the same payload hash (e.g. ledger restored from backup) it is reused rather than rebuilt.
        $versionId = Get-SDAUniqueVersionId -State $State -VersionId $CatalogEntry.VersionId -Sha256 $integrity.Sha256
        $paths = Get-SDAVersionPaths -Config $Config -Target $Target -VersionId $versionId
        $reuse = $false
        $suffix = 1
        while (Test-Path -LiteralPath $paths.Local) {
            $manifestPath = Join-Path $paths.Local 'DriverManifest.json'
            $existingHash = $null
            if (Test-Path -LiteralPath $manifestPath) {
                try { $existingHash = (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).PayloadSha256 } catch { }
            }
            if ($existingHash -eq $integrity.Sha256) {
                Write-SDALog "Version folder $($paths.Local) already holds this payload - reusing it." -Severity Warning
                $reuse = $true
                break
            }
            $suffix++
            $versionId = "{0}-{1}-{2}" -f $CatalogEntry.VersionId, $integrity.Sha256.Substring(0, 8).ToLowerInvariant(), $suffix
            $paths = Get-SDAVersionPaths -Config $Config -Target $Target -VersionId $versionId
        }

        if (-not $reuse) {
            $manifest = [ordered]@{
                Tool             = 'SCCMDriverAutomation'
                Vendor           = $Target.Vendor
                Model            = $Target.Model
                CatalogModelName = $CatalogEntry.CatalogModelName
                OperatingSystem  = $Target.OSName
                OSBuild          = $Target.OSBuild
                Architecture     = $Target.Architecture
                VersionId        = $versionId
                VendorVersion    = $CatalogEntry.VendorVersion
                ReleaseDate      = $CatalogEntry.ReleaseDate
                SystemIds        = @($CatalogEntry.SystemIds)
                SourceUrl        = $CatalogEntry.Url
                PayloadFile      = $CatalogEntry.FileName
                PayloadSha256    = $integrity.Sha256
                VendorHash       = $CatalogEntry.Hash
                VendorHashAlgo   = $integrity.VendorHashAlgo
                Signature        = $integrity.Signature
                Signer           = $integrity.Signer
                InfCount         = $info.InfCount
                FileCount        = $info.FileCount
                ExtractedBytes   = $info.SizeBytes
                StagedUtc        = (Get-Date).ToUniversalTime().ToString('o')
                StagedBy         = Get-SDAInitiator
                StagedOn         = $env:COMPUTERNAME
            }
            New-SDAPackageContent -Config $Config -ExtractPath $extract -VersionPath $paths.Local -ImageName ("{0} {1} {2}" -f $Target.Vendor, $Target.Model, $versionId) -Manifest $manifest
        }

        $record = [ordered]@{
            VersionId        = $versionId
            VendorVersion    = $CatalogEntry.VendorVersion
            ReleaseDate      = $CatalogEntry.ReleaseDate
            CatalogModelName = $CatalogEntry.CatalogModelName
            SystemIds        = @($CatalogEntry.SystemIds)
            SourceUrl        = $CatalogEntry.Url
            FileName         = $CatalogEntry.FileName
            VendorHash       = $CatalogEntry.Hash
            Sha256           = $integrity.Sha256
            Signature        = $integrity.Signature
            Signer           = $integrity.Signer
            ContentFormat    = $Config.ConfigMgr.ContentFormat
            InfCount         = $info.InfCount
            ExtractedBytes   = $info.SizeBytes
            StagedPath       = $paths.Local
            StagedUnc        = $paths.Unc
            StagedUtc        = (Get-Date).ToUniversalTime().ToString('o')
            Status           = 'Available'
            BlockedReason    = $null
        }
        $State.Versions = @($State.Versions) + $record
        Add-SDAHistory -State $State -Action 'Stage' -ToVersion $versionId -Reason "Vendor version $($CatalogEntry.VendorVersion) released $($CatalogEntry.ReleaseDate)"
        Save-SDAState -Config $Config -State $State
        Write-SDALog "Staged version $versionId at $($paths.Local)."
        $succeeded = $true
        return $record
    } finally {
        if (Test-Path -LiteralPath $extract) {
            try { Remove-SDAPath -Path $extract -Config $Config } catch { Write-SDALog "Could not clean extraction folder '$extract': $($_.Exception.Message)" -Severity Warning }
        }
        # Keep a failed download so the next run can resume it; remove it after a successful stage.
        if ($succeeded -and -not $Config.General.KeepDownloads -and (Test-Path -LiteralPath $downloadDir)) {
            try { Remove-SDAPath -Path $downloadDir -Config $Config } catch { Write-SDALog "Could not clean download folder '$downloadDir': $($_.Exception.Message)" -Severity Warning }
        }
    }
}

function Invoke-SDATargetUpdate {
    <#
    .SYNOPSIS
        Full scheduled pipeline for one target: catalog check, stage new release, deploy to the entry
        ring, optional seed / auto-promotion to Production, retention.
    .PARAMETER DryRun
        Read-only: reports what would happen; no downloads, no ConfigMgr or ledger changes.
    .OUTPUTS
        Result object for the run report.
    #>
    [CmdletBinding()]
    param (
        $Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)]$Target,
        [switch]$DryRun
    )

    $result = [pscustomobject]@{
        Target            = $Target.DisplayName
        Key               = $Target.Key
        Status            = 'UpToDate'
        CatalogVersion    = $null
        CatalogDate       = $null
        ProductionVersion = $null
        PilotVersion      = $null
        Actions           = New-Object System.Collections.Generic.List[string]
        Message           = ''
    }

    $state = Get-SDAState -Config $Config -Target $Target
    $pilot = $Config.Versioning.PilotRing
    $entryRing = if ($pilot.Enabled) { 'Pilot' } else { 'Production' }

    $entry = Find-SDACatalogEntry -Target $Target -Config $Config
    $state.LastChecked = (Get-Date).ToUniversalTime().ToString('o')
    if (-not $entry) {
        $result.Status = 'NotInCatalog'
        $result.Message = 'Vendor catalog has no driver pack for this model / OS.'
        if (-not $DryRun) { Save-SDAState -Config $Config -State $state }
        $result.ProductionVersion = $state.Deployed.Production
        $result.PilotVersion = $state.Deployed.Pilot
        return $result
    }
    $result.CatalogVersion = $entry.VendorVersion
    $result.CatalogDate = $entry.ReleaseDate
    $state.LastCatalog = [ordered]@{ VendorVersion = $entry.VendorVersion; ReleaseDate = $entry.ReleaseDate; Url = $entry.Url; Hash = $entry.Hash }

    # --- 1. Stage the catalog release if it is new -------------------------------------------------
    $record = Find-SDAKnownVersion -State $state -CatalogEntry $entry
    if ($record -and $record.Status -eq 'Available' -and -not (Test-SDAVersionUsable -Version $record)) {
        Write-SDALog "Content for version $($record.VersionId) is missing from '$($record.StagedPath)' - it will be re-staged." -Severity Warning
        $record.Status = 'Pruned'
        Add-SDAHistory -State $state -Action 'Prune' -ToVersion $record.VersionId -Reason 'Content folder missing on disk'
        $record = $null
    }

    if (-not $record) {
        if ($DryRun) {
            $result.Status = 'UpdateAvailable'
            $result.Actions.Add("Would stage $($entry.VendorVersion) ($($entry.FileName)) and deploy it to $entryRing")
            $result.ProductionVersion = $state.Deployed.Production
            $result.PilotVersion = $state.Deployed.Pilot
            return $result
        }
        $record = Import-SDAVersion -Config $Config -State $state -Target $Target -CatalogEntry $entry
        $result.Actions.Add("Staged $($record.VersionId)")
        $result.Status = 'Staged'
    } elseif ($record.Status -eq 'Blocked') {
        $result.Status = 'Blocked'
        $result.Message = "Latest vendor release $($record.VersionId) is blocked: $($record.BlockedReason)"
        Write-SDALog $result.Message -Severity Warning
    } elseif ($record.Status -eq 'Pruned') {
        # The vendor catalog now lists an old, already-retired release (e.g. vendor withdrew a newer pack).
        $result.Message = "Catalog lists previously retired version $($record.VersionId) - no automatic downgrade."
        Write-SDALog $result.Message -Severity Warning
        $record = $null
    }

    # --- 2. Deploy to the entry ring ---------------------------------------------------------------
    if ($record -and $record.Status -eq 'Available') {
        $currentId = $state.Deployed[$entryRing]
        if ($currentId -ne $record.VersionId) {
            $currentRecord = if ($currentId) { Get-SDAVersionRecord -State $state -VersionId $currentId } else { $null }
            if ($state.Holds[$entryRing]) {
                $result.Message = "$entryRing ring is on hold ($($state.Holds[$entryRing].Reason)) - $($record.VersionId) staged but not deployed."
                Write-SDALog $result.Message -Severity Warning
                if ($result.Status -eq 'UpToDate') { $result.Status = 'Held' }
            } elseif (-not (Test-SDAVersionNewer -Candidate $record -Current $currentRecord)) {
                $result.Message = "Catalog version $($record.VersionId) is older than deployed $currentId - no automatic downgrade."
                Write-SDALog $result.Message -Severity Warning
            } elseif ($DryRun) {
                $result.Status = 'UpdateAvailable'
                $result.Actions.Add("Would deploy $($record.VersionId) to $entryRing")
            } else {
                Publish-SDAVersion -Context $Context -Config $Config -State $state -Target $Target -Ring $entryRing -VersionId $record.VersionId -Action 'Deploy' -Reason "New vendor release $($record.VendorVersion)" | Out-Null
                $result.Actions.Add("Deployed $($record.VersionId) to $entryRing")
                $result.Status = 'Updated'
            }
        }

        # First import with a pilot ring: optionally give Production the same baseline.
        if ($pilot.Enabled -and $pilot.SeedProductionOnFirstImport -and -not $state.Deployed.Production -and -not $state.Holds.Production) {
            if ($DryRun) {
                $result.Status = 'UpdateAvailable'
                $result.Actions.Add("Would seed Production with $($record.VersionId)")
            } else {
                Publish-SDAVersion -Context $Context -Config $Config -State $state -Target $Target -Ring 'Production' -VersionId $record.VersionId -Action 'Deploy' -Reason 'Initial baseline (SeedProductionOnFirstImport)' | Out-Null
                $result.Actions.Add("Seeded Production with $($record.VersionId)")
                $result.Status = 'Updated'
            }
        }
    }

    # --- 3. Time-based promotion Pilot -> Production -----------------------------------------------
    $promoteDays = [int]$pilot.AutoPromoteAfterDays
    if ($pilot.Enabled -and $promoteDays -gt 0 -and $state.Deployed.Pilot -and $state.Deployed.Pilot -ne $state.Deployed.Production) {
        $pilotRecord = Get-SDAVersionRecord -State $state -VersionId $state.Deployed.Pilot
        $prodRecord  = if ($state.Deployed.Production) { Get-SDAVersionRecord -State $state -VersionId $state.Deployed.Production } else { $null }
        $since = Get-SDARingDeployedUtc -State $state -Ring 'Pilot' -VersionId $state.Deployed.Pilot
        $ageDays = if ($since) { ((Get-Date).ToUniversalTime() - $since).TotalDays } else { 0 }

        if ($state.Holds.Production) {
            Write-SDALog "Production ring is on hold - skipping automatic promotion of $($state.Deployed.Pilot)."
        } elseif ($ageDays -ge $promoteDays -and (Test-SDAVersionUsable -Version $pilotRecord) -and (Test-SDAVersionNewer -Candidate $pilotRecord -Current $prodRecord)) {
            if ($DryRun) {
                $result.Status = 'UpdateAvailable'
                $result.Actions.Add("Would promote $($pilotRecord.VersionId) to Production (in Pilot {0:N0} days)" -f $ageDays)
            } else {
                Publish-SDAVersion -Context $Context -Config $Config -State $state -Target $Target -Ring 'Production' -VersionId $pilotRecord.VersionId -Action 'Promote' -Reason ("Automatic promotion after {0:N0} days in Pilot" -f $ageDays) | Out-Null
                $result.Actions.Add("Promoted $($pilotRecord.VersionId) to Production")
                $result.Status = 'Updated'
            }
        } elseif ($ageDays -lt $promoteDays) {
            Write-SDALog ("Pilot version {0} has been in Pilot {1:N1} of {2} days before promotion." -f $state.Deployed.Pilot, $ageDays, $promoteDays)
        }
    }

    # --- 4. Retention ------------------------------------------------------------------------------
    if (-not $DryRun) {
        $pruned = Invoke-SDARetention -Config $Config -State $state
        if ($pruned -gt 0) { $result.Actions.Add("Pruned $pruned old version(s)") }
        Save-SDAState -Config $Config -State $state
    }

    $result.ProductionVersion = $state.Deployed.Production
    $result.PilotVersion = $state.Deployed.Pilot
    return $result
}

function Invoke-SDARollback {
    <#
    .SYNOPSIS
        Re-points a ring to an earlier staged version and (by default) blocks the version being replaced
        so the scheduled run will not re-deploy it.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][ValidateSet('Production', 'Pilot')][string]$Ring,
        [string]$ToVersion,
        [Parameter(Mandatory)][string]$Reason,
        [switch]$NoBlock,
        [switch]$Hold
    )

    $state = Get-SDAState -Config $Config -Target $Target
    $current = $state.Deployed[$Ring]
    if (-not $current) { throw "Nothing is deployed to the $Ring ring of $($Target.DisplayName)." }

    if ($ToVersion) {
        $destination = Get-SDAVersionRecord -State $state -VersionId $ToVersion
        if (-not $destination) { throw "Version '$ToVersion' is not in the ledger. Available: $((@($state.Versions | Where-Object { Test-SDAVersionUsable $_ }).VersionId) -join ', ')" }
    } else {
        $destination = Get-SDARollbackCandidate -State $state -Ring $Ring
        if (-not $destination) { throw "No earlier usable version is staged for the $Ring ring of $($Target.DisplayName)." }
    }
    if ($destination.VersionId -eq $current) { throw "Version '$current' is already deployed to the $Ring ring." }

    Publish-SDAVersion -Context $Context -Config $Config -State $state -Target $Target -Ring $Ring -VersionId $destination.VersionId -Action 'Rollback' -Reason $Reason | Out-Null

    if (-not $NoBlock) {
        $bad = Get-SDAVersionRecord -State $state -VersionId $current
        if ($bad -and $bad.Status -ne 'Blocked') {
            $bad.Status = 'Blocked'
            $bad.BlockedReason = $Reason
            Add-SDAHistory -State $state -Action 'Block' -ToVersion $current -Reason $Reason
            Write-SDALog "Version $current blocked - it will not be deployed automatically again."
        }
        foreach ($otherRing in @('Production', 'Pilot') | Where-Object { $_ -ne $Ring }) {
            if ($state.Deployed[$otherRing] -eq $current) {
                Write-SDALog "Blocked version $current is still deployed to the $otherRing ring - roll that ring back as well if required." -Severity Warning
            }
        }
    }
    if ($Hold) {
        Set-SDARingHold -State $state -Ring $Ring -Reason $Reason
    }
    Save-SDAState -Config $Config -State $state
    return [pscustomobject]@{ Target = $Target.DisplayName; Ring = $Ring; From = $current; To = $destination.VersionId; Blocked = (-not $NoBlock); Held = [bool]$Hold; PackageID = $state.Packages[$Ring].PackageID }
}

function Invoke-SDAPromotion {
    <#
    .SYNOPSIS
        Promotes the Pilot version (or an explicit version) to Production.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)]$Target,
        [string]$Version,
        [Parameter(Mandatory)][string]$Reason
    )

    $state = Get-SDAState -Config $Config -Target $Target
    if (-not $Version) { $Version = $state.Deployed.Pilot }
    if (-not $Version) { throw "Nothing is deployed to the Pilot ring of $($Target.DisplayName); specify -Version." }
    if ($state.Deployed.Production -eq $Version) { throw "Version '$Version' is already in Production." }

    $from = $state.Deployed.Production
    Publish-SDAVersion -Context $Context -Config $Config -State $state -Target $Target -Ring 'Production' -VersionId $Version -Action 'Promote' -Reason $Reason | Out-Null
    return [pscustomobject]@{ Target = $Target.DisplayName; Ring = 'Production'; From = $from; To = $Version; PackageID = $state.Packages.Production.PackageID }
}

function Set-SDAVersionStatus {
    <#
    .SYNOPSIS
        Blocks or unblocks a version in a ledger (does not change what is deployed).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$VersionId,
        [Parameter(Mandatory)][ValidateSet('Blocked', 'Available')][string]$Status,
        [Parameter(Mandatory)][string]$Reason
    )

    $record = Get-SDAVersionRecord -State $State -VersionId $VersionId
    if (-not $record) { throw "Version '$VersionId' is not in the ledger." }
    if ($record.Status -eq 'Pruned') { throw "Version '$VersionId' has been pruned; its content no longer exists." }
    if ($record.Status -eq $Status) { Write-SDALog "Version $VersionId is already $Status."; return }

    $record.Status = $Status
    $record.BlockedReason = if ($Status -eq 'Blocked') { $Reason } else { $null }
    Add-SDAHistory -State $State -Action $(if ($Status -eq 'Blocked') { 'Block' } else { 'Unblock' }) -ToVersion $VersionId -Reason $Reason
    foreach ($ring in @('Production', 'Pilot')) {
        if ($Status -eq 'Blocked' -and $State.Deployed[$ring] -eq $VersionId) {
            Write-SDALog "Version $VersionId is blocked but still deployed to $ring - use Invoke-DriverRollback.ps1 to replace it." -Severity Warning
        }
    }
}

function Set-SDARingHold {
    <#
    .SYNOPSIS
        Places a ring on hold (no automatic deploy/promote) or releases it.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][ValidateSet('Production', 'Pilot')][string]$Ring,
        [Parameter(Mandatory)][string]$Reason,
        [switch]$Release
    )

    if ($Release) {
        if (-not $State.Holds[$Ring]) { Write-SDALog "$Ring ring is not on hold."; return }
        $State.Holds[$Ring] = $null
        Add-SDAHistory -State $State -Action 'Release' -Ring $Ring -Reason $Reason
        Write-SDALog "$Ring ring released - automatic changes resume on the next run."
    } else {
        $State.Holds[$Ring] = [ordered]@{ SetUtc = (Get-Date).ToUniversalTime().ToString('o'); By = (Get-SDAInitiator); Reason = $Reason }
        Add-SDAHistory -State $State -Action 'Hold' -Ring $Ring -Reason $Reason
        Write-SDALog "$Ring ring placed on hold - no automatic deployments until released."
    }
}

#endregion Deployment
