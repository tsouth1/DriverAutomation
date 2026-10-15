# SCCMDriverAutomation

Driver pack automation for Configuration Manager. It runs unattended as **SYSTEM** on the site
server, or on a separate member server, and does the following:

* Reads the official Dell, HP and Lenovo driver pack catalogs.
* Downloads new releases through your proxy.
* Verifies each download with the vendor hash and Authenticode, and scans it with Defender.
* Stages each release as an **immutable, versioned** folder.
* Keeps one ConfigMgr package per model, OS and ring pointed at the chosen version.
* Records every change in an auditable ledger, so any model can be **rolled back** with one command.

See [ANALYSIS.md](ANALYSIS.md) for the review of the upstream Driver Automation Tool and why this
design differs.

---

## Contents

| File | Purpose |
|---|---|
| `Invoke-DriverAutomation.ps1` | Scheduled entry point (`-DryRun`, `-PreflightOnly`, `-Vendor`, `-Model`) |
| `Invoke-DriverRollback.ps1` | Roll a ring back to the previous or a specific version (`-ListVersions` to inspect) |
| `Invoke-DriverPromotion.ps1` | Promote Pilot (or a specific version) to Production |
| `Set-DriverDeploymentState.ps1` | Block / unblock versions, hold / release rings (ledger only) |
| `Get-DriverVersionReport.ps1` | What is deployed where, rollback targets, history, DP status |
| `Get-DriverCatalogModels.ps1` | Every model and Windows build the vendor catalogs publish packs for, with the exact Model / SystemIds values to configure |
| `Start-DriverAutomationGUI.ps1` | Management GUI: versions and history, promote / roll back / block / hold, runs, configuration editor, log and report viewer |
| `Set-DriverAutomationProxyCredential.ps1` | Store a proxy credential (only if computer-account auth is not possible) |
| `Install-DriverAutomation.ps1` | Install, lock down ACLs, register the event source and the SYSTEM scheduled task, run the preflight |
| `Config\DriverAutomation.json` | All settings and the list of managed models |
| `Modules\SCCMDriverAutomation\` | The module: Logging, Configuration, VersionStore, Network, Catalog, CatalogBrowse, Vendor{Dell,HP,Lenovo}, Staging, ConfigMgr, Deployment, Session |

---

## How it works

```
 Vendor catalog (signed CAB / HTTPS XML)
          │  newest pack for model + OS
          ▼
 Known in ledger? ── yes ──► already deployed / blocked / held?  → nothing to do
          │ no
          ▼
 Download (proxy, resume, retry) → vendor hash + Authenticode → Defender scan
          → extract → INF check → DISM WIM capture → DriverManifest.json
          ▼
 <package source share>\<Vendor>\<Model>\<OS Build Arch>\<VersionId>\   (immutable)
          ▼
 Entry ring package (Pilot if enabled, else Production)
   create once, afterwards only PkgSourcePath is re-pointed + RefreshPkgSource
          ▼
 Optional auto-promotion Pilot → Production after N days, then retention
