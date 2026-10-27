<#
.SYNOPSIS
    Removes old data under C:\SCRIPTS: log entries, old files and surplus backups, as the settings say.
.DESCRIPTION
    Part of Powershell Scripts Management (PSM). The Frontend sync (Sync-ScriptsFromDfs.ps1) calls it
    after every run; it can also be run on its own (use -WhatIf first).

    What is cleaned (targets):
      - Cleanup.Targets in C:\SCRIPTS\Data\Settings\Scripts.json (all servers), by default:
          every Logs\*.log trimmed to its entries of the last N days, and *.tmp leftovers in Logs.
      - Cleanup.Targets in each application's own settings file (Applications\...\Data\<App>.json),
        for the files that application creates.
    Every settings file is read with Get-ApplicationSettings, so the published per-server override
    (<App>.<SERVER>.json) and the local override of this server
    (Applications\Data\Settings\<App>.json) apply.

    How many days (first value found):
      1. Days on the target itself,
      2. Cleanup.Days of the application (or of Scripts.json for its own targets),
      3. Cleanup.DefaultDays in Scripts.json (90 when not set).
      -1 means never clean (that target, application or, as DefaultDays, everything without its own value).

    Target types:
      LogEntries  Write-AdvancedLog text logs (*.log): entries older than the cutoff are removed from
                  the file (header and newer entries kept; a file is rewritten only when it changes).
      Files       files older than the cutoff (last write) are deleted. "Recurse": true includes subfolders.
      KeepCount   only the newest "Keep" files are kept (days are not used).
    Path is relative to C:\SCRIPTS and may use wildcards, e.g. "Logs\\Transcripts\\*.log".

    The device's cleanup list, C:\SCRIPTS\Applications\Data\Settings\Cleanup.json, is processed too:
    one-off items (a File, Folder or scheduled Task, by full path) that an installer, a manifest's
    "Cleanup" list or an administrator added with Add-ScriptsCleanupItem, each deleted once it is due
    (Added + Days; -1 = never). Deleted or already missing items move to the list's Done history;
    failures stay with LastError and are tried again next run. These paths may be outside C:\SCRIPTS
    (e.g. C:\POSHACME.migrated) but never a system location, C:\SCRIPTS itself, its main folders,
    Applications\Data or live Certs data (Test-ScriptsCleanupItem).

    Safety: only files inside C:\SCRIPTS; never scripts (.ps1/.psm1/.psd1), never anything under
    Applications\Data (inventory, local settings) or a Certs folder; Files and KeepCount only delete
    in a folder named Logs, Backups, Transcripts, Temp, Tmp or Archive. Anything else is reported as
    refused.
.PARAMETER Root
    Scripts root. Defaults to the folder above Functions (C:\SCRIPTS).
.PARAMETER SettingsPath
    Scripts settings. Defaults to <Root>\Data\Settings\Scripts.json.
.EXAMPLE
    PS> . C:\SCRIPTS\Functions\Invoke-ScriptsCleanup.ps1; Invoke-ScriptsCleanup -WhatIf
.EXAMPLE
    PS> . C:\SCRIPTS\Functions\Invoke-ScriptsCleanup.ps1; (Invoke-ScriptsCleanup).Targets | Format-Table
.INPUTS
    None
.OUTPUTS
    [pscustomobject] Time, DefaultDays, Removed (files), Trimmed (log entries), FreedKB, Failed, Targets
    (one row per target: Owner, Type, Path, Days, Removed, Trimmed, FreedKB, Note).
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-22
    Time: 15:00:00
    Time Zone: Central Standard Time
    Function Or Application: Function
    Version: 1.1.1
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: Claude

    Copyright (c) 2026
    Licensed under the MIT License.
    Full text available at: https://opensource.org/licenses/MIT

    Overide Variables
    Overide Filename:
    Overide Log Filename: Invoke-ScriptsCleanup
    Overide Text Log File Path:
    Overide Log Type:
.LINK
    https://www.tnandc.com
#>

