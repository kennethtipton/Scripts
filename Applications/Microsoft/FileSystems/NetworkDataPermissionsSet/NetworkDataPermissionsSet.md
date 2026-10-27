# NetworkDataPermissionsSet — folder permissions and FLD- groups from rules

Location: `C:\SCRIPTS\Applications\Microsoft\FileSystems\NetworkDataPermissionsSet`
Version: 1.0.0 (`Data\NetworkDataPermissionsSet.json`)

Sets the permissions of shared folders, and their FLD- groups, from rules in one JSON file. Run it
from the workstation with an account that can manage the groups and the folders.
`Set-NetworkDataPermissions.ps1` **only reports** unless you add `-Apply`.

## Group names

`FLD-<Role>-<SHARE>.<folder path as named on disk, '\' replaced by '.'>`

| Role | Rights | Example |
|---|---|---|
| A — Administrators | Full Control | `FLD-A-DATA`, `FLD-A-DATA.Facilities` |
| E — Editors | Modify | `FLD-E-DATA.Facilities.Houses.Mckenzie` |
| R — Reviewers | Read & Execute | `FLD-R-DATA.Facilities.Houses.Mckenzie` |
| T — Traverse | Traverse + list, this folder only | `FLD-T-DATA.Facilities` |

AD limits group names to 64 characters. A longer name needs `GroupPath` in its rule, for example
`Facility.TN.MORRISON.MHC.OfficeManagmentFiles`. All groups are Global security groups.

## The Facilities layout

```
Facilities                      A, E (all facilities, carried down), T
├─ Houses | MHCs | SkilledNursing | Offices
│                               A (delegate that type), E/R (staff across that type, carried down), T
│  └─ <site>                    E, R              e.g. FLD-E-DATA.Facilities.Houses.Logan
│     └─ Management (MHCs)      E, R; ShareAdminsOnly + BlockCarryDown: only FLD-A-DATA and its own groups
```

