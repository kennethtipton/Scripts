#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Posh-ACME and Posh-ACME.Deploy and moves the server's Posh-ACME data into the shared Certs folder.
.DESCRIPTION
    Core install, the same on every server that gets Let's Encrypt certificates. Run it before
    the install script of any server role (ExchangeServer\Install-ExchangeLE.ps1, and later
    RDS or IIS), as the account in RunAs of Data\PoshAcme.json (the task account).

    Posh-ACME has two parts in two places: the module code lives in the PowerShell modules
    folder, and the files it creates (ACME account, orders, certificates) are stored wherever
    POSHACME_HOME points. They are handled separately:

    1. Folders, permissions, POSHACME_HOME. Creates the data folder (Certs), restricts $SCA
       (and every role folder under it) to Administrators and SYSTEM, then sets the
       machine-wide and session POSHACME_HOME to Certs, before the module is installed or
       imported.
    2. Modules. Each module in Data\PoshAcme.json must be installed exactly once, the newest version
       in the PowerShell Gallery. If not, every version is uninstalled and the newest installed
       for all users. (SetupApplications.ps1 may already have done this from the workstation.)
    3. Data. Decided by whether old data exists, not by whether the module is installed:
       - Old store (Migrate.From, C:\POSHACME\certs) has data and Certs is empty (or
         -Resync): disables the old tasks first (actions containing Migrate.OldTaskPattern)
         so nothing renews into the old store, zips the whole old folder (Migrate.Archive,
         C:\POSHACME, scripts included) to $SCA\Backups, copies the store to Certs and compares
         every file (name and SHA256).
       - Certs already has data: nothing is copied. Warns if the old store has newer files
         (an old task renewed since); run again with -Resync.
       - No old data: warns that a new ACME account and order are needed.
    4. Check. From Certs: the LE_PROD account, the orders, the order for this server, and the
       saved plugin arguments (DNS credentials). Those are encrypted for the account that saved
       them, so this only passes when run as that account.
    5. Retire the old store. Only when step 4 passed and the old store has nothing newer: makes
       sure the old tasks are disabled and a backup zip exists, then renames the old folder to
       Migrate.RenameTo (C:\POSHACME.migrated). Nothing is deleted here: once the data is confirmed,
      the renamed folder and the disabled old tasks are put on the server's cleanup list
      (Migrate.CleanupDays, 30) and the backup zips too (Migrate.BackupKeepDays, 90); the Frontend
      sync's Invoke-ScriptsCleanup deletes them when due. Remove it by hand earlier after the
       first successful renewal by the new task.

    If anything fails after old tasks were disabled in this run, they are enabled again.

    Settings come from the application's own settings file, Data\PoshAcme.json next to this
    script (copied with the application): RunAs, Domain, Modules (with the Posh-ACME DataVariable
    and DataFolder) and Migrate. Data\PoshAcme.<COMPUTERNAME>.json, if present, overrides values
    for this server only (Get-ApplicationSettings). Parameters override both.

    Both Posh-ACME data layouts are recognised: older stores name the Let's Encrypt folder
    acme-v02.api.letsencrypt.org, newer ones (Posh-ACME 4.x) name it LE_PROD. Orders are found
    by their main domain, not by folder name. The deployment manifest in
    C:\SCRIPTS\Installs\Data stays on the setup machine and is not used here.

    Folder layout (paths are derived from this script's location):
      $SL   C:\SCRIPTS                                  Script Location
      $SF   C:\SCRIPTS\Functions                        shared functions (Write-AdvancedLog)
      $SG   C:\SCRIPTS\Logs                             shared logs (PoshAcme.log)
      $SA   C:\SCRIPTS\Applications                     applications
      $SCA  C:\SCRIPTS\Applications\OpenSource\PoshAcme this application (core)
            $SCA\Certs                                  Posh-ACME data (POSHACME_HOME), shared by all roles
            $SCA\Backups                                zip of the old folder taken before migration
            $SCA\ExchangeServer                         Exchange role

    Run in an elevated Windows PowerShell 5.1 session (works over OpenSSH).
.PARAMETER SettingsPath
    Settings file. Defaults to Data\PoshAcme.json next to this script.
.PARAMETER OldHome
    Old Posh-ACME data folder to migrate. Defaults to Migrate.From in the settings.
.PARAMETER OldTaskPattern
    Text in the action of old tasks to disable. Defaults to Migrate.OldTaskPattern.
.PARAMETER ArchiveFolder
    Old folder to zip and rename. Defaults to Migrate.Archive.
.PARAMETER ArchiveRenameTo
    New name for the old folder once retired. Defaults to Migrate.RenameTo.
.PARAMETER RunAs
    Account expected to run this (owns the encrypted plugin arguments). Defaults to RunAs in the settings.
.PARAMETER Domain
    Main domain of this server's order. Defaults to Domain in the settings, else this computer's FQDN.
.PARAMETER Resync
    Copy the old store again although Certs already has data (after an old task renewed).
.PARAMETER KeepOldFolder
    Do not rename the old folder in step 5.
.PARAMETER LogFileName
    Base name of the text log file in $SG.
.PARAMETER SkipModuleReinstall
    Leaves the installed modules alone.
.EXAMPLE
    PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\Install-PoshAcme.ps1
.EXAMPLE
    PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\Install-PoshAcme.ps1 -Resync
.INPUTS
    None
.OUTPUTS
    None
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-13
    Time: 12:00:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 2.4.1
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: Claude

    Copyright (c) 2026
    Licensed under the MIT License.
    Full text available at: https://opensource.org/licenses/MIT

    Overide Variables
    Overide Filename:
    Overide Log Filename: PoshAcme
    Overide Text Log File Path: C:\SCRIPTS\Logs\PoshAcme.log
    Overide Log Type:
.LINK
    https://www.tnandc.com
#>
[CmdletBinding()]
param(
    [string]$SettingsPath,
    [string]$OldHome,
    [string]$OldTaskPattern,
    [string]$ArchiveFolder,
    [string]$ArchiveRenameTo,
    [string]$RunAs,
    [string]$Domain,
    [switch]$Resync,
    [switch]$KeepOldFolder,
    [string]$LogFileName = 'PoshAcme',
    [switch]$SkipModuleReinstall
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'Install-PoshAcme.ps1'

#region Standard locations
$SCA = $PSScriptRoot                           # C:\SCRIPTS\Applications\OpenSource\PoshAcme
# $SA is the nearest parent folder named 'Applications', however deep the app is nested
$SA  = $SCA
while ($SA -and (Split-Path -Path $SA -Leaf) -ne 'Applications') { $SA = Split-Path -Path $SA -Parent }
if (-not $SA) { throw "$SCA is not inside an 'Applications' folder." }
$SL  = Split-Path -Path $SA -Parent            # C:\SCRIPTS
$SF  = Join-Path -Path $SL -ChildPath 'Functions'
$SG  = Join-Path -Path $SL -ChildPath 'Logs'
$BackupDir = Join-Path -Path $SCA -ChildPath 'Backups'
#endregion

#region Settings (Data\PoshAcme.json, then parameters)
if (-not $SettingsPath) { $SettingsPath = Join-Path -Path $SCA -ChildPath 'Data\PoshAcme.json' }
$Cfg = $null
$GetSettingsPath = Join-Path -Path $SF -ChildPath 'Get-ApplicationSettings.ps1'
if (-not (Test-Path -Path $SettingsPath)) { Write-Warning "Settings $SettingsPath not found; using built-in defaults." }
elseif (Test-Path -Path $GetSettingsPath) { . $GetSettingsPath; $Cfg = Get-ApplicationSettings -Path $SettingsPath }
else {
    Write-Warning "$GetSettingsPath not found; per-server overrides (Data\PoshAcme.$env:COMPUTERNAME.json) are ignored."
    $Cfg = Get-Content -Path $SettingsPath -Raw | ConvertFrom-Json
}

$Migrate = if ($Cfg) { $Cfg.Migrate } else { $null }
function Get-Setting { param($Value, $FromManifest, $Default) if ($Value) { $Value } elseif ($FromManifest) { "$FromManifest" } else { $Default } }
$OldHome         = Get-Setting $OldHome         $(if ($Migrate) { $Migrate.From })           'C:\POSHACME\certs'
$OldTaskPattern  = Get-Setting $OldTaskPattern  $(if ($Migrate) { $Migrate.OldTaskPattern }) 'C:\POSHACME\'
$ArchiveFolder   = Get-Setting $ArchiveFolder   $(if ($Migrate) { $Migrate.Archive })        (Split-Path -Path $OldHome -Parent)
$ArchiveRenameTo = Get-Setting $ArchiveRenameTo $(if ($Migrate) { $Migrate.RenameTo })       "$ArchiveFolder.migrated"
$RunAs           = Get-Setting $RunAs           $(if ($Cfg) { $Cfg.RunAs }) ''
$Domain          = Get-Setting $Domain          $(if ($Cfg) { $Cfg.Domain }) (('{0}.{1}' -f $env:COMPUTERNAME, (Get-CimInstance Win32_ComputerSystem).Domain).ToLower())

$Modules = @(if ($Cfg -and $Cfg.Modules) { $Cfg.Modules | ForEach-Object { "$($_.Name)" } } else { 'Posh-ACME', 'Posh-ACME.Deploy' })
$PoshMod = if ($Cfg) { $Cfg.Modules | Where-Object { $_.Name -eq 'Posh-ACME' } | Select-Object -First 1 } else { $null }
$DataVariable = if ($PoshMod -and $PoshMod.DataVariable) { "$($PoshMod.DataVariable)" } else { 'POSHACME_HOME' }
$CertsDir     = if ($PoshMod -and $PoshMod.DataFolder) { "$($PoshMod.DataFolder)" } else { Join-Path -Path $SCA -ChildPath 'Certs' }
#endregion

#region Logging
New-Item -ItemType Directory -Path $SG -Force | Out-Null
$TextLog = Join-Path -Path $SG -ChildPath "$LogFileName.log"

$WriteLogPath = Join-Path -Path $SF -ChildPath 'Write-AdvancedLog.ps1'
if (Test-Path -Path $WriteLogPath) { . $WriteLogPath }
else { Write-Warning "Write-AdvancedLog not found at $WriteLogPath. Logging to the console only." }

# Compare-Files checks the copied data file by file (step 3)
$CompareFilesPath = Join-Path -Path $SF -ChildPath 'Compare-Files.ps1'
if (-not (Test-Path -Path $CompareFilesPath)) { throw "Required function file missing: $CompareFilesPath. Copy the application again with SetupApplications.ps1 (Base copies the common functions)." }
. $CompareFilesPath

function Write-InstallLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR')]
        [string]$LogType = 'INFO'
    )

    if ($LogType -eq 'WARNING') { Write-Warning $Message } else { Write-Host "  $Message" }

    if (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue) {
        $LogArgs = @{
            Message     = $Message
            ScriptName  = $ScriptName
            LogFileName = $LogFileName
            LogFile     = $TextLog
            LogType     = $LogType
        }
        # Only actionable entries go to the event log; routine INFO stays in the text log.
        if ($LogType -ne 'INFO') { $LogArgs.WriteEventLog = $true }
        try { Write-AdvancedLog @LogArgs }
        catch { Write-Host "  Write-AdvancedLog failed: $($_.Exception.Message)" }
    }
}
#endregion

