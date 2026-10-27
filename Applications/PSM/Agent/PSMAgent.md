# PSMAgent — the PSM web service on each server

Location: `C:\SCRIPTS\Applications\PSM\Agent`
Version: 1.0.0 (`Data\PSMAgent.json`)

A small HTTPS web service (Pode 2.14.1 + Pode.Web 1.0.0-preview3) on every PSM server. It shows
**that server's** PSM data — device record, applications and their settings, logs, cleanup list —
as web pages for people and as a JSON API for scripts. It is **read-only**: nothing can be changed
through it.

| | |
|---|---|
| Address | `https://<server-fqdn>:8776/` (8776 = PSM on a telephone keypad) |
| Certificate | the server's auto-enrolled internal CA certificate (template *Client Server Authentication*, GPO *CERTIFICATES*); self-signed with a warning in the log if there is none |
| Sign-in | domain account in **FLD-SCRIPTS.REVIEWERS** or **FLD-SCRIPTS.ADMINS** (nested membership counts) |
| Runs as | scheduled task `\PSM\PsmAgent`, SYSTEM, at startup + a 5-minute watchdog |
| Firewall | rule *PSM Agent (TCP 8776)*, inbound, Domain profile only |
| Logs | `C:\SCRIPTS\Logs\PsmAgent.log` (start, certificate, install) and `C:\SCRIPTS\Logs\PsmAgent\` (Pode's error log, 30 days) |

## Web pages

Open `https://<server-fqdn>:8776/` and sign in with your domain account. The session lasts
`SessionMinutes` (60) and is extended while you use it.

| Page | Shows |
|---|---|
| Overview | server, OS, hardware, disks, PSM sync / log shipping / cleanup results, PSM tasks, unmanaged content |
| Applications | one tab per application: version, folder, which settings layers change which values, the merged settings |
| Logs | any log in `C:\SCRIPTS\Logs`, filtered by type, text and days |
| Cleanup | this server's cleanup list (pending and done) |

## JSON API

All routes are `GET`, return JSON, and — except `/api/health` — need sign-in.

### Sign-in for scripts

The API uses **HTTP Basic** authentication against Active Directory, on every request (no session,
no cookie). The password travels inside the HTTPS connection only. Use a domain account in
FLD-SCRIPTS.REVIEWERS or FLD-SCRIPTS.ADMINS; for unattended scripts, a dedicated service account
added to FLD-SCRIPTS.REVIEWERS.

