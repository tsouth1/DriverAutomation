#region Staging
<#
    Turns a verified vendor payload into immutable, versioned package content:

        <PackageSourceLocalRoot>\<Vendor>\<Model>\<OS [Build] Arch>\<VersionId>\
            DriverPackage.wim        (ContentFormat = WIM)   or   Drivers\...  (ContentFormat = Raw)
            DriverManifest.json      provenance: source URL, hashes, signer, INF count, staged time

    Version folders are never modified after creation. Deploying or rolling back only changes which
    folder a ConfigMgr package points at, so every retained version is an exact, re-deployable copy.
#>

function Invoke-SDAProcess {
    <#
    .SYNOPSIS
        Runs an executable hidden, waits with a timeout and returns the exit code.
        On timeout the whole process tree is terminated (self-extractors spawn children).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [int]$TimeoutMinutes = 60,
        [string]$WorkingDirectory
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        if (-not $process.WaitForExit([int]([TimeSpan]::FromMinutes($TimeoutMinutes).TotalMilliseconds))) {
            Write-SDALog "Process '$FilePath' exceeded $TimeoutMinutes minute(s) - terminating process tree." -Severity Error
            & "$env:SystemRoot\System32\taskkill.exe" /PID $process.Id /T /F 2>&1 | Out-Null
            throw "Process '$(Split-Path -Leaf $FilePath)' timed out after $TimeoutMinutes minute(s)."
        }
        $process.WaitForExit()   # flush async handles
        return $process.ExitCode
    } finally {
        $process.Dispose()
    }
}

function Set-SDAProtectedAcl {
    <#
    .SYNOPSIS
        Replaces the ACL with SYSTEM + BUILTIN\Administrators full control (inheritance disabled).
        Used for the data root (state, logs, secrets) because a SYSTEM task consumes those files.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)][string]$Path)

    $system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $item = Get-Item -LiteralPath $Path -Force

    if ($item.PSIsContainer) {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $inherit = [System.Security.AccessControl.InheritanceFlags]::None
    }
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($admins)
    foreach ($sid in @($system, $admins)) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', $inherit, 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Assert-SDAPathUnderRoot {
    <#
    .SYNOPSIS
        Throws unless Path resolves strictly beneath one of the given roots (guards every recursive delete).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Roots
    )

    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $r = [System.IO.Path]::GetFullPath($root).TrimEnd('\')
        if ($full.Length -gt ($r.Length + 1) -and $full.StartsWith("$r\", [StringComparison]::OrdinalIgnoreCase)) { return }
    }
    throw "Refusing to modify '$Path' - it is not inside a managed root ($($Roots -join '; '))."
}

function Remove-SDAPath {
    <#
    .SYNOPSIS
        Recursively deletes a folder/file after verifying it is inside a managed root.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )

    Assert-SDAPathUnderRoot -Path $Path -Roots @($Config.Paths.DataRoot, $Config.ConfigMgr.PackageSourceLocalRoot)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    # Clear read-only attributes some vendor extractors set, otherwise Remove-Item fails.
    Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReadOnly } |
        ForEach-Object { $_.Attributes = $_.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly) }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Test-SDAFreeSpace {
    <#
    .SYNOPSIS
        Throws if the volume hosting Path has less than MinimumGB free.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$MinimumGB
    )

    $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
    if ($root.StartsWith('\\')) {
        # DriveInfo does not accept shares; GetDiskFreeSpaceEx does (quota-aware, as seen by this account).
        if (-not ('SDA.NativeDisk' -as [type])) {
            Add-Type -Namespace SDA -Name NativeDisk -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool GetDiskFreeSpaceEx(string directory, out ulong freeBytesAvailable, out ulong totalBytes, out ulong totalFreeBytes);
'@
        }
        $available = [uint64]0; $total = [uint64]0; $totalFree = [uint64]0
        if (-not [SDA.NativeDisk]::GetDiskFreeSpaceEx($root.TrimEnd('\') + '\', [ref]$available, [ref]$total, [ref]$totalFree)) {
            throw "Cannot read free space on $root (error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
        }
        $freeGB = [Math]::Round($available / 1GB, 1)
    } else {
        $drive = New-Object System.IO.DriveInfo($root)
        $freeGB = [Math]::Round($drive.AvailableFreeSpace / 1GB, 1)
    }
    if ($freeGB -lt $MinimumGB) {
        throw "Insufficient free space on $root ($freeGB GB free, $MinimumGB GB required by General.MinimumFreeSpaceGB)."
    }
    return $freeGB
}

function Get-SDAVersionPaths {
    <#
    .SYNOPSIS
        Local and UNC locations of a version's content folder.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$VersionId
    )

    $osSegment = ("{0}{1} {2}" -f $Target.OSName, $(if ($Target.OSBuild) { " $($Target.OSBuild)" } else { '' }), $Target.Architecture)
    $relative = Join-Path (ConvertTo-SDASafeName $Target.Vendor) (Join-Path (ConvertTo-SDASafeName $Target.Model) (Join-Path (ConvertTo-SDASafeName $osSegment) (ConvertTo-SDASafeName $VersionId)))
    return @{
        Local = Join-Path $Config.ConfigMgr.PackageSourceLocalRoot $relative
        Unc   = Join-Path $Config.ConfigMgr.PackageSourceUncRoot $relative
    }
}

