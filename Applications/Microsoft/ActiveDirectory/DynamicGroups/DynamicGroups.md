# DynamicGroups

Location: `C:\SCRIPTS\Applications\Microsoft\ActiveDirectory\DynamicGroups`
Version: 1.1.0 (`Data\DynamicGroups.json`)
Last updated: 2026-10-19

## What this is

Rule-based ("dynamic") Active Directory groups. Each rule names a group, the OU it lives in, and
the user attributes that decide membership. Every 2 hours (or on demand) the sync:

1. Creates the group in its OU if it does not exist.
2. Finds the enabled users below the search base that match the rule.
3. Adds users who match and are missing; removes users who no longer match.
   Nested groups, computers and contacts in the group are left alone.

Rules are edited in a GUI (`Show-DynamicGroupEditor.ps1`), which can also preview who a rule
matches and what the next run would change.

## Where things live

| What | Where | Copied / synced by PSM? |
|---|---|---|
| Scripts and functions | the application folder | Yes |
| Settings and `Version` | `Data\DynamicGroups.json` (per-server override: `Data\DynamicGroups.<COMPUTERNAME>.json`) | Yes |
| Rules template (no groups) | `Data\DynamicGroupRules.Template.json` | Yes |
| **The rules** | `Data\Rules\DynamicGroupRules.json`, previous versions in `Data\Rules\Backups\` (last 30) | **No: server-local** |
| Run transcripts | `Logs\Transcripts\` (30 days) | No |

The rules are entered on the server after the install, with the editor. A copy from
SetupApplications or the hourly PSM Frontend pull updates the scripts and settings but never
touches `Data\Rules`. The copy in the repository has no groups.

## Install

Manifest: `C:\SCRIPTS\Installs\Data\DynamicGroups.json` (pick it in SetupApplications and add the
server). Then on the server, in Windows PowerShell 5.1 as an administrator:

| Where | Command | Task runs as |
|---|---|---|
| Domain controller | `Install-DynamicGroups.ps1 -RunAsSystem` | SYSTEM (the DC's computer account) |
| Services server, gMSA | `Install-DynamicGroups.ps1 -GmsaAccount 'gmsa-DynGroups$'` | the gMSA (no stored password) |
| Services server, domain account | `Install-DynamicGroups.ps1 -TaskUser 'GENERATIONSGAIT\svc-DynGroups'` | that account (password asked at the console; works over OpenSSH) |

The installer: creates the rules file from the template (or moves a 1.0.0 `Config\DynamicGroups.json`
there), restricts the folder to Administrators and SYSTEM, gives a gMSA/domain task account
read/execute plus Modify on `Logs` and `C:\SCRIPTS\Logs` only, creates the event log source,
registers the task and records the install in the PSM inventory.

A gMSA or domain account needs, on the group OUs: create group objects, and write `member` and
`description` on the managed groups. Services server: `Install-WindowsFeature RSAT-AD-PowerShell`.

## Files

| File | Purpose |
|---|---|
| `Update-DynamicGroups.ps1` | The sync. Run by the task; `-WhatIf` shows changes without making them; `-GroupName` runs named rules (`-IncludeDisabled` also runs disabled ones) |
| `Show-DynamicGroupEditor.ps1` | GUI: add/edit/copy/delete rules, Preview, Save, Run Now, View Log |
| `Install-DynamicGroups.ps1` | Rules file, permissions, event source, task (every 2 hours), inventory |
| `Data\DynamicGroups.json` | Settings: default search base, default OU for new rules, DC, interval, retention |
| `Data\DynamicGroupRules.Template.json` | Empty rules, copied to `Data\Rules` on first install |
| `Functions\Get-DynamicGroupSetting.ps1` | Reads the settings, finds the rules file |
| `Functions\ConvertTo-DynamicGroupLdapFilter.ps1` | Rule -> LDAP filter (values escaped) |
| `Functions\Get-DynamicGroupConfig.ps1` | Reads the rules and fills in defaults |
| `Functions\Save-DynamicGroupConfig.ps1` | Writes the rules safely, with backup |
| `Functions\Get-DynamicGroupTargetMember.ps1` | Users that match a rule |

Logs: summary `C:\SCRIPTS\Logs\DynamicGroups.log` (newest first); WARNING/ERROR also go to the
**Managed Powershell Scripts** event log; full output per run in `Logs\Transcripts\`.

Scheduled task: `\ActiveDirectory\DynamicGroups\UpdateDynamicGroups`, every 2 hours from the next
even hour; a run in progress is never started twice.

## Rule fields (JSON)

| Field | Meaning |
|---|---|
| `Name` | Group name and sAMAccountName. No spaces |
| `Description` | Written to the group |
| `Path` | OU the group is created in |
| `GroupScope` / `GroupCategory` | Global, Universal, DomainLocal / Security, Distribution |
| `Enabled` | `false` pauses the rule (group left as is; `-GroupName` skips it unless `-IncludeDisabled`) |
| `SearchBase` | Users are searched here and below. Empty = `DefaultSearchBase` in the settings |
| `IncludeDisabledUsers` | Default `false` |
| `MatchType` | `All` (AND) or `Any` (OR) of the criteria |
| `Criteria` | `Attribute` (LDAP name, e.g. `title`, `department`, `physicalDeliveryOfficeName`), `Operator` (Equals, NotEquals, StartsWith, EndsWith, Contains, Present, NotPresent), `Value` |
| `ExcludeUsers` | sAMAccountNames never added |
| `LdapFilter` | Optional raw LDAP filter that replaces the criteria |
| `AllowEmpty` | Default `false`: a rule that matches nobody never empties an existing group |

## Safety

- Deleting a rule does not delete the group; the sync just stops managing it.
- A rule matching nobody removes nobody unless `AllowEmpty` is true (protects against typos).
- An error in one rule skips that group only.
- Manual changes to a managed group's user members are undone at the next run. To keep
  someone out, use `ExcludeUsers`; to add someone who does not match, change the rule.
- The folder is Administrators/SYSTEM only (the task account can read it): whoever can edit the
  rules controls group membership. Do not put privileged groups (Domain Admins etc.) under rules.

## Status

### Done
- [x] Filter builder, settings/rules load and save, and the full sync (create, add, remove, guard,
      nested groups kept, -WhatIf) tested; prelim run on 2026-10-19 added 8 users to
      `DEPT-ExecutiveDirectors` (rule `title` Equals `Executive Director`).
- [x] 1.1.0: settings and version in `Data\`, rules server-local in `Data\Rules`, PSM manifest and
      inventory, tighter task-account permissions, gMSA option, console password prompt.

### To do
- [ ] Copy with SetupApplications (DynamicGroups) to the DC or services server.
- [ ] Run `Install-DynamicGroups.ps1` there (see Install).
- [ ] Add the rules in the editor (the server starts with none), e.g. `DEPT-ExecutiveDirectors`:
      group OU `OU=DepartmentalGroups,OU=AA.Common.Groups,OU=GGI,DC=generationsgaither,DC=com`,
      `title` Equals `Executive Director`. Use **Preview** to check titles that vary.
- [ ] `Update-DynamicGroups.ps1 -WhatIf`, then let the task run.

## Quick reference

```powershell
$App = 'C:\SCRIPTS\Applications\Microsoft\ActiveDirectory\DynamicGroups'
& "$App\Show-DynamicGroupEditor.ps1"                         # edit rules (GUI)
& "$App\Update-DynamicGroups.ps1" -WhatIf                    # preview all changes
& "$App\Update-DynamicGroups.ps1" -GroupName DEPT-ExecutiveDirectors
Start-ScheduledTask -TaskPath '\ActiveDirectory\DynamicGroups\' -TaskName UpdateDynamicGroups
Get-Content C:\SCRIPTS\Logs\DynamicGroups.log -TotalCount 20
```
