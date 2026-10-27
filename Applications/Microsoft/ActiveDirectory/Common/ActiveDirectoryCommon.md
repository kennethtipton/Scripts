# ActiveDirectoryCommon — shared Active Directory functions

Location: `C:\SCRIPTS\Applications\Microsoft\ActiveDirectory\Common`
Version: 1.0.0 (`Data\ActiveDirectoryCommon.json`)

A library application: functions that several AD scripts share (former employees, folder
permissions, printers ...). It has no install step. An application that uses it lists
`ActiveDirectoryCommon` in its manifest's `DependsOn`, so SetupApplications copies it only to the
machines that do AD work. Those machines need `RSAT-AD-PowerShell`.

Load it in a script:

```powershell
Get-ChildItem -Path 'C:\SCRIPTS\Applications\Microsoft\ActiveDirectory\Common\Functions\*.ps1' | ForEach-Object { . $_.FullName }
```

## Move-AdUserToOu

Moves users to an OU.

```powershell
Move-AdUserToOu -Identity jdoe -TargetOu 'OU=To.MAKE_PST,OU=AA.FormerEmployees,OU=GGI,DC=generationsgaither,DC=com' -Reason 'Left 10/24'
'jdoe', 'asmith' | Move-AdUserToOu -TargetOu $Ou -WhatIf
```

- `-Identity` accepts a sAMAccountName, UPN, DN, GUID or SID, or `Get-ADUser` objects from the pipeline.
- It checks that the target OU exists. Users already in the target OU are skipped.
- An account protected from accidental deletion is unprotected for the move, then protected again.
- Every read and write goes to one domain controller (`-Server`, or a writable DC of the site).
- It returns one result per user: `Moved`, `Skipped`, `WhatIf` or `Failed`. A failure doesn't stop the
  other users.
- It writes to `C:\SCRIPTS\Logs\ActiveDirectory.log`.

## Remove-AdUserAccount

Deletes user accounts. Every account is checked first, and a record is saved before it is deleted.

**Always refused:**

- built-in accounts (RID below 1000)
- privileged accounts (`adminCount = 1`)

**Refused unless overridden:**

| Check | Default (settings) | Override |
|---|---|---|
| Account is enabled | `Delete.RequireDisabled` | `-AllowEnabled` |
| Not directly in an allowed OU | `Delete.AllowedOUs` = `To.Delete` | `-AllowedOu <DN>` or `'*'` |
| Has an Exchange mailbox | `Delete.RefuseWithMailbox` | `-AllowMailbox` |

A refused account returns `Refused` with every reason, and nothing changes.

**The record.** Before deleting, the function writes
`C:\SCRIPTS\Logs\ActiveDirectory\DeletedUsers\<user>_<date>.json`. It holds every attribute as text
(photos and certificates left out), the group memberships, the SID and GUID, and who deleted the
account, when and why. If the record can't be written, nothing is deleted. `-RecordOnly` writes the
record and changes nothing, for example as the first step of archiving a former employee.

**The AD Recycle Bin is off in this forest (checked 2026-10-27).** A deleted account can only be
reanimated as a tombstone: it comes back without its groups and most of its attributes. The record
is what lets you rebuild it, so keep the DeletedUsers folder backed up. Turning on the Recycle Bin
(`Enable-ADOptionalFeature 'Recycle Bin Feature'`) can't be undone, but it makes deletions fully
restorable for 180 days.

**How it deletes.** It uses `Remove-ADObject -Recursive`, because accounts with phones have ActiveSync
device objects under them; there were 109 such device containers in the domain. Home folders,
mailboxes and files are not touched.

`ConfirmImpact` is High, so PowerShell asks before each deletion unless you pass `-Confirm:$false`.

```powershell
Remove-AdUserAccount -Identity jdoe -Reason 'Former employee, data archived'
Get-ADUser -SearchBase 'OU=To.Delete,OU=AA.FormerEmployees,OU=GGI,DC=generationsgaither,DC=com' -Filter * |
    Remove-AdUserAccount -Reason 'Quarterly clean-up' -WhatIf
Remove-AdUserAccount -Identity jdoe -RecordOnly            # record only
```

## Tested (2026-10-27, Windows PowerShell 5.1, no changes made)

- **Move:**
  - `-WhatIf` reported the move.
  - A user already in the target OU was skipped.
  - An unknown name returned `Failed` without stopping the others.
- **Remove refused:**
  - a former employee still in To.MAKE_PST and with a mailbox;
  - the built-in Administrator (5 reasons);
  - a Domain Admin account.
- **Remove reached the delete step** under `-WhatIf` once the OU and mailbox checks were waived.
- **`-RecordOnly`** wrote complete records for two users: 98–103 attributes, groups, SID. Both accounts
  were still in AD afterwards.