#region Data helpers
# True when a folder holds Posh-ACME Let's Encrypt (LE_PROD) data, in either layout:
# acme-v02.api.letsencrypt.org (older stores) or LE_PROD (Posh-ACME 4.x).
function Test-PoshAcmeStore {
    param([string]$Path)
    [bool](Get-ChildItem -Path $Path -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'LE_PROD' -or $_.Name -like 'acme-v02.api.letsencrypt.org*' })
}

# Newest file write time in a folder (UTC), or MinValue
function Get-NewestWrite {
    param([string]$Path)
    $N = Get-ChildItem -Path $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($N) { $N.LastWriteTimeUtc } else { [datetime]::MinValue }
}

# Files of $From that are missing in $To or differ (Compare-Files, SHA256). Empty = complete copy.
function Compare-StoreCopy {
    param([string]$From, [string]$To)
    # One base for both the folder and its files, so relative paths are always cut correctly
    # (Resolve-Path and Get-ChildItem can disagree on short 8.3 names such as KENNET~1).
    $Dir = New-Object System.IO.DirectoryInfo((Resolve-Path -Path $From).ProviderPath)
    $Root = $Dir.FullName.TrimEnd('\')
    foreach ($F in $Dir.EnumerateFiles('*', [System.IO.SearchOption]::AllDirectories)) {
        $Rel = $F.FullName.Substring($Root.Length + 1)
        $T = Join-Path -Path $To -ChildPath $Rel
        if (-not (Test-Path -Path $T -PathType Leaf)) { "missing: $Rel" }
        elseif (-not (Compare-Files -File1Path $T -File2Path $F.FullName -WhatIf:$false).AreEqual) { "different: $Rel" }
    }
}

# Zips a whole folder into $BackupDir; checks every file made it into the zip. Returns the zip path.
function Backup-OldFolder {
    param([string]$Folder, [string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $Zip = Join-Path -Path $Destination -ChildPath ('{0}_{1}_{2:yyyyMMdd_HHmmss}.zip' -f (Split-Path -Path $Folder -Leaf), $env:COMPUTERNAME, (Get-Date))
    # .NET ZipFile rather than Compress-Archive: it includes hidden files.
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($Folder, $Zip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
    $Archive = [System.IO.Compression.ZipFile]::OpenRead($Zip)
    try { $InZip = @($Archive.Entries | Where-Object { $_.Name }).Count } finally { $Archive.Dispose() }
    $OnDisk = @(Get-ChildItem -Path $Folder -Recurse -File -Force).Count
    if ($InZip -lt $OnDisk) { throw "Backup $Zip has $InZip files, $Folder has $OnDisk." }
    $Zip
}

# Old tasks: every scheduled task whose action mentions the pattern
function Get-OldTasks {
    param([string]$Pattern)
    try { @(Get-ScheduledTask -ErrorAction Stop | Where-Object { ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -match [regex]::Escape($Pattern) }) }
    catch {
        # The ScheduledTasks cmdlets fail on some servers ("The request was aborted"): read the task
        # definitions instead. Same properties as used here: TaskPath, TaskName, State.
        Write-InstallLog "Get-ScheduledTask failed ($($_.Exception.Message)); reading the task files in $env:windir\System32\Tasks instead." -LogType WARNING
        $TasksDir = Join-Path -Path $env:windir -ChildPath 'System32\Tasks'
        @(Get-ChildItem -Path $TasksDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            try { $X = [xml](Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop) } catch { return }
            $Act = @($X.Task.Actions.Exec | ForEach-Object { "$($_.Command) $($_.Arguments)" }) -join ' '
            if ($Act -notmatch [regex]::Escape($Pattern)) { return }
            $Rel = $_.FullName.Substring($TasksDir.Length)                     # \Folder\Name
            [pscustomobject]@{
                TaskPath = ($Rel -replace '[^\\]+$', '')
                TaskName = $_.Name
                State    = if ("$($X.Task.Settings.Enabled)" -eq 'false') { 'Disabled' } else { 'Ready' }
            }
        })
    }
}
#endregion

$DisabledThisRun = New-Object System.Collections.Generic.List[object]

try {
    Write-InstallLog "Posh-ACME core install started on $env:COMPUTERNAME as $env:USERDOMAIN\$env:USERNAME. Folder: $SCA, data: $CertsDir, old store: $OldHome, order domain: $Domain$(if ($Cfg -and $Cfg.OverridePath) { ", overrides: $($Cfg.OverridePath)" })."
    $Me = "$env:USERDOMAIN\$env:USERNAME"
    if ($RunAs -and $Me -ne $RunAs) {
        Write-InstallLog "Running as $Me, but the settings say $RunAs. The data copies fine, but the saved DNS credentials can only be read by $RunAs, so step 4 will fail and the old folder will not be retired. Run again as $RunAs." -LogType WARNING
    }

    #region 1. Folders, permissions and POSHACME_HOME
    Write-Host "`n[1/5] Folders, permissions and $DataVariable" -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $CertsDir -Force | Out-Null
    # Administrators + SYSTEM only, including the role folders (Certs holds the ACME account key and PFX files)
    # The folder itself: no inherited permissions, only Administrators and SYSTEM (inherited by
    # everything below). Then everything below is reset to inherit just that. (Granting with /T
    # instead strips files of every permission: the (OI)(CI) grant only applies to folders.)
    & icacls $SCA /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $SCA." }
    if (Get-ChildItem -Path $SCA -Force) {
        & icacls (Join-Path -Path $SCA -ChildPath '*') /reset /T /C /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls /reset failed under $SCA." }
    }
    if (-not $CertsDir.StartsWith($SCA, [StringComparison]::OrdinalIgnoreCase)) {
        Write-InstallLog "$CertsDir is outside $SCA, so it does not get the Administrators/SYSTEM-only permissions. Restrict it by hand." -LogType WARNING
    }
    Write-InstallLog "$SCA restricted to Administrators and SYSTEM."

    # Set before the module is installed or imported, so Posh-ACME never creates data in its
    # default per-user folder (%LOCALAPPDATA%\Posh-ACME). Scripts that set it themselves (the
    # old tasks, Renew-ExchangeLE.ps1) are not affected.
    $PrevHome = [Environment]::GetEnvironmentVariable($DataVariable, 'Machine')
    if ($PrevHome -ne $CertsDir) {
        [Environment]::SetEnvironmentVariable($DataVariable, $CertsDir, 'Machine')
        $PrevText = if ($PrevHome) { $PrevHome } else { '(not set)' }
        Write-InstallLog "Machine $DataVariable changed from $PrevText to $CertsDir. New sessions use it; open sessions keep the old value."
    }
    else {
        Write-InstallLog "Machine $DataVariable already $CertsDir."
    }
    Set-Item -Path "Env:$DataVariable" -Value $CertsDir
    #endregion

    #region 2. Modules
    Write-Host "`n[2/5] Modules: $($Modules -join ', ')" -ForegroundColor Cyan
    if ($SkipModuleReinstall) {
        Write-InstallLog 'Module check skipped (-SkipModuleReinstall).'
    }
    else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        }
        # Correct = exactly one version of each, the newest in the gallery. If the gallery cannot be
        # asked (an old PowerShellGet such as 1.0.0.1 reports "PowerShell Gallery is currently
        # unavailable"), usable installed modules are kept instead of stopping the install.
        $GalleryError = $null
        $Wrong = @(foreach ($M in $Modules) {
            $Have = @(Get-Module -ListAvailable -Name $M | ForEach-Object { "$($_.Version)" } | Select-Object -Unique)
            $Newest = $null
            if (-not $GalleryError) {
                try { $Newest = "$((Find-Module -Name $M -Repository PSGallery -ErrorAction Stop).Version)" }
                catch { $GalleryError = $_.Exception.Message }
            }
            if ($GalleryError) { continue }
            if ($Have.Count -ne 1 -or $Have[0] -ne $Newest) {
                Write-InstallLog "$M is installed as $(if ($Have) { $Have -join ', ' } else { '(none)' }); expected only $Newest."
                $M
            }
        })
        if ($GalleryError) {
            $PSGet = (Get-Module -ListAvailable -Name PowerShellGet | Sort-Object Version -Descending | Select-Object -First 1).Version
            $Usable = $true
            foreach ($M in $Modules) {
                $Top = Get-Module -ListAvailable -Name $M | Sort-Object Version -Descending | Select-Object -First 1
                if (-not $Top -or ($M -eq 'Posh-ACME' -and $Top.Version.Major -lt 4)) { $Usable = $false }
                Write-InstallLog "$M installed: $(if ($Top) { (@(Get-Module -ListAvailable -Name $M | ForEach-Object { "$($_.Version)" } | Select-Object -Unique)) -join ', ' } else { '(none)' })."
            }
            $Hint = "Fix: update PowerShellGet (now $PSGet) or push the modules from the setup machine (SetupApplications.ps1 module fix, or Install-ServerModule), then run this again with -SkipModuleReinstall."
            if (-not $Usable) { throw "Cannot reach the PowerShell Gallery ($GalleryError) and the installed modules are missing or too old (Posh-ACME 4.0+ needed). $Hint" }
            Write-InstallLog "Cannot check the PowerShell Gallery ($GalleryError). Keeping the installed modules, which are usable. $Hint" -LogType WARNING
        }
        elseif ($Wrong.Count -eq 0) {
            Write-InstallLog "$($Modules -join ' and ') already correct (one version each, the newest)."
        }
        else {
            # Remove in reverse order (Posh-ACME.Deploy before Posh-ACME), install in order
            foreach ($M in ($Modules[($Modules.Count - 1)..0])) {
                Remove-Module -Name $M -Force -ErrorAction SilentlyContinue
                if (Get-InstalledModule -Name $M -ErrorAction SilentlyContinue) {
                    Uninstall-Module -Name $M -AllVersions -Force
                    Write-InstallLog "Uninstalled $M (all versions)."
                }
                $Leftover = Get-Module -ListAvailable -Name $M
                if ($Leftover) {
                    Write-InstallLog "$M still present outside PowerShellGet: $($Leftover.ModuleBase -join '; '). Remove those folders manually." -LogType WARNING
                }
            }
            foreach ($M in $Modules) {
                Install-Module -Name $M -Scope AllUsers -Repository PSGallery -Force -AllowClobber
                Write-InstallLog "Installed $M $((Get-InstalledModule -Name $M).Version)."
            }
        }
    }
    #endregion

    #region 3. Data
    Write-Host "`n[3/5] Posh-ACME data" -ForegroundColor Cyan
    $OldHasData   = Test-PoshAcmeStore -Path $OldHome
    $CertsHasData = @(Get-ChildItem -Path $CertsDir -Force -ErrorAction SilentlyContinue).Count -gt 0
    $OldIsNewer   = $OldHasData -and $CertsHasData -and ((Get-NewestWrite $OldHome) -gt (Get-NewestWrite $CertsDir))
    $BackupZip    = $null

    if ($OldHasData -and (-not $CertsHasData -or $Resync)) {
        # Stop the old tasks first so nothing renews into the old store during or after the copy
        foreach ($T in Get-OldTasks -Pattern $OldTaskPattern) {
            if ($T.State -ne 'Disabled') {
                Disable-ScheduledTask -ErrorAction Stop -TaskPath $T.TaskPath -TaskName $T.TaskName | Out-Null
                $DisabledThisRun.Add($T)
                Write-InstallLog "Disabled old task $($T.TaskPath)$($T.TaskName)."
            }
        }

        $BackupZip = Backup-OldFolder -Folder $ArchiveFolder -Destination $BackupDir
        Write-InstallLog "Backed up $ArchiveFolder (scripts and data) to $BackupZip."

        & robocopy $OldHome $CertsDir /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed copying $OldHome (exit $LASTEXITCODE)." }

        $Diff = @(Compare-StoreCopy -From $OldHome -To $CertsDir)
        if ($Diff.Count) { throw "Copy of $OldHome to $CertsDir is incomplete: $($Diff -join '; ')" }
        $Count = @(Get-ChildItem -Path $OldHome -Recurse -File -Force).Count
        Write-InstallLog "Copied $OldHome to $CertsDir$(if ($Resync) { ' (resync)' }): $Count files, all identical (SHA256)."
        $OldIsNewer = $false
    }
    elseif ($CertsHasData) {
        Write-InstallLog "$CertsDir already has data; not copying."
        if ($OldIsNewer) {
            Write-InstallLog "$OldHome has files newer than $CertsDir (an old task renewed after the copy). Run again with -Resync." -LogType WARNING
        }
    }
    else {
        Write-InstallLog "No Posh-ACME data in $OldHome or $CertsDir. Create a new ACME account and order (New-PAAccount, New-PAOrder) as $(if ($RunAs) { $RunAs } else { 'the task account' }) before installing a role." -LogType WARNING
    }

    # Other stores (Posh-ACME's per-user default) are reported only
    foreach ($O in @(Get-ChildItem -Path 'C:\Users\*\AppData\Local\Posh-ACME' -Directory -ErrorAction SilentlyContinue | Where-Object { Test-PoshAcmeStore -Path $_.FullName })) {
        Write-InstallLog "Posh-ACME data also in $($O.FullName) (default location when $DataVariable is not set). Not used and not migrated; check it holds nothing needed." -LogType WARNING
    }
    #endregion

    #region 4. Check the data from Certs
    Write-Host "`n[4/5] Check the data in $CertsDir" -ForegroundColor Cyan
    $DataOk = $false
    if (Test-PoshAcmeStore -Path $CertsDir) {
        Import-Module Posh-ACME -Force
        Set-PAServer LE_PROD
        $Account = Get-PAAccount
        if (-not $Account) { throw "No ACME account selected for LE_PROD in $CertsDir." }
        Write-InstallLog "ACME account $($Account.id) ($($Account.status))."
        $Orders = @(Get-PAOrder -List)
        $Orders | Format-Table MainDomain, Status, CertExpires, Plugin -AutoSize | Out-String | Write-Host

        $Order = $Orders | Where-Object { $_.MainDomain -eq $Domain } | Select-Object -First 1
        if (-not $Order) {
            Write-InstallLog "No order for $Domain under account $($Account.id)." -LogType WARNING
            $Order = $Orders | Select-Object -First 1
        }
        if ($Order) {
            try {
                $PluginArgs = if ($Order.Name) { Get-PAPluginArgs -Name $Order.Name -ErrorAction Stop } else { Get-PAPluginArgs -MainDomain $Order.MainDomain -ErrorAction Stop }
                Write-InstallLog "Order $($Order.Name) ($($Order.MainDomain)): plugin $((@($Order.Plugin) | Select-Object -Unique) -join ', '), $(@($PluginArgs.Keys).Count) saved plugin argument(s) readable as $Me."
                $DataOk = $true
            }
            catch {
                Write-InstallLog "Cannot read the saved plugin arguments of $($Order.MainDomain) as ${Me}: $($_.Exception.Message). They are encrypted for the account that saved them$(if ($RunAs) { " ($RunAs)" }); renewals must run as that account." -LogType WARNING
            }
        }
    }
    else {
        Write-InstallLog "$CertsDir has no LE_PROD data yet." -LogType WARNING
    }
    #endregion

    #region 5. Retire the old store
    Write-Host "`n[5/5] Old store $ArchiveFolder" -ForegroundColor Cyan
    if (-not (Test-Path -Path $ArchiveFolder)) {
        Write-InstallLog "$ArchiveFolder not present; nothing to retire."
    }
    elseif ($KeepOldFolder) {
        Write-InstallLog "$ArchiveFolder kept (-KeepOldFolder)."
    }
    elseif (-not $DataOk) {
        Write-InstallLog "$ArchiveFolder kept: the data in $CertsDir is not confirmed usable (step 4)." -LogType WARNING
        if ($DisabledThisRun.Count) { throw 'Data check failed after the old tasks were disabled.' }
    }
    elseif ($OldIsNewer) {
        Write-InstallLog "$ArchiveFolder kept: it has newer data than $CertsDir. Run again with -Resync." -LogType WARNING
    }
    else {
        foreach ($T in Get-OldTasks -Pattern $OldTaskPattern) {
            if ($T.State -ne 'Disabled') {
                Disable-ScheduledTask -ErrorAction Stop -TaskPath $T.TaskPath -TaskName $T.TaskName | Out-Null
                $DisabledThisRun.Add($T)
                Write-InstallLog "Disabled old task $($T.TaskPath)$($T.TaskName)."
            }
        }
        if (-not $BackupZip) {
            $BackupZip = Backup-OldFolder -Folder $ArchiveFolder -Destination $BackupDir
            Write-InstallLog "Backed up $ArchiveFolder (scripts and data) to $BackupZip."
        }
        $Target = if (Test-Path -Path $ArchiveRenameTo) { '{0}_{1:yyyyMMdd_HHmmss}' -f $ArchiveRenameTo, (Get-Date) } else { $ArchiveRenameTo }
        try {
            Rename-Item -Path $ArchiveFolder -NewName (Split-Path -Path $Target -Leaf) -ErrorAction Stop
            Write-InstallLog "Renamed $ArchiveFolder to $Target (backup: $BackupZip). Delete it after the first successful renewal by the new task."
        }
        catch {
            Write-InstallLog "Could not rename $ArchiveFolder (in use?): $($_.Exception.Message). The old tasks stay disabled; rename it by hand." -LogType WARNING
        }
    }
    #endregion

    # Leftovers of the migration go on this server's cleanup list (Applications\Data\Settings\Cleanup.json),
    # once the new store is confirmed: the renamed old folder and the disabled old tasks after
    # Migrate.CleanupDays (30), the backup zips (old secrets inside) after Migrate.BackupKeepDays (90).
    # Invoke-ScriptsCleanup deletes them when due (Frontend sync); an item already listed is kept as it is.
    $CleanFn = Join-Path -Path $SF -ChildPath 'Invoke-ScriptsCleanup.ps1'
    if ($DataOk -and (Test-Path -Path $CleanFn)) {
        . $CleanFn
        $CleanDays = if ($Migrate -and "$($Migrate.CleanupDays)" -match '^-?\d+$') { [int]$Migrate.CleanupDays } else { 30 }
        $ZipDays   = if ($Migrate -and "$($Migrate.BackupKeepDays)" -match '^-?\d+$') { [int]$Migrate.BackupKeepDays } else { 90 }
        $Leftovers = @(
            Get-ChildItem -Path (Split-Path -Path $ArchiveRenameTo -Parent) -Directory -Filter "$(Split-Path -Path $ArchiveRenameTo -Leaf)*" -ErrorAction SilentlyContinue |
                ForEach-Object { @{ Type = 'Folder'; Path = $_.FullName; Days = $CleanDays; Reason = "Old Posh-ACME store, migrated to $CertsDir" } }
            Get-OldTasks -Pattern $OldTaskPattern | Where-Object { $_.State -eq 'Disabled' } |
                ForEach-Object { @{ Type = 'Task'; Path = "$($_.TaskPath)$($_.TaskName)"; Days = $CleanDays; Reason = 'Old Posh-ACME task, replaced by the PoshAcme role task' } }
            Get-ChildItem -Path $BackupDir -Filter 'POSHACME_*.zip' -File -ErrorAction SilentlyContinue |
                ForEach-Object { @{ Type = 'File'; Path = $_.FullName; Days = $ZipDays; Reason = 'Backup of the old Posh-ACME folder (contains old keys and scripts)' } }
        )
        foreach ($L in $Leftovers) {
            try { $Item = Add-ScriptsCleanupItem @L -By 'Install-PoshAcme.ps1'; Write-InstallLog "Cleanup list: $($L.Type) $($L.Path) is deleted on $(if ($Item.Due) { ([datetime]$Item.Due).ToString('yyyy-MM-dd') } else { 'never (-1)' })." }
            catch { Write-InstallLog "Not put on the cleanup list: $($_.Exception.Message)" -LogType WARNING }
        }
    }

    # Record the install in the inventory (local file, plus the DFS drop folder when reachable)
    $InvPath = Join-Path -Path $SF -ChildPath 'Update-ApplicationInventory.ps1'
    if (Test-Path -Path $InvPath) {
        . $InvPath
        $Inv = Update-ApplicationInventory -Application 'PoshAcme' -Action Installed -Version $(if ($Cfg) { "$($Cfg.Version)" } else { '' }) -Result $(if ($DataOk) { 'OK' } else { 'Warnings' }) -Details @{ Domain = $Domain; DataFolder = $CertsDir; DataChecked = [bool]$DataOk; Overrides = $(if ($Cfg -and $Cfg.OverridePath) { Split-Path -Path $Cfg.OverridePath -Leaf } else { '' }) } -WarningAction SilentlyContinue
        if ($Inv.Message -ne 'OK') { Write-InstallLog "Inventory: $($Inv.Message)" -LogType WARNING } else { Write-InstallLog "Inventory updated ($($Inv.File))." }
    }
    Write-InstallLog 'Posh-ACME core install completed.'
    Write-Host "`nNext: install the server role, for example:" -ForegroundColor Green
    Write-Host "  & '$(Join-Path -Path $SCA -ChildPath 'ExchangeServer\Install-ExchangeLE.ps1')'"
}
catch {
    # Do not leave renewals stopped: enable again what this run disabled
    foreach ($T in $DisabledThisRun) {
        try { Enable-ScheduledTask -TaskPath $T.TaskPath -TaskName $T.TaskName | Out-Null; Write-InstallLog "Enabled old task $($T.TaskPath)$($T.TaskName) again." }
        catch { Write-InstallLog "Could not enable old task $($T.TaskPath)$($T.TaskName) again: $($_.Exception.Message)" -LogType ERROR }
    }
    Write-InstallLog "Posh-ACME core install failed: $($_.Exception.Message)" -LogType ERROR
    throw
}

# Example usage:
# PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\Install-PoshAcme.ps1
# PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\Install-PoshAcme.ps1 -Resync
# PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\Install-PoshAcme.ps1 -SkipModuleReinstall -KeepOldFolder


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCpIVFNskMk+rBG
# qQT3CxKRVodszPRwiVVu+ZQypU46WKCCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIBbdScY7
# 0uuLaJIpUmQsf/FtS1h0X7UulEfIujrGHBWHMA0GCSqGSIb3DQEBAQUABIIBAJx8
# vszllD53OzG09+mJbVWEfpkbj+mNLY7CxEPUJUeS5nb6HhD1SwykQk+lCcdufhOY
# xuIup7romsBWHo9WvALeYAfyBFHnrVmEePH+OnqnlAaSirrskh5Qufygk8UEfKOf
# X2yxWIVXi3pop+Q0vC2WJLQYg3XHPdfIv+NtT24UIQ90lPWW1ghCyRnP76E5RZ9P
# 8JA/Wg4JkFZuIbTtLkyuoVOulgI62hnIciFqeJfYQBVLV859FFvkrryLk+LHy9Qg
# htB9DuCQu5218arhstZ0QU9b5XktxYHaejz5uBh1K0md0wFLrrWYqdAQOklrhl/K
# ASCbzQK/9FFjnNTZ7lqhggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDIyMTk1
# MzMzWjAvBgkqhkiG9w0BCQQxIgQgbDgVx4PUjw+y6w3YAICk9AXSQt1qSmrLeCu6
# 28+hyk4wDQYJKoZIhvcNAQEBBQAEggIAi+7QVkCuMRieFzl2tvd0XYm200DJ93hC
# w6ZMo+NmxHsfIGy5q2L+A9Gy3AaMrg0FgDTDt+8Hye3vKps7fJ+8+S3LsQG0fMM8
# ZRhXtCN9O8DotN0pKVJtXEuDZxjQBVphIiM0gMsszLCI/cw2x0vkikGD7J80LQLZ
# AO8AIjmqbkFH15IY3O1pTWwqbq9UFaeNpAm3lQEKaYTqhvLEg0hTFvZ3iw7H907+
# YMVq7qr9DaxWVJUw+nMtBb8T1jJZ9OP1A7v2np+YEQga/DbMd91ArvDNTjbV6RjP
# 9a2u5EsMxo1mFrb9SD1/j9PGFf2zM/EV7sKIGxFGREpDuDO/x4NFHK643HcAhSaa
# OHAYsig42bHi127ka3WXnBNlO8PUWAjgLRlcZYRzPvm1VEu25fegjv0S1CR2NpBR
# jPATjvBpaAgUpljszMGko2YRtnxxbDlZn8s+3yxmJzsA4guCIosh8ck2iXriJisd
# S6RUyGUVBENyIdgZLtgBFPMUp/p07H+hy52o8rGC6LAPmxh4mSCbKgI2dIv8PR0j
# USeJWYdxo8Vlu2obRZ+fb6P2po9ufkZKL1L031DzB6veps2GkmosC5WLz6vrQFSm
# +ypA0iDnu94IO9HLynEooO1FlhOK2jLeJt3GlVJFw1XE7S8/LSiIBgqEjJEvV+mM
# xebnhex7+js=
# SIG # End signature block