| Status | Meaning |
|---|---|
| 200 | OK |
| 400 | bad request (for example a log name with `\` or `..`) — body `{ "Error": "..." }` |
| 401 | not signed in, wrong password, or not in an allowed group |
| 404 | no such application on this server — body `{ "Error": "..." }` |
| 500 | the agent failed reading the data — body `{ "Error": "..." }` |

### Routes

| Route | Returns |
|---|---|
| `/api/health` | **No sign-in.** `{ Device, Agent, Time }` — use it for monitoring |
| `/api/device` | the device record (`Applications\Data\device.<SERVER>.json`, written by the Frontend sync): `Device`, `Updated`, `Os`, `Hardware`, `Disks`, `Network`, `PowerShell`, `Psm` (sync, log shipping, cleanup, tasks), `Applications`, `Modules`, `Unmanaged`, `OtherTasks`. Before the first sync: a minimal record with a `Note` |
| `/api/apps` | the applications on this server: `Name`, `Version`, `Folder`, `SettingsFile`, `PublishedOverride` (true when `<App>.<SERVER>.json` exists), `LocalOverride` (the keys the local override sets) |
| `/api/apps/{name}/settings` | one application's settings: `Name`, `Merged` (what the scripts use) and `Layers` — *Published*, *Published for this server*, *Local override* — each with `Path`, `Exists` and `Changes` (`Key` in dotted form, `Value`). `{name}` is the application name or its settings file name; `Scripts` gives `Data\Settings\Scripts.json` |
| `/api/logs` | the logs in `C:\SCRIPTS\Logs`: `Name`, `SizeKB`, `Changed` |
| `/api/logs/{name}` | the entries of one log (name without `.log`), newest first: `Time`, `Script`, `Type`, `Message` |
| `/api/cleanup` | the cleanup list: `Items` and `Done`, each with `Type` (File, Folder, Task), `Path`, `Days`, `Added`, `Due`, `Reason`, `By`, `LastError` |

`/api/logs/{name}` takes these query parameters (all optional):

| Parameter | Example | Meaning |
|---|---|---|
| `since` | `2026-10-26` or `2026-10-26T08:00` | entries at or after this time |
| `type` | `ERROR` | only this type: `INFO`, `WARNING`, `ERROR` |
| `search` | `certificate` | text in the message or script name (not case-sensitive) |
| `max` | `100` | at most this many entries (default `LogMaxEntries` = 500, limit 5000) |

## Examples

### PowerShell

Works in Windows PowerShell 5.1 and PowerShell 7. The server certificate is trusted on domain
machines, so no certificate switches are needed.

```powershell
$Server = 'srv010010037055.generationsgaither.com'
$Base   = "https://${Server}:8776/api"
$Cred   = Get-Credential GENERATIONSGAIT\kennethtipton

# Is it up? (no sign-in)
Invoke-RestMethod "$Base/health"

# The server's device record
$Device = Invoke-RestMethod "$Base/device" -Credential $Cred
$Device.Os
$Device.Psm.Sync

# Applications and one application's settings
Invoke-RestMethod "$Base/apps" -Credential $Cred | Format-Table Name, Version, LocalOverride
$S = Invoke-RestMethod "$Base/apps/PoshAcme/settings" -Credential $Cred
$S.Layers | ForEach-Object { $_.Layer; $_.Changes | Format-Table Key, Value }

# Errors in the last 24 hours of one log
$Since = (Get-Date).AddDays(-1).ToString('s')
Invoke-RestMethod "$Base/logs/Sync-ScriptsFromDfs?type=ERROR&since=$Since" -Credential $Cred |
    Format-Table Time, Script, Message -Wrap

# What is waiting to be cleaned up
(Invoke-RestMethod "$Base/cleanup" -Credential $Cred).Items | Format-Table Type, Path, Due
```

Ask every PSM server at once, for example for errors since this morning:

```powershell
$Cred  = Get-Credential GENERATIONSGAIT\kennethtipton
$Since = (Get-Date).Date.ToString('s')
Get-ADGroupMember 'APP-PowershellScriptsManagement.Frontend' -Recursive | ForEach-Object {
    $Fqdn = "$($_.Name).generationsgaither.com".ToLower()
    try {
        foreach ($Log in Invoke-RestMethod "https://${Fqdn}:8776/api/logs" -Credential $Cred -TimeoutSec 10) {
            Invoke-RestMethod "https://${Fqdn}:8776/api/logs/$($Log.Name)?type=ERROR&since=$Since" -Credential $Cred |
                Select-Object @{ n = 'Server'; e = { $Fqdn } }, @{ n = 'Log'; e = { $Log.Name } }, Time, Message
        }
    }
    catch { Write-Warning "${Fqdn}: $($_.Exception.Message)" }
} | Format-Table -Wrap
```

### curl

```bash
curl https://srv010010037055.generationsgaither.com:8776/api/health
curl -u 'GENERATIONSGAIT\kennethtipton' "https://srv010010037055.generationsgaither.com:8776/api/logs/PsmAgent?max=20"
```

`curl -u` without a password prompts for it. On a machine that does not trust the internal CA, add
`--cacert <IssuingCA chain .pem>` rather than `-k`.

## Install and operate

| Script | What it does |
|---|---|
| `Install-PsmAgent.ps1` | Checks the Pode / Pode.Web versions, stops a running agent, checks the port is free, creates the firewall rule, registers `\PSM\PsmAgent`, starts it and waits for `/api/health`, records the install. `-Remove` deletes the task and the firewall rule; `-NoStart` registers without starting. |
| `Start-PsmAgent.ps1` | The service itself (what the task runs). `-TestMode`: plain HTTP on 127.0.0.1 without sign-in, for development. `-ListenAddress 127.0.0.1`: HTTPS on localhost only (testing without elevation). |
| `Functions\Get-PsmAgentData.ps1` | The read-only data functions behind the pages and the API. |

Installed with **SetupApplications** (application *PSMAgent*); it copies the Pode modules to the
server, so the server needs no internet access.

Check a server:

```powershell
Get-ScheduledTask -TaskPath '\PSM\' -TaskName PsmAgent | Get-ScheduledTaskInfo   # LastTaskResult 267009 = running
Get-NetTCPConnection -LocalPort 8776 -State Listen
Get-Content C:\SCRIPTS\Logs\PsmAgent.log -TotalCount 10                          # newest first
```

After a server gets a new certificate (auto-enrollment renews it before it expires), restart the
task so the agent picks it up:

```powershell
Stop-ScheduledTask -TaskPath '\PSM\' -TaskName PsmAgent; Start-ScheduledTask -TaskPath '\PSM\' -TaskName PsmAgent
```

## Settings (`Data\PSMAgent.json`)

| Setting | Default | Meaning |
|---|---|---|
| `Port` | 8776 | HTTPS port (re-run the installer after a change, for the firewall rule) |
| `Threads` | 3 | request threads |
| `ViewGroups` | FLD-SCRIPTS.REVIEWERS | may sign in and view |
| `AdminGroups` | FLD-SCRIPTS.ADMINS | may sign in; reserved for future actions |
| `SessionMinutes` | 60 | web page sign-in lifetime |
| `Certificate.PreferIssuer` | generationsgaither | a certificate whose issuer contains this wins |
| `Certificate.AllowSelfSigned` | true | start self-signed when there is no CA certificate |
| `LogMaxEntries` | 500 | default `max` for log queries |
| `Modules` | Pode 2.14.1, Pode.Web 1.0.0-preview3 | exact versions imported |

Override per server like any PSM application: `Data\PSMAgent.<SERVER>.json` (published) or
`C:\SCRIPTS\Applications\Data\Settings\PSMAgent.json` (local, never synced).

## Notes

- Do not install the agent on the domain controllers or the CA (srv010010038035): they are Tier 0
  and need no extra listening service.
- Browsers on DT-13GFDV2 see an *AVG Web/Mail Shield* certificate because AVG inspects HTTPS
  there; the server itself serves the CA certificate.
