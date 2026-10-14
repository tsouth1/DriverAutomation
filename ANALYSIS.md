# Analysis: MSEndpointMgr Driver Automation Tool (DAT) v10.3.2

This is a review of the upstream repository cloned into the parent folder. The main logic is in
`Driver Automation Tool\Modules\DriverAutomationToolCore\DriverAutomationToolCore.psm1`, a single
module of about 25,500 lines. A WPF UI (`UI\MainApplication.ps1`, about 32,000 lines) and a headless
runner (`Start-DATHeadlessBuild.ps1`) both call into it. Line numbers below refer to that `.psm1`.

## 1. How it queries vendor "APIs"

None of the three OEMs offers a real API for this. DAT downloads the vendor's published XML catalogs
and filters them. The catalog URLs live in `Data\OEMLinks.xml`. At runtime that file is pulled from
`raw.githubusercontent.com/maurice-daly/DriverAutomationTool/master/Data/OEMLinks.xml`
(`Get-DATOEMModelInfo`, ~line 643, URL hard-coded at ~line 653). Whoever controls that GitHub file
therefore controls which download URLs every DAT install uses.

| Vendor | Catalog | Parsing (Get-DATOEMModelInfo / Invoke-DATOEMDownloadModule) | Version used |
|---|---|---|---|
| Dell | `downloads.dell.com/catalog/DriverPackCatalog.cab` → expand.exe | `DriverPackManifest.DriverPackage` filtered by `SupportedOperatingSystems.OperatingSystem.osCode` (`Windows11`) and `osArch`; model from `SupportedSystems.Brand.Model` (`name`, `systemID`); URL = `downloads.dell.com/` + `path` | `dellVersion` (e.g. `A11`) |
| HP | `hpia.hpcloud.hp.com/.../HPClientDriverPackCatalog.cab` | `ProductOSDriverPackList.ProductOSDriverPack` (SystemId, SystemName, OSName `Windows 11 64-bit, 24H2`) joined to `SoftPaqList.SoftPaq` on `SoftPaqId` for URL, version, MD5/SHA256. An alternative "SoftPaq" mode runs HPCMSL `New-HPDriverPack -WhatIf` in a child process and scrapes its console output | SoftPaq `Version` |
| Lenovo | `download.lenovo.com/cdrt/td/catalogv2.xml` (plain XML) | `ModelList.Model` (name, `Types.Type` = MTM), `SCCM` child nodes keyed by `os`/`version` with URL as inner text, plus optional `GFX` supplemental packs | `SCCM@date` |

DAT also calls its own service (`api.driverautomationtool.com`, see `Data\DATAPIConfig.json`) for
Microsoft, Acer, Fujitsu and ASUS. That file ships with **`telemetryEnabled: true`** and an HMAC
secret, so a stock install sends build and driver reports to a third-party endpoint.

## 2. How it downloads and stages drivers

* **Download**: `Invoke-DATContentDownload` (~line 1112). It accepts HTTPS URLs only, sends a HEAD
  request to get the size, and treats a cached file as valid when its size matches. It downloads with
  a bundled `curl.exe` (gated by an Authenticode check or a SHA-256 pin), then System32 curl, then
  HttpClient / Invoke-WebRequest / BITS. The proxy settings come from the registry
  (`Get-DATProxySettings`, modes System / Manual / None), and the proxy password is stored with DPAPI.
* **Integrity**: `Test-DATFileSignature` (~line 265) checks Authenticode against a publisher
  allow-list and extracts ZIPs to check the files inside. Vendor hashes are verified only on some
  paths, such as the Lenovo/Dell "latest drivers" modes and DAT API catalog entries.
* **Extraction**: `Invoke-DATDriverFilePackaging` (~line 1964) uses these switches:
  * Lenovo: `/VERYSILENT /DIR=` (Inno Setup, launched with `-Verb RunAs`)
  * HP: `/s /e /f <dir>`, with the legacy `/s /e=<dir>` as a fallback
  * Others: `/s /e=<dir>`
  * CAB and ZIP files: expand / archive extraction

  It then captures a WIM with wimlib or an external `dism.exe /Capture-Image`, and checks for paths
  longer than 260 characters.