#region Cleanup list (Applications\Data\Settings\Cleanup.json on each device)
# Items to delete once, after an install or migration: an old folder (C:\POSHACME.migrated), a backup
# with old secrets, a script that an install renamed, an old scheduled task. Added by installers
# (Add-ScriptsCleanupItem), by manifests ("Cleanup": [...], added by the Frontend sync) or by hand;
# processed by Invoke-ScriptsCleanup when due. The file is server-local: never published or synced.
#   { "Items": [ { "Type": "Folder|File|Task", "Path": "...", "Days": 30, "Added": "...", "Due": "...",
#                  "Reason": "...", "By": "...", "LastError": "" } ],
#     "Done":  [ { "Type", "Path", "Result", "Time", "Reason", "By" } ] }   (last 50)

function Get-ScriptsCleanupListPath {
    param([string]$Root = (Split-Path -Path $PSScriptRoot -Parent))
    Join-Path -Path $Root.TrimEnd('\') -ChildPath 'Applications\Data\Settings\Cleanup.json'
}

# Why an item may not be removed, or '' when it may. Paths outside C:\SCRIPTS are allowed (that is the
# point of the list), but never system locations, C:\SCRIPTS itself or its live data.
function Test-ScriptsCleanupItem {
    param([string]$Type, [string]$Path, [string]$Root = (Split-Path -Path $PSScriptRoot -Parent))
    $Root = $Root.TrimEnd('\')
    if ($Type -eq 'Task') {
        if ($Path -notmatch '^\\.+') { return 'a task path starts with \ (folder\name)' }
        if ($Path -like '\Microsoft\Windows\*') { return 'Windows tasks (\Microsoft\Windows\) are never removed' }
        if ($Path -like '\PSM\*') { return 'PSM tasks are never removed' }
        return ''
    }
    if ($Path -notmatch '^[A-Za-z]:\\.') { return 'not a full local path (X:\...)' }
    if ($Path -match '[\*\?]') { return 'wildcards are not allowed' }
    $Full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $D = $Full.Substring(0, 2)
    $Exact = @("$D\Windows", "$D\Program Files", "$D\Program Files (x86)", "$D\ProgramData", "$D\Users", "$D\PerfLogs",
        $Root, "$Root\Applications", "$Root\Data", "$Root\Data\Settings", "$Root\Functions", "$Root\Modules", "$Root\Logs", "$Root\Installs", "$Root\Applications\PSM")
    if ($Full.Length -le 3 -or ($Exact | Where-Object { $Full -ieq $_ })) { return 'a system or scripts root folder' }
    foreach ($Under in "$D\Windows\", "$D\Program Files\", "$D\Program Files (x86)\", "$D\System Volume Information", "$D\`$Recycle.Bin", "$Root\Applications\Data\", "$Root\Applications\Data") {
        if ($Full.StartsWith($Under, [System.StringComparison]::OrdinalIgnoreCase)) { return "inside $Under" }
    }
    if ($Full -match '^[A-Za-z]:\\Users\\[^\\]+$') { return 'a user profile folder' }
    if ($Full.StartsWith("$Root\", [System.StringComparison]::OrdinalIgnoreCase) -and ($Full.Substring($Root.Length + 1).Split('\') -contains 'Certs')) { return 'live Certs data under the scripts folder' }
    ''
}

function Read-ScriptsCleanupList {
    param([string]$Path)
    $L = [ordered]@{ Items = New-Object System.Collections.Generic.List[object]; Done = New-Object System.Collections.Generic.List[object] }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $J = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        foreach ($I in @($J.Items | Where-Object { $_ })) { $L.Items.Add($I) }
        foreach ($I in @($J.Done | Where-Object { $_ })) { $L.Done.Add($I) }
    }
    $L
}
function Save-ScriptsCleanupList {
    param([string]$Path, $List)
    $Dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $Doc = [ordered]@{}
    $Doc['Notes'] = 'Items to delete once they are due (Added + Days; -1 = never). Type File, Folder or Task (\folder\name). Add with Add-ScriptsCleanupItem, a manifest "Cleanup" list, or by hand. Processed by Invoke-ScriptsCleanup after each Frontend sync; this file is never synced.'
    $Doc['Items'] = [object[]]$List.Items.ToArray()
    $Doc['Done'] = [object[]]@($List.Done | Select-Object -Last 50)
    $Tmp = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N').Substring(0, 8)
    [System.IO.File]::WriteAllText($Tmp, (ConvertTo-Json -InputObject $Doc -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $Tmp -Destination $Path -Force
}

<#
.SYNOPSIS
    Adds a file, folder or scheduled task to this device's cleanup list (Cleanup.json), to be deleted
    after a number of days. Adding the same Type and Path again changes nothing (the first entry stays).
.EXAMPLE
    PS> Add-ScriptsCleanupItem -Path 'C:\POSHACME.migrated' -Days 30 -Reason 'Old Posh-ACME store, migrated to PoshAcme\Certs'
.EXAMPLE
    PS> Add-ScriptsCleanupItem -Type Task -Path '\Powershell\Update certificate for netsolutions' -Days 30 -Reason 'Replaced by \IIS\LetsEncrypt\RenewIisCertificates'
#>
function Add-ScriptsCleanupItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [ValidateSet('Auto', 'File', 'Folder', 'Task')]
        [string]$Type = 'Auto',

        [int]$Days = 30,

        [string]$Reason = '',

        [string]$By = $(if ($MyInvocation.PSCommandPath) { Split-Path -Path $MyInvocation.PSCommandPath -Leaf } else { "$env:USERDOMAIN\$env:USERNAME" }),

        [string]$Root = (Split-Path -Path $PSScriptRoot -Parent)
    )
    if ($Type -eq 'Auto') { $Type = if ($Path -like '\*') { 'Task' } elseif (Test-Path -LiteralPath $Path -PathType Container) { 'Folder' } else { 'File' } }
    $Why = Test-ScriptsCleanupItem -Type $Type -Path $Path -Root $Root
    if ($Why) { throw "Not added to the cleanup list: $Path ($Why)." }
    $ListPath = Get-ScriptsCleanupListPath -Root $Root
    $List = Read-ScriptsCleanupList -Path $ListPath
    $Same = $List.Items | Where-Object { "$($_.Type)" -eq $Type -and "$($_.Path)" -ieq $Path } | Select-Object -First 1
    if ($Same) { Write-Verbose "Already on the cleanup list: $Type $Path (due $($Same.Due))."; return $Same }
    $Now = Get-Date
    $Item = [pscustomobject][ordered]@{
        Type = $Type; Path = $Path; Days = $Days
        Added = $Now.ToString('s'); Due = $(if ($Days -lt 0) { '' } else { $Now.AddDays($Days).ToString('s') })
        Reason = $Reason; By = $By; LastError = ''
    }
    $List.Items.Add($Item)
    Save-ScriptsCleanupList -Path $ListPath -List $List
    $Item
}
#endregion

function Invoke-ScriptsCleanup {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Root = (Split-Path -Path $PSScriptRoot -Parent),

        [Parameter(Mandatory = $false)]
        [string]$SettingsPath
    )

    # The folder's real (long) name, so files listed under it always compare as inside it
    if (Test-Path -LiteralPath $Root) { $Root = (Get-Item -LiteralPath $Root).FullName }
    $Root = $Root.TrimEnd('\')
    if (-not $SettingsPath) { $SettingsPath = Join-Path -Path $Root -ChildPath 'Data\Settings\Scripts.json' }
    foreach ($F in 'Get-ApplicationSettings.ps1', 'Write-AdvancedLog.ps1') {
        $P = Join-Path -Path $PSScriptRoot -ChildPath $F
        if ((Test-Path -Path $P) -and -not (Get-Command -Name ($F -replace '\.ps1$') -ErrorAction SilentlyContinue)) { . $P }
    }
    $LocalSettings = Join-Path -Path $Root -ChildPath 'Applications\Data\Settings'
    $Rows = New-Object System.Collections.Generic.List[object]
    $LineRx = [regex]'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \| '

    # Days: target, then owner (Cleanup.Days), then the default; -1 = never; $null = not set
    function Get-Days {
        param($Value)
        if ($null -eq $Value -or "$Value" -eq '') { return $null }
        $N = 0; if ([int]::TryParse("$Value", [ref]$N)) { return $N }
        $null
    }
    function Test-Allowed {
        param([string]$File, [string]$Type)
        $Full = [System.IO.Path]::GetFullPath($File)
        if (-not $Full.StartsWith("$Root\", [System.StringComparison]::OrdinalIgnoreCase)) { return 'outside the scripts folder' }
        $Rel = $Full.Substring($Root.Length + 1)
        if ([System.IO.Path]::GetExtension($Full) -in '.ps1', '.psm1', '.psd1') { return 'scripts are never removed' }
        if ($Rel -like 'Applications\Data\*') { return 'Applications\Data is never cleaned' }
        $Parts = @($Rel.Split('\') | Select-Object -SkipLast 1)
        if ($Parts -contains 'Certs') { return 'Certs folders are never cleaned' }
        if ($Type -eq 'LogEntries') { if ([System.IO.Path]::GetExtension($Full) -ne '.log') { return 'LogEntries only trims *.log files' } }
        elseif (-not ($Parts | Where-Object { $_ -in 'Logs', 'Backups', 'Transcripts', 'Temp', 'Tmp', 'Archive' })) { return 'files are only deleted in a Logs, Backups, Transcripts, Temp, Tmp or Archive folder' }
        ''
    }

    $Result = [ordered]@{ Time = (Get-Date).ToString('s'); DefaultDays = 90; Removed = 0; Trimmed = 0; FreedKB = 0; Failed = 0; ListPending = 0; Targets = @() }
    try {
        #region Targets: Scripts.json, then every application settings file on disk
        $Cfg = Get-ApplicationSettings -Path $SettingsPath -LocalSettingsFolder $LocalSettings
        $Default = 90
        if ($Cfg.Cleanup) { $D = Get-Days $Cfg.Cleanup.DefaultDays; if ($null -ne $D) { $Default = $D } }
        $Result.DefaultDays = $Default
        $Owners = New-Object System.Collections.Generic.List[object]
        $Owners.Add([pscustomobject]@{ Name = 'Scripts'; Settings = $Cfg })
        $AppsDir = Join-Path -Path $Root -ChildPath 'Applications'
        foreach ($F in @(Get-ChildItem -Path $AppsDir -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
            $_.Directory.Name -eq 'Data' -and $_.BaseName -notmatch '\.' -and $_.FullName -notlike "$AppsDir\Data\*" })) {
            try {
                $S = Get-ApplicationSettings -Path $F.FullName -LocalSettingsFolder $LocalSettings
                if ($S.Cleanup -and $S.Cleanup.Targets) { $Owners.Add([pscustomobject]@{ Name = $(if ($S.Name) { "$($S.Name)" } else { $F.BaseName }); Settings = $S }) }
            }
            catch { Write-Verbose "Skipped $($F.FullName): $($_.Exception.Message)" }
        }
        #endregion

        foreach ($O in $Owners) {
            $C = $O.Settings.Cleanup
            $OwnerDays = if ($C) { Get-Days $C.Days } else { $null }
            foreach ($T in @($C.Targets | Where-Object { $_ })) {
                $Type = if ("$($T.Type)") { "$($T.Type)" } else { 'Files' }
                $Days = Get-Days $T.Days; if ($null -eq $Days) { $Days = $OwnerDays }; if ($null -eq $Days) { $Days = $Default }
                $Row = [ordered]@{ Owner = $O.Name; Type = $Type; Path = "$($T.Path)"; Days = $Days; Removed = 0; Trimmed = 0; FreedKB = 0; Note = '' }
                try {
                    if (-not "$($T.Path)") { throw 'no Path' }
                    if ($Type -ne 'KeepCount' -and $Days -lt 0) { $Row.Note = 'kept (Days -1)'; continue }
                    if ($Type -notin 'LogEntries', 'Files', 'KeepCount') { throw "unknown Type '$Type'" }
                    $Pattern = Join-Path -Path $Root -ChildPath "$($T.Path)"
                    $Files = @(Get-ChildItem -Path $Pattern -File -Force -Recurse:([bool]$T.Recurse) -ErrorAction SilentlyContinue)
                    $Cutoff = (Get-Date).AddDays(-$Days)
                    $Refused = @()

                    if ($Type -eq 'KeepCount') {
                        $Keep = if ("$($T.Keep)" -match '^\d+$') { [int]$T.Keep } else { 10 }
                        $Row.Days = ''
                        $Doomed = @($Files | Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep)
                    }
                    elseif ($Type -eq 'Files') { $Doomed = @($Files | Where-Object { $_.LastWriteTime -lt $Cutoff }) }
                    else { $Doomed = @() }

                    foreach ($F in $Doomed) {
                        $Why = Test-Allowed -File $F.FullName -Type $Type
                        if ($Why) { $Refused += "$($F.Name): $Why"; continue }
                        if ($PSCmdlet.ShouldProcess($F.FullName, 'Delete')) { Remove-Item -LiteralPath $F.FullName -Force }
                        $Row.Removed++; $Row.FreedKB += [math]::Round($F.Length / 1KB, 1)
                    }

                    if ($Type -eq 'LogEntries') {
                        foreach ($F in $Files) {
                            $Why = Test-Allowed -File $F.FullName -Type $Type
                            if ($Why) { $Refused += "$($F.Name): $Why"; continue }
                            $SizeBefore = $F.Length
                            $Text = [System.IO.File]::ReadAllText($F.FullName, [System.Text.Encoding]::Default)
                            $Lines = $Text.TrimEnd("`r", "`n") -split "\r?\n"
                            $Keep = New-Object System.Collections.Generic.List[string]
                            $Drop = 0; $Current = $true
                            foreach ($L in $Lines) {
                                $M = $LineRx.Match($L)
                                if ($M.Success) {
                                    $When = [datetime]::ParseExact($M.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
                                    $Current = $When -ge $Cutoff
                                    if (-not $Current) { $Drop++ }
                                }
                                # header, blank and continuation lines follow the entry above them (the header is first)
                                if ($Current) { $Keep.Add($L) }
                            }
                            if (-not $Drop) { continue }
                            if ($PSCmdlet.ShouldProcess($F.FullName, "Remove $Drop entr$(if ($Drop -eq 1) { 'y' } else { 'ies' }) older than $Days days")) {
                                $New = ($Keep -join "`r`n") + "`r`n"
                                $Tmp = '{0}.{1}.tmp' -f $F.FullName, [guid]::NewGuid().ToString('N').Substring(0, 8)
                                [System.IO.File]::WriteAllText($Tmp, $New, [System.Text.Encoding]::Default)
                                Move-Item -LiteralPath $Tmp -Destination $F.FullName -Force
                                $Row.FreedKB += [math]::Round(($SizeBefore - [System.Text.Encoding]::Default.GetByteCount($New)) / 1KB, 1)
                            }
                            $Row.Trimmed += $Drop
                        }
                    }
                    if ($Refused) { $Row.Note = "refused: $(($Refused | Select-Object -First 3) -join '; ')$(if ($Refused.Count -gt 3) { " (+$($Refused.Count - 3) more)" })" }
                }
                catch { $Row.Note = "failed: $($_.Exception.Message)"; $Result.Failed++ }
                finally {
                    $Rows.Add([pscustomobject]$Row)
                    $Result.Removed += $Row.Removed; $Result.Trimmed += $Row.Trimmed; $Result.FreedKB += $Row.FreedKB
                }
            }
        }

        #region The device's cleanup list (Cleanup.json): items whose time has come
        $ListPath = Get-ScriptsCleanupListPath -Root $Root
        if (Test-Path -LiteralPath $ListPath) {
            $List = Read-ScriptsCleanupList -Path $ListPath
            $Changed = $false
            $Now = Get-Date
            # A copy to walk while items are removed (ToArray: 5.1 fails on @() around this list)
            $Pending = $List.Items.ToArray()
            foreach ($I in $Pending) {
                $Row = [ordered]@{ Owner = 'Cleanup.json'; Type = "$($I.Type)"; Path = "$($I.Path)"; Days = $I.Days; Removed = 0; Trimmed = 0; FreedKB = 0; Note = '' }
                $Due = [datetime]::MinValue
                if (-not "$($I.Due)" -or -not [datetime]::TryParse("$($I.Due)", [ref]$Due)) { $Row.Note = 'kept (Days -1)'; $Rows.Add([pscustomobject]$Row); continue }
                if ($Due -gt $Now) { $Row.Note = "due $($Due.ToString('yyyy-MM-dd'))"; $Rows.Add([pscustomobject]$Row); continue }
                $Why = Test-ScriptsCleanupItem -Type "$($I.Type)" -Path "$($I.Path)" -Root $Root
                $Done = $null
                try {
                    if ($Why) { throw "refused: $Why" }
                    if ("$($I.Type)" -eq 'Task') {
                        # schtasks.exe, not the ScheduledTasks cmdlets: those fail on some servers ("The request was aborted")
                        # Run through cmd.exe so schtasks' error text never reaches PowerShell as an
                        # error record (5.1 turns it into a terminating error under 'Stop')
                        $Tn = "$($I.Path)" -replace '"', ''
                        & cmd.exe /c "schtasks.exe /Query /TN `"$Tn`" >nul 2>&1"
                        if ($LASTEXITCODE -ne 0) { $Done = 'already gone' }
                        elseif ($PSCmdlet.ShouldProcess($Tn, 'Delete scheduled task')) {
                            $Out = & cmd.exe /c "schtasks.exe /Delete /TN `"$Tn`" /F 2>&1"
                            if ($LASTEXITCODE -ne 0) { throw "schtasks /Delete: $($Out -join ' ')" }
                            $Done = 'deleted'
                        }
                    }
                    elseif (-not (Test-Path -LiteralPath "$($I.Path)")) { $Done = 'already gone' }
                    else {
                        $Size = (Get-ChildItem -LiteralPath "$($I.Path)" -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
                        if ($PSCmdlet.ShouldProcess("$($I.Path)", "Delete $("$($I.Type)".ToLower())")) {
                            Remove-Item -LiteralPath "$($I.Path)" -Recurse -Force -ErrorAction Stop
                            $Done = 'deleted'
                        }
                        $Row.Removed = 1; $Row.FreedKB = [math]::Round([double]$Size / 1KB, 1)
                    }
                    $Row.Note = if ($Done) { $Done } else { 'would be deleted (WhatIf)' }
                }
                catch {
                    $Row.Note = "failed: $($_.Exception.Message)"; $Result.Failed++
                    if (-not $WhatIfPreference) { $I | Add-Member -NotePropertyName LastError -NotePropertyValue "$((Get-Date).ToString('s')) $($_.Exception.Message)" -Force; $Changed = $true }
                }
                if ($Done -and -not $WhatIfPreference) {
                    [void]$List.Items.Remove($I)
                    $List.Done.Add([pscustomobject][ordered]@{ Type = "$($I.Type)"; Path = "$($I.Path)"; Result = $Done; Time = $Now.ToString('s'); Reason = "$($I.Reason)"; By = "$($I.By)" })
                    $Changed = $true
                }
                $Rows.Add([pscustomobject]$Row)
                $Result.Removed += $Row.Removed; $Result.FreedKB += $Row.FreedKB
            }
            if ($Changed) { Save-ScriptsCleanupList -Path $ListPath -List $List }
            $Result.ListPending = $List.Items.Count
        }
        #endregion
    }
    catch {
        $Result.Failed++
        $Rows.Add([pscustomobject]@{ Owner = 'Scripts'; Type = ''; Path = ''; Days = ''; Removed = 0; Trimmed = 0; FreedKB = 0; Note = "failed: $($_.Exception.Message)" })
    }
    $Result.FreedKB = [math]::Round($Result.FreedKB, 1)
    $Result.Targets = $Rows.ToArray()
    if (-not $WhatIfPreference -and ($Result.Removed -or $Result.Trimmed -or $Result.Failed) -and (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue)) {
        $Msg = 'Cleanup: {0} file(s)/item(s) removed, {1} log entr(ies) trimmed, {2} KB freed, {3} failed; {4} item(s) waiting on the cleanup list.' -f $Result.Removed, $Result.Trimmed, $Result.FreedKB, $Result.Failed, $Result.ListPending
    $Listed = @($Result.Targets | Where-Object { $_.Owner -eq 'Cleanup.json' -and "$($_.Note)" -in 'deleted', 'already gone' })
    if ($Listed) { $Msg += ' From the list: ' + (($Listed | ForEach-Object { "$($_.Type) $($_.Path) ($($_.Note))" }) -join '; ') + '.' }
        try { Write-AdvancedLog -Message $Msg -ScriptName 'Invoke-ScriptsCleanup.ps1' -LogFileName 'Invoke-ScriptsCleanup' -LogType $(if ($Result.Failed) { 'WARNING' } else { 'INFO' }) } catch { }
    }
    [pscustomobject]$Result
}

# Example usage:
# PS> . C:\SCRIPTS\Functions\Invoke-ScriptsCleanup.ps1
# PS> (Invoke-ScriptsCleanup -WhatIf).Targets | Format-Table -AutoSize
# PS> Invoke-ScriptsCleanup -Root C:\Temp\ScriptsCopy -Verbose


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDV4jgl8yfQD67I
# zJG6EiSW3Ubd5Z8Ht5qLv9PQJ9u7G6CCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEINOm5w8x
# bAY4kZ0RRp1WPPAmUeeyhz29dhlgWjmxStYHMA0GCSqGSIb3DQEBAQUABIIBAA/l
# PYBqgiHgt3fi08+l6isvPTxnQY3Tbef0tkeyKWNvyXXBOgl6VJUigbWCk+aW6Y47
# T8Za90AgDuNE+T5B+IhJFvvs+V2riw63f+YaKLgQ1eQDffb5j+6rS13DX1npiKLp
# 3fhsGfMCGMWPWHCIYsP/6kFLleLb4dHAayV24Il/twvIiej5ovhT4+NtsbGiWSVK
# 4Y3RpQqbM1xTpUNFOrPm+KeJUM8XuOag0LLZanasflWsFrehmGC8c+mxF/yKmeH/
# bGQUHVR+cxVA06+r/9q0raF+NFkwxGFBAeCXun4WmAJeOIZ9H7nr0/gi40+A+OOB
# b4u59mSDf4munCJHCSahggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDIyMTk1
# NDE4WjAvBgkqhkiG9w0BCQQxIgQgy8qfaxDWr3z8Zyzl/8weJ49YR21tL7ABJvml
# O72J5KEwDQYJKoZIhvcNAQEBBQAEggIAgHZWnKFI2LpD6D18TUx6/lzsMh0/gxVi
# ob+54lJNLrUYvL1UlaA9NYiIARJCiK0H/hFsy+kcjyw+WCp6p8rpmHIKIcqGc5Jq
# dp/SOGk2D471hwiZAk0C8HOfTT5Fuv+Q7ldVLz5S6qX7hje+HjKCP/yNF4BZVOFH
# eC3rqPLOqPbSFgHq499wAysTKijuUjX3L1QP3AM5UCWx6jQJ58CZV2ff36+GuCnb
# Zv7uBl0Ph7plsRwDJbL91RA2SCQ1rYOR4mTZCfnwV7i7B0gMknWaWqvf8wP0GRFf
# QOh6lySlomv8f1QC3JkMkrVed1sxSBVLY9G2xgyx/Co2EsLWJ3uqwmuteAj5/2GF
# x6Go6DQd4yU/5+YazdIFwyrhbdUVvCWQmkNZveAgXGhOEsyvNxUVikmVDi5pd+1M
# b+gzHToP3yV0Y41zTXJHVVun/l0AGHYZTaNhB3OftQnLMhq7wdX//dwLGHfJhCZN
# kzQ/vnCI+E5W1cdG2b7cQFBiIwaTEqmwHibVgcYskia37G49ReXTJIPiP7G4NImR
# 6+/hpPt5MVfLvzZSov9QjwiIqqqUuIoUdNTcqion2PENawbV3BlxlqO3vRNlItLw
# 3JFNilfw2wWLDc1tdAAQzKNS0wW5JJPbG+IfcP37h2MvgZeqmLVHSAZcuf8yzx5u
# YF1o07ogE9E=
# SIG # End signature block
