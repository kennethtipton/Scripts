<#
.SYNOPSIS
    Pulls this device's scripts from the DFS scripts share, so it never runs an out of date copy.
.DESCRIPTION
    Part of Powershell Scripts Management (PSM): the Frontend, installed on every device that runs
    these scripts. Runs as the scheduled task \PSM\SyncScriptsFromDfs (SYSTEM, every
    SyncIntervalMinutes; Install-FrontendScriptsSync.ps1 creates it). The source is the first
    enabled transport (Transports in C:\SCRIPTS\Data\Settings\Scripts.json, read with
    Get-ScriptsTransport); the workstation publishes to it. This version moves files over the Dfs
    transport only; Sftp and Ftp come later.

    What is pulled:
      $SL  C:\SCRIPTS              only checked: must be reachable here and on DFS (no files pulled)
      $SF  C:\SCRIPTS\Functions    always; except the setup-only tools listed under Exclude in
                                   Base.json (Copy-FilesToServer, Set-ScriptSignature, ...)
      $SD  C:\SCRIPTS\Data         always, with subfolders
      $SM  C:\SCRIPTS\Modules      always, with subfolders
      Applications                 only those this device uses: every application with an inventory
                                   record update.<DEVICE>.<App>.json, here (C:\SCRIPTS\Applications\Data)
                                   or in the DFS drop folder. The files are the ones listed in the
                                   application's manifest (and the manifests it DependsOn), read from
                                   DfsRoot\Installs\Data. The Installs folder itself is never pulled.

    Rules (the same as Copy-FilesToServer):
      - Files are compared by SHA256; a file is copied when missing here or different, else left alone.
      - Never downgrade: when an application's settings file (AppData in its manifest) has a higher
        Version here than on DFS, it is a test copy pushed with SetupApplications. That manifest's
        files are held (logged, and Held in the inventory record) until the version is published.
        Each manifest of a DependsOn chain is checked on its own. The shared files (Functions, Data,
        Modules) are held the same way when Data\Settings\Scripts.json (the Shared version) is newer
        here than on DFS.
      - Scripts (.ps1/.psm1/.psd1) are copied only when their signature on DFS is Valid. This task runs
        as SYSTEM, so an unsigned or altered script on the share is never pulled.
      - Nothing outside C:\SCRIPTS is written, and nothing is deleted.
      - Each file is written under a temporary name and renamed, so a script is never half copied.

    After that it creates the local settings stubs (Applications\Data\Settings\<Name>.json, for Scripts
    and each installed application; never replaced), runs Invoke-ScriptsCleanup (old log entries and
    files, per Cleanup in the settings) and, last, Write-DeviceRecord.ps1 (next to this script) writes
    device.<DEVICE>.json (the server, the result of this run and of the cleanup, the PSM apps and
    anything unmanaged on disk) to the inventory drop folder.

    Then Send-LogsToDfs.ps1 (next to this script) sends the new lines of C:\SCRIPTS\Logs\*.log to
    DFS\Logs\Updates\<DEVICE>, where the Backend merges them (LogShipping in Scripts.json).

    Afterwards each application's inventory record gets a Synced entry (version, files updated,
    failures), which Update-InventoryIndex.ps1 merges into Inventory.json. A run that changes
    nothing writes only the inventory entry (the device's heartbeat), not the text log.

    The computer account (DOMAIN\DEVICE$) needs read access to DfsRoot, including each application
    folder it uses (the FLD-SCRIPTS.<App>.REVIEWERS groups), and Editors rights on the drop folder.
.PARAMETER SettingsPath
    Settings file. Defaults to C:\SCRIPTS\Data\Settings\Scripts.json.
.PARAMETER DfsRoot
    Pull from this folder instead of the Dfs transport's Root in the settings (for testing).
.PARAMETER LocalRoot
    Write to this folder instead of C:\SCRIPTS (for testing). Destinations in the manifests are
    moved from C:\SCRIPTS to it.
.PARAMETER NoInventory
    Do not write Synced entries to the inventory.
.PARAMETER LogFileName
    Base name of the text log file in C:\SCRIPTS\Logs.
.EXAMPLE
    PS> C:\SCRIPTS\Applications\PSM\FrontendScriptsSync\Sync-ScriptsFromDfs.ps1 -WhatIf
.EXAMPLE
    PS> C:\SCRIPTS\Applications\PSM\FrontendScriptsSync\Sync-ScriptsFromDfs.ps1 -Verbose
.INPUTS
    None
.OUTPUTS
    [pscustomobject] one row per file that was or would be changed or skipped: Area, Item, Action.
    Exit code 0 on success, 1 when anything failed or was refused.
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-15
    Time: 10:00:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 1.6.1
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: Claude

    Copyright (c) 2026
    Licensed under the MIT License.
    Full text available at: https://opensource.org/licenses/MIT

    Overide Variables
    Overide Filename:
    Overide Log Filename: Sync-ScriptsFromDfs
    Overide Text Log File Path:
    Overide Log Type:
.LINK
    https://www.tnandc.com
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SettingsPath,

    [string]$DfsRoot,

    [string]$LocalRoot,

    [switch]$NoInventory,

    [string]$LogFileName = 'Sync-ScriptsFromDfs'
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'Sync-ScriptsFromDfs.ps1'

#region Standard locations
$SCA = $PSScriptRoot                           # C:\SCRIPTS\Applications\PSM\FrontendScriptsSync
$SA  = $SCA
while ($SA -and (Split-Path -Path $SA -Leaf) -ne 'Applications') { $SA = Split-Path -Path $SA -Parent }
if (-not $SA) { throw "$SCA is not inside an 'Applications' folder." }
$SL  = Split-Path -Path $SA -Parent            # C:\SCRIPTS
$SF  = Join-Path -Path $SL -ChildPath 'Functions'
if (-not $SettingsPath) { $SettingsPath = Join-Path -Path $SL -ChildPath 'Data\Settings\Scripts.json' }
if (-not $LocalRoot) { $LocalRoot = $SL }
$LocalRoot = $LocalRoot.TrimEnd('\')
#endregion

foreach ($F in 'Write-AdvancedLog.ps1', 'Get-ApplicationSettings.ps1', 'Get-ScriptsTransport.ps1', 'Update-ApplicationInventory.ps1') {
    $P = Join-Path -Path $SF -ChildPath $F
    if (Test-Path -Path $P) { . $P }
}
function Write-SyncLog {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO', 'WARNING', 'ERROR')][string]$LogType = 'INFO')
    switch ($LogType) {
        'WARNING' { Write-Warning $Message }
        'ERROR'   { Write-Host $Message -ForegroundColor Red }
        default   { Write-Verbose $Message }
    }
    # -WhatIf only previews; nothing is logged.
    if (-not $WhatIfPreference -and (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue)) {
        $LogArgs = @{ Message = $Message; ScriptName = $ScriptName; LogFileName = $LogFileName; LogType = $LogType }
        if ($LogType -ne 'INFO') { $LogArgs.WriteEventLog = $true }
        try { Write-AdvancedLog @LogArgs } catch { Write-Warning "Write-AdvancedLog failed: $($_.Exception.Message)" }
    }
}

# C:\SCRIPTS\x (as written in a manifest) -> the same path under another root
function ConvertTo-RootPath {
    param([string]$Path, [string]$Root)
    $Std = 'C:\SCRIPTS'
    if (-not $Path.StartsWith($Std, [System.StringComparison]::OrdinalIgnoreCase)) { throw "'$Path' is not under $Std." }
    $Root.TrimEnd('\') + $Path.Substring($Std.Length)
}

# True when $Path is $Root or inside it (after resolving .. segments)
function Test-UnderRoot {
    param([string]$Path, [string]$Root)
    $Full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $R = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $Full.Equals($R, [System.StringComparison]::OrdinalIgnoreCase) -or $Full.StartsWith("$R\", [System.StringComparison]::OrdinalIgnoreCase)
}

$ExitCode = 0
$Rows = New-Object System.Collections.Generic.List[object]

try {
    #region Settings and SL check
    $Cfg = if (Get-Command -Name Get-ApplicationSettings -ErrorAction SilentlyContinue) { Get-ApplicationSettings -Path $SettingsPath } else { Get-Content -Path $SettingsPath -Raw | ConvertFrom-Json }
    if (-not $DfsRoot) {
        # Enabled transports in priority order; this version moves files over DFS only
        $Transports = @(Get-ScriptsTransport -Settings $Cfg)
        if (-not $Transports) {
            Write-Verbose "No transport is enabled in ${SettingsPath}: this device reports locally only, nothing to sync."
            exit 0
        }
        $Dfs = $Transports | Where-Object { $_.Type -eq 'Dfs' } | Select-Object -First 1
        if (-not $Dfs) {
            Write-SyncLog "Enabled transport(s) $(($Transports | ForEach-Object { $_.Name }) -join ', ') are not supported by this version yet (DFS only); nothing synced." -LogType WARNING
            exit 1
        }
        $DfsRoot = $Dfs.Root
    }
    $DfsRoot = $DfsRoot.TrimEnd('\')
    if (-not (Test-Path -Path $LocalRoot -PathType Container)) { throw "Local root $LocalRoot not found." }
    if (-not (Test-Path -Path $DfsRoot -PathType Container)) { throw "DFS root $DfsRoot not reachable as $env:USERDOMAIN\$env:USERNAME." }
    $InstallsDfs = Join-Path -Path $DfsRoot -ChildPath 'Installs\Data'
    if (-not (Test-Path -Path $InstallsDfs -PathType Container)) { throw "$InstallsDfs not found: the manifests have not been published to DFS." }
    $Device = $env:COMPUTERNAME.ToUpper()
    #endregion

    #region Manifests (read from DFS, never copied here)
    function Get-DfsManifestChain {
        param([string]$Name, [string[]]$Seen = @())
        if ($Seen -contains $Name) { throw "Circular DependsOn: $($Seen -join ' -> ') -> $Name" }
        $Path = Join-Path -Path $InstallsDfs -ChildPath "$Name.json"
        if (-not (Test-Path -Path $Path -PathType Leaf)) { throw "Manifest $Path not found." }
        $M = Get-Content -Path $Path -Raw | ConvertFrom-Json
        foreach ($Dep in @($M.DependsOn | Where-Object { $_ })) { Get-DfsManifestChain -Name "$Dep" -Seen ($Seen + $Name) }
        $M
    }
    $Base = if (Test-Path -Path (Join-Path -Path $InstallsDfs -ChildPath 'Base.json')) { Get-DfsManifestChain -Name 'Base' } else { $null }
    # Setup-only tools: everything Base leaves out of the Functions folder
    $FunctionExcludes = @($Base.Files | Where-Object { "$($_.Source)" -like 'C:\SCRIPTS\Functions\*' } | ForEach-Object { @($_.Exclude) } | Where-Object { $_ })

    # Applications this device uses: its inventory records, here and in the DFS drop folder
    $InvFolder = if ($Cfg.InventoryFolder) { "$($Cfg.InventoryFolder)" } else { 'Applications\Data' }
    $RecordDirs = @((Join-Path -Path $LocalRoot -ChildPath 'Applications\Data'), (Join-Path -Path $DfsRoot -ChildPath $InvFolder))
    $Apps = @(foreach ($Dir in $RecordDirs) {
        Get-ChildItem -Path $Dir -Filter "update.$Device.*.json" -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name.Substring("update.$Device.".Length) -replace '\.json$', '' }
    }) | Where-Object { $_ -and $_ -ne 'Base' } | Sort-Object -Unique
    #endregion

    #region Work list: Area, Source (DFS), Destination (local)
    $Work = New-Object System.Collections.Generic.List[object]
    $Folders = New-Object System.Collections.Generic.List[string]
    function Add-Work {
        param([string]$Area, [string]$Source, [string]$Destination)
        $Work.Add([pscustomobject]@{ Area = $Area; Source = $Source; Destination = $Destination })
    }

    # Never downgrade the shared files either: Data\Settings\Scripts.json carries the Shared version
    # (Functions, Data, Modules). Newer here than on DFS = a test push of shared files from the
    # workstation; they are left alone until that version is published.
    $HoldCache = @{}
    $ReadVer = { param($P) try { "$((Get-Content -LiteralPath $P -Raw | ConvertFrom-Json).Version)" } catch { '' } }
    $SharedLocal = & $ReadVer (Join-Path -Path $LocalRoot -ChildPath 'Data\Settings\Scripts.json')
    $SharedDfs   = & $ReadVer (Join-Path -Path $DfsRoot -ChildPath 'Data\Settings\Scripts.json')
    $L = $null; $D = $null
    if ([version]::TryParse($SharedLocal, [ref]$L) -and [version]::TryParse($SharedDfs, [ref]$D) -and $L -gt $D) {
        $HoldCache['Shared'] = "local $SharedLocal is newer than DFS $SharedDfs"
        Write-SyncLog "Held Shared (Functions, Data, Modules): $($HoldCache['Shared']) (a test copy; they sync again once that version is published)."
        $Rows.Add([pscustomobject]@{ Area = 'Shared'; Item = 'Functions, Data, Modules'; Action = "Held: $($HoldCache['Shared'])" })
    }

    # SF, SD, SM: whole folders
    foreach ($Sub in 'Functions', 'Data', 'Modules') {
        if ($HoldCache['Shared']) { break }
        $Src = Join-Path -Path $DfsRoot -ChildPath $Sub
        if (-not (Test-Path -Path $Src -PathType Container)) { Write-Verbose "$Src not on DFS; skipped."; continue }
        $Folders.Add((Join-Path -Path $LocalRoot -ChildPath $Sub))
        $Recurse = $Sub -ne 'Functions'
        foreach ($F in @(Get-ChildItem -Path $Src -File -Recurse:$Recurse -Force)) {
            if ($Sub -eq 'Functions' -and ($FunctionExcludes | Where-Object { $F.Name -like $_ })) { continue }
            if ($F.Name -like '*.tmp') { continue }
            Add-Work -Area $Sub -Source $F.FullName -Destination ($LocalRoot + $F.FullName.Substring($DfsRoot.Length))
        }
    }

    # Never downgrade: a manifest whose settings file (AppData) has a higher Version here than on
    # DFS is a test copy pushed from the workstation; its files are left alone until it is published.
    function Get-ManifestHold {
        param($Manifest)
        $Name = "$($Manifest.Name)"
        if ($HoldCache.ContainsKey($Name)) { return $HoldCache[$Name] }
        $Text = ''
        if ("$($Manifest.AppData)") {
            $ReadVer = { param($P) try { "$((Get-Content -LiteralPath $P -Raw | ConvertFrom-Json).Version)" } catch { '' } }
            $LocalVer = & $ReadVer (ConvertTo-RootPath -Path "$($Manifest.AppData)" -Root $LocalRoot)
            $DfsVer   = & $ReadVer (ConvertTo-RootPath -Path "$($Manifest.AppData)" -Root $DfsRoot)
            $L = $null; $D = $null
            if ([version]::TryParse($LocalVer, [ref]$L) -and [version]::TryParse($DfsVer, [ref]$D) -and $L -gt $D) {
                $Text = "local $LocalVer is newer than DFS $DfsVer"
                Write-SyncLog "Held ${Name}: $Text (a test copy; it syncs again once that version is published)."
                $Rows.Add([pscustomobject]@{ Area = $Name; Item = "$($Manifest.AppData)"; Action = "Held: $Text" })
            }
        }
        $HoldCache[$Name] = $Text
        $Text
    }

    # Applications: the manifests' files
    $AppInfo = @{}
    $ManifestCleanup = New-Object System.Collections.Generic.List[object]   # "Cleanup" items of the manifests applied
    foreach ($App in $Apps) {
        try { $Chain = @(Get-DfsManifestChain -Name $App) }
        catch {
            Write-SyncLog "Application $App (inventory record found) has no usable manifest on DFS: $($_.Exception.Message)" -LogType WARNING
            $Rows.Add([pscustomobject]@{ Area = $App; Item = "$App.json"; Action = "Failed: $($_.Exception.Message)" })
            $ExitCode = 1
            continue
        }
        $Top = $Chain[-1]
        $AppInfo[$App] = [pscustomobject]@{ AppData = "$($Top.AppData)"; Manifests = @($Chain | ForEach-Object { "$($_.Name)" }) }
        foreach ($M in $Chain) {
            if (Get-ManifestHold -Manifest $M) { continue }
            foreach ($CI in @($M.Cleanup | Where-Object { $_ -and "$($_.Path)" })) { $ManifestCleanup.Add([pscustomobject]@{ Manifest = "$($M.Name)"; Item = $CI }) }
            foreach ($Folder in @($M.Folders | Where-Object { $_ })) { $Folders.Add((ConvertTo-RootPath -Path "$Folder" -Root $LocalRoot)) }
            foreach ($F in @($M.Files | Where-Object { $_ })) {
                $Src = ConvertTo-RootPath -Path "$($F.Source)" -Root $DfsRoot
                $Dst = if ($F.Destination) { ConvertTo-RootPath -Path "$($F.Destination)" -Root $LocalRoot } else { ConvertTo-RootPath -Path "$($F.Source)" -Root $LocalRoot }
                if ($Src -match '[\*\?]') {
                    $Exclude = @($F.Exclude | Where-Object { $_ })
                    foreach ($Hit in @(Get-ChildItem -Path $Src -File -ErrorAction SilentlyContinue)) {
                        if ($Exclude | Where-Object { $Hit.Name -like $_ }) { continue }
                        Add-Work -Area $App -Source $Hit.FullName -Destination (Join-Path -Path $Dst -ChildPath $Hit.Name)
                    }
                }
                else { Add-Work -Area $App -Source $Src -Destination $Dst }
            }
        }
    }
    #endregion

    #region Copy
    foreach ($Folder in @($Folders | Sort-Object -Unique)) {
        if (-not (Test-UnderRoot -Path $Folder -Root $LocalRoot)) { throw "Manifest folder $Folder is outside $LocalRoot." }
        if (Test-Path -Path $Folder -PathType Container) { continue }
        if ($PSCmdlet.ShouldProcess($Folder, 'Create folder')) {
            New-Item -ItemType Directory -Path $Folder -Force | Out-Null
            Write-SyncLog "Created $Folder."
        }
    }

    $Counts = @{}
    $Seen = @{}
    foreach ($W in $Work) {
        if ($Seen.ContainsKey($W.Destination)) { continue }
        $Seen[$W.Destination] = $true
        if (-not $Counts.ContainsKey($W.Area)) { $Counts[$W.Area] = [pscustomobject]@{ Files = 0; Updated = 0; Failed = 0 } }
        $C = $Counts[$W.Area]
        $C.Files++

        $Problem = ''
        if (-not (Test-UnderRoot -Path $W.Destination -Root $LocalRoot)) { $Problem = "destination outside $LocalRoot" }
        elseif (-not (Test-UnderRoot -Path $W.Source -Root $DfsRoot)) { $Problem = "source outside $DfsRoot" }
        elseif (-not (Test-Path -LiteralPath $W.Source -PathType Leaf)) { $Problem = 'not found on DFS' }
        elseif ([System.IO.Path]::GetExtension($W.Source) -in '.ps1', '.psm1', '.psd1') {
            $Sig = (Get-AuthenticodeSignature -LiteralPath $W.Source).Status
            if ("$Sig" -ne 'Valid') { $Problem = "signature $Sig on DFS" }
        }
        if ($Problem) {
            $C.Failed++
            $ExitCode = 1
            Write-SyncLog "Not pulled $($W.Source): $Problem." -LogType WARNING
            $Rows.Add([pscustomobject]@{ Area = $W.Area; Item = $W.Destination; Action = "Refused: $Problem" })
            continue
        }

        $Exists = Test-Path -LiteralPath $W.Destination -PathType Leaf
        if ($Exists -and (Get-FileHash -LiteralPath $W.Destination).Hash -eq (Get-FileHash -LiteralPath $W.Source).Hash) { continue }

        $Verb = if ($Exists) { 'Updated' } else { 'Copied' }
        if (-not $PSCmdlet.ShouldProcess($W.Destination, $(if ($Exists) { 'Replace file (contents differ)' } else { 'Copy new file' }))) {
            $Rows.Add([pscustomobject]@{ Area = $W.Area; Item = $W.Destination; Action = "Would be $($Verb.ToLower()) (WhatIf)" })
            continue
        }
        $Tmp = $null
        try {
            $Dir = Split-Path -Path $W.Destination -Parent
            if (-not (Test-Path -Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
            $Tmp = '{0}.{1}.tmp' -f $W.Destination, [guid]::NewGuid().ToString('N').Substring(0, 8)
            Copy-Item -LiteralPath $W.Source -Destination $Tmp -Force
            Move-Item -LiteralPath $Tmp -Destination $W.Destination -Force
            $C.Updated++
            Write-SyncLog "$($Verb.ToLower()) $($W.Destination)."
            $Rows.Add([pscustomobject]@{ Area = $W.Area; Item = $W.Destination; Action = $Verb })
        }
        catch {
            if ($Tmp -and (Test-Path -LiteralPath $Tmp)) { Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue }
            $C.Failed++
            $ExitCode = 1
            Write-SyncLog "Could not pull $($W.Source): $($_.Exception.Message)" -LogType ERROR
            $Rows.Add([pscustomobject]@{ Area = $W.Area; Item = $W.Destination; Action = "Failed: $($_.Exception.Message)" })
        }
    }
    #endregion

    #region Summary and inventory
    $Updated = ($Counts.Values | Measure-Object -Property Updated -Sum).Sum
    $Failed  = ($Counts.Values | Measure-Object -Property Failed -Sum).Sum
    $Summary = "Sync from $DfsRoot : $(@($Seen.Keys).Count) files checked, $([int]$Updated) updated, $([int]$Failed) failed. Applications: $(if ($Apps) { $Apps -join ', ' } else { 'none enrolled' })."
    if ($Updated -or $Failed) { Write-SyncLog $Summary -LogType $(if ($Failed) { 'WARNING' } else { 'INFO' }) } else { Write-Verbose $Summary }

    if (-not $NoInventory -and -not $WhatIfPreference -and (Get-Command -Name Update-ApplicationInventory -ErrorAction SilentlyContinue)) {
        foreach ($App in $Apps) {
            if (-not $AppInfo.ContainsKey($App)) { continue }
            $Info = $AppInfo[$App]
            $AppVer = ''
            if ($Info.AppData) {
                try { $AppVer = "$((Get-Content -Path (ConvertTo-RootPath -Path $Info.AppData -Root $LocalRoot) -Raw | ConvertFrom-Json).Version)" } catch { }
            }
            $Areas = @($Counts.Keys | Where-Object { $_ -eq $App -or $_ -in 'Functions', 'Data', 'Modules' })
            $U = [int](($Areas | ForEach-Object { $Counts[$_].Updated } | Measure-Object -Sum).Sum)
            $X = [int](($Areas | ForEach-Object { $Counts[$_].Failed } | Measure-Object -Sum).Sum)
            $Res = if ($X) { 'Failed' } else { 'OK' }
            $Details = @{ Updated = $U; Failed = $X; Source = $DfsRoot; Manifests = ($Info.Manifests -join ' -> ') }
            $Held = @($Info.Manifests | Where-Object { $HoldCache[$_] } | ForEach-Object { "$_ ($($HoldCache[$_]))" })
            if ($Held) { $Details.Held = $Held -join '; ' }
            Update-ApplicationInventory -Application $App -Action Synced -Version $AppVer -Result $Res `
                -SettingsPath $SettingsPath -Details $Details | Out-Null
        }
    }
    #endregion
}
catch {
    $ExitCode = 1
    Write-SyncLog "Sync failed: $($_.Exception.Message)" -LogType ERROR
}

# Log shipping: send this device's new log lines to DFS (Send-LogsToDfs.ps1). Only for the real
# C:\SCRIPTS (not a -LocalRoot test) and never with -WhatIf; it does not change the exit code.
if (-not $WhatIfPreference -and $LocalRoot -eq $SL) {
    $Ship = Join-Path -Path $SCA -ChildPath 'Send-LogsToDfs.ps1'
    if (Test-Path -Path $Ship) {
        try {
            $ShipArgs = @{ SettingsPath = $SettingsPath }
            if ($DfsRoot) { $ShipArgs.DfsRoot = $DfsRoot }
            $Shipped = & $Ship @ShipArgs
            Write-Verbose "Log shipping: $($Shipped.Records) record(s) in $($Shipped.Sent) file(s), $($Shipped.Failed) failed."
        }
        catch { Write-SyncLog "Log shipping failed: $($_.Exception.Message)" -LogType WARNING }
    }

    # Local override stubs (Applications\Data\Settings\<Name>.json) for Scripts and every installed
    # application, so each server has an obvious place for its own values. Created once, never replaced.
    $LocalSettings = Join-Path -Path $SL -ChildPath 'Applications\Data\Settings'
    $StubNames = @('Scripts') + @(if ($AppInfo) { $AppInfo.Values | Where-Object { $_.AppData } | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.AppData) } })
    foreach ($N in @($StubNames | Select-Object -Unique)) {
        $Stub = Join-Path -Path $LocalSettings -ChildPath "$N.json"
        if (Test-Path -Path $Stub) { continue }
        try {
            if (-not (Test-Path $LocalSettings)) { New-Item -ItemType Directory -Path $LocalSettings -Force | Out-Null }
            $StubText = [ordered]@{
                Name  = $N
                Notes = "Local settings of $env:COMPUTERNAME for $N. Add only the values that differ from the published settings, e.g. { `"Cleanup`": { `"Days`": 30 } } (-1 = never clean). Objects merge key by key. This file is never published and never replaced by the sync."
            } | ConvertTo-Json
            [System.IO.File]::WriteAllText($Stub, $StubText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch { Write-SyncLog "Could not create $Stub : $($_.Exception.Message)" -LogType WARNING }
    }

    # Cleanup (Invoke-ScriptsCleanup in Functions): old log entries and files, per the settings, and
    # the device's cleanup list. Manifests can add to that list ("Cleanup": [ { "Path", "Type",
    # "Days", "Reason" } ], e.g. a script the application renamed); an item already listed stays as it is.
    $Cleaned = $null
    $CleanFn = Join-Path -Path $SF -ChildPath 'Invoke-ScriptsCleanup.ps1'
    if (Test-Path -Path $CleanFn) {
        try {
            . $CleanFn
            foreach ($MC in $ManifestCleanup.ToArray()) {          # ToArray: 5.1 fails on @() around this list
                $I = $MC.Item
                $P = "$($I.Path)"
                if ($P -notmatch '^[A-Za-z]:\\|^\\') { $P = Join-Path -Path $SL -ChildPath $P }          # relative to C:\SCRIPTS
                elseif ($P -like 'C:\SCRIPTS\*') { $P = ConvertTo-RootPath -Path $P -Root $SL }
                $AddArgs = @{ Root = $SL; Path = $P; Reason = $(if ("$($I.Reason)") { "$($I.Reason)" } else { "listed in manifest $($MC.Manifest)" }); By = "manifest $($MC.Manifest)" }
                if ("$($I.Type)") { $AddArgs.Type = "$($I.Type)" }
                if ("$($I.Days)" -match '^-?\d+$') { $AddArgs.Days = [int]$I.Days } else { $AddArgs.Days = 0 }
                try { [void](Add-ScriptsCleanupItem @AddArgs) }
                catch { Write-SyncLog "Manifest $($MC.Manifest) cleanup item not added: $($_.Exception.Message)" -LogType WARNING }
            }
            $Cleaned = Invoke-ScriptsCleanup -Root $SL -SettingsPath $SettingsPath
        }
        catch { Write-SyncLog "Cleanup failed: $($_.Exception.Message)" -LogType WARNING }
    }

    # Device record (Write-DeviceRecord.ps1): this server, its PSM state and what is on disk, for
    # the inventory and the web/API. Does not change the exit code.
    $RecordScript = Join-Path -Path $SCA -ChildPath 'Write-DeviceRecord.ps1'
    if (Test-Path -Path $RecordScript) {
        try {
            $SyncResult = @{
                ExitCode = $ExitCode
                Checked  = if ($Seen) { @($Seen.Keys).Count } else { 0 }
                Updated  = [int]$Updated
                Failed   = [int]$Failed
                Held     = @(if ($HoldCache) { $HoldCache.Keys | Where-Object { $HoldCache[$_] } | ForEach-Object { "$_ ($($HoldCache[$_]))" } })
            }
            $RecArgs = @{ SettingsPath = $SettingsPath; Sync = $SyncResult; Shipping = $Shipped; Cleanup = $Cleaned }
            if ($DfsRoot) { $RecArgs.DfsRoot = $DfsRoot }
            $Rec = & $RecordScript @RecArgs
            Write-Verbose "Device record: local $($Rec.LocalWritten), DFS $($Rec.DropWritten). $($Rec.Message)"
        }
        catch { Write-SyncLog "Device record failed: $($_.Exception.Message)" -LogType WARNING }
    }
}

$Rows
exit $ExitCode

# Example usage:
# PS> C:\SCRIPTS\Applications\PSM\FrontendScriptsSync\Sync-ScriptsFromDfs.ps1 -WhatIf | Format-Table -AutoSize
# PS> C:\SCRIPTS\Applications\PSM\FrontendScriptsSync\Sync-ScriptsFromDfs.ps1 -Verbose
# PS> C:\SCRIPTS\Applications\PSM\FrontendScriptsSync\Sync-ScriptsFromDfs.ps1 -LocalRoot C:\Temp\SyncTest -NoInventory -Verbose


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDLPPk6TodlkTy3
# 89wa3TBEujJ3Fxc3YfUPFhD9cQxkpqCCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEILPeveJ2
# vkRxh7vnDdAJclF8ZcYBnRhYAzxMjVijKQ5TMA0GCSqGSIb3DQEBAQUABIIBACP3
# ffGZkbnzzLlbnb7lxKy2U2IE5Irm43BopGCwv3h4dmDtQyhZXnozyKo5DKNFXvXx
# uKXGgSr52gUG2vYjIFi32v3Koo9W2Xx8FWXodDsahBkmb6lVgp8T4g2KXjfFdOlB
# X73asVpR1CzLR42ECkwGyybuSkHevCMqIDTYTeTmqTJZMIS8PlSoWsgSkIjMCYPK
# PMmH5A+INvlZgJA9a1NIhSF6KVU+AzskswM+GzPTs3QaH1Je5htGgDAsG/GcSZwN
# iId/d6Y4CyccYEzCp0yIzPowICwjXmJ7ndGSzASoKMHY2BbedqKDVo37KpcIrTc1
# qZvYrGu45K1OfS+aXbWhggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDIzMTM1
# NDE1WjAvBgkqhkiG9w0BCQQxIgQg/zmZ1UQ8FVGJIG46MVS8MaLT3a7j1sBQ4t2w
# gvU9gEIwDQYJKoZIhvcNAQEBBQAEggIAQ2r2u8iRCT6QxjuMQ2Fs7t7e3WriabsS
# 2k1UOuB/gblmVICErGnZTI9zByuScNtLxBTqTpaS1neuY7jukNjNZhhEF5u6sDPx
# NvAugcD4yATMbRxs+YLBG5aT8DSU2tELmiPItxc8dxpe/g2v0mCgSq1M5qHzHG46
# vh9jE1PygrzVNIiOz0V3XxZr6U+cl4yuAVQmUoR2kdjtIPU4svenB/A0Y6o2gHwJ
# DlypYpiiRgMuoW8KkDd2+s1+OPqsMs1aLz98NJWIcHWhxpSbxGjYvZpzV6GQY2Vb
# F5nS3QsqT10GQc+4rkkDqu0KckYcjdPd6PrOsgurxbZoXQA4uZviRi6tyCNvGKCf
# FqZV7wUcTNBzM9k6W95XvclE/FRuuoKTUOOUBSIyZIOalamL4qHzqw3arzDx/rRs
# AyZ0b0rzTbKZ/KCmtf+8DnhUJtLoDkInNO9uXq4nMi10kHygWSrnWMujLfDZeIjw
# 8e9qgbUSMZdfnVTRiXMqqT14WLkCTlrzWPWb8e2g3Tls+5JPiDgpfpVWFdPwsJtj
# YyaHei/NJzZBIVj0f+/NBce09cT29qjiw098tdKHu32/dvYhigpGGleXl9kjsXeb
# taPxa/HeXbpBNhEaxMuDB5/uFhyAXbYouoCPpX4QQBkerxffyeH1MlDNreB0NfCG
# gXfbvv8asNg=
# SIG # End signature block