function Expand-SDADriverPackage {
    <#
    .SYNOPSIS
        Extracts a vendor driver pack (CAB / ZIP / self-extracting EXE) into Destination.
    .NOTES
        Extraction switches:
          Dell .cab      expand.exe -F:*
          Dell .exe      /s /e="<dir>"
          HP   .exe      /s /e /f "<dir>"   (modern SoftPaq), falls back to legacy /s /e="<dir>"
          Lenovo .exe    Inno Setup: /VERYSILENT /DIR="<dir>" /EXTRACT=YES (target must not exist)
        Success is judged by the presence of .inf files, not by exit codes (HP SoftPaqs, for example,
        return non-zero codes on successful extraction).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Vendor,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [int]$TimeoutMinutes = 60
    )

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    Unblock-File -LiteralPath $Path -ErrorAction SilentlyContinue

    $hasInf = { param ($dir) (Test-Path -LiteralPath $dir) -and [bool](Get-ChildItem -LiteralPath $dir -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue | Select-Object -First 1) }

    switch ($extension) {
        '.cab' {
            New-Item -Path $Destination -ItemType Directory -Force | Out-Null
            $exit = Invoke-SDAProcess -FilePath (Join-Path $env:SystemRoot 'System32\expand.exe') -Arguments ('"{0}" -F:* "{1}"' -f $Path, $Destination) -TimeoutMinutes $TimeoutMinutes
            if ($exit -ne 0) { throw "expand.exe returned $exit extracting '$Path'." }
        }
        '.zip' {
            New-Item -Path $Destination -ItemType Directory -Force | Out-Null
            Expand-SDAZipSafely -Path $Path -Destination $Destination
        }
        '.exe' {
            $attempts = switch ($Vendor) {
                'Lenovo' { @('/VERYSILENT /DIR="{0}" /EXTRACT="YES" /SUPPRESSMSGBOXES /NORESTART /SP-') }
                'HP'     { @('/s /e /f "{0}"', '/s /e="{0}"') }
                default  { @('/s /e="{0}"') }
            }
            foreach ($template in $attempts) {
                if (Test-Path -LiteralPath $Destination) { Remove-SDAPath -Path $Destination -Config $Config }
                if ($Vendor -ne 'Lenovo') { New-Item -Path $Destination -ItemType Directory -Force | Out-Null }
                $arguments = $template -f $Destination.TrimEnd('\')
                Write-SDALog "Extracting with: $(Split-Path -Leaf $Path) $arguments"
                $exit = Invoke-SDAProcess -FilePath $Path -Arguments $arguments -TimeoutMinutes $TimeoutMinutes -WorkingDirectory (Split-Path -Parent $Path)
                if (& $hasInf $Destination) {
                    if ($exit -ne 0) { Write-SDALog "Extractor returned exit code $exit but produced driver files - treating as success." -Severity Warning }
                    break
                }
                Write-SDALog "Extraction attempt produced no .inf files (exit code $exit)." -Severity Warning
            }
        }
        default { throw "Unsupported driver pack format '$extension' ($Path)." }
    }

    if (-not (& $hasInf $Destination)) {
        throw "Extraction of '$Path' produced no driver (.inf) files."
    }
}

