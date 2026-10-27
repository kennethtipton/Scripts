# PoshAcme - Let's Encrypt Automation: Synopsis

Location: `C:\SCRIPTS\Applications\OpenSource\PoshAcme`
Last updated: 2026-10-21

## What this is

Automatic Let's Encrypt certificate renewal and deployment, built on the open-source
**Posh-ACME** and **Posh-ACME.Deploy** PowerShell modules (MIT, by Ryan Bolger; installed from
the PowerShell Gallery, not stored here).

It is split into two parts:

- **Core** (`PoshAcme\`): installs the two modules and the shared `Certs\` folder (Posh-ACME
  data). The same on every server that gets Let's Encrypt certificates.
- **Server roles** (`PoshAcme\<Role>\`): what to do with the certificate on that kind of
  server. Today: `ExchangeServer\` (GGI's two Exchange 2019 servers). Later roles (RDS, IIS)
  go in their own subfolders and reuse the core.

Each part has a manifest in `C:\SCRIPTS\Installs\Data\` (used by `C:\SCRIPTS\Installs\SetupApplications.ps1` and `Copy-FilesToServer`):
`PoshAcme.json` (core) and `PoshAcmeExchangeServer.json` (Exchange role, `DependsOn` the core,
so copying the role also copies the core).

### Exchange role

Every day a scheduled task on each Exchange server:

1. Renews that server's Let's Encrypt certificate when due (about every 60 days).
2. Deploys it to the Exchange front end: IIS 443 (OWA, ECP, ActiveSync), IMAP, POP, SMTP.
3. Binds it to the **Exchange Back End** IIS site on port 444 (Exchange's own cmdlets do not).
4. Keeps the internal transport (SMTP between the Exchange servers) on the stable
   Auth certificate instead of the 90-day LE cert.
5. Verifies 443 and 444 and logs the result.

Both servers are set up identically: same folder, same scripts, same task.

### Certificate management window

`Show-PoshAcmeCertificateManagement.ps1` (core, 1.1.0) is the interactive tool for the
Posh-ACME side. Run it on the server itself, elevated, as the renewal account
(`RunAs`, GENERATIONSGAIT\Administrator):

- **Account:** Let's Encrypt production or staging, create the ACME account (contact e-mail),
  change the contact, pick the current account. A brand-new server starts here.
- **Certificates:** every order with expiry, DNS plugin and what uses it. **New...** requests
  a certificate. DNS validation either reuses the saved settings of an existing certificate
  or uses any of Posh-ACME's DNS plugins (HurricaneElectric, Cloudflare, Route53, Azure,
  Windows DNS, RFC2136, ...); the fields come from the plugin itself. Also **Renew now**,
  **DNS settings...** (e.g. new HE password), **Remove...** (optionally revoke).
- **IIS Deployments:** (IIS role only) one row per HTTPS binding in IIS with a certificate
  drop-down; **(none)** stops managing that binding (IIS keeps its current certificate). Saves
  `IisServer\Data\Deployments\IisCertificates.json` and runs `Renew-IisLE.ps1 -DeployCurrent`.
  Bindings themselves are added and removed in IIS Manager.

DNS credentials are needed only when a certificate is first requested (or its DNS settings
change). Posh-ACME saves them with the order, encrypted for the account that entered them,
and reuses them on every renewal. They never go into this application's files or logs.
Defaults (preselected plugin, DNS wait, key sizes) are under `Manager` in `Data\PoshAcme.json`.
## Servers

| | SRV010010037050 | SRV010010050050 |
|---|---|---|
| IPv4 / IPv6 | 10.10.37.50 / 2001:470:c03f:25::32 | 10.10.50.50 / 2001:470:c03f:32::32 |
| LE certificate (thumbprint) | 9235D06E3B6AA931E49E9B811F609FF55D7C545C | 3F5865A81547C5A972D53CC314E5980B3B51365A |
| LE certificate expires | 2026-12-18 | 2026-11-16 |
| Posh-ACME account | 89735466 | 113484768 |
| Validation | DNS, Hurricane Electric plugin | DNS, Hurricane Electric plugin |
| Old task (to be replaced) | `\LetsEncrypt\Posh-ACME Submit Renewal (SRV010010037050-EXCHANGE)` | `\Microsoft\Exchange (POSH-ACME)\Exchange Server srv010010050050` |

Shared on both servers:

- **Auth / internal transport certificate:** `B1E5BFBCC966D2D0F563D18B0E91CDCBC8D7C1F6`
  (CN=Microsoft Exchange Server Auth Certificate, expires 2031-10-12)
- **Task account:** `GENERATIONSGAIT\Administrator`. The HE plugin credentials are saved
  encrypted for this account; the task must run as it.

## Files

| File | Version | Purpose |
|---|---|---|
| `Install-PoshAcme.ps1` | 2.2.0 | Core install / rebuild, settings from `Data\PoshAcme.json`: `Certs` folder and permissions, machine `POSHACME_HOME` (set first), modules (newest only), then the data: disables the old tasks, zips `C:\POSHACME`, copies `C:\POSHACME\certs` to `Certs` and compares every file, checks the account, order and DNS credentials from `Certs`, then renames `C:\POSHACME` to `C:\POSHACME.migrated`. `-Resync` copies again if an old task renewed since |
| `Test-PoshAcmePrerequisites.ps1` | 1.4.0 | Read-only core check: session and run-as account, signatures, modules (one version, newest), `POSHACME_HOME`, data stores and orders, old tasks and old folder, outbound 443 |
| `ExchangeServer\Install-ExchangeLE.ps1` | 2.1.0 | Exchange role: checks the core is installed, registers the task, disables old tasks |
| `ExchangeServer\Renew-ExchangeLE.ps1` | 2.1.0 | Run daily by the task. `-DeployCurrent` redeploys the current cert without renewing |
| `ExchangeServer\Test-ExchangeLEPrerequisites.ps1` | 2.1.0 | Read-only Exchange check (PASS/WARN/FAIL/INFO), including WinRM. `-RepairWinRM` fixes only missing pieces |
| `ExchangeServer\Functions\Set-ExchangeBackEndCertificate.ps1` | 1.1.0 | Binds a cert to Exchange Back End :444 |
| `ExchangeServer\Functions\Set-InternalTransportCertificate.ps1` | 1.1.0 | Pins the default internal transport (SMTP) cert |

Settings, copied with the application (the install scripts read them from their own folder; the deployment manifests in `C:\SCRIPTS\Installs\Data` stay on the setup machine):

- `Data\PoshAcme.json` - core: version, run-as account, modules and where Posh-ACME keeps its data (`POSHACME_HOME`), migration paths. Bump `Version` whenever a core file changes; the setup window compares it with each server's copy.
- `ExchangeServer\Data\PoshAcmeExchangeServer.json` - Exchange role: version, run-as account, internal transport (Auth) thumbprint, Exchange servers, task path/name/time.
- Per-server overrides: `<file>.<COMPUTERNAME>.json` next to either file lists only what differs on that server (read with `C:\SCRIPTS\Functions\Get-ApplicationSettings.ps1`). Example: `Data\PoshAcme.SRV010010200051.json` sets `RunAs` to `TNC\Administrator` and `Domain` to `mail.tnandc.net` (the main domain of that server's order).
- Both Posh-ACME data layouts are handled: `acme-v02.api.letsencrypt.org\<account>\<domain>` (older stores, the GGI servers) and `LE_PROD\<account>\<order name>` (Posh-ACME 4.x, srv010010200051). Orders are matched by main domain.

Folders created on the server:

- `Certs\` - Posh-ACME data (`POSHACME_HOME`), shared by all roles: ACME account key, orders, PFX files. The whole `PoshAcme` folder is Admins/SYSTEM only. Never copy into source control.
- `Backups\` - zip of the whole old `C:\POSHACME` (scripts and data) taken before migration. Contains the old plain-text PFX password; Admins/SYSTEM only.
- `ExchangeServer\Logs\Transcripts\` - full console output of each renew run (kept 90 days).

Logging:

- Core install: `C:\SCRIPTS\Logs\PoshAcme.log`.
- Exchange role: `C:\SCRIPTS\Logs\ExchangeLetsEncrypt.log` (newest first), via `C:\SCRIPTS\Functions\Write-AdvancedLog.ps1` (v1.1.0).
- WARNING/ERROR also go to the **Managed Powershell Scripts** event log (source `ManagedPSScripts`, IDs 2/3).

Scheduled task: `\Exchange\LetsEncrypt\RenewExchangeCertificate`, daily at 03:47.
A real renewal restarts IIS (about 30-60 s OWA/ECP blip); a no-renewal day changes nothing.

## Status (2026-10-12)

### Done

- [x] Expiring cert found: the "CN=Federation" cert `0A7D...` was actually the **OAuth (Auth) cert**, expiring 2026-10-12. Replaced with `B1E5BF...` and published (`Set-AuthConfig`); present on both servers. There is no federation trust in the org.
- [x] 050050: `MSExchangePowerShellAppPool` was stopped (EMS fell over to 037050). Started; EMS connects locally.
- [x] 037050: `MSExchangeOWAAppPool` had autoStart off (did not start after reboot). Fixed; all 17 pools started with autoStart on, both servers.
- [x] Scripts rewritten into this package, following the C:\SCRIPTS conventions; pre-install check passes on both servers.
- [x] WinRM fixed: the GPO `DesktopsAndLaptops(CommonSettings)` had a typo and wrong ranges in its IPv6 filter, so WinRM only listened on IPv4. Corrected for all sites; both servers now run remote commands on each other by name. A stray WinRM HTTPS listener on 443 (037050) is gone.
- [x] GPO cleanup: 41 GPOs down to 8 (unlinked and obsolete ones removed; backup in `C:\SCRIPTS\DATA\GPOBackups\`).
- [x] Script signing: `C:\SCRIPTS\Functions\Set-ScriptSignature.ps1` signs with the GGI code-signing cert `F1C24CF6B8C13B81BE0C8295D75919CB5F8E4C35` (domain sub CA, trusted by all domain machines). 58 scripts signed, all Valid.

### To do - Let's Encrypt (in order, one server at a time)

- [ ] Remove the earlier test copy `C:\SCRIPTS\Applications\POSHACME` on both servers; place this package at `C:\SCRIPTS\Applications\OpenSource\PoshAcme`.
- [ ] Sign it: `Set-ScriptSignature -Path 'C:\SCRIPTS\Applications\OpenSource\PoshAcme'`.
- [ ] Copy to both servers from the admin workstation: `C:\SCRIPTS\Installs\SetupApplications.ps1`, tick PoshAcmeExchangeServer (copies the core too, checks/fixes the modules; Preview first). It lists the install steps below.
- [ ] On each server (OpenSSH, elevated `powershell.exe`, not EMS / pwsh 7), as `GENERATIONSGAIT\Administrator`:
  - [ ] `Test-PoshAcmePrerequisites.ps1`; no FAIL.
  - [ ] `Install-PoshAcme.ps1`. Must run as `GENERATIONSGAIT\Administrator` (owns the DNS credentials), otherwise step 4 fails and the old tasks are enabled again. Do not use `-SkipModuleReinstall` on 037050 (it has Posh-ACME 3.15.0).
  - [ ] `ExchangeServer\Test-ExchangeLEPrerequisites.ps1`; no FAIL outside WinRM.
  - [ ] `ExchangeServer\Install-ExchangeLE.ps1`. The task account defaults to `GENERATIONSGAIT\Administrator` (`-TaskUser`); only its password is prompted for on the console.
- [ ] Run `ExchangeServer\Renew-ExchangeLE.ps1 -DeployCurrent`. Expect in the log: `Deployment complete`, 443 and 444 on the LE thumbprint.
  - 037050: back end 444 moves from the **missing** cert `6AB0ED...` to `9235D0...`.
  - 050050: internal transport moves from the LE cert to `B1E5BF...`.
- [ ] After the first real renewal from the new task (050050 due around mid-October): confirm 443 and 444 both changed to the new thumbprint, then run `ExchangeServer\Install-ExchangeLE.ps1 -RemoveOldTasks` and delete `C:\POSHACME.migrated` (it contains a plain-text PFX password in the old scripts; the zip in `Backups\` stays).
- [ ] Remove the retired certs from both servers once stable: `0A7D34BE...` (old Auth, expired) and `E306868...` (unused Federation).
- [ ] Rotate the Posh-ACME PFX password (`Set-PAOrder <domain> -PfxPass ...`); the current one was exposed in old scripts.
- [ ] Optional hardening: execution policy `AllSigned` for servers (GPO) and drop `-ExecutionPolicy Bypass` from the task, so signatures are enforced.

### To do - related infrastructure found along the way

- [ ] **Firewall: `WINDOWS_REMOTE_MANAGMENT_(WinRM)` rule** in GPO `DesktopsAndLaptops(Firewall Rules)` (linked at GGI) allows **all ports from any address**. Restrict to TCP 5985/5986 and the management addresses below.
- [ ] **NetXMS GPO** (old `Firewall Settings` GPO was deleted): create `Servers_NetXmsAgent` with inbound TCP 4700 (check `ListenPort` in `nxagentd.conf`), UDP 161 and ICMP echo from the management addresses; WMI filter `ServerOS` (`ProductType = "2" OR ProductType = "3"`); link at `GGI` and `Domain Controllers`.
- [ ] Decide on the removed `GGI MANAGEMENT SERVER` rule (all ports from the management server); replace with something narrower if still needed.
- [ ] **DNS cleanup** on both Exchange servers: stop registering `169.254.x`, `fe80::` and `fde1:` addresses (`Set-DnsClient -RegisterThisConnectionsAddress $false` on the right adapters, delete stale records). Check what the 169.254.1.2 adapter is first.
- [ ] Recreate printer deployment (old printer GPOs broke with type 4 drivers) and certificate autoenrollment for the new cert servers.

Management / NetXMS addresses (IPv6 derived from the addressing scheme; verify each):

| IPv4 | IPv6 |
|---|---|
| 10.10.37.59 | 2001:470:c03f:25::3b |
| 10.10.37.200 | 2001:470:c03f:25::c8 |
| 10.10.37.205 | 2001:470:c03f:25::cd |
| 10.10.37.217 | 2001:470:c03f:25::d9 |
| 10.10.200.41 | 2001:470:8:a36::29 |
| 10.10.200.42 | 2001:470:8:a36::2a |
| 10.10.200.200 | 2001:470:8:a36::c8 |

## Conventions (apply to all changes)

- Layout: `$SL` C:\SCRIPTS, `$SF` C:\SCRIPTS\Functions (shared), `$SD` C:\SCRIPTS\DATA, `$SG` C:\SCRIPTS\LOGS, `$SA` C:\SCRIPTS\Applications, `$SCA` current application, `$SCAPF` the application's own Functions folder. Apps are grouped by vendor/source: `Applications\OpenSource\`, `Applications\Microsoft\Exchange\`, `Applications\Microsoft\ActiveDirectory\`, `Applications\MikroTik\`, `Applications\3CX\`.
- PascalCase for folders, files and variables. No spaces; use an underscore if one is unavoidable.
- Standard header block (Author, Company, Date, Version, AI Used, MIT license, Overide Variables). Bump the version on every change.
- Shared functions are dot-sourced from `$SF`; logging goes through `Write-AdvancedLog`.
- Windows PowerShell 5.1 compatible, ASCII only.
- Re-sign after every edit: `Set-ScriptSignature` (signs unsigned and changed scripts, skips the rest; adds the trailing blank line that signing needs).

## Quick reference

```powershell
# From the admin workstation: copy core + Exchange role to both servers
C:\SCRIPTS\Installs\SetupApplications.ps1
# or without the window:
. C:\SCRIPTS\Functions\Copy-FilesToServer.ps1
Copy-FilesToServer -Name PoshAcmeExchangeServer -WhatIf

# On the server: core, then the Exchange role
C:\SCRIPTS\Applications\OpenSource\PoshAcme\Test-PoshAcmePrerequisites.ps1
C:\SCRIPTS\Applications\OpenSource\PoshAcme\Install-PoshAcme.ps1
C:\SCRIPTS\Applications\OpenSource\PoshAcme\ExchangeServer\Test-ExchangeLEPrerequisites.ps1
C:\SCRIPTS\Applications\OpenSource\PoshAcme\ExchangeServer\Install-ExchangeLE.ps1

# Deploy the current cert now (no renewal)
C:\SCRIPTS\Applications\OpenSource\PoshAcme\ExchangeServer\Renew-ExchangeLE.ps1 -DeployCurrent

# What is bound where
netsh http show sslcert ipport=0.0.0.0:443 | findstr Hash
netsh http show sslcert ipport=0.0.0.0:444 | findstr Hash
Get-AuthConfig | fl CurrentCertificateThumbprint
Get-TransportService | fl Name, InternalTransportCertificateThumbprint
```
