#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Sets folder permissions and their FLD- groups from the rules in Data\NetworkDataPermissionsSet.json.
.DESCRIPTION
    Every folder a rule manages (see Areas in NetworkDataPermissionsSet.json) is a Permanent Shared Folder: a group
    works inside it and others keep shortcuts to its files, so only administrators can rename, move,
    delete or hide it; editors get "list + add files/folders" on the folder itself and Modify on its
    contents. For every such folder the script:
      - works out its groups, named FLD-<Role>-<SHARE>.<path as on disk> (A Administrators, E Editors,
        R Reviewers, T Traverse), and finds each in AD: as it is, or as a legacy group to rename in place
        (the SID, members and current permissions stay) or to merge into it
      - nests the folder's groups into its parent's Traverse group, so members can reach it
      - makes the folder restricted (inheritance off) with exactly: Base (SYSTEM, Administrators) + the
        Administrators groups of every folder above it + the CarryDown groups of the rules above it +
        its own groups
      - checks every file and folder inside it. Anything that doesn't simply inherit its permissions -
        moved in from another folder (a move keeps the old permissions) or given permissions by hand -
        is reset to inherit (with -Apply; -SkipContents turns it off). Folders managed by another rule
        are left to that rule; restricted folders no rule knows about are left alone and reported.

    Safe to run again and again: what is already right is left alone, so a regular run repairs
    whatever users have moved in since the last one.

    Without -Apply nothing is changed: it reports, per folder, what would be added and removed, the
    group creations / renames / merges, missing nestings, the items with their own permissions inside,
    and the legacy groups no rule uses. With -Apply it makes those changes (supports -WhatIf).

    Run it with an account that can manage the groups (OU) and the folders' permissions. The share
    paths are DFS paths; changes replicate to the other DFS members (resetting many items creates a
    replication backlog, so run big trees after hours).
.PARAMETER Area
    Only this area (Areas[].Name). Default: all areas.
.PARAMETER Folder
    Only folders whose path (relative to the share, e.g. Facility\TN.DAYTON.FACILITY.MHC) matches this
    wildcard. Default: all. The share root group is always resolved.
.PARAMETER Apply
    Make the changes. Without it the script only reports.
.PARAMETER SkipContents
    With -Apply, don't reset the files and folders inside. By default they are checked, and any that
    don't simply inherit (moved in, or given permissions by hand) are reset to inherit.
.PARAMETER SettingsPath
    Settings file. Defaults to Data\NetworkDataPermissionsSet.json next to this script.
.PARAMETER RootPath
    Use this path for the share instead of Shares.<share>.Path (e.g. D:\DATA when run on a file server).
.EXAMPLE
    PS> C:\SCRIPTS\Applications\Microsoft\FileSystems\NetworkDataPermissionsSet\Set-NetworkDataPermissions.ps1
    Report for every area.
.EXAMPLE
    PS> .\Set-NetworkDataPermissions.ps1 -Folder 'Facility\TN.MORRISON.CAMPUS-SUNNY_ACRES_ROAD' -Apply
    Fix one facility (its groups, nesting and folder permissions).
.EXAMPLE
    PS> .\Set-NetworkDataPermissions.ps1 -Folder 'Facilities*' -Apply -WhatIf
    Show every change, including the resets of moved-in files, without making them.
.INPUTS
    None
.OUTPUTS
    None (report text)
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-26
    Time: 15:00:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 1.0.0
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: Claude

    Copyright (c) 2026
    Licensed under the MIT License.
    Full text available at: https://opensource.org/licenses/MIT

    Overide Variables
    Overide Filename:
    Overide Log Filename: NetworkDataPermissionsSet
    Overide Text Log File Path:
    Overide Log Type:
.LINK
    https://www.tnandc.com
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Area,
    [string]$Folder = '*',
    [switch]$Apply,
    [switch]$SkipContents,
    [string]$SettingsPath,
    [string]$RootPath
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'Set-NetworkDataPermissions.ps1'
$LogFileName = 'NetworkDataPermissionsSet'

#region Standard locations
$SCA = $PSScriptRoot                           # C:\SCRIPTS\Applications\Microsoft\FileSystems\NetworkDataPermissionsSet
$SA  = $SCA
while ($SA -and (Split-Path -Path $SA -Leaf) -ne 'Applications') { $SA = Split-Path -Path $SA -Parent }
if (-not $SA) { throw "$SCA is not inside an 'Applications' folder." }
$SL  = Split-Path -Path $SA -Parent            # C:\SCRIPTS
$SF  = Join-Path -Path $SL -ChildPath 'Functions'
if (-not $SettingsPath) { $SettingsPath = Join-Path -Path $SCA -ChildPath 'Data\NetworkDataPermissionsSet.json' }
$BackupDir = Join-Path -Path $SL -ChildPath 'Logs\NetworkDataPermissionsSet'          # icacls /save copies, one per folder change
#endregion

foreach ($F in 'Write-AdvancedLog.ps1', 'Get-ApplicationSettings.ps1') {
    $P = Join-Path -Path $SF -ChildPath $F
    if (Test-Path -Path $P) { . $P }
}
function Write-FsLog {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO', 'WARNING', 'ERROR')][string]$LogType = 'INFO')
    if ($LogType -eq 'WARNING') { Write-Warning $Message } elseif ($LogType -eq 'ERROR') { Write-Host "  ERROR: $Message" -ForegroundColor Red } else { Write-Host "  $Message" }
    if (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue) {
        $LogArgs = @{ Message = $Message; ScriptName = $ScriptName; LogFileName = $LogFileName; LogType = $LogType }
        if ($LogType -ne 'INFO') { $LogArgs.WriteEventLog = $true }
        try { Write-AdvancedLog @LogArgs } catch { }
    }
}

#region ACL helpers (Windows PowerShell 5.1 and PowerShell 7)
$SyncBit = [int][System.Security.AccessControl.FileSystemRights]::Synchronize

