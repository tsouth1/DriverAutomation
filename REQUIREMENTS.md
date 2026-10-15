# Requirements

What the server, ConfigMgr, the network and your security tooling need before you install
SCCMDriverAutomation. Installation and day-to-day use are in [INSTRUCTIONS.md](INSTRUCTIONS.md), and
the overview is in [README.md](README.md).

* [Where it runs](#where-it-runs)
* [Every server](#every-server)
* [Running from a separate server](#running-from-a-separate-server)
* [ConfigMgr permissions](#configmgr-permissions)
* [Network, proxy and security tooling](#network-proxy-and-security-tooling)

---

## Where it runs

The tool can run on the **site server** (primary or CAS) or on a **separate member server**, such as a
management or file server. The site server is the simplest choice: the site and the SMS Provider are
detected automatically, and the package source share and ConfigMgr access are usually in place already.

## Every server

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

### What the checks verify

Preflight, dry runs and full runs check the package share before doing anything else:

| Check | Account checked | Result |
|---|---|---|
| Share reachable; package folder exists or can be created | The account running the check | Stops the run |
| Write and delete a test file | The account running the check | Stops the run |
| Create nested folders, rename a folder, delete it (what staging and retention do) | The account running the check | Stops the run |
| Free space against `MinimumFreeSpaceGB` | n/a | Stops the run |
| The **site server's** computer account can read the folder (NTFS permissions) and the share (share permissions) | The site server, looked up in ConfigMgr and AD | Warning only |

* **Which account runs the check.** From the GUI or a console, the first three checks run as
  **you**. Only `Install-DriverAutomation.ps1 -RunPreflight` runs them as SYSTEM (the computer account),
  exactly as the scheduled task does. Use that after changing share permissions.
* **The site server check**
  * **How it works.** It finds the site server in ConfigMgr and its groups in Active Directory
    (including nested groups), then compares them with the folder's and the share's permissions.
  * **Groups it always counts.** Everyone, Authenticated Users and the file server's local Users group,
    because every computer account is in them.
  * **Local Administrators.** Access only through the file server's local Administrators group is
    reported as a warning, because membership there can't be seen from here.
  * **When it can't run.** Reading share permissions needs admin rights on the file server; without
    them, only the NTFS permissions are checked and the log says so. If ConfigMgr or AD can't be
    reached, the check is skipped with a warning.
  * **It never stops a run.** Look for these lines in the log: a site server that can't read the share
    makes distribution fail later.

## Running from a separate server

Everything above, plus:

* **Site connection.** Set `ConfigMgr.SiteCode` (e.g. `PS1`) and `ConfigMgr.ProviderMachine` (the SMS
  Provider's FQDN). They are only detected automatically on a server that hosts the SMS Provider.
* **Network to the SMS Provider.** With `CimProtocol` = `Dcom` (default), allow TCP 135 and the dynamic
  RPC ports from this server to the SMS Provider. With `Wsman`, allow TCP 5985 and make sure WinRM is
  enabled on the SMS Provider.
* **Computer account.** Wherever these documents say computer account, use this server's account
  (`DOMAIN\SERVER$`), not the site server's. It needs the ConfigMgr role below and **Modify** on the
  package source share and folder.
* **Site server read access.** When the share is not on the site server, give the site server's
  computer account **Read** on the share and folder, so it can copy the content to distribution
  points. The preflight and every run warn when it can't (see
  [What the checks verify](#what-the-checks-verify)).
* **Proxy.** Allow this server's computer account through the proxy. A stored proxy credential only
  works on the server where it was saved, so run `Set-DriverAutomationProxyCredential.ps1` there.
* **One server only.** The lock that stops runs from overlapping is per server, and the ledgers live
  in that server's `DataRoot`. Never run the scheduled task on two servers against the same packages.
  When moving an existing installation, disable the old task and copy `<DataRoot>\State` to the new
  server.
* The rollback, promotion, block and hold scripts and the GUI read the local ledgers, so run them on
  this server.

## ConfigMgr permissions

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
| `DefaultCredentials` *(default, recommended)* | Authenticates as the computer account via Negotiate/Kerberos (NTLM fallback). No secret is stored. Ask the proxy team to allow the AD group from [ConfigMgr permissions](#configmgr-permissions) for the vendor domains. |
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