The old `Facility` folder is being retired. Its groups are renamed to the new folders, keeping the same
SIDs, so the old folders keep working while data is moved. The script leaves it alone (`ExcludeTopFolders`).
Copy data in (a copy takes the new folder's permissions). If something is moved in instead, the next `-Apply` fixes it.

## Where the groups live

```
OU=SecurityGroups,OU=AA.Common.Groups,OU=GGI          (FolderGroupsOU in Scripts.json)
└─ OU=DATA          FLD-A-DATA, FLD-A-DATA.Users (Users has only that one group)
   ├─ OU=Dept       FLD-A-DATA.Dept, ...
   ├─ OU=Facility   FLD-A/E/T-DATA.Facility and every facility's groups
   └─ OU=GENERAL    FLD-A-DATA.GENERAL, ...
```

There is one OU per share, and one OU per top-level folder below it. The exceptions are the
`SharedOUTopFolders` (Users), whose groups go in the share's OU. `-Apply` creates missing OUs,
protected from accidental deletion. It also moves existing groups into the right OU; their SID stays.

To delegate a top-level folder, put people in `FLD-A-DATA.<Folder>`: they can repair permissions anywhere
in that folder. In ADUC, also give that group "Create, delete and manage groups / Modify the membership of
a group" on `OU=<Folder>`. They can then manage who is in its groups.

## Restricted subfolders inside a facility

A facility sometimes needs a subfolder that only some of its staff can open, for example one without
the facility's Reviewers. Add a rule for it:

```json
{ "Path": "Facility\\TN.DAYTON.FACILITY.MHC\\Nursing", "Roles": [ "E" ], "KeepParentRoles": [ "E" ] }
```

- `Roles`: the subfolder's own groups (here `FLD-E-DATA.Facility.TN.DAYTON.FACILITY.MHC.Nursing`).
- `KeepParentRoles`: which of the facility's groups stay. `[ "E" ]` keeps the facility's Editors and drops
  its Reviewers. Leave it empty to keep only the subfolder's own groups.
- The administrators (`FLD-A-DATA`, `FLD-A-DATA.Facilities`) and the all-facility editors are always there.
- The facility folder gets a Traverse group, and the subfolder's groups are nested into it, so the
  subfolder's members can open the facility folder.

The report lists every restricted folder that no rule manages, with a rule ready to paste. When the
group name would be longer than 64 characters, the rule includes a `GroupPath` placeholder.

## Sites

Every site OU (`TN.*`, `KY.*` under GGI) should have one folder under Facility. Corporate and
administrative sites are excluded (`Sites.Exclude`). Where the folder name differs from the site OU
name, `Sites.Folders` maps one to the other. `TN.ALL_HOUSES` is `Shared`: it belongs to every house. The
report lists sites without a folder, and folders without a site. It only reports and creates nothing.

## What a rule does

Every folder a rule manages is **restricted** (inheritance off). Its permissions are exactly:

1. SYSTEM and Administrators — Full Control
2. the **A** group of every managed folder above it, and of the share root (`FLD-A-DATA`)
3. the **CarryDown** groups of the rules above it (Facility carries `FLD-E-DATA.Facility`: editors of every facility)
4. its own groups (`Roles`)

There is no CREATOR OWNER entry.

### Permanent Shared Folders

Every folder a rule manages is a **Permanent Shared Folder**. A group works inside it, and other people
keep shortcuts and mapped paths to its files. So the folder itself must never be renamed, moved,
deleted or hidden. Only the administrators (A groups) can do that.

| Editors (E) get | Rights |
|---|---|
| on the folder itself | list it, save new files, create subfolders (no delete, rename or attribute changes) |
| on its subfolders and files | Modify: edit, rename, delete |

Reviewers (R) can read everything. The owner of each Permanent Shared Folder is set to Administrators
(`Owner`), because an owner can always change a folder's permissions.

This was tested with an editor account. It could save, edit, rename and delete files, and create,
rename and delete subfolders. It could not hide, rename, delete or move the Permanent Shared Folder. A managed folder's groups are nested into its parent's **T** group, so
members can open the parent and reach their folder. A parent without a T role gets one automatically.

Anything else on a managed folder is removed, for example `BUILTIN\Users` or groups under old names.
**Contents are repaired on every run.** With `-Apply`, the script checks every file and folder inside each
Permanent Shared Folder against what it should inherit from its own parent. It resets to inherit:

- items **moved in** from another folder. A move keeps the permissions they had at the old location,
  even though they show as "inherited".
- items given permissions **by hand**.

It stops at folders managed by another rule. Restricted folders that no rule manages are left alone
and reported, with a ready-made rule. `-SkipContents` turns the repair off. Without `-Apply` the report
lists what would be reset.

**Run it again and again.** Anything that is already right is left alone: existing groups, matching
permissions, merges already done. A regular run, by hand or as a scheduled task, repairs whatever
users have moved in since the last one.

## Top-level folders: delegated administration

Every top-level folder of a share has its own Administrators group (`TopFolderRoles`):
`FLD-A-DATA.Dept`, `FLD-A-DATA.Facility`, `FLD-A-DATA.GENERAL` and `FLD-A-DATA.Users`. The groups
can stay empty until the administration of that folder is delegated. Anyone in a group can then fix
permissions anywhere in that folder.

- On a top folder that **a rule manages** (Facility), the group is part of the rule. It is also carried
  into every restricted folder below it.
- On a top folder that **no rule manages yet** (Dept, GENERAL, Users), the script only **adds**
  `FLD-A-DATA.<Folder>` to the folder. It also adds `FLD-A-DATA` and `FLD-A-DATA.<Folder>` to every
  folder below it that blocks inheritance, because inheritance doesn't reach those. Nothing else
  on those folders changes.

System folders and `ExcludeTopFolders` (DfsrPrivate, the DFSR test folder) are skipped. Finding the
restricted folders means reading the permissions of every folder in the tree. Over the DFS path that
takes several minutes for Users; on the file server, `-RootPath D:\DATA` is much faster.

## Existing groups (legacy)

For each group it needs, the script looks in AD for:

1. the new name,
2. the groups listed under `Legacy` for that name, in order,
3. the old naming pattern: `FLD-DATA.FACILITY.<FOLDER>.EDITORS`, `.EDITOR`, `.REVIEWERS`, `.ADMIN`, `.TRAVERSE`, etc.

The first group found is **renamed in place**: its name, pre-2000 name, display name and description
change. Its SID stays, so members and current permissions keep working. Members of any further
matches are **copied into it** (merge). Those groups get a "Merged into …" description; delete them
by hand. The report lists FLD- groups that no rule uses.

## Running it

```powershell
$Fs = 'C:\SCRIPTS\Applications\Microsoft\FileSystems\NetworkDataPermissionsSet\Set-NetworkDataPermissions.ps1'

& $Fs                                                   # report, all areas
& $Fs -Folder 'Facility\TN.DAYTON*'                     # report, matching folders only
& $Fs -Folder 'Facility\TN.MORRISON.CAMPUS-SUNNY_ACRES_ROAD' -Apply -WhatIf   # every step, nothing done
& $Fs -Folder 'Facility\TN.MORRISON.CAMPUS-SUNNY_ACRES_ROAD' -Apply           # do it
```

A `-Folder` run also creates or renames the groups of the folders above it (carried and Traverse
groups), because the folder needs them.

**Rollback.** Before changing a folder, `-Apply` saves its permissions with `icacls /save` to
`C:\SCRIPTS\Logs\NetworkDataPermissionsSet\<date>_<folder>.acl`. To restore:

```powershell
icacls "\\generationsgaither.com\ALL_DATA\DATA\Facility" /restore "C:\SCRIPTS\Logs\NetworkDataPermissionsSet\<file>.acl"
```

Run the restore against the **parent** folder. Group renames are written to `C:\SCRIPTS\Logs\NetworkDataPermissionsSet.log`.

**After a change**, users pick up new group memberships at their next sign-in. Servers pick them up
after a reboot, or after `klist -li 0x3e7 purge`.

**DFS.** The paths are DFS paths, so changes replicate to the other DATA members. Use
the first run on a big tree after hours.

## Settings (`Data\NetworkDataPermissionsSet.json`)

| Setting | Meaning |
|---|---|
| `GroupNameFormat`, `MaxGroupNameLength` | `FLD-{Role}-{Share}{Path}`, 64 |
| `Roles` | rights, scope and description template of A, E, R, T |
| `Base` | always-present entries (SIDs of SYSTEM and Administrators) |
| `Shares.<SHARE>.Path`, `.RootRoles` | share path (DFS), groups at the share root |
| `Areas[].Rules[]` | `Path` (relative to the share; a last segment `*` = every folder directly below; an exact path beats `*`), `Roles`, `CarryDown`, `GroupPath`, `Note` |
| `Legacy` | new name → existing groups to rename or merge |
| `LegacyNameFormats`, `LegacyRoleWords` | the old naming pattern, tried automatically |
| `GroupsOU` | empty = `Groups.FolderGroupsOU` in `Scripts.json` |