## 3. How it imports into ConfigMgr

* **Connection**: `Connect-DATConfigMgr` resolves the site through `SMS_ProviderLocation`.
  `New-DATCimSession` tries WSMan, then DCOM, then the short hostname, and finally falls back to
  `Get-WmiObject`.
* **Package**: `New-DATConfigMgrPkg` (~line 4578) creates a **standard package** (`SMS_Package`)
  through `[WmiClass]`. It does **not** import drivers into the ConfigMgr driver catalog. The package
  is set up as follows:
  * Name: `Drivers - <OEM> <Model> - <OS> <Arch>`
  * Description: `Models included: <baseboards>`
  * `Version` set to the catalog version
  * Source in `<root>\<OEM>\<Model>\<OS>\<Arch>\<Version>`, converted to a UNC path
  * Moved to the `Driver Packages\<OEM>` console folder
  * Distributed to the selected DP groups / DPs, with optional binary differential replication (BDR)
  * `SourceDate` stamped
* **Consumption**: `Scripts\Invoke-CMApplyDriverPackage.ps1` (Modern Driver Management) runs on the
  client during OSD. It queries the AdminService for packages, drops names containing `Pilot` or
  `Retired` in Production mode (or keeps only `Pilot` in Pilot mode), matches the device SKU against
  the description, and picks the **newest `SourceDate`**.

## 4. Existing versioning and rollback

What exists:
* **Skip if present**: if a package with the same name and the same `Version` exists, the build is
  skipped. A new version creates a **new package with the same name**, so several packages share
  that name.
* **ForceUpdate**: replaces the content of the existing package **in place**. The previous content
  is deleted, so it cannot be restored.
* **Retention**: `Invoke-DATPackageRetention` (~line 14720) keeps `RetainCount` older packages per
  name, ordered by `SourceDate`, and can delete their source folders.
* **Pilot / Retired**: rings are a naming convention (`Drivers Pilot - ...`) that the client script
  honours.
* **Change detection**: fingerprint manifests track changes in the "latest drivers" modes.

What is missing:
* **No rollback operation.** To roll back you must delete or rename the newer package by hand so
  that the client picks the older `SourceDate`. Task sequences that reference a PackageID directly
  need editing.
* **No block list.** The next scheduled build re-creates a version you just removed.
* **No audit trail** of who changed what or why, and no hold / freeze per ring.

## 5. Scheduled / unattended mode

`Register-DATScheduledBuild` (~line 8741) registers `Start-DATHeadlessBuild.ps1` to run as SYSTEM.
It runs with `-ExecutionPolicy Bypass` and refuses to register if the script directory is writable
by non-admins, which is good practice. Configuration is a `BuildConfig.json` exported from the UI,
plus HKLM registry values.

## Conclusions that shaped the custom solution

1. **Keep** the proven vendor catalog sources and parsing rules, the extraction switches, the
   standard-package plus WIM approach, and the naming and description convention. Matching that
   convention keeps the solution compatible with Modern Driver Management (`Invoke-CMApplyDriverPackage.ps1`).
2. **Drop** the runtime download of URLs from GitHub (supply-chain exposure) and the telemetry. Use
   vendor catalog URLs from local configuration only.
3. **Replace** "a new package per version" plus in-place ForceUpdate with **one stable package per
   ring, pointed at immutable version folders**. Deploy and rollback then become the same safe,
   auditable operation, and the PackageID never changes.
4. **Add** a per-model ledger, a block list, ring holds, a mandatory reason on every manual change,
   and event-log auditing.
5. **Design for SYSTEM**:
   * Use the machine WinHTTP proxy and computer-account (Kerberos) proxy authentication.
   * Talk to the SMS Provider over CIM rather than the ConfigurationManager module.
   * Avoid `-ExecutionPolicy Bypass`, and support AllSigned with your own code-signing certificate.
