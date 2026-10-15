# Instructions

How to install SCCMDriverAutomation, choose the models it manages, apply its packages in a task
sequence and run it day to day. Check [REQUIREMENTS.md](REQUIREMENTS.md) first; the overview and
screenshots are in [README.md](README.md).

* [Installation](#installation)
  * [Defining models](#defining-models)
* [Applying the drivers in a task sequence](#applying-the-drivers-in-a-task-sequence)
* [Day-to-day operations](#day-to-day-operations)
  * [Management GUI](#management-gui)
  * [Command line](#command-line)
* [Migrating from the Driver Automation Tool](#migrating-from-the-driver-automation-tool)

---

## Installation

```powershell
# 1. Edit Config\DriverAutomation.json (paths, DP groups, proxy, models - see below)
# 2. From an elevated PowerShell on the server that will run it:
.\Install-DriverAutomation.ps1 -At 02:00 -RunPreflight
#    optional: -DaysOfWeek Tuesday,Thursday   -SigningCertificateThumbprint <thumbprint>
# 3. See what the first run would do, without making changes:
& 'C:\Program Files\SCCMDriverAutomation\Invoke-DriverAutomation.ps1' -DryRun
# 4. Run it now (or wait for the schedule):
Start-ScheduledTask -TaskPath '\SCCMDriverAutomation\' -TaskName 'SCCM Driver Automation'
```

`-RunPreflight` runs `Invoke-DriverAutomation.ps1 -PreflightOnly` **as SYSTEM** through a temporary
scheduled task. It checks the proxy path, catalog signatures, ConfigMgr permissions, DP groups and the
share mapping exactly as the scheduled task will see them. That is where most first-time problems
show up: proxy 407 errors for the computer account, missing RBAC, and share permissions.

### Defining models

The easiest way is **Configuration > Add from vendor catalog** in the GUI: scan the catalogs, search
for a model or system ID, tick the models and the Windows builds you want, then click **Add ticked
models to the configuration**. Names and system IDs are copied from the catalog, so they always
match. A model that shares a system ID with one you already have (HP often ships one pack for a whole
platform, such as all G10 models on `8B41`) is added to that existing entry instead of creating a
second package for the same hardware. From the command line:

```powershell
.\Get-DriverCatalogModels.ps1 -Vendor Lenovo | Where-Object Model -like 'ThinkPad T14*' | Format-Table
.\Get-DriverCatalogModels.ps1 -Vendor HP | Where-Object { $_.SystemIds -contains '8B41' }
```

To write entries by hand:

```json
{ "Vendor": "Dell",   "Model": "Latitude 7440",      "SystemIds": ["0C0B","0C0C","0C0D"],
  "OperatingSystems": [ { "Name": "Windows 11", "Architecture": "x64" } ] },
{ "Vendor": "HP",     "Model": "HP EliteBook 840 14 inch G10 Notebook PC", "SystemIds": ["8B41"],
  "OperatingSystems": [ { "Name": "Windows 11", "Build": "24H2" } ] },
{ "Vendor": "Lenovo", "Model": "ThinkPad T14 Gen 4", "SystemIds": ["21HD","21HE"],
  "OperatingSystems": [ { "Name": "Windows 11", "Build": "24H2" } ] }
```

* **SystemIds** are the most reliable match key:
  * Dell: SystemSKU (`Win32_ComputerSystem.SystemSKUNumber`)
  * HP: baseboard product (`Win32_BaseBoard.Product`)
  * Lenovo: the first 4 characters of `Win32_ComputerSystem.Model`

  They also populate the package description (`Models included: ...`) that MDM matches against. If
  the SystemIds and the model name point to *different* catalog models, the target fails with a
  configuration error rather than deploying the wrong drivers.
* HP and Lenovo publish packs per Windows feature update, so `Build` is required for them. Dell packs
  cover all builds of a Windows version.
* The sample IDs above were checked against the live catalogs in October 2026. Check your own fleet
  in ConfigMgr hardware inventory.

---

## Applying the drivers in a task sequence

The tool builds and updates the packages. It adds nothing to your task sequences. Each package holds
`DriverPackage.wim` (one index, all the pack's drivers) and `DriverManifest.json`, or a `Drivers`
folder when `ContentFormat` is `Raw`. The task sequence injects them into the new OS while it is
still offline:

```
WinPE
  Partition Disk
  Apply Operating System        sets OSDTargetSystemDrive; _SMSTSMDataPath is now on the target disk
  Apply Windows Settings
  Apply Network Settings
  ► Apply drivers               mount the WIM read-only → DISM /Add-Driver into the offline OS → unmount
  Setup Windows and ConfigMgr   first boot of the new OS: Windows installs the staged drivers
```

`DISM /Add-Driver` only stages the drivers in the offline OS's driver store. Windows installs them
when it detects the hardware during setup after the reboot. That is why storage and network drivers
must be added before **Setup Windows and ConfigMgr**. The built-in **Apply Driver Package** step can't
be used: it only takes ConfigMgr driver packages built from imported drivers, and these are standard
packages.

### Choosing the package

Each model needs a condition that matches its hardware. Use the same IDs the tool puts in `SystemIds`
and in the package description (`Models included: ...`). All of these are in `root\cimv2`:

| Vendor | Task sequence WMI query condition |
|---|---|
| Dell | `SELECT * FROM Win32_ComputerSystem WHERE SystemSKUNumber = "0C0B"` |
| HP | `SELECT * FROM Win32_BaseBoard WHERE Product = "8B41"` |
| Lenovo | `SELECT * FROM Win32_ComputerSystem WHERE Model LIKE "21HD%" OR Model LIKE "21HE%"` |

Model names (`Win32_ComputerSystem.Model`, or `Win32_ComputerSystemProduct.Version` for Lenovo's
friendly name) also work, but they vary more between BIOS versions and regions than the IDs do.

Keep exactly one model group true per device. To test a new version on some devices first, add the
**Drivers Pilot - ...** packages in a second set of groups with an extra condition, such as a
collection variable `DriverRing = Pilot` on your pilot collection. Use `DriverRing not equals Pilot`
on the Production groups.

If you'd rather not maintain one group per model, Modern Driver Management's
`Invoke-CMApplyDriverPackage.ps1` finds the package by matching the description and name conventions
the tool uses (see [Versioning model](README.md#versioning-model)).

### Option 1: Run Command Line steps

This layout is the simplest and needs nothing extra in the boot image. A nested task sequence keeps
it out of the main one.

1. **Create mount folder** (Run Command Line):
   `cmd.exe /c md "%_SMSTSMDataPath%\DrvMount"`
2. One group per model, with the WMI condition above. Each contains:
   * **Mount drivers** (Run Command Line). Set **Package** to that model's driver package. The step
     runs in the package folder, so the WIM can be named without a path:

     ```
     dism.exe /Mount-Image /ImageFile:"DriverPackage.wim" /Index:1 /MountDir:"%_SMSTSMDataPath%\DrvMount" /ReadOnly /LogPath:"%_SMSTSLogPath%\DriverMount.log"
     ```
   * **Set Task Sequence Variable**: `DriversMounted` = `True`
3. A group **Inject drivers**, with the condition *task sequence variable `DriversMounted` equals
   `True`*. It contains:
   * **Inject drivers** (Run Command Line):

     ```
     dism.exe /Image:%OSDTargetSystemDrive%\ /Add-Driver /Driver:"%_SMSTSMDataPath%\DrvMount" /Recurse /LogPath:"%_SMSTSLogPath%\DriverInject.log"
     ```
   * **Unmount drivers** (Run Command Line, **Continue on error**):

     ```
     dism.exe /Unmount-Image /MountDir:"%_SMSTSMDataPath%\DrvMount" /Discard
     ```

If no group matched, the inject group is skipped and the device is built with inbox drivers only. To
stop the build instead, add a **Run Command Line** step `cmd.exe /c exit 1` with the condition
*`DriversMounted` not exists*.

For `Raw` packages, skip the mount and unmount steps. Set the inject step's **Package** to the
model's package and use `/Driver:"Drivers"`.

### Option 2: one PowerShell step with error handling

Each model group contains only a **Download Package Content** step. Select the model's package, set
**Custom path** to `%_SMSTSMDataPath%\DriverContent`, and tick **Save path as a variable** with the
base name `DRIVERS`. The path then lands in `DRIVERS01`. After the groups, one **Run PowerShell
Script** step (execution policy *Bypass*) runs this script from a small script package. The boot image
needs the *Windows PowerShell (WinPE-PowerShell)* optional component.

```powershell
# Apply-DriverPackage.ps1 - injects the downloaded driver package into the offline OS.
$tsenv   = New-Object -ComObject Microsoft.SMS.TSEnvironment
$content = $tsenv.Value('DRIVERS01')
if (-not $content) { throw 'No driver package was downloaded for this model (DRIVERS01 is empty).' }
$target  = $tsenv.Value('OSDTargetSystemDrive') + '\'
$mount   = Join-Path $tsenv.Value('_SMSTSMDataPath') 'DrvMount'
$log     = Join-Path $tsenv.Value('_SMSTSLogPath') 'DriverInject.log'

$manifest = Join-Path $content 'DriverManifest.json'
if (Test-Path $manifest) {
    $m = Get-Content $manifest -Raw | ConvertFrom-Json
    Write-Output "Driver package: $($m.Vendor) $($m.Model) $($m.OperatingSystem) $($m.OSBuild), version $($m.VersionId) ($($m.InfCount) INF)"
}

$wim = Join-Path $content 'DriverPackage.wim'
if (Test-Path $wim) {
    New-Item -ItemType Directory -Path $mount -Force | Out-Null
    & dism.exe /Mount-Image "/ImageFile:$wim" /Index:1 "/MountDir:$mount" /ReadOnly "/LogPath:$log"
    if ($LASTEXITCODE -ne 0) { throw "Mounting $wim failed (exit code $LASTEXITCODE). See $log." }
    $source = $mount
} else {
    $source = Join-Path $content 'Drivers'          # ContentFormat = Raw
    if (-not (Test-Path $source)) { throw "No DriverPackage.wim or Drivers folder in $content." }
}

try {
    & dism.exe "/Image:$target" /Add-Driver "/Driver:$source" /Recurse "/LogPath:$log"
    if ($LASTEXITCODE -ne 0) { throw "Driver injection failed (exit code $LASTEXITCODE). See $log." }
} finally {
    if ($source -eq $mount) {
        & dism.exe /Unmount-Image "/MountDir:$mount" /Discard
        if ($LASTEXITCODE -ne 0) { Write-Warning "Unmount failed (exit code $LASTEXITCODE); the build continues." }
    }
}
```

This version always unmounts, logs which pack and version went onto the device, fails the step when
no package matched, and handles both content formats.

### Tips

* **Logs.** Write DISM logs to `%_SMSTSLogPath%` so they are collected with `smsts.log`, not inside
  the mount folder, which disappears on unmount. To record what was staged, add
  `dism.exe /Image:%OSDTargetSystemDrive%\ /Get-Drivers` after the inject step. Drivers show up as
  `oem<n>.inf`; the original file name is in the output.
* **Mount location.** Mount on the target disk (`%_SMSTSMDataPath%` after Apply Operating System), not
  on `X:`. WinPE's RAM drive is small, and mounting needs an NTFS volume (error `0xc142011f` means the
  volume doesn't support reparse points).
* **Content access.** *Download content locally when needed* is the normal deployment option. Access
  directly from the distribution point also works, because the WIM is mounted read-only, but then DISM
  reads it over the network.
* **Leftover mounts.** If a build fails while the WIM is mounted, `dism.exe /Cleanup-Mountpoints`
  clears the stale mount. Partitioning the disk on the next attempt also removes it.
* **No `/ForceUnsigned`.** Vendor packs are signed, and 64-bit Windows does not load unsigned kernel
  drivers anyway.
* **Signature errors (1920).** One reported fix for driver signature errors after injection is
  capturing the WIM with `/EA` (extended attributes). The tool captures without it. Raise an issue if
  you see this with one of its packages.
* **Standalone media.** Offline media built with the driver packages included works the same way.
* **In-place upgrades.** In an upgrade task sequence, don't mount: a mount doesn't survive the
  upgrade's reboots. Expand the WIM to a folder instead with
  `dism.exe /Apply-Image /ImageFile:"DriverPackage.wim" /Index:1 /ApplyDir:"%_SMSTSMDataPath%\DriverContent"`.
  Point **Upgrade Operating System > Provide the following driver content to Windows Setup** (the
  `OSDUpgradeStagedContent` variable) at that folder.

### Other approaches

* **Servicing the OS image itself.** Adding drivers to `install.wim` with
  `Mount-WindowsImage` / `Add-WindowsDriver` / `Dismount-WindowsImage -Save` bakes them into one golden
  image. It suits a small fixed fleet or air-gapped builds, but the image then needs rebuilding and
  re-testing for every driver change. It also grows with every model, and it gets none of this tool's
  versioning or rollback. Per-model packages applied at deployment time avoid all of that.
* **Boot image drivers.** WinPE needs its own storage and network drivers to reach the disk and the
  distribution point. These packages are for the full OS. Add WinPE drivers to the boot image in the
  console from the vendor's WinPE driver packs.

---

## Day-to-day operations

### Management GUI

The installer adds **Start menu > SCCM Driver Automation**. You can also run
`.\Start-DriverAutomationGUI.ps1` from the install folder. It asks for elevation because the scripts
require it. See the [screenshots](README.md#screenshots) for each tab.

| Tab | What it does |
|---|---|
| Models & versions | Each model / OS with its Production and Pilot version, package IDs, latest catalog release, rollback target and holds. Select one to see its staged versions and audit history. Buttons: Promote, Roll back, Block / Unblock version, Hold / Release ring. Each asks for a reason. |
| Run | Preflight, dry run or full run for selected vendors and models, as you. Shows the scheduled task's state, last result and next run, and can start it (as SYSTEM). |
| Configuration | Models grid with their operating systems, plus a form for every other setting. **Add from vendor catalog** lists every model and build the vendors publish packs for, filterable by name, system ID, OS, build and release date, and adds the ticked ones. Save validates with the same rules as the scripts and warns when a path's drive doesn't exist on this server. The previous file is kept as `DriverAutomation.json.bak`. |
| Logs | CMTrace log viewer with filter, warnings-only and auto-refresh. Opens the log in CMTrace when it is installed. |
| Run reports | The CSV report of each run, colour-coded by status. |

The GUI contains no deployment logic. Every button runs the matching script below in a separate
Windows PowerShell process and shows its output, so the run lock, ledger, logs and event log behave
exactly as they do from the command line. Promote, roll back and runs from the Run tab use **your**
account, which needs the ConfigMgr rights in [ConfigMgr permissions](REQUIREMENTS.md#configmgr-permissions). Only the
scheduled task runs as the computer account.

### Command line

```powershell
cd 'C:\Program Files\SCCMDriverAutomation'

# What is deployed where, and what each ring would roll back to
.\Get-DriverVersionReport.ps1 | Format-Table
.\Get-DriverVersionReport.ps1 -DistributionStatus | Format-Table   # adds DP status from ConfigMgr
.\Get-DriverVersionReport.ps1 -History | Where-Object Action -in 'Rollback','Block'

# Inspect versions of one model
.\Invoke-DriverRollback.ps1 -Vendor Dell -Model 'Latitude 7440' -OperatingSystem 'Windows 11' -ListVersions

# Roll back Production to the previous version. The bad version is blocked so the schedule won't redeploy it.
.\Invoke-DriverRollback.ps1 -Vendor Dell -Model 'Latitude 7440' -OperatingSystem 'Windows 11' -Reason 'INC0012345 audio BSOD'

# Roll back to a specific version and freeze the ring until further notice
.\Invoke-DriverRollback.ps1 -Vendor HP -Model 'HP EliteBook 840 14 inch G10 Notebook PC' -OperatingSystem 'Windows 11' -OSBuild 24H2 `
    -ToVersion '7.00-A-1' -Hold -Reason 'CHG0004567'

# Promote Pilot -> Production early (or when AutoPromoteAfterDays = 0)
.\Invoke-DriverPromotion.ps1 -Vendor Lenovo -Model 'ThinkPad T14 Gen 4' -OperatingSystem 'Windows 11' -OSBuild 24H2 -Reason 'Pilot sign-off'

# Ledger-only controls
.\Set-DriverDeploymentState.ps1 -Vendor Dell -Model 'Latitude 7440' -OperatingSystem 'Windows 11' -UnblockVersion A11 -Reason 'Fixed by BIOS 1.9'
.\Set-DriverDeploymentState.ps1 -Vendor Dell -Model 'Latitude 7440' -OperatingSystem 'Windows 11' -ReleaseRing Production -Reason 'Resolved'
```

The rollback and promotion scripts ask for confirmation (`ConfirmImpact = High`). They support
`-WhatIf` and `-Confirm:$false`, and they require `-Reason`. Clients receive rolled-back content once
the new content version reaches their distribution point. Binary differential replication (enabled
by default) shortens that, because the older content is usually still largely present on the DPs.

---

## Migrating from the Driver Automation Tool

DAT creates a new package per version with the same name. This tool manages exactly one package per
name and ring, so it stops with a clear error when it finds duplicates or an unmanaged package with
the same name. To migrate a model, choose one of these:

* Remove or rename the old DAT packages (rename to `... Retired` to keep them out of MDM). This tool
  then creates fresh packages.
* Leave a single DAT package per name and set `ConfigMgr.AdoptExistingPackages = true`. That package
  is taken over, keeps its PackageID, and is re-pointed to this tool's version folders on the next
  release. The adoption is recorded in the ledger.