function Get-FsDirSecurity {
    param([Parameter(Mandatory)][string]$Path)
    $Sections = [System.Security.AccessControl.AccessControlSections]::Access
    if ($PSVersionTable.PSEdition -eq 'Core') { return [System.IO.FileSystemAclExtensions]::GetAccessControl([System.IO.DirectoryInfo]::new($Path), $Sections) }
    (Get-Item -LiteralPath $Path -Force).GetAccessControl($Sections)
}
function Set-FsDirSecurity {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Security)
    if ($PSVersionTable.PSEdition -eq 'Core') { [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]::new($Path), $Security); return }
    (Get-Item -LiteralPath $Path -Force).SetAccessControl($Security)
}
function Get-FsScope {
    param($Rule)
    $Inh = [int]$Rule.InheritanceFlags; $Prop = [int]$Rule.PropagationFlags
    if ($Inh -eq 3 -and $Prop -eq 0) { return 'All' }
    if ($Inh -eq 0) { return 'ThisFolder' }
    if ($Inh -eq 3 -and $Prop -eq 2) { return 'Children' }
    "$($Rule.InheritanceFlags)/$($Rule.PropagationFlags)"
}
# Normalized explicit permissions of a folder: one "sid|rights|scope|type" key each (Synchronize ignored,
# a this-folder entry plus a children-only entry with the same rights counted as one 'All' entry)
function Get-FsAceKeys {
    param([Parameter(Mandatory)]$Security)
    $Raw = @($Security.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object {
        $Rights = [int]$_.FileSystemRights -band (-bnot $SyncBit)
        if ($Rights -eq 268435456) { $Rights = [int][System.Security.AccessControl.FileSystemRights]::FullControl -band (-bnot $SyncBit) }   # GENERIC_ALL
        [pscustomobject]@{ Sid = "$($_.IdentityReference)"; Rights = $Rights; Scope = (Get-FsScope $_); Type = "$($_.AccessControlType)" }
    })
    $Keys = New-Object System.Collections.Generic.List[string]
    foreach ($G in ($Raw | Group-Object -Property Sid, Rights, Type)) {
        $Scopes = @($G.Group.Scope | Select-Object -Unique)
        if ($Scopes -contains 'ThisFolder' -and $Scopes -contains 'Children') { $Scopes = @(@('All') + @($Scopes | Where-Object { $_ -notin 'ThisFolder', 'Children' }) | Select-Object -Unique) }
        foreach ($S in $Scopes) { $Keys.Add(('{0}|{1}|{2}|{3}' -f $G.Group[0].Sid, $G.Group[0].Rights, $S, $G.Group[0].Type)) }
    }
    $Keys.ToArray()
}
$NameCache = @{}
function Get-FsName {
    param([string]$Sid)
    if ($Sid -like 'NEW:*') { return $Sid.Substring(4) }
    if (-not $NameCache.ContainsKey($Sid)) {
        $NameCache[$Sid] = try { "$((New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate([System.Security.Principal.NTAccount]))" -replace '^[^\\]+\\', '' } catch { $Sid }
    }
    $NameCache[$Sid]
}
function Format-FsKey {
    param([string]$Key)
    $P = $Key -split '\|'
    $Rights = [int]$P[1]
    $Word = switch ($Rights) {
        ([int][System.Security.AccessControl.FileSystemRights]::FullControl -band (-bnot $SyncBit)) { 'Full'; break }
        ([int][System.Security.AccessControl.FileSystemRights]::Modify) { 'Modify'; break }
        ([int][System.Security.AccessControl.FileSystemRights]::ReadAndExecute) { 'Read'; break }
        ([int]([System.Security.AccessControl.FileSystemRights]'ReadAndExecute, CreateFiles, CreateDirectories')) { 'List + add files/folders (no delete, rename or attributes)'; break }
        default { "$([System.Security.AccessControl.FileSystemRights]$Rights)" -replace 'ReadAndExecute', 'Read' }
    }
    if ($Word -eq 'Read' -and $P[2] -eq 'ThisFolder') { $Word = 'Traverse + list' }
    $Scope = if ($P[2] -eq 'All') { '' } elseif ($P[2] -eq 'ThisFolder') { ' (this folder only)' } elseif ($P[2] -eq 'Children') { ' (subfolders and files only)' } else { " ($($P[2]))" }
    '{0}{1}: {2}{3}' -f $(if ($P[3] -eq 'Deny') { 'DENY ' } else { '' }), (Get-FsName $P[0]), $Word, $Scope
}
# Rights of an access rule as a comparable number: Synchronize dropped, generic rights mapped to file rights
function Get-FsRightsValue {
    param([int]$Rights)
    $R = [int64]$Rights -band 0xFFFFFFFFL
    $Out = $R -band 0x0FFFFFFF
    if ($R -band 0x10000000) { $Out = $Out -bor ([int][System.Security.AccessControl.FileSystemRights]::FullControl) }   # GENERIC_ALL
    if ($R -band 0x80000000) { $Out = $Out -bor 0x20089 }                                                               # GENERIC_READ
    if ($R -band 0x40000000) { $Out = $Out -bor 0x20116 }                                                               # GENERIC_WRITE
    if ($R -band 0x20000000) { $Out = $Out -bor 0x200A0 }                                                               # GENERIC_EXECUTE
    [int]($Out -band (-bnot $SyncBit))
}
# What an item should inherit from its parent folder, as "sid|rights|type" keys. CREATOR OWNER / GROUP
# entries become the item's owner entry, so they are left out here and the owner's entries are ignored.
function Get-FsExpectedInherited {
    param([Parameter(Mandatory)]$ParentAcl, [bool]$IsFolder)
    $Keys = @{}; $Creator = $false
    foreach ($A in $ParentAcl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        $Inh = [int]$A.InheritanceFlags; $NoProp = ([int]$A.PropagationFlags -band 1) -eq 1
        $Applies = if ($IsFolder) { ($Inh -band 1) -or (($Inh -band 2) -and -not $NoProp) } else { ($Inh -band 2) -ne 0 }   # 1 = containers, 2 = objects
        if (-not $Applies) { continue }
        $Sid = "$($A.IdentityReference)"
        if ($Sid -in 'S-1-3-0', 'S-1-3-1') { $Creator = $true; continue }
        $Keys[('{0}|{1}|{2}' -f $Sid, (Get-FsRightsValue ([int]$A.FileSystemRights)), $A.AccessControlType)] = $true
    }
    [pscustomobject]@{ Keys = $Keys; Creator = $Creator }
}
# Files and folders inside a Permanent Shared Folder whose permissions are not simply what they inherit:
#   Explicit   - permissions set on the item itself (added by hand)
#   Stale      - inherited entries that don't match its parent (moved in from elsewhere: a move keeps
#                the old inherited permissions)
#   Restricted - a folder that blocks inheritance and no rule manages: left alone (and not entered)
# Stops at folders in $Skip (managed by a rule). With -Fix, resets each Explicit / Stale item to inherit
# (icacls /reset) before looking inside it, so its contents are checked against the corrected folder.
function Get-FsContentProblems {
    param([Parameter(Mandatory)][string]$Path, [hashtable]$Skip, [switch]$Fix)
    $ParentAcl = try { Get-Acl -LiteralPath $Path } catch { $null }
    if (-not $ParentAcl) { return }
    $ForFolders = Get-FsExpectedInherited -ParentAcl $ParentAcl -IsFolder $true
    $ForFiles = Get-FsExpectedInherited -ParentAcl $ParentAcl -IsFolder $false
    foreach ($Item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        if ($Item.PSIsContainer -and $Skip.ContainsKey($Item.FullName.ToLower())) { continue }
        $Acl = try { Get-Acl -LiteralPath $Item.FullName } catch { $null }
        if (-not $Acl) { continue }
        if ($Acl.AreAccessRulesProtected) {
            if ($Item.PSIsContainer) { [pscustomobject]@{ Path = $Item.FullName; Kind = 'Restricted'; Fixed = $false }; continue }
            $Kind = 'Explicit'                                        # a file that blocks inheritance
        }
        else {
            $Rules = @($Acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
            $Kind = ''
            if (@($Rules | Where-Object { -not $_.IsInherited }).Count) { $Kind = 'Explicit' }
            else {
                $Want = if ($Item.PSIsContainer) { $ForFolders } else { $ForFiles }
                $Owner = try { "$($Acl.GetOwner([System.Security.Principal.SecurityIdentifier]))" } catch { '' }
                $Have = @{}
                foreach ($A in $Rules) {
                    $Sid = "$($A.IdentityReference)"
                    if ($Want.Creator -and $Sid -eq $Owner) { continue }
                    $Have[('{0}|{1}|{2}' -f $Sid, (Get-FsRightsValue ([int]$A.FileSystemRights)), $A.AccessControlType)] = $true
                }
                $Same = ($Have.Count -eq $Want.Keys.Count) -and -not @($Have.Keys | Where-Object { -not $Want.Keys.ContainsKey($_) }).Count
                if (-not $Same) { $Kind = 'Stale' }
            }
        }
        $Fixed = $false
        if ($Kind) {
            if ($Fix) {
                $Eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                $Out = & icacls.exe $Item.FullName /reset /Q 2>&1
                $ErrorActionPreference = $Eap
                $Fixed = ($LASTEXITCODE -eq 0)
                if (-not $Fixed) { Write-FsLog "Reset failed: $($Item.FullName): $($Out -join ' ')" -LogType WARNING }
            }
            [pscustomobject]@{ Path = $Item.FullName; Kind = $Kind; Fixed = $Fixed }
        }
        if ($Item.PSIsContainer) { Get-FsContentProblems -Path $Item.FullName -Skip $Skip -Fix:$Fix }
    }
}
#endregion

#region AD helpers
$GroupCache = @{}
function Find-FsGroup {
    param([Parameter(Mandatory)][string]$Name)
    $K = $Name.ToLower()
    if (-not $GroupCache.ContainsKey($K)) {
        $Q = $Name -replace "'", "''"
        $GroupCache[$K] = Get-ADGroup -Filter "Name -eq '$Q' -or SamAccountName -eq '$Q'" -Properties Description, DisplayName, Members | Select-Object -First 1
    }
    $GroupCache[$K]
}
#endregion

try {
    #region Settings
    $Cfg = if (Get-Command -Name Get-ApplicationSettings -ErrorAction SilentlyContinue) { Get-ApplicationSettings -Path $SettingsPath } else { Get-Content -Path $SettingsPath -Raw | ConvertFrom-Json }
    $OU = "$($Cfg.GroupsOU)"
    if (-not $OU) {
        $Scripts = Get-Content -Path (Join-Path $SL 'Data\Settings\Scripts.json') -Raw | ConvertFrom-Json
        $OU = "$($Scripts.Groups.FolderGroupsOU)"
    }
    if (-not $OU) { throw 'No OU for new groups (GroupsOU in NetworkDataPermissionsSet.json or Groups.FolderGroupsOU in Scripts.json).' }
    $MaxLen = if ($Cfg.MaxGroupNameLength) { [int]$Cfg.MaxGroupNameLength } else { 64 }
    $Roles = @{}
    foreach ($P in $Cfg.Roles.PSObject.Properties) {
        $Roles[$P.Name] = [pscustomobject]@{
            Letter = $P.Name; Word = "$($P.Value.Word)"; Scope = "$($P.Value.Scope)"; Description = "$($P.Value.Description)"
            Rights = ([int][System.Security.AccessControl.FileSystemRights]("$($P.Value.Rights)")) -band (-bnot $SyncBit)
            # ThisFolderRights: different rights on the managed folder itself (Editors: no Delete, so they
            # can't delete or rename the folder; full Rights on everything inside it)
            ThisFolderRights = if ($P.Value.ThisFolderRights) { ([int][System.Security.AccessControl.FileSystemRights]("$($P.Value.ThisFolderRights)")) -band (-bnot $SyncBit) } else { $null }
        }
    }
    $OwnerSid = if ($Cfg.Owner) { "$($Cfg.Owner)" } else { '' }
    $LegacyMap = @{}
    if ($Cfg.Legacy) { foreach ($P in $Cfg.Legacy.PSObject.Properties) { $LegacyMap[$P.Name.ToLower()] = @($P.Value) } }
    $LegacyWords = @{}
    foreach ($P in $Cfg.LegacyRoleWords.PSObject.Properties) { $LegacyWords[$P.Name] = @($P.Value) }
    #endregion

    # OU of a group: <GroupsOU>, then OU=<SHARE>, then OU=<top-level folder> (unless that folder is in
    # SharedOUTopFolders, or GroupsOUPerTopFolder is off)
    $OuFor = {
        param([string]$Rel)
        if (-not $Cfg.GroupsOUPerTopFolder) { return $OU }
        $ShareOu = "OU=$Share,$OU"
        $Top = ($Rel -split '\\')[0]
        if (-not $Rel -or @($Cfg.SharedOUTopFolders | ForEach-Object { "$_" }) -contains $Top) { return $ShareOu }
        "OU=$Top,$ShareOu"
    }
    $OuSeen = @{}
    $ConfirmOu = {
        param([string]$Dn)
        if ($OuSeen.ContainsKey($Dn.ToLower())) { return }
        $Exists = try { [bool](Get-ADOrganizationalUnit -Identity $Dn) } catch { $false }
        if (-not $Exists) {
            $ParentOu = $Dn -replace '^OU=[^,]+,', ''
            & $ConfirmOu $ParentOu
            $Totals.OUs++
            Write-Host "  ou     CREATE  $Dn" -ForegroundColor Yellow
            if ($Apply -and $PSCmdlet.ShouldProcess($Dn, 'Create OU (protected from accidental deletion)')) {
                New-ADOrganizationalUnit -Name (($Dn -split ',')[0] -replace '^OU=', '') -Path $ParentOu -ProtectedFromAccidentalDeletion $true
                Write-FsLog "Created OU $Dn."
            }
        }
        $OuSeen[$Dn.ToLower()] = $true
    }

    $Totals = [ordered]@{ OUs = 0; Create = 0; Rename = 0; Move = 0; Merge = 0; Nest = 0; Folders = 0; Owners = 0; Children = 0 }
    $UsedGroups = @{}
    $Mode = if ($Apply) { 'APPLY' } else { 'REPORT (nothing is changed; use -Apply)' }
    Write-Host ''
    Write-Host "NetworkDataPermissionsSet $($Cfg.Version) - $Mode" -ForegroundColor Cyan

    foreach ($A in @($Cfg.Areas | Where-Object { -not $Area -or $_.Name -eq $Area })) {
        $Share = "$($A.Share)"
        $ShareCfg = $Cfg.Shares.$Share
        if (-not $ShareCfg) { throw "Area $($A.Name): share '$Share' is not in Shares." }
        $ShareRoot = if ($RootPath) { $RootPath.TrimEnd('\') } else { "$($ShareCfg.Path)".TrimEnd('\') }
        if (-not (Test-Path -LiteralPath $ShareRoot)) { throw "Share path not found: $ShareRoot" }
        Write-Host ''
        Write-Host "=== Area $($A.Name)  (share $Share = $ShareRoot)" -ForegroundColor Cyan

        #region Folders the rules manage
        $Suggest = New-Object System.Collections.Generic.List[string]  # restricted folders no rule manages
        $Folders = @{}                                                 # rel (lower) -> folder object
        # Rules with more wildcards first, exact paths last: the most specific rule wins
        foreach ($Rule in @($A.Rules | Sort-Object { - ([regex]::Matches("$($_.Path)", '[*?]').Count) })) {
            $RulePath = "$($Rule.Path)".Trim('\')
            $Wild = $RulePath -match '[*?]'
            # Expand wildcards in any segment (e.g. Facilities\MHCs\*\Management): only existing folders
            $Rels = @('')
            foreach ($Seg in ($RulePath -split '\\')) {
                $Rels = @(foreach ($Base in $Rels) {
                        $BaseFull = if ($Base) { Join-Path $ShareRoot $Base } else { $ShareRoot }
                        if ($Seg -match '[*?]') {
                            Get-ChildItem -LiteralPath $BaseFull -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $Seg } |
                                ForEach-Object { if ($Base) { "$Base\$($_.Name)" } else { $_.Name } }
                        }
                        elseif ($Base) { "$Base\$Seg" } else { $Seg }
                    })
            }
            foreach ($Rel in $Rels) {
                $Full = Join-Path $ShareRoot $Rel
                if (-not (Test-Path -LiteralPath $Full)) { if (-not $Wild) { Write-FsLog "Rule path not found, skipped: $Full" -LogType WARNING }; continue }
                $GroupPath = if ($Rule.GroupPath -and -not $Wild) { "$($Rule.GroupPath)" } else { $Rel -replace '\\', '.' }
                # (properties filled one by one: list values inside the literal break Windows PowerShell 5.1)
                $Fo = [pscustomobject]@{ Rel = $Rel; Full = $Full; GroupPath = $GroupPath; Roles = $null; CarryDown = $null; KeepParent = $null; BlockCarry = $false; ShareAdminsOnly = [bool]$Rule.ShareAdminsOnly; Groups = $null }
                $Fo.Roles = New-Object System.Collections.Generic.List[string]
                $Fo.CarryDown = [string[]]@($Rule.CarryDown | Where-Object { $_ } | ForEach-Object { "$_" })
                $Fo.KeepParent = [string[]]@($Rule.KeepParentRoles | Where-Object { $_ } | ForEach-Object { "$_" })
                $Fo.BlockCarry = [bool]$Rule.BlockCarryDown
                $Fo.Groups = @{}
                foreach ($R in @($Rule.Roles)) { if (-not $Roles.ContainsKey("$R")) { throw "Rule $RulePath`: unknown role '$R'." }; $Fo.Roles.Add("$R") }
                $Folders[$Rel.ToLower()] = $Fo                         # exact rules are processed last and win
            }
        }
        # A managed folder below another needs Traverse on its parent
        foreach ($Fo in $Folders.Values) {
            $Parent = Split-Path -Path $Fo.Rel -Parent
            if ($Parent -and $Folders.ContainsKey($Parent.ToLower()) -and -not $Folders[$Parent.ToLower()].Roles.Contains('T')) { $Folders[$Parent.ToLower()].Roles.Add('T') }
        }
        #endregion

        #region Groups: find, rename, merge or create
        $GroupFor = {
            param([string]$Role, [string]$GroupPath, [string]$Rel, [string]$Full)
            $Path = if ($GroupPath) { ".$GroupPath" } else { '' }
            $Name = "$($Cfg.GroupNameFormat)" -replace '\{Role\}', $Role -replace '\{Share\}', $Share.ToUpper() -replace '\{Path\}', $Path
            $Spec = [pscustomobject]@{
                Name = $Name; Role = $Role; Rel = $Rel; Full = $Full; Group = $null; Action = ''; From = $null; Merge = $null; Problem = ''
                Description = ($Roles[$Role].Description -replace '\{Folder\}', $(if ($Rel) { "$($ShareCfg.Path)\$Rel" } else { "$($ShareCfg.Path)" }))
                OU = (& $OuFor $Rel)
            }
            if ($Name.Length -gt $MaxLen) { $Spec.Problem = "name is $($Name.Length) characters (limit $MaxLen); set GroupPath in the rule"; return $Spec }
            $Candidates = New-Object System.Collections.Generic.List[string]
            if ($LegacyMap.ContainsKey($Name.ToLower())) { foreach ($L in $LegacyMap[$Name.ToLower()]) { $Candidates.Add("$L") } }
            $LegacyPath = if ($Rel) { '.' + ($Rel -replace '\\', '.').ToUpper() } else { '' }
            foreach ($Fmt in @($Cfg.LegacyNameFormats)) {
                foreach ($W in $LegacyWords[$Role]) {
                    $L = "$Fmt" -replace '\{Share\}', $Share.ToUpper() -replace '\{PATH\}', $LegacyPath -replace '\{Word\}', $W
                    if (-not $Candidates.Contains($L)) { $Candidates.Add($L) }
                }
            }
            $Found = @($Candidates.ToArray() | ForEach-Object { Find-FsGroup $_ } | Where-Object { $_ } | Sort-Object -Property { "$($_.SID)" } -Unique)
            $Exact = Find-FsGroup $Name
            if ($Exact -and $Exact.Name -eq $Name -and $Exact.SamAccountName -eq $Name) {
                $Spec.Group = $Exact; $Spec.Action = 'Exists'
                $Spec.Merge = @($Found | Where-Object { "$($_.SID)" -ne "$($Exact.SID)" })
            }
            elseif ($Exact) {
                $Spec.Group = $Exact; $Spec.Action = 'Rename'; $Spec.From = $Exact
                $Spec.Merge = @($Found | Where-Object { "$($_.SID)" -ne "$($Exact.SID)" })
            }
            elseif ($Found) {
                # the first candidate that exists, in the order listed (Legacy entry first)
                $First = $null
                foreach ($C in $Candidates.ToArray()) { $G = Find-FsGroup $C; if ($G) { $First = $G; break } }
                $Spec.Group = $First; $Spec.Action = 'Rename'; $Spec.From = $First
                $Spec.Merge = @($Found | Where-Object { "$($_.SID)" -ne "$($First.SID)" })
            }
            else { $Spec.Action = 'Create' }
            $Spec
        }

        $RootSpecs = @{}
        foreach ($R in @($ShareCfg.RootRoles)) { $RootSpecs["$R"] = & $GroupFor "$R" '' '' $ShareRoot }
        # Every top-level folder of the share gets its own groups (TopFolderRoles, normally A), so its
        # administration can be delegated; key "<role>|<folder>"
        $TopSpecs = @{}
        $Excl = @($ShareCfg.ExcludeTopFolders | ForEach-Object { "$_" })
        foreach ($Top in @(Get-ChildItem -LiteralPath $ShareRoot -Directory -Force | Where-Object { $Excl -notcontains $_.Name -and -not ($_.Attributes -band [System.IO.FileAttributes]::System) })) {
            foreach ($R in @($ShareCfg.TopFolderRoles | Where-Object { $_ })) { $TopSpecs["$R|$($Top.Name.ToLower())"] = & $GroupFor "$R" $Top.Name $Top.Name $Top.FullName }
        }
        foreach ($Fo in $Folders.Values) {
            foreach ($R in $Fo.Roles) {
                $K = "$R|$($Fo.Rel.ToLower())"
                $Fo.Groups[$R] = if ($TopSpecs.ContainsKey($K)) { $TopSpecs[$K] } else { & $GroupFor $R $Fo.GroupPath $Fo.Rel $Fo.Full }
            }
        }
        $AllSpecs = @(@($RootSpecs.Values) + @($TopSpecs.Values) + @($Folders.Values | ForEach-Object { $_.Groups.Values }))

        $SidOf = { param($Spec) if ($Spec.Group) { "$($Spec.Group.SID)" } else { "NEW:$($Spec.Name)" } }

        foreach ($S in ($AllSpecs | Sort-Object Name -Unique)) {
            if ($S.Group) { $UsedGroups["$($S.Group.SID)"] = $true }
            foreach ($M in @($S.Merge | Where-Object { $_ })) { $UsedGroups["$($M.SID)"] = $true }
        }
        #endregion

        #region Per folder
        $Managed = @{}; foreach ($Fo in $Folders.Values) { $Managed[$Fo.Full.ToLower()] = $true }
        $Targets = @($Folders.Values | Where-Object { $_.Rel -like $Folder } | Sort-Object Rel)
        # The targets' groups and those of every managed folder above them (carried, Traverse)
        $TargetTops = @($Targets | ForEach-Object { ($_.Rel -split '\\')[0].ToLower() } | Select-Object -Unique)
        $SpecsToShow = @(@($RootSpecs.Values) + @($TopSpecs.Values | Where-Object { $_.Rel -like $Folder -or $TargetTops -contains $_.Rel.ToLower() }) + @($Targets | ForEach-Object {
                    $_.Groups.Values
                    $Up = Split-Path -Path $_.Rel -Parent
                    while ($Up) { if ($Folders.ContainsKey($Up.ToLower())) { $Folders[$Up.ToLower()].Groups.Values }; $Up = Split-Path -Path $Up -Parent }
                }))

        # Group changes first (folders need their SIDs)
        foreach ($S in ($SpecsToShow | Sort-Object Name -Unique)) {
            if ($S.Problem) { Write-FsLog "$($S.Name): $($S.Problem)" -LogType ERROR; continue }
            $Members = if ($S.Group) { @($S.Group.Members).Count } else { 0 }
            switch ($S.Action) {
                'Create' {
                    $Totals.Create++
                    & $ConfirmOu $S.OU
                    Write-Host ("  group  CREATE  {0}  in {1}" -f $S.Name, ($S.OU -replace ',OU=AA\.Common\.Groups.*$', '')) -ForegroundColor Yellow
                    if ($Apply -and $PSCmdlet.ShouldProcess($S.Name, "Create group in $($S.OU)")) {
                        $S.Group = New-ADGroup -Name $S.Name -SamAccountName $S.Name -DisplayName $S.Name -GroupScope Global -GroupCategory Security -Path $S.OU -Description $S.Description -PassThru
                        $GroupCache[$S.Name.ToLower()] = $S.Group
                        Write-FsLog "Created group $($S.Name)."
                    }
                }
                'Rename' {
                    $Totals.Rename++
                    $Old = if ($S.From.Name -ne $S.From.SamAccountName) { "$($S.From.Name) (pre-2000 name $($S.From.SamAccountName))" } else { $S.From.Name }
                    Write-Host ("  group  RENAME  {0}  ->  {1}  ({2} members)" -f $Old, $S.Name, $Members) -ForegroundColor Yellow
                    if ($Apply -and $PSCmdlet.ShouldProcess($Old, "Rename group to $($S.Name)")) {
                        if ($S.From.Name -ne $S.Name) { Rename-ADObject -Identity $S.From.ObjectGUID -NewName $S.Name }
                        Set-ADGroup -Identity $S.From.ObjectGUID -SamAccountName $S.Name -DisplayName $S.Name -Description $S.Description
                        $S.Group = Get-ADGroup -Identity $S.From.ObjectGUID -Properties Description, DisplayName, Members
                        $GroupCache[$S.Name.ToLower()] = $S.Group
                        Write-FsLog "Renamed group $Old to $($S.Name) (same SID $($S.Group.SID))."
                    }
                }
                'Exists' {
                    if ($S.Group.Description -ne $S.Description -or $S.Group.DisplayName -ne $S.Name) {
                        Write-Host ("  group  update description  {0}" -f $S.Name)
                        if ($Apply -and $PSCmdlet.ShouldProcess($S.Name, 'Set description and display name')) { Set-ADGroup -Identity $S.Group.ObjectGUID -Description $S.Description -DisplayName $S.Name }
                    }
                }
            }
            # Existing (or renamed) group in another OU: move it (the SID stays)
            if ($S.Group -and $S.Action -ne 'Create') {
                $InOu = $S.Group.DistinguishedName -replace '^CN=.+?(?<!\\),', ''
                if ($InOu -ne $S.OU) {
                    & $ConfirmOu $S.OU
                    $Totals.Move++
                    Write-Host ("  group  MOVE    {0}  to {1}" -f $S.Name, ($S.OU -replace ',OU=AA\.Common\.Groups.*$', '')) -ForegroundColor Yellow
                    if ($Apply -and $PSCmdlet.ShouldProcess($S.Name, "Move to $($S.OU)")) {
                        Move-ADObject -Identity $S.Group.ObjectGUID -TargetPath $S.OU
                        Write-FsLog "Moved group $($S.Name) to $($S.OU)."
                    }
                }
            }
            foreach ($M in @($S.Merge | Where-Object { $_ })) {
                if ($S.Group -and -not @(@($M.Members) | Where-Object { @($S.Group.Members) -notcontains $_ }).Count) { continue }   # already merged (re-run)
                $Totals.Merge++
                Write-Host ("  group  MERGE   {0} ({1} members) into {2}; then delete it by hand" -f $M.Name, @($M.Members).Count, $S.Name) -ForegroundColor Yellow
                if ($Apply -and $S.Group -and $PSCmdlet.ShouldProcess($M.Name, "Copy members into $($S.Name)")) {
                    $Mem = @(Get-ADGroupMember -Identity $M.ObjectGUID)
                    if ($Mem) { Add-ADGroupMember -Identity $S.Group.ObjectGUID -Members $Mem }
                    Set-ADGroup -Identity $M.ObjectGUID -Description ("Merged into {0} on {1}; not used on any folder. Delete when no longer needed." -f $S.Name, (Get-Date -Format 'yyyy-MM-dd'))
                    Write-FsLog "Copied $($Mem.Count) member(s) of $($M.Name) into $($S.Name)."
                }
            }
        }
        # After renames and moves, read the groups again (names, distinguished names, members)
        if ($Apply -and -not $WhatIfPreference) {
            foreach ($S in @($AllSpecs | Where-Object { $_.Group })) {
                $S.Group = Get-ADGroup -Identity $S.Group.ObjectGUID -Properties Description, DisplayName, Members
                $GroupCache[$S.Name.ToLower()] = $S.Group
            }
        }

        # Top-level folders no rule manages: add only Administrators groups (nothing else changes) -
        # the top folder's own A group on the top folder, and the share's and the top folder's A groups
        # on every restricted folder below it (inheritance doesn't reach those), so the administrators
        # can repair permissions anywhere in it
        $AddAdmins = {
            param([string]$Path, [string]$Rel, [object[]]$Specs, [string]$Why)
            $Sec = Get-FsDirSecurity -Path $Path
            $Have = @(Get-FsAceKeys -Security $Sec)
            $Need = @($Specs | Where-Object { $_ -and -not $_.Problem -and $Have -notcontains ('{0}|{1}|All|Allow' -f (& $SidOf $_), $Roles['A'].Rights) })
            if (-not $Need) { return }
            Write-Host ''
            Write-Host "[$Rel]  ($Why)" -ForegroundColor White
            foreach ($S in $Need) { Write-Host "  + $(Format-FsKey ('{0}|{1}|All|Allow' -f (& $SidOf $S), $Roles['A'].Rights))" -ForegroundColor Green }
            $Totals.Folders++
            if (-not $Apply) { return }
            $Names = ($Need | ForEach-Object { $_.Name }) -join ', '
            if (@($Need | Where-Object { -not $_.Group }).Count) {
                if ($WhatIfPreference) { [void]$PSCmdlet.ShouldProcess($Path, "Add $Names Full Control (after the groups exist)") }
                else { Write-FsLog "${Rel}: $Names not added; group missing." -LogType ERROR }
                return
            }
            if (-not $PSCmdlet.ShouldProcess($Path, "Add $Names Full Control")) { return }
            if (-not (Test-Path -LiteralPath $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
            $BackupFile = Join-Path $BackupDir ('{0}_{1}.acl' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), ($Rel -replace '[\\/:*?"<>|]', '_'))
            $Eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $Out = & icacls.exe $Path /save $BackupFile /Q 2>&1
            $ErrorActionPreference = $Eap
            if ($LASTEXITCODE -ne 0) { throw "Could not save the current permissions of $Path ($($Out -join ' ')); nothing changed there." }
            foreach ($S in $Need) {
                $Sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                            $S.Group.SID, [System.Security.AccessControl.FileSystemRights]::FullControl,
                            [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit', [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)))
            }
            Set-FsDirSecurity -Path $Path -Security $Sec
            Write-FsLog "${Rel}: added $Names Full Control; previous saved to $BackupFile."
        }
        foreach ($K in ($TopSpecs.Keys | Where-Object { $_ -like 'A|*' } | Sort-Object)) {
            $S = $TopSpecs[$K]
            if ($Managed.ContainsKey($S.Full.ToLower()) -or $S.Rel -notlike $Folder) { continue }
            & $AddAdmins $S.Full $S.Rel @($S) 'no rule: only its Administrators group is added'
            $Below = @(Get-ChildItem -LiteralPath $S.Full -Directory -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
                    $Excl -notcontains $_.Name -and -not ($_.Attributes -band [System.IO.FileAttributes]::System) -and -not $Managed.ContainsKey($_.FullName.ToLower()) -and
                    $(try { (Get-FsDirSecurity -Path $_.FullName).AreAccessRulesProtected } catch { $false }) })
            foreach ($D in ($Below | Sort-Object FullName)) {
                & $AddAdmins $D.FullName $D.FullName.Substring($ShareRoot.Length + 1) @(@($RootSpecs['A']) + @($S)) 'restricted folder, no rule: only the administrators groups are added'
            }
        }

        foreach ($Fo in $Targets) {
            Write-Host ''
            Write-Host "[$($Fo.Rel)]  Permanent Shared Folder" -ForegroundColor White

            # Desired permissions: Base + Administrators above + CarryDown above + own roles
            $Desired = New-Object System.Collections.Generic.List[object]
            foreach ($B in @($Cfg.Base)) {
                $Sid = if ("$($B.Identity)" -match '^S-1-') { "$($B.Identity)" } else { "$((New-Object System.Security.Principal.NTAccount("$($B.Identity)")).Translate([System.Security.Principal.SecurityIdentifier]))" }
                $Desired.Add([pscustomobject]@{ Sid = $Sid; Rights = ([int][System.Security.AccessControl.FileSystemRights]("$($B.Rights)")) -band (-bnot $SyncBit); Scope = 'All' })
            }
            $Carried = New-Object System.Collections.Generic.List[object]
            foreach ($R in $RootSpecs.Keys) { if ($R -eq 'A') { $Carried.Add($RootSpecs[$R]) } }
            $TopKey = 'A|' + ($Fo.Rel -split '\\')[0].ToLower()
            # ShareAdminsOnly: of all the administrators groups, only the share's (FLD-A-DATA) comes down
            if ($TopSpecs.ContainsKey($TopKey) -and -not $Fo.ShareAdminsOnly) { $Carried.Add($TopSpecs[$TopKey]) }   # the top-level folder's administrators
            $Up = Split-Path -Path $Fo.Rel -Parent
            $Chain = New-Object System.Collections.Generic.List[object]
            while ($Up) { if ($Folders.ContainsKey($Up.ToLower())) { $Chain.Insert(0, $Folders[$Up.ToLower()]) }; $Up = Split-Path -Path $Up -Parent }
            foreach ($Anc in $Chain) {
                # BlockCarryDown: only the administrators come down into this folder
                foreach ($R in $Anc.Roles) { if (($R -eq 'A' -and -not $Fo.ShareAdminsOnly) -or ($Anc.CarryDown -contains $R -and -not $Fo.BlockCarry)) { $Carried.Add($Anc.Groups[$R]) } }
            }
            # KeepParentRoles: e.g. keep the facility's Editors on a restricted subfolder, but not its Reviewers
            $ParentRel = Split-Path -Path $Fo.Rel -Parent
            if ($ParentRel -and $Folders.ContainsKey($ParentRel.ToLower())) {
                foreach ($R in $Fo.KeepParent) {
                    if ($Folders[$ParentRel.ToLower()].Groups.ContainsKey($R)) { $Carried.Add($Folders[$ParentRel.ToLower()].Groups[$R]) }
                    else { Write-FsLog "$($Fo.Rel): KeepParentRoles '$R' - the parent has no such group." -LogType WARNING }
                }
            }
            foreach ($R in $Fo.Roles) { $Carried.Add($Fo.Groups[$R]) }
            foreach ($S in $Carried.ToArray()) {                      # (.ToArray(): @() around an empty List fails in 5.1)
                $Ro = $Roles[$S.Role]
                if ($null -ne $Ro.ThisFolderRights -and $Ro.Scope -eq 'All') {
                    $Desired.Add([pscustomobject]@{ Sid = (& $SidOf $S); Rights = $Ro.ThisFolderRights; Scope = 'ThisFolder' })
                    $Desired.Add([pscustomobject]@{ Sid = (& $SidOf $S); Rights = $Ro.Rights; Scope = 'Children' })
                }
                else { $Desired.Add([pscustomobject]@{ Sid = (& $SidOf $S); Rights = $Ro.Rights; Scope = $Ro.Scope }) }
            }
            $DesiredKeys = @($Desired.ToArray() | ForEach-Object { '{0}|{1}|{2}|Allow' -f $_.Sid, $_.Rights, $_.Scope } | Select-Object -Unique)

            $Sec = Get-FsDirSecurity -Path $Fo.Full
            $CurrentKeys = @(Get-FsAceKeys -Security $Sec)
            $Protected = $Sec.AreAccessRulesProtected
            $Add = @($DesiredKeys | Where-Object { $CurrentKeys -notcontains $_ })
            $Remove = @($CurrentKeys | Where-Object { $DesiredKeys -notcontains $_ })

            if (-not $Protected) { Write-Host '  inheritance: ON -> OFF (restricted)' -ForegroundColor Yellow }
            foreach ($K in $Add) { Write-Host "  + $(Format-FsKey $K)" -ForegroundColor Green }
            foreach ($K in $Remove) { Write-Host "  - $(Format-FsKey $K)" -ForegroundColor Red }
            $Changed = (-not $Protected) -or $Add -or $Remove
            $Missing = @()                                            # groups not created yet (report / -WhatIf)
            if (-not $Changed) { Write-Host '  permissions OK' -ForegroundColor DarkGray }

            # Owner: whoever created a folder owns it, and an owner can always change its permissions
            if ($OwnerSid) {
                $CurOwner = try { "$((Get-Acl -LiteralPath $Fo.Full).GetOwner([System.Security.Principal.SecurityIdentifier]))" } catch { '' }
                if ($CurOwner -and $CurOwner -ne $OwnerSid) {
                    $Totals.Owners++
                    Write-Host "  owner: $(Get-FsName $CurOwner) -> $(Get-FsName $OwnerSid)" -ForegroundColor Yellow
                    if ($Apply -and $PSCmdlet.ShouldProcess($Fo.Full, "Set owner to $(Get-FsName $OwnerSid)")) {
                        $Eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                        $Out = & icacls.exe $Fo.Full /setowner "*$OwnerSid" /Q 2>&1
                        $ErrorActionPreference = $Eap
                        if ($LASTEXITCODE -ne 0) { Write-FsLog "$($Fo.Rel): owner not changed: $($Out -join ' ')" -LogType WARNING }
                        else { Write-FsLog "$($Fo.Rel): owner $(Get-FsName $CurOwner) -> $(Get-FsName $OwnerSid)." }
                    }
                }
            }

            # Nesting: this folder's groups into the parent's Traverse group
            $Parent = Split-Path -Path $Fo.Rel -Parent
            if ($Parent -and $Folders.ContainsKey($Parent.ToLower())) {
                $T = $Folders[$Parent.ToLower()].Groups['T']
                foreach ($R in $Fo.Roles) {
                    $Child = $Fo.Groups[$R]
                    $Have = if ($T.Group -and $Child.Group) { @($T.Group.Members) -contains "$($Child.Group.DistinguishedName)" } else { $false }
                    if (-not $Have) {
                        $Totals.Nest++
                        Write-Host "  nest   $($Child.Name)  into  $($T.Name)" -ForegroundColor Yellow
                        if ($Apply -and -not ($T.Group -and $Child.Group) -and -not $WhatIfPreference) { Write-FsLog "Not nested (group missing): $($Child.Name) into $($T.Name)" -LogType WARNING }
                        elseif ($Apply -and $PSCmdlet.ShouldProcess($T.Name, "Add member $($Child.Name)") -and $T.Group -and $Child.Group) {
                            Add-ADGroupMember -Identity $T.Group.ObjectGUID -Members $Child.Group.ObjectGUID
                        }
                    }
                }
            }

            if ($Changed) {
                $Totals.Folders++
                $Missing = @($Desired.ToArray() | Where-Object { $_.Sid -like 'NEW:*' })
                if ($Apply -and $Missing) {
                    # groups created/renamed above now have SIDs
                    foreach ($D in $Missing) { $G = Find-FsGroup $D.Sid.Substring(4); if ($G) { $D.Sid = "$($G.SID)" } }
                    $Missing = @($Desired.ToArray() | Where-Object { $_.Sid -like 'NEW:*' })
                }
                if ($Apply -and $Missing -and $WhatIfPreference) { [void]$PSCmdlet.ShouldProcess($Fo.Full, "Set restricted permissions (+$($Add.Count) / -$($Remove.Count), after the groups above exist)") }
                elseif ($Apply -and $Missing) { Write-FsLog "$($Fo.Rel): permissions not set; group(s) missing: $(($Missing | ForEach-Object { $_.Sid.Substring(4) }) -join ', ')" -LogType ERROR }
                elseif ($Apply -and $PSCmdlet.ShouldProcess($Fo.Full, 'Set restricted permissions')) {
                    # Rollback copy: icacls "<parent folder>" /restore "<file>"
                    if (-not (Test-Path -LiteralPath $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
                    $BackupFile = Join-Path $BackupDir ('{0}_{1}.acl' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), ($Fo.Rel -replace '[\\/:*?"<>|]', '_'))
                    $Eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                    $Out = & icacls.exe $Fo.Full /save $BackupFile /Q 2>&1
                    $ErrorActionPreference = $Eap
                    if ($LASTEXITCODE -ne 0) { throw "Could not save the current permissions of $($Fo.Full) ($($Out -join ' ')); nothing changed there." }
                    $New = New-Object System.Security.AccessControl.DirectorySecurity
                    $New.SetAccessRuleProtection($true, $false)
                    foreach ($D in $Desired.ToArray()) {
                        $Inh = if ($D.Scope -in 'All', 'Children') { [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' } else { [System.Security.AccessControl.InheritanceFlags]::None }
                        $Prop = if ($D.Scope -eq 'Children') { [System.Security.AccessControl.PropagationFlags]::InheritOnly } else { [System.Security.AccessControl.PropagationFlags]::None }
                        $New.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                                    (New-Object System.Security.Principal.SecurityIdentifier($D.Sid)), [System.Security.AccessControl.FileSystemRights]($D.Rights -bor $SyncBit),
                                    $Inh, $Prop, [System.Security.AccessControl.AccessControlType]::Allow)))
                    }
                    Set-FsDirSecurity -Path $Fo.Full -Security $New
                    Write-FsLog "$($Fo.Rel): permissions set (+$($Add.Count) / -$($Remove.Count)$(if (-not $Protected) { ', inheritance off' })); previous saved to $BackupFile."
                }
            }

            # Contents: everything inside should simply inherit from this folder. Moved-in items keep their
            # old (inherited) permissions and items given permissions by hand are reset - on every -Apply,
            # so the script can be run again and again to repair them.
            $FixNow = $Apply -and -not $SkipContents -and -not $WhatIfPreference -and -not $Missing
            $Inside = @(Get-FsContentProblems -Path $Fo.Full -Skip $Managed -Fix:$FixNow)
            foreach ($U in @($Inside | Where-Object Kind -eq 'Restricted')) {
                Write-Host "  inside: restricted folder no rule manages (left alone): $($U.Path.Substring($ShareRoot.Length + 1))" -ForegroundColor Yellow
                $Suggest.Add($U.Path.Substring($ShareRoot.Length + 1))
            }
            $Wrong = @($Inside | Where-Object { $_.Kind -in 'Explicit', 'Stale' })
            if ($Wrong) {
                $Totals.Children += $Wrong.Count
                $Moved = @($Wrong | Where-Object Kind -eq 'Stale').Count
                $Hand = @($Wrong | Where-Object Kind -eq 'Explicit').Count
                $What = (@($(if ($Moved) { "$Moved moved in (old permissions)" }), $(if ($Hand) { "$Hand with permissions set by hand" })) | Where-Object { $_ }) -join ', '
                if ($FixNow) {
                    $Done = @($Wrong | Where-Object Fixed).Count
                    Write-FsLog "$($Fo.Rel): $Done of $($Wrong.Count) item(s) inside reset to inherit ($What)."
                }
                else {
                    Write-Host ("  inside: {0} item(s) don't match this folder's permissions: {1}{2}" -f $Wrong.Count, $What, $(if ($SkipContents) { ' (-SkipContents: left as they are)' } else { ' (-Apply makes them inherit)' })) -ForegroundColor Yellow
                    foreach ($X in ($Wrong | Select-Object -First 5)) { Write-Host "    $($X.Kind.ToLower()): $($X.Path.Substring($Fo.Full.Length + 1))" }
                    if ($Wrong.Count -gt 5) { Write-Host "    ... $($Wrong.Count - 5) more" }
                    if ($Apply -and $WhatIfPreference) { [void]$PSCmdlet.ShouldProcess($Fo.Full, "Reset $($Wrong.Count) item(s) inside to inherit") }
                }
            }
        }
        #endregion

        #region Rules to add for restricted folders nobody manages yet
        if ($Suggest.Count) {
            Write-Host ''
            Write-Host '  Restricted folders no rule manages. To manage them, add rules like these to Areas[].Rules' -ForegroundColor Yellow
            Write-Host '  (Roles: their own groups; KeepParentRoles: which of the parent folder''s groups stay, e.g. [ "E" ]):' -ForegroundColor Yellow
            foreach ($Rel in $Suggest.ToArray()) {
                $Long = ("$($Cfg.GroupNameFormat)" -replace '\{Role\}', 'E' -replace '\{Share\}', $Share.ToUpper() -replace '\{Path\}', ('.' + ($Rel -replace '\\', '.'))).Length
                $Gp = if ($Long -gt $MaxLen) { ', "GroupPath": "<shorter path: the name is ' + $Long + ' characters, limit ' + $MaxLen + '>"' } else { '' }
                Write-Host ('    {{ "Path": "{0}", "Roles": [ "E", "R" ], "KeepParentRoles": [ ]{1} }},' -f ($Rel -replace '\\', '\\'), $Gp)
            }
        }
        #endregion

        #region Sites: one Facility folder per site (corporate / administrative sites excluded)
        if ($A.Sites) {
            $SiteCfg = $A.Sites
            $Excluded = @($SiteCfg.Exclude | ForEach-Object { "$_".ToLower() })
            # Folders: site OU -> folder path(s) below Folder (a campus can list several houses)
            $Map = @{}; if ($SiteCfg.Folders) { foreach ($P in $SiteCfg.Folders.PSObject.Properties) { $Map[$P.Name.ToLower()] = @($P.Value | ForEach-Object { "$_" }) } }
            $Under = Join-Path $ShareRoot "$($SiteCfg.Folder)"
            # The site folders: Depth levels below Folder (2 = <type>\<site>, e.g. Houses\Logan)
            $Depth = if ($SiteCfg.Depth) { [int]$SiteCfg.Depth } else { 1 }
            $Existing = @(Get-ChildItem -LiteralPath $Under -Directory -Force -Recurse -Depth ($Depth - 1) | Where-Object { ($_.FullName.Substring($Under.Length + 1) -split '\\').Count -eq $Depth } | ForEach-Object { $_.FullName.Substring($Under.Length + 1) })
            $Claimed = @{}
            $Lines = New-Object System.Collections.Generic.List[string]
            foreach ($Site in @(Get-ADOrganizationalUnit -SearchBase "$($SiteCfg.SearchBase)" -SearchScope OneLevel -Filter * | Where-Object { $_.Name -match "$($SiteCfg.NamePattern)" } | Sort-Object Name)) {
                if ($Excluded -contains $Site.Name.ToLower()) { continue }
                if (-not $Map.ContainsKey($Site.Name.ToLower())) { $Lines.Add(("    site {0}: not mapped to a folder (Sites.Folders)" -f $Site.Name)); continue }
                foreach ($Want in $Map[$Site.Name.ToLower()]) {
                    $Claimed[$Want.ToLower()] = $true
                    if (-not (Test-Path -LiteralPath (Join-Path $Under $Want))) { $Lines.Add(("    site {0}: no folder {1}\{2}" -f $Site.Name, $SiteCfg.Folder, $Want)) }
                }
            }
            foreach ($N in $Existing) {
                if (-not $Claimed.ContainsKey($N.ToLower()) -and @($SiteCfg.Shared) -notcontains $N) { $Lines.Add(("    folder {0}\{1}: no site (add it to Sites.Folders or Sites.Shared)" -f $SiteCfg.Folder, $N)) }
            }
            Write-Host ''
            if ($Lines.Count) { Write-Host "  Sites and $($SiteCfg.Folder) folders that don't match:" -ForegroundColor Yellow; foreach ($L in $Lines.ToArray()) { Write-Host $L } }
            else { Write-Host "  Sites: every site has its $($SiteCfg.Folder) folder." -ForegroundColor DarkGray }
        }
        #endregion

        #region Legacy groups no rule uses
        $Prefixes = if ($A.LegacyPrefixes) { @($A.LegacyPrefixes | ForEach-Object { "$_" }) } else { @($Folders.Values | ForEach-Object { "FLD-$($Share.ToUpper())." + (($_.Rel -split '\\')[0]).ToUpper() } | Select-Object -Unique) }
        $Unused = foreach ($Pre in $Prefixes) {
            $Like = "$Pre*"
            Get-ADGroup -Filter "Name -like '$Like'" -Properties Members | Where-Object { -not $UsedGroups.ContainsKey("$($_.SID)") }
        }
        if ($Unused) {
            Write-Host ''
            Write-Host '  Legacy groups no rule uses (map them in Legacy, or delete them by hand):' -ForegroundColor Yellow
            foreach ($U in ($Unused | Sort-Object Name)) { Write-Host ("    {0}  ({1} members)" -f $U.Name, @($U.Members).Count) }
        }
        #endregion
    }

    Write-Host ''
    Write-Host ("Summary: OUs create {0}; groups create {1}, rename {2}, move {3}, merge {4}; nestings {5}; folders to change {6}; owners to set {7}; items inside with own permissions {8}." -f $Totals.OUs, $Totals.Create, $Totals.Rename, $Totals.Move, $Totals.Merge, $Totals.Nest, $Totals.Folders, $Totals.Owners, $Totals.Children) -ForegroundColor Cyan
    if (-not $Apply) { Write-Host 'Nothing was changed. Run again with -Apply (add -WhatIf to preview each step).' -ForegroundColor Cyan }
}
catch {
    Write-FsLog "Folder security failed: $($_.Exception.Message)" -LogType ERROR
    throw
}

# Example usage:
# PS> C:\SCRIPTS\Applications\Microsoft\FileSystems\NetworkDataPermissionsSet\Set-NetworkDataPermissions.ps1
# PS> C:\SCRIPTS\Applications\Microsoft\FileSystems\NetworkDataPermissionsSet\Set-NetworkDataPermissions.ps1 -Folder 'Facility\TN.MORRISON.CAMPUS-SUNNY_ACRES_ROAD' -Apply


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAxX+BW6eKlAUE3
# p3lZrmWk/P6TzyE5evKj/i2NulCiLKCCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
# 5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBa
# Fw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lD
# ZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3E
# MB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKy
# unWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsF
# xl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU1
# 5zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJB
# MtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObUR
# WBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6
# nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxB
# YKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5S
# UUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+x
# q4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIB
# NjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwP
# TzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMC
# AYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENB
# LmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0Nc
# Vec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnov
# Lbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65Zy
# oUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFW
# juyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPF
# mCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9z
# twGpn1eqXijiuZQwgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqG
# SIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRy
# dXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYg
# MjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphB
# cr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6p
# vF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHe
# HYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEd
# gkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjU
# jsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bR
# VFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeS
# LsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIV
# NSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL
# 6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2Zd
# SoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFU
# eEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/
# BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0j
# BBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0
# cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8E
# PDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVz
# dGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEw
# DQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/
# T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQ
# E7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9r
# EVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y
# 1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gx
# dEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3t
# y9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcy
# tL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEB
# YTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud
# /v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiS
# uEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZP
# ubdcMIIG6DCCBNCgAwIBAgITQAAAAqtBkGO1asEvkAAAAAACqzANBgkqhkiG9w0B
# AQsFADBwMRMwEQYKCZImiZPyLGQBGRYDY29tMSIwIAYKCZImiZPyLGQBGRYSZ2Vu
# ZXJhdGlvbnNnYWl0aGVyMTUwMwYDVQQDEyxnZW5lcmF0aW9uc2dhaXRoZXItU1JW
# MDEwMDEwMDM4MDM1LUlzc3VpbmdDQTAeFw0yNjA4MjAxNzMzNTRaFw0yNzAxMzEx
# NzI3MjVaMDgxFDASBgNVBAoTC0dlbmVyYXRpb25zMSAwHgYDVQQDExdQb3dlcnNo
# ZWxsIENvZGUgU2lnbmluZzCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEB
# AMgHhkqXmzDlBuov3PJaCmpZddU3S+1mt4Yaahz121grfW1H+nHXf2cUuzH12wzG
# ErW+kF0lqkBll/26aHzETnBepOxaP+KCoKZ7db4mYctch5wdDTANplQu35hPEO6I
# yNhrEk5UQqAjM9ONKCdWkzBo+/vaTbQDpYwc7h2s1s8dZdjU4tqy72+ThXEx8Vp3
# OePAXZ1moCIPXuhjSEoCMasqIuWDwavRRLXONBrhhue84FPyFa7qpTOz7Hg98DfW
# pMA+ZIXl/KJVlRdN5H8b0IZiWczfHUyz76fw67tzngUR7CI2xeTkdSpJ1dl2O+Xi
# T33pvcVEnjq/Pql0rddXBbUCAwEAAaOCArEwggKtMD0GCSsGAQQBgjcVBwQwMC4G
# JisGAQQBgjcVCIK0njms71qCqYE6gt6kboK4gAOBOIO8mwSBh4VAAgFkAgEDMBMG
# A1UdJQQMMAoGCCsGAQUFBwMDMA4GA1UdDwEB/wQEAwIHgDAbBgkrBgEEAYI3FQoE
# DjAMMAoGCCsGAQUFBwMDMB0GA1UdDgQWBBRT5Uu5LaLJBCLOFGRaVsipJu+gMjAf
# BgNVHSMEGDAWgBROXx35Y5WKLzaZqCYJ3GvzXL4RnDCB/QYDVR0fBIH1MIHyMIHv
# oIHsoIHphoHmbGRhcDovLy9DTj1nZW5lcmF0aW9uc2dhaXRoZXItU1JWMDEwMDEw
# MDM4MDM1LUlzc3VpbmdDQSxDTj1zcnYwMTAwMTAwMzgwMzUsQ049Q0RQLENOPVB1
# YmxpYyUyMEtleSUyMFNlcnZpY2VzLENOPVNlcnZpY2VzLENOPUNvbmZpZ3VyYXRp
# b24sREM9Z2VuZXJhdGlvbnNnYWl0aGVyLERDPWNvbT9jZXJ0aWZpY2F0ZVJldm9j
# YXRpb25MaXN0P2Jhc2U/b2JqZWN0Q2xhc3M9Y1JMRGlzdHJpYnV0aW9uUG9pbnQw
# gekGCCsGAQUFBwEBBIHcMIHZMIHWBggrBgEFBQcwAoaByWxkYXA6Ly8vQ049Z2Vu
# ZXJhdGlvbnNnYWl0aGVyLVNSVjAxMDAxMDAzODAzNS1Jc3N1aW5nQ0EsQ049QUlB
# LENOPVB1YmxpYyUyMEtleSUyMFNlcnZpY2VzLENOPVNlcnZpY2VzLENOPUNvbmZp
# Z3VyYXRpb24sREM9Z2VuZXJhdGlvbnNnYWl0aGVyLERDPWNvbT9jQUNlcnRpZmlj
# YXRlP2Jhc2U/b2JqZWN0Q2xhc3M9Y2VydGlmaWNhdGlvbkF1dGhvcml0eTANBgkq
# hkiG9w0BAQsFAAOCAgEAAHvAjyztTm9FmITG34NV4dx+megfwLzllxDHlShSacUx
# XzEPlVd4XScO3O1a+0sngL1XuE8xVDBe6suITmBjbN/BYo8vRjbIUlwUYE54FhRD
# rUOHYYEIecLI1ax1qpnS19Fy8YIOu7y14R2NwbY38uNZ7UDb5TBGiwJdHR+jlQVX
# Qyu0gONFsaP/mqeFKqkOKAQ0UWo38Q6U/4zJ5I9nuiHULQWqEiUEF0kTEudFWwhP
# hiwGjiIRGzmpJtiMuffHRk2kDk3wXcFyR4cjtkQjXqq3crMRnxoC3FohGFL4EmXe
# 3knNDtgR3ODvE0zrzHiPCBeF/goZ5p+/6v35xfCLPDRzXCz1FC3U6/VVomuLf5ln
# m6tO0+X9iFFi2LsnvYi6omNesi+qBRQcXq0uPbK8eA/grIk4+zVVooM2Dc9diS0C
# hwoFqMV0t0H3lpdmCXCLIqYaqO4FwxTy1Mm/Q6PZHPD/Uxq8QUPeOtvD5x7RsNRw
# zT+yaU73mqtqPc/lrcG6SRWd3jE79GbkGM3n+0FfD097Ks0lk/U820Is++u/8gPV
# kEe2UePSM2XYc4CYUlPYStlcyMh1t44TX/5l6qypJBehjdzYnvMe2ZRDL3SmPj4K
# AJiHANKMgoKK9GSW3qCeXMT+qevxRBKnhkBJcBYn/mHIMhHbwSwSTxU0mW+ggLMw
# ggbtMIIE1aADAgECAhAIT9wzT35FTtvDD4/5khg1MA0GCSqGSIb3DQEBCwUAMGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYg
# MjAyNSBDQTEwHhcNMjYwODA1MDAwMDAwWhcNMzcxMTA0MjM1OTU5WjBjMQswCQYD
# VQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lD
# ZXJ0IFNIQTI1NiBSU0E0MDk2IFRpbWVzdGFtcCBSZXNwb25kZXIgMjAyNiAxMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtnum8sn+zUr41JtMZbP9OMYw
# +HwJDpG5xkIu/lqcfNYmMX81YmsUiHLbh9ykpeWBGKTLhYBrAN9Tdg/QEzG32XcO
# bmgIblnr0CoQ3WSAeDZ6nH6X6VkFyYkJw3QBJREwvm4UhLzSxmwPA7cFKRTEOMsm
# EEj6qJk/dqLEAL+oQYuOwE2UuiX1Vnul8YReIyWd4kgLn9gq6LNXM0UplkR6jL/Q
# Hxmb6fMoGBJYbnaUI7XD6cKDpekK2SVMld4iDbzeHDtOaaxldH5IxuNusQ69nd8/
# ZXEiB5Hbxj3RlK13cX1W4DlFXKdv/CEhM8Cj1vvlmvhNroyPdRGbbpBlgyf8Wdu5
# N6ByhFwURn0U6ozlPoxN22v+fviUhP+6DR547OZnpBMWDfei1f5sVGwiiW/KQTWO
# K97g+4RJpPzPNV4VYMAwO2jM2Aty2QYPVmOQTJm0msuXnJrSbl2gf9JylpkJlWXq
# k1Q4LJsxz+TELoQCZIljbgvTJgoPU2R12ydv8i1UqL/adelA0y7U9Pmmtbze9Xx3
# rtajC5SzQd1jgfwAwsa90v9YcSPdmeoyoBBA/27cCL237l5DTYYPDLQ4ON3OLTGW
# nvRb6jDrf/T75gMRfUzSLCBQfBusm9+mSWRlC/Df6S/e9Q8i13CuhzOT2Jx+V/nl
# bXM4QoBwlUAhelwwJT0CAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQCMAAwHQYDVR0O
# BBYEFBTJY4owLtRK+26U8+bjQH717M3iMB8GA1UdIwQYMBaAFO9vU0rp5AZ8esri
# kFb2L9RJ7MtOMA4GA1UdDwEB/wQEAwIHgDAWBgNVHSUBAf8EDDAKBggrBgEFBQcD
# CDCBlQYIKwYBBQUHAQEEgYgwgYUwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRp
# Z2ljZXJ0LmNvbTBdBggrBgEFBQcwAoZRaHR0cDovL2NhY2VydHMuZGlnaWNlcnQu
# Y29tL0RpZ2lDZXJ0VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIw
# MjVDQTEuY3J0MF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYy
# MDI1Q0ExLmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJ
# KoZIhvcNAQELBQADggIBAI3FOmEenVIK35msCYB+fShAsWvSYvLBItoNdAgQ2jIq
# rGsVsluXMJU/+mRebBc52s6lbKAvOVPXaizmKkMLLflEEKDZQx4CkS2t8aHPjkXh
# a3hYZ010htFa3dhNgmalH5vuWvh3tTCf4frTS7gPtGc4Z/xaPhQ2AB1mR8eEe/Wb
# H0RWHvVIl6VwQ3+g5FKNfN2N/DWJkf13w2H+2GfqEfbd35Ww8CvoYBjLNIDTadcP
# WdgsjsiOaK/7EsKJgLjUNIVgvcaFOLLQ/GlrA+0ZHJoFUbOr5SJN8zykPspXIXlp
# DJY/gqFUZRROeab9GVgmhbdOJcD/63RhxPahFUGbckRONqMe6DYAv6/mOG0pWd3c
# PStsdcS7buj5DyniwRY8yooMH6ptx5vpP/pZzBPBeZD2U4IsthyxB5Jaa8qrOkB5
# z160TXiM5ADMspZ0TfD9MJoq0tFpFPssKRFhWeEDYPvcUuN7U7lvcdHl4ezQ3NT/
# 7Ffs1sR1yh/LRbdZ3B3Vc6q2WmD8mDC0p9kzl2o73iVtS946IkEj7FkRsZGww1te
# YxERROC745xrtjvcw9ZyyUjHZWGRIpJeMNsPquCDf0fkyHtB+J4AiNZqCQk23rxh
# +KbpyMTNVKItJ5l92Svl20U9NbqMBOVYl1h54NEYLJq1/xHWFKPNK903zJZA9P2D
# MIIITDCCBgCgAwIBAgITGQAAAAu8LyA0hwqD9AAAAAAACzBBBgkqhkiG9w0BAQow
# NKAPMA0GCWCGSAFlAwQCAwUAoRwwGgYJKoZIhvcNAQEIMA0GCWCGSAFlAwQCAwUA
# ogMCAUAwbTETMBEGCgmSJomT8ixkARkWA2NvbTEiMCAGCgmSJomT8ixkARkWEmdl
# bmVyYXRpb25zZ2FpdGhlcjEyMDAGA1UEAxMpZ2VuZXJhdGlvbnNnYWl0aGVyLVNS
# VjAxMDAxMDAzNzAzNS1Sb290Q0EwHhcNMjUwMTMxMTcxNzI1WhcNMjcwMTMxMTcy
# NzI1WjBwMRMwEQYKCZImiZPyLGQBGRYDY29tMSIwIAYKCZImiZPyLGQBGRYSZ2Vu
# ZXJhdGlvbnNnYWl0aGVyMTUwMwYDVQQDEyxnZW5lcmF0aW9uc2dhaXRoZXItU1JW
# MDEwMDEwMDM4MDM1LUlzc3VpbmdDQTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAME7bcPuw+OBlpLFMrUpTOHjElzdC+VrSCfa9scUjHCqDU2B9rTBDzN5
# 5xpCu+NC4psqMzLIbOOOmv1KkfKvdDNkmgK7sJ6v4CxXrLsVELZkugW7mQG2NpTY
# yurNWkIxxn6U8wZHIwRbzH3a5XPHgeejY8+XEn4lDeQ/gy4HZPrT6gO2ML9MoED0
# jkXuSpBlotXDlv8D/EJTvTWoT3i/8sSa6J5uO+r0ckCSCkxvMy4zwifEFLmUNope
# nB8aPzs4NkRnPhNg7OcRyjssDcijiVWV8Tee9N0iAc637aJrTD8CtSyUDMAA0Zhh
# tjaGlcj7xXM1GhBvmlwn0EchVyGsALPC41AMHQRi3FNl6k633iXssKkcQL51EuAx
# XWS73CrcD1w1leFNVZnxmtW3yGzto6ND9ZSuYwyrBrqJLVfXVQJC+0ruUNrz/B/5
# jHey1Se4iLQnGrgrLVhJAAZHGAXuVTYB4f5s1cjjvj7+h6i/ZnJOYlCEW8ipwVW4
# 1AFjnxEAenzxAFv7NeoWuusJoPq9sGvC9xJfxClWt9zZfu4qJ95k1e+t1t4CSnvM
# 5O0uY4KqQDX1I0IOTozy9jT04QSLpm3VdLmznOFebja1213JR/D3GeApyqNJzEr5
# wWiIeZWkk27a+Yc3e9xGTke2nT06j+ytb66v8CIdxuy9JdfBn8aNAgMBAAGjggJ4
# MIICdDAQBgkrBgEEAYI3FQEEAwIBADAdBgNVHQ4EFgQUTl8d+WOVii82magmCdxr
# 81y+EZwwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwDgYDVR0PAQH/BAQDAgGG
# MA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAUQBf/oJasKe2FCSOPWKt9FaN9
# U1EwgfoGA1UdHwSB8jCB7zCB7KCB6aCB5oaB42xkYXA6Ly8vQ049Z2VuZXJhdGlv
# bnNnYWl0aGVyLVNSVjAxMDAxMDAzNzAzNS1Sb290Q0EsQ049c3J2MDEwMDEwMDM3
# MDM1LENOPUNEUCxDTj1QdWJsaWMlMjBLZXklMjBTZXJ2aWNlcyxDTj1TZXJ2aWNl
# cyxDTj1Db25maWd1cmF0aW9uLERDPWdlbmVyYXRpb25zZ2FpdGhlcixEQz1jb20/
# Y2VydGlmaWNhdGVSZXZvY2F0aW9uTGlzdD9iYXNlP29iamVjdENsYXNzPWNSTERp
# c3RyaWJ1dGlvblBvaW50MIHmBggrBgEFBQcBAQSB2TCB1jCB0wYIKwYBBQUHMAKG
# gcZsZGFwOi8vL0NOPWdlbmVyYXRpb25zZ2FpdGhlci1TUlYwMTAwMTAwMzcwMzUt
# Um9vdENBLENOPUFJQSxDTj1QdWJsaWMlMjBLZXklMjBTZXJ2aWNlcyxDTj1TZXJ2
# aWNlcyxDTj1Db25maWd1cmF0aW9uLERDPWdlbmVyYXRpb25zZ2FpdGhlcixEQz1j
# b20/Y0FDZXJ0aWZpY2F0ZT9iYXNlP29iamVjdENsYXNzPWNlcnRpZmljYXRpb25B
# dXRob3JpdHkwQQYJKoZIhvcNAQEKMDSgDzANBglghkgBZQMEAgMFAKEcMBoGCSqG
# SIb3DQEBCDANBglghkgBZQMEAgMFAKIDAgFAA4ICAQCXYn6MOeflWh5jgspvzRQQ
# CWPuI3Ob3d3xt3bCSp1EW7uSAk1vkSc7OmcAUTayZXI7HH9KjIBTey1yuss4ynun
# /ZD87JBLTX9IWZcnD7SsDddk/7Qi4zRMj+Z8orAeLifAHXDGVFogWPr7giAvJU8n
# XPFjmz+5h6Vhujn9Ny5iaCKGXDbsb0FBimSqTyFMZ3hY5Z0AK87dWQIHWnx227Rm
# n5OIJCNC1lqpzHOgRs+VObKNSJMnSjyxOY77AaW73mXf0JGSJ4e61jJGvkghuZmX
# 3D+VvyOeXiNUfVpPRw5EVSUdPqYm6Y7pKTa0Dc7Wat4lCe8UGNwowIA3RfpzxeL3
# o6CvCn2tslFCtyO40fKX6Rgh+Fl5cAddwLYQTIULk4pxLqJBtAUPVhd+yTc+S6gl
# shFy+j1H9m1K9HfoQBTgukTKn3QWkn49FbbiNTAQ/Sr9XN4HF7/zJEu8WrA6GeLq
# QVYtIm2lwELocI3UPzSpp7Vw8TpRsFhJSOvfWEBjbNBvAWB7g79/AuotJ0DHIxnu
# yK6i6mf3ZUi9hj9g+lyXB/TQoRH8p3f01lpl7x60COLxJTSd4C3W0msRsTaqeO7x
# ZNZuc3i35mRD3XPmchB3Xgmx/qxAbnv8vDvOe86nz4wDRcHJtKoOtRdXDuBxqavy
# 8e8SwzOBXivKZRSg9xYQMTGCBWQwggVgAgEBMIGHMHAxEzARBgoJkiaJk/IsZAEZ
# FgNjb20xIjAgBgoJkiaJk/IsZAEZFhJnZW5lcmF0aW9uc2dhaXRoZXIxNTAzBgNV
# BAMTLGdlbmVyYXRpb25zZ2FpdGhlci1TUlYwMTAwMTAwMzgwMzUtSXNzdWluZ0NB
# AhNAAAACq0GQY7VqwS+QAAAAAAKrMA0GCWCGSAFlAwQCAQUAoIGEMBgGCisGAQQB
# gjcCAQwxCjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIIqQcTSf
# 2euQUFau9bbbSlUwfrolD5nbK5ZQarUqMOqSMA0GCSqGSIb3DQEBAQUABIIBAExZ
# CR9/c7eMe7H6qTHN1dLjKrJsDd/v/sNSZqDTBuCckvtV2hkxA7NMZh1le1JBtfea
# 2NnfAW525v9brk7xfEb1A5MSZzRD0iyaVwBUCy8jwgzJZyy/jr1gytzfe5VXytCM
# u2R6HwnYm98JkzRbIB73ALAnO+gfrJwyxoOD9eQFz6ExuPKCRI+Q7u79W6GKK3OD
# TLUVBEgAgGcvtAqXHM2p7/B3zaIGLEIjG2+joKcQ1y9xg9wIB2Ja2CaEQL1nX1Nf
# VWJ/SIMSfoKSUdWCc3Ab1oxtdPtK4HpdKlQhG+akfHeZdFaAd0+6Sz7UDg4UDbHF
# RoYKBcxjnKBswcA7Kf+hggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDI3MTM1
# MzQ3WjAvBgkqhkiG9w0BCQQxIgQgW5eE7Wy0aMK7lx71bUvkZZQdx6l6MSADUoUu
# lkjmKRswDQYJKoZIhvcNAQEBBQAEggIADAShRwtXGFXv5pO8BucfWcGHks4yZ5S0
# kINx7tzyAZWLOM3cjtxa+zx+Qd97ZT3YGkhdVdaJoNyxeLGOG8Bdu5fKbmD0cpVw
# 0wJGQVaOtnTTqusjfTTzTXfvxLaQ7Nj4tzjzaZ0gcQDBt5110dvr7HU6QEx65bR2
# p8KzHlQxZshXUwZtMTAzo+ZjPpzNlXTCwhY9l0j8cyuVKdNhM/OUUp8USLu2dc2U
# wdGg+voYgGmGycM443WI0sWVAGyHrKRqNlPfMa4NTFGLQECPw+P5x0+sfVpMWtwo
# RNjCDKR7Ne7ntamE1b0QRUV1KKli0LG0VArvUutyGNCzf0RIBccuBgvsiZsxyTMt
# uYrBfcmsWFyLhHsq8USiQf7t/atzjr4wRu54DSU9xQ+mDZpN57kasCB7E4zZCrVz
# YKn3BCBngj3fOBaFK49JLCH7SHYLYYGg7VbiwDAOlHf9vVVHPkEk7QnN2IPjhCCH
# TlQMch0IwapIQFri4hbFPPMnwk2t8L0bjsgbvFL2bj/Tu1xZaBIkdYqkUd7kQN3h
# 2sLc2XBGCThM4nNJegNaDke08RQcyagPu/K8WxoyR/25P1Kq37DvBuGLNb+zxbns
# NAv1clfvJz3fRRPO7CFCxMTsmKMmxVtt826YLV6PsNVkiIJEpRim3v+rZslKf2am
# 5OoTrx/SohE=
# SIG # End signature block