```

### Versioning model

* **One package per model, OS and ring.** The PackageID never changes. Deploying a version, promoting
  it or rolling it back only changes the package's source path, version field and description, and
  then triggers a DP content update. Task sequences that reference the package directly keep working,
  and so does Modern Driver Management (`Invoke-CMApplyDriverPackage.ps1`).
  * Production package: `Drivers - Dell Latitude 7440 - Windows 11 x64`
  * Pilot package: `Drivers Pilot - Dell Latitude 7440 - Windows 11 x64`. MDM excludes names
    containing *Pilot* in Production mode and uses them in Pilot mode.
* **Version folders are immutable.** They are built in a temporary folder and renamed into place, so
  every retained version is an exact, re-deployable copy. The `DriverManifest.json` inside each folder
  records the source URL, hashes, signer, INF count and who staged it.
* **Ledger.** `<DataRoot>\State\<model-key>.json` holds the PackageID per ring, the deployed version
  per ring, holds, every staged version (Available / Blocked / Pruned), and an append-only history of
  Stage / Deploy / Promote / Rollback / Block / Unblock / Hold / Release / Prune / Adopt entries. Each
  history entry records the initiating identity and the reason. Writes are atomic and keep a `.bak`
  copy. A machine-wide mutex prevents the scheduled run and an administrator's rollback from
  interleaving.
* **Retention.** `RetainVersions` staged versions are kept per target, minimum 2. Versions deployed
  to any ring, and each ring's current rollback target, are never pruned.
* **Vendor re-releases.** If a vendor republishes a pack under the same version label with a different
  payload, the new staging is given a suffix, e.g. `A11-1f2e3d4c`.
* **No automatic downgrades.** If a vendor withdraws a release and the catalog points back at an older
  pack, the run logs a warning instead of downgrading.

### What it downloads

The tool downloads the vendors' **enterprise driver packs**, not the latest individual drivers. Each
run takes the newest pack the catalog lists for a model, OS and build:

| Vendor | Catalog | Packs |
|---|---|---|
| Dell | `downloads.dell.com/catalog/DriverPackCatalog.cab` | Dell Command Deploy driver packs |
| HP | `hpia.hpcloud.hp.com/.../HPClientDriverPackCatalog.cab` | HP Driver Pack SoftPaqs, per platform and Windows build |
| Lenovo | `download.lenovo.com/cdrt/td/catalogv2.xml` | SCCM driver packs, per model and Windows build |

Vendors rebuild these packs every few months, less often for older models, and some models stop
getting new packs. Individual drivers (graphics, Wi-Fi, chipset) and BIOS updates are released more
often, so a pack is usually behind what Dell Command Update, HP Image Assistant or Lenovo System
Update would install. The packs are still the usual choice for OS deployment: the vendor tests them as
a set, they hold plain INF drivers that DISM can inject offline, and they are signed and hashed in the
catalog, which the tool verifies.

Use the packs to give a freshly imaged device working storage, network and base drivers. To keep
drivers current afterwards, use the vendor update tool, Windows Update for Business driver updates or
ConfigMgr third-party updates. Individual drivers and BIOS updates are not in scope for this tool.

---

## Requirements

The tool can run on the **site server** (primary or CAS) or on a **separate member server**, such as a
management or file server. The site server is the simplest choice: the site and the SMS Provider are
detected automatically, and the package source share and ConfigMgr access are usually in place already.

### Every server

* Windows Server 2016 or later, domain-joined, with Windows PowerShell 5.1. `dism.exe`, `expand.exe`
  and `robocopy.exe` are built in.
* `General.DataRoot` on a local fixed drive of the server running the tool. Downloads, extraction,
  WIM capture, ledgers and logs live there.
* Disk space: driver packs are 1–3 GB each, plus the WIM. Size `MinimumFreeSpaceGB` accordingly. It is
  checked on the data root and on the package source, including when that is a remote share.
* Outbound HTTPS to the vendor domains for the running server's computer account
  (see [Network](#network-proxy-and-security-tooling)).
* ConfigMgr rights for the running server's **computer account** (see
  [ConfigMgr permissions](#configmgr-permissions)).
* A package source share. Set `ConfigMgr.PackageSourceUncRoot` to its UNC path. ConfigMgr packages
  point there, so the site server must be able to read it. Then either:
  * **Share on the server running the tool:** set `PackageSourceLocalRoot` to the local path of the
    same folder. The preflight writes a test file locally and checks it is visible through the UNC
    path.
  * **Share on another server:** leave `PackageSourceLocalRoot` blank. Content is written to the share
    directly. WIMs are captured under `DataRoot` first and then copied across. The preflight checks
    the share is reachable and writable.

### Running from a separate server

Everything above, plus:

* **Site connection.** Set `ConfigMgr.SiteCode` (e.g. `PS1`) and `ConfigMgr.ProviderMachine` (the SMS
  Provider's FQDN). They are only detected automatically on a server that hosts the SMS Provider.
* **Network to the SMS Provider.** With `CimProtocol` = `Dcom` (default), allow TCP 135 and the dynamic
  RPC ports from this server to the SMS Provider. With `Wsman`, allow TCP 5985 and make sure WinRM is
  enabled on the SMS Provider.
* **Computer account.** Wherever this README says computer account, use this server's account
  (`DOMAIN\SERVER$`), not the site server's. It needs the ConfigMgr role below and **Modify** on the
  package source share and folder.
* **Site server read access.** When the share is not on the site server, give the site server's
  computer account **Read** on the share and folder, so it can copy the content to distribution
  points.
* **Proxy.** Allow this server's computer account through the proxy. A stored proxy credential only
  works on the server where it was saved, so run `Set-DriverAutomationProxyCredential.ps1` there.
* **One server only.** The lock that stops runs from overlapping is per server, and the ledgers live
  in that server's `DataRoot`. Never run the scheduled task on two servers against the same packages.
  When moving an existing installation, disable the old task and copy `<DataRoot>\State` to the new
  server.
* The rollback, promotion, block and hold scripts and the GUI read the local ledgers, so run them on
  this server.

### ConfigMgr permissions

The task runs as SYSTEM, so it reaches the SMS Provider as the running server's computer account
(`DOMAIN\SERVER$`). No user or service account is involved. One-time setup:

1. Create an AD group, e.g. `SCCM-DriverAutomation`, and add the running server's computer account to
   it.
2. In the console, go to **Administration → Security → Administrative Users → Add User or Group**.
   Add the group with a security role that covers the following, scoped to the security scope your
   driver packages use (e.g. *Default*):
   * **Package**: Read, Create, Modify, Distribute, Move Object, Set Security Scope
   * **Folder Class**: Read, Create, Modify
   * **Distribution Point**: Read
   * **Distribution Point Group**: Read, Modify

   The built-in *Operating System Deployment Manager* role covers these. A copied, trimmed custom role
   is preferable.
3. Refresh the computer account's Kerberos ticket so it picks up the new group: reboot, or run
   `klist -li 0x3e7 purge` from an elevated prompt.
4. Give the computer account **Modify** on the package source folder (share and NTFS). This is usually
   already in place when the tool runs on the site server and the share is local to it.

Administrators who run the rollback and promotion scripts use their own ConfigMgr rights. Those
scripts must be run elevated on the server where the tool is installed.

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

## Day-to-day operations

### Management GUI

The installer adds **Start menu > SCCM Driver Automation**. You can also run
`.\Start-DriverAutomationGUI.ps1` from the install folder. It asks for elevation because the scripts
require it.

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
account, which needs the ConfigMgr rights in [ConfigMgr permissions](#configmgr-permissions). Only the
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

## Network, proxy and security tooling

The aim is traffic that proxies, secure web gateways, AV and EDR recognise as legitimate. Nothing in
the design tries to hide from them.

### Proxy

| `Network.ProxyMode` | Behaviour |
|---|---|
| `WinHttp` *(default)* | Uses the machine proxy (`netsh winhttp set proxy proxy.corp:8080 "<local>;*.corp.local"`). This is the correct place for a SYSTEM task's proxy. The value is read from the registry, so it does not depend on the server's display language. |
| `Manual` | `ProxyUrl` plus `ProxyBypass` host patterns. |
| `System` | WinINET / PAC / WPAD of the executing account. SYSTEM rarely has any, so this is mostly useful for interactive testing. |
| `None` | Direct connection. |

| `Network.ProxyAuthentication` | Behaviour |
|---|---|
| `DefaultCredentials` *(default, recommended)* | Authenticates as the computer account via Negotiate/Kerberos (NTLM fallback). No secret is stored. Ask the proxy team to allow the AD group above for the vendor domains. |
| `StoredCredential` | Uses a credential saved with `Set-DriverAutomationProxyCredential.ps1`. It is encrypted with DPAPI (LocalMachine scope) and the file ACL allows only SYSTEM and Administrators. Avoid proxies that accept only Basic authentication. |
| `None` | Anonymous. |

### Destinations to allow-list

These hosts are needed for the catalogs, the packs and Dell's redirect target:

* `downloads.dell.com`, `dl.dell.com`
* `hpia.hpcloud.hp.com`, `ftp.hp.com`
* `download.lenovo.com`

The tool refuses any URL, including a redirect target, outside `Network.AllowedDomains`, and refuses
anything that isn't HTTPS. HTTP links in vendor catalogs are upgraded to HTTPS. Every request carries
the fixed `User-Agent` from the configuration, so proxy and EDR rules can match on it.

### TLS inspection

Certificate validation is never disabled. If the proxy re-signs TLS, its root CA must be in the
server's **LocalMachine\Root** store. Many organisations bypass inspection for these vendor CDN
domains because the payloads are multi-GB signed binaries. That decision belongs to your security
team. The tool works either way.

### AV / EDR

What the tool does to stay compatible:
* The scheduled task command line is plain: `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File ...`.
  * There is no `-EncodedCommand` and no `-ExecutionPolicy Bypass`.
  * There is no download-and-execute from %TEMP%.
* With `-SigningCertificateThumbprint`, the installer signs every script and the task runs under
  `AllSigned`. That works with WDAC or AppLocker script enforcement.
* Vendor extractors run only after the vendor hash has matched and their Authenticode signer (Dell /
  HP / Lenovo) has been verified. They run from `<DataRoot>\Work\Downloads`, a fixed, ACL-protected
  path.
* After download and after extraction, the tool runs an explicit **Microsoft Defender on-demand scan**
  (`MpCmdRun -Scan -ScanType 3`). A detection stops the import.

What to agree with the security team:
* Allow the vendor self-extractors by **publisher (signer) rule**, not by path exclusion, if EDR flags
  the child processes they spawn.
* Keep Defender exclusions to the ones Microsoft documents for ConfigMgr site servers. **Do not
  exclude** `Work\Downloads` or `Work\X`; the tool depends on those folders being scanned.
* Optionally alert on event IDs 1002 (run failed) and 1101 (rollback) from source `SCCMDriverAutomation`.

---

## Logs, events and exit codes

| Item | Location |
|---|---|
| CMTrace log (rolls at `LogMaxSizeMB`) | `<DataRoot>\Logs\DriverAutomation.log` |
| Per-run CSV report (last 90 kept) | `<DataRoot>\Logs\Reports\Run-yyyyMMdd-HHmmss.csv` |
| DISM capture logs | `<DataRoot>\Logs\dism-*.log` |
| Ledgers | `<DataRoot>\State\*.json` (+ `.bak`) |
| Version provenance | `DriverManifest.json` in every version folder |

Event log: Application, source `SCCMDriverAutomation`.

| Event ID | Meaning |
|---|---|
| 1000 | Run succeeded |
| 1001 | Run finished with failures |
| 1002 | Run failed |
| 1100 | Deploy or promote |
| 1101 | Rollback |
| 1102 | Block, unblock, hold or release |

Exit codes of `Invoke-DriverAutomation.ps1`: `0` success, `1` one or more targets failed, `2` fatal
error (configuration, lock, prerequisites or site connection).

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

---

## Scope and limitations

* **Standard packages, not driver catalog import.** Like DAT and MDM, drivers are delivered as
  standard packages and applied with DISM, or with *Apply Driver Package* pointed at the package
  content. Importing tens of thousands of INFs into the ConfigMgr driver catalog bloats the site
  database and slows the console; Microsoft and the community moved away from that pattern.
* Vendor driver packs only. BIOS/firmware, HP per-SoftPaq builds and Dell DCU-style "latest drivers"
  builds are not implemented.
* Arm64 is supported where Dell publishes Arm64 packs. The HP and Lenovo catalogs handled here are x64.
* Lenovo's catalog has no version numbers, so the pack date (`yyyyMMdd`) is the version.

## Testing status

Verified on Windows PowerShell 5.1:
* Configuration validation
* Live parsing of the current Dell, HP and Lenovo catalogs, including Dell and HP catalog signature
  verification
* The SystemId / name conflict guard
* Download, resume, retry and the 404 fast-fail
* Domain allow-list, HTTPS upgrade, zip-slip protection and the delete-path guard
* Hash and Authenticode gates
* Ledger persistence and backup recovery
* Rollback candidate selection, block and hold
* Retention
* The full per-target pipeline in `-DryRun`, including Pilot auto-promotion
* Catalog browsing: every Lenovo row and a 450-row sample across all vendors resolve to the same pack
  with the deployment resolvers, apart from a handful of retired builds where two catalog entries list
  the same hardware and the runtime takes the newest of them

**Not yet exercised against a live site:**
* The ConfigMgr writes: package create / re-point / distribute and folder moves
* Multi-GB extraction and DISM capture

Before you rely on rollback, run `-PreflightOnly` and a first real run against a lab site or a single
model, then do one rollback test.