function Expand-SDAZipSafely {
    <#
    .SYNOPSIS
        ZIP extraction that rejects entries escaping the destination (zip-slip).
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Destination)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $zip.Entries) {
            $target = [System.IO.Path]::GetFullPath((Join-Path $root $entry.FullName))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Archive entry '$($entry.FullName)' escapes the extraction folder - archive rejected."
            }
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
                New-Item -Path $target -ItemType Directory -Force | Out-Null
                continue
            }
            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -Path $parent -ItemType Directory -Force | Out-Null }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally {
        $zip.Dispose()
    }
}

function Get-SDADriverContentInfo {
    <#
    .SYNOPSIS
        Summarises extracted driver content and flags paths that DISM cannot capture.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)][string]$Path)

    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction Stop)
    $infs  = @($files | Where-Object { $_.Extension -eq '.inf' })
    $long  = @($files | Where-Object { $_.FullName.Length -ge 260 })
    return [pscustomobject]@{
        FileCount     = $files.Count
        InfCount      = $infs.Count
        SizeBytes     = [int64](($files | Measure-Object -Property Length -Sum).Sum)
        LongPathFiles = $long.Count
    }
}

function New-SDAPackageContent {
    <#
    .SYNOPSIS
        Builds the immutable version folder from extracted drivers (WIM capture or raw copy) and writes
        DriverManifest.json. Builds into a temporary sibling folder and renames at the end so a failed
        build never leaves a half-populated version folder behind.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$ExtractPath,
        [Parameter(Mandatory)][string]$VersionPath,
        [Parameter(Mandatory)][string]$ImageName,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest
    )

    $building = "$VersionPath.building"
    if (Test-Path -LiteralPath $building) { Remove-SDAPath -Path $building -Config $Config }
    if (Test-Path -LiteralPath $VersionPath) { throw "Version folder already exists (versions are immutable): $VersionPath" }
    New-Item -Path $building -ItemType Directory -Force | Out-Null

    try {
        if ($Config.ConfigMgr.ContentFormat -eq 'WIM') {
            $wim = Join-Path $building 'DriverPackage.wim'
            # On a remote share, capture to the local data root and copy the finished image across.
            $capture = if ($wim.StartsWith('\\')) { "$ExtractPath.wim" } else { $wim }
            $dismLog = Join-Path $Config.Paths.Logs ("dism-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            $dism = Join-Path $env:SystemRoot 'System32\dism.exe'
            $safeName = $ImageName -replace '"', ''
            $arguments = '/English /Capture-Image /ImageFile:"{0}" /CaptureDir:"{1}" /Name:"{2}" /Description:"{2}" /Compress:max /CheckIntegrity /LogPath:"{3}"' -f $capture, $ExtractPath.TrimEnd('\'), $safeName, $dismLog
            Write-SDALog "Capturing WIM: $capture"
            try {
                $exit = Invoke-SDAProcess -FilePath $dism -Arguments $arguments -TimeoutMinutes ([int]$Config.Extraction.TimeoutMinutes * 2)
                if ($exit -ne 0 -or -not (Test-Path -LiteralPath $capture)) { throw "DISM capture failed with exit code $exit - see $dismLog" }
                if ($capture -ne $wim) {
                    Write-SDALog "Copying WIM to $wim"
                    Copy-Item -LiteralPath $capture -Destination $wim -Force
                    if ((Get-Item -LiteralPath $wim).Length -ne (Get-Item -LiteralPath $capture).Length) { throw "Copy of the WIM to $wim is incomplete." }
                }
            } finally {
                if ($capture -ne $wim) { Remove-Item -LiteralPath $capture -Force -ErrorAction SilentlyContinue }
            }
            $Manifest['ContentFile'] = 'DriverPackage.wim'
            $Manifest['ContentSizeBytes'] = (Get-Item -LiteralPath $wim).Length
        } else {
            $dest = Join-Path $building 'Drivers'
            $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
            $arguments = '"{0}" "{1}" /E /COPY:DAT /DCOPY:T /R:2 /W:5 /NP /NFL /NDL /NJH /XJ' -f $ExtractPath.TrimEnd('\'), $dest
            Write-SDALog "Copying raw driver content to $dest"
            $exit = Invoke-SDAProcess -FilePath $robocopy -Arguments $arguments -TimeoutMinutes ([int]$Config.Extraction.TimeoutMinutes)
            if ($exit -ge 8) { throw "Robocopy failed with exit code $exit." }
            $Manifest['ContentFile'] = 'Drivers'
            $Manifest['ContentSizeBytes'] = [int64]((Get-ChildItem -LiteralPath $dest -Recurse -File | Measure-Object -Property Length -Sum).Sum)
        }

        $Manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $building 'DriverManifest.json') -Encoding UTF8
        Rename-Item -LiteralPath $building -NewName (Split-Path -Leaf $VersionPath)
    } catch {
        $buildError = $_
        try { Remove-SDAPath -Path $building -Config $Config } catch { Write-SDALog "Could not remove partial build folder '$building': $($_.Exception.Message)" -Severity Warning }
        throw $buildError
    }
}

function Invoke-SDARetention {
    <#
    .SYNOPSIS
        Deletes staged content beyond Versioning.RetainVersions for one target.
    .DESCRIPTION
        Never removes: the version deployed to any ring, or the current Production rollback candidate.
        Ledger records are kept (Status = Pruned) so the audit history stays complete.
    .OUTPUTS
        Number of versions pruned.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State
    )

    $retain = [int]$Config.Versioning.RetainVersions
    $protected = New-Object System.Collections.Generic.HashSet[string]
    foreach ($ring in @('Production', 'Pilot')) {
        if ($State.Deployed[$ring]) { [void]$protected.Add($State.Deployed[$ring]) }
        $candidate = Get-SDARollbackCandidate -State $State -Ring $ring
        if ($candidate) { [void]$protected.Add($candidate.VersionId) }
    }

    $staged = @($State.Versions | Where-Object { $_.Status -ne 'Pruned' -and $_.StagedPath } |
        Sort-Object -Property @{ Expression = { Get-SDAVersionSortDate $_ } } -Descending)

    $kept = 0
    $pruned = 0
    foreach ($v in $staged) {
        if ($protected.Contains($v.VersionId)) { $kept++; continue }
        if ($kept -lt $retain) { $kept++; continue }
        try {
            Remove-SDAPath -Path $v.StagedPath -Config $Config
            $v.Status = 'Pruned'
            $v['PrunedUtc'] = (Get-Date).ToUniversalTime().ToString('o')
            Add-SDAHistory -State $State -Action 'Prune' -ToVersion $v.VersionId -Reason "Exceeded RetainVersions ($retain)"
            Write-SDALog "Pruned version $($v.VersionId) ($($v.StagedPath))."
            $pruned++
        } catch {
            Write-SDALog "Failed to prune version $($v.VersionId): $(Format-SDAError $_)" -Severity Warning
        }
    }
    return $pruned
}

#endregion Staging
