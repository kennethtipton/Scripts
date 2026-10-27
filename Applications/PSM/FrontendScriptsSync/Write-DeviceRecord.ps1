<#
.SYNOPSIS
    Writes this device's record (device.<DEVICE>.json): the server itself, its PSM state, and what is
    on disk under C:\SCRIPTS, for the inventory and the PSM web/API.
.DESCRIPTION
    Part of Powershell Scripts Management (PSM), Frontend. Runs at the end of every
    Sync-ScriptsFromDfs.ps1 run (task \PSM\SyncScriptsFromDfs), which passes the result of the sync
    and of the log shipping; it can also run on its own.

    The record (JSON, Format 1):
      Device, Domain, Fqdn, Updated
      Os          Caption, Version, Build, Installed, LastBoot, UptimeDays
      Hardware    Manufacturer, Model, Cpus (logical), MemoryGB
      Disks       fixed volumes: Drive, SizeGB, FreeGB
      Network     IPv4 and global IPv6 addresses
      PowerShell  Windows PowerShell and PowerShell 7 versions
      Psm         Frontend version, the last Sync (time, exit code, files checked/updated/failed,
                  held test copies), LogShipping (entries sent, failures) and Cleanup (files
                  removed, log entries trimmed, refused/failed targets), the \PSM\ tasks, and
                  LocalSettings (the local override files and which keys they set)
      Applications  every PSM application found on disk (a manifest's settings file is here):
                    version here and on DFS, Status (current, held = newer here (a test copy),
                    behind, not published), Enrolled (has an inventory record)
      Modules     installed versions of the PowerShell modules the manifests ask for
      Unmanaged   folders under C:\SCRIPTS\Applications that no manifest covers, and non-standard
                  folders/files in C:\SCRIPTS: path, files, scripts, last change
      OtherTasks  scheduled tasks outside \PSM\ and \Microsoft\ that run PowerShell or anything in
                  C:\SCRIPTS: path, state, account, command (password-like arguments masked),
                  last run and result

    Written to C:\SCRIPTS\Applications\Data\device.<DEVICE>.json and to the DFS inventory drop folder
    (the Dfs transport's Root\InventoryFolder), each under a temporary name and then renamed.
    The Backend (Update-InventoryIndex.ps1) adds the records to Inventory.json under Devices.

    It only reads (files, scheduled tasks, CIM); nothing is changed or run. Settings: DeviceRecord
    in C:\SCRIPTS\Data\Settings\Scripts.json (Enabled).
.PARAMETER SettingsPath
    Settings file. Defaults to C:\SCRIPTS\Data\Settings\Scripts.json.
.PARAMETER DfsRoot
    DFS scripts root. Defaults to the Dfs transport's Root in the settings.
.PARAMETER Sync
    Result of the sync run (from Sync-ScriptsFromDfs.ps1): ExitCode, Checked, Updated, Failed, Held.
.PARAMETER Shipping
    Result of Send-LogsToDfs.ps1 (Records, Sent, Failed, Messages).
.PARAMETER Cleanup
    Result of Invoke-ScriptsCleanup.
.PARAMETER PassThru
    Also return the record.
.EXAMPLE
    PS> C:\SCRIPTS\Applications\PSM\FrontendScriptsSync\Write-DeviceRecord.ps1 -PassThru | ConvertTo-Json -Depth 6
.INPUTS
    None
.OUTPUTS
    [pscustomobject] LocalWritten, DropWritten, Message (and the record with -PassThru).
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-22
    Time: 14:00:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 1.2.0
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: Claude

    Copyright (c) 2026
    Licensed under the MIT License.
    Full text available at: https://opensource.org/licenses/MIT

    Overide Variables
    Overide Filename:
    Overide Log Filename: Write-DeviceRecord
    Overide Text Log File Path:
    Overide Log Type:
.LINK
    https://www.tnandc.com
#>
[CmdletBinding()]
param(
    [string]$SettingsPath,
    [string]$DfsRoot,
    [hashtable]$Sync,
    $Shipping,
    $Cleanup,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'Write-DeviceRecord.ps1'

#region Standard locations
$SCA = $PSScriptRoot
$SA  = $SCA
while ($SA -and (Split-Path -Path $SA -Leaf) -ne 'Applications') { $SA = Split-Path -Path $SA -Parent }
if (-not $SA) { throw "$SCA is not inside an 'Applications' folder." }
$SL = Split-Path -Path $SA -Parent
$SF = Join-Path -Path $SL -ChildPath 'Functions'
if (-not $SettingsPath) { $SettingsPath = Join-Path -Path $SL -ChildPath 'Data\Settings\Scripts.json' }
#endregion

foreach ($F in 'Write-AdvancedLog.ps1', 'Get-ApplicationSettings.ps1', 'Get-ScriptsTransport.ps1') {
    $P = Join-Path -Path $SF -ChildPath $F
    if (Test-Path -Path $P) { . $P }
}
function Write-RecordLog {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO', 'WARNING', 'ERROR')][string]$LogType = 'INFO')
    if ($LogType -eq 'INFO') { Write-Verbose $Message; return }
    Write-Warning $Message
    if (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue) {
        try { Write-AdvancedLog -Message $Message -ScriptName $ScriptName -LogFileName 'Write-DeviceRecord' -LogType $LogType } catch { }
    }
}

# Read-only helpers: every part is optional, a failure leaves that part empty
function Get-Safe { param([scriptblock]$Block, $Default = $null) try { & $Block } catch { Write-Verbose "skipped: $($_.Exception.Message)"; $Default } }
function Get-JsonVersion { param([string]$Path) if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) { try { "$((Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).Version)" } catch { '' } } else { '' } }
function ConvertTo-RootPath { param([string]$Path, [string]$Root) $Root.TrimEnd('\') + $Path.Substring('C:\SCRIPTS'.Length) }
# Arguments that look like secrets are masked before anything leaves the server
function Hide-Secret {
    param([string]$Text)
    $T = $Text -replace '(?i)(-(Password|Pass|Pwd|PfxPass|Secret|Token|ApiKey|Key|Credential)\s+)("[^"]*"|''[^'']*''|\S+)', '$1***'
    $T = $T -replace '(?i)((password|pwd|pass|secret|token|apikey)\s*[=:]\s*)("[^"]*"|''[^'']*''|[^\s;,]+)', '$1***'
    $T = $T -replace '(?i)(\s/p(ass(word)?)?[:\s]+)\S+', '$1***'
    $T = $T -replace '(?i)(/user:\S+\s+)(?![/-])("[^"]*"|\S+)', '$1***'          # net use ... /user:x <password>
    $T = $T -replace '(?i)(\s-p\s+)("[^"]*"|\S+)', '$1***'                        # tools taking -p <password>
    if ($T.Length -gt 400) { $T.Substring(0, 400) + '...' } else { $T }
}
function Get-DateText { param($D) if ($D -and $D -is [datetime] -and $D.Year -gt 1999) { $D.ToString('s') } else { '' } }

$Out = [pscustomobject]@{ LocalWritten = $false; DropWritten = $false; Message = ''; Record = $null }
try {
    #region Settings
    $Cfg = if (Get-Command -Name Get-ApplicationSettings -ErrorAction SilentlyContinue) { Get-ApplicationSettings -Path $SettingsPath } else { Get-Content -Path $SettingsPath -Raw | ConvertFrom-Json }
    if ($Cfg.DeviceRecord -and $Cfg.DeviceRecord.PSObject.Properties['Enabled'] -and -not [bool]$Cfg.DeviceRecord.Enabled) { $Out.Message = 'Disabled (DeviceRecord.Enabled).'; return $Out }
    if (-not $DfsRoot) { $DfsRoot = Get-Safe { "$((Get-ScriptsTransport -Settings $Cfg -Type Dfs | Select-Object -First 1).Root)" } '' }
    $DfsRoot = "$DfsRoot".TrimEnd('\')
    $InvFolder = if ($Cfg.InventoryFolder) { "$($Cfg.InventoryFolder)" } else { 'Applications\Data' }
    $Device = $env:COMPUTERNAME.ToUpper()
    #endregion

    #region Server
    $OsI = Get-Safe { Get-CimInstance -ClassName Win32_OperatingSystem }
    $Cs  = Get-Safe { Get-CimInstance -ClassName Win32_ComputerSystem }
    $Domain = if ($Cs) { "$($Cs.Domain)".ToLower() } else { "$env:USERDNSDOMAIN".ToLower() }
    $Os = [ordered]@{
        Caption    = "$($OsI.Caption)".Trim()
        Version    = "$($OsI.Version)"
        Build      = "$($OsI.BuildNumber)"
        Installed  = Get-DateText $OsI.InstallDate
        LastBoot   = Get-DateText $OsI.LastBootUpTime
        UptimeDays = if ($OsI.LastBootUpTime) { [math]::Round(((Get-Date) - $OsI.LastBootUpTime).TotalDays, 1) } else { $null }
    }
    $Hardware = [ordered]@{
        Manufacturer = "$($Cs.Manufacturer)"
        Model        = "$($Cs.Model)"
        Cpus         = $Cs.NumberOfLogicalProcessors
        MemoryGB     = if ($Cs.TotalPhysicalMemory) { [math]::Round($Cs.TotalPhysicalMemory / 1GB, 1) } else { $null }
    }
    $Disks = @(Get-Safe { Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        [ordered]@{ Drive = $_.DeviceID; SizeGB = [math]::Round($_.Size / 1GB, 1); FreeGB = [math]::Round($_.FreeSpace / 1GB, 1) }
    } } @())
    $Network = @(Get-Safe { Get-NetIPAddress -AddressState Preferred -ErrorAction Stop | Where-Object {
        $_.IPAddress -notmatch '^(127\.|169\.254\.|::1$|fe80:)' -and $_.InterfaceAlias -notmatch 'Loopback'
    } | Sort-Object AddressFamily, IPAddress | ForEach-Object { [ordered]@{ Address = $_.IPAddress; Prefix = $_.PrefixLength; Interface = $_.InterfaceAlias } } } @())
    $Pwsh = Get-Safe { $C = Get-Command -Name pwsh.exe -ErrorAction Stop | Select-Object -First 1; "$($C.Version)" } ''
    $PowerShell = [ordered]@{ Windows = "$($PSVersionTable.PSVersion)"; Core = $Pwsh }
    #endregion

    #region Manifests: from DFS (as the sync reads them), else the local copy of Installs
    $ManDir = if ($DfsRoot -and (Test-Path -Path (Join-Path $DfsRoot 'Installs\Data'))) { Join-Path $DfsRoot 'Installs\Data' } else { Join-Path $SL 'Installs\Data' }
    $Manifests = @(Get-Safe { Get-ChildItem -Path $ManDir -Filter '*.json' -File | ForEach-Object {
        try { $M = Get-Content -Path $_.FullName -Raw | ConvertFrom-Json; $M | Add-Member -NotePropertyName FileName -NotePropertyValue $_.BaseName -Force; $M } catch { }
    } } @())
    #endregion

    #region Applications on disk
    $Records = @(Get-Safe { Get-ChildItem -Path (Join-Path $SL 'Applications\Data') -Filter "update.$Device.*.json" -File | ForEach-Object { $_.Name.Substring("update.$Device.".Length) -replace '\.json$', '' } } @())
    $ManagedRoots = New-Object System.Collections.Generic.List[string]
    $Applications = @(foreach ($M in $Manifests) {
        if (-not "$($M.AppData)" -or "$($M.AppData)" -notlike 'C:\SCRIPTS\*') { continue }
        $Local = ConvertTo-RootPath -Path "$($M.AppData)" -Root $SL
        if (-not (Test-Path -LiteralPath $Local -PathType Leaf)) { continue }
        $AppRoot = Split-Path -Path (Split-Path -Path $Local -Parent) -Parent    # ...\<App>\Data\<App>.json -> ...\<App>
        $ManagedRoots.Add($AppRoot)
        $Here = Get-JsonVersion $Local
        $Dfs  = if ($DfsRoot) { Get-JsonVersion (ConvertTo-RootPath -Path "$($M.AppData)" -Root $DfsRoot) } else { '' }
        $L = $null; $D = $null
        $Status = if (-not $Dfs) { 'not published' }
                  elseif ($Here -eq $Dfs) { 'current' }
                  elseif ([version]::TryParse($Here, [ref]$L) -and [version]::TryParse($Dfs, [ref]$D) -and $L -gt $D) { 'held (newer here: test copy)' }
                  else { 'behind' }
        $Name = if ($M.Name) { "$($M.Name)" } else { $M.FileName }
        [ordered]@{
            Name     = $Name
            Path     = $AppRoot
            Version  = $Here
            DfsVersion = $Dfs
            Status   = $Status
            Enrolled = [bool]($Records -contains $Name -or $Records -contains $M.FileName)
        }
    })
    # Base and the PSM folders are always managed
    $ManagedRoots.Add((Join-Path $SL 'Applications\PSM')); $ManagedRoots.Add((Join-Path $SL 'Applications\Data'))
    #endregion

    #region Unmanaged: files under Applications that no installed manifest covers, and extra root content
    $Unmanaged = New-Object System.Collections.Generic.List[object]
    $AppsDir = Join-Path $SL 'Applications'
    $Loose = @(Get-Safe { Get-ChildItem -Path $AppsDir -File -Recurse -Force -ErrorAction SilentlyContinue } @()) | Where-Object {
        $FP = $_.FullName
        -not ($ManagedRoots | Where-Object { $FP.StartsWith("$_\", [System.StringComparison]::OrdinalIgnoreCase) })
    }
    foreach ($G in @($Loose | Group-Object { $Parts = $_.FullName.Substring($AppsDir.Length + 1).Split('\'); if ($Parts.Count -gt 2) { "$($Parts[0])\$($Parts[1])" } else { $Parts[0] } })) {
        $Unmanaged.Add([ordered]@{
            Path     = Join-Path $AppsDir $G.Name
            Files    = $G.Count
            Scripts  = @($G.Group | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' }).Count
            Changed  = Get-DateText (($G.Group | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime)
        })
    }
    $Standard = 'Applications', 'Data', 'Functions', 'Modules', 'Logs', 'Installs'
    foreach ($I in @(Get-Safe { Get-ChildItem -Path $SL -Force | Where-Object { $_.Name -notin $Standard -and $_.Name -notlike '.*' } } @())) {
        $Files = if ($I.PSIsContainer) { @(Get-ChildItem -LiteralPath $I.FullName -File -Recurse -Force -ErrorAction SilentlyContinue) } else { @($I) }
        $Unmanaged.Add([ordered]@{
            Path    = $I.FullName
            Files   = $Files.Count
            Scripts = @($Files | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' }).Count
            Changed = Get-DateText (($Files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime)
        })
    }
    #endregion

    #region Modules the manifests ask for
    $ModNames = @($Manifests | ForEach-Object { $_.Modules } | Where-Object { $_.Name } | ForEach-Object { "$($_.Name)" } | Sort-Object -Unique)
    $Modules = @(foreach ($N in $ModNames) {
        $Found = @(Get-Safe { Get-Module -ListAvailable -Name $N } @())
        [ordered]@{ Name = $N; Versions = @($Found | ForEach-Object { "$($_.Version)" } | Sort-Object { [version]$_ } -Descending -Unique) }
    })
    #endregion

    #region Scheduled tasks
    function ConvertTo-TaskInfo {
        param($T)
        $I = Get-Safe { $T | Get-ScheduledTaskInfo }
        [ordered]@{
            Path       = "$($T.TaskPath)$($T.TaskName)"
            State      = "$($T.State)"
            RunAs      = "$($T.Principal.UserId)"
            Command    = Hide-Secret (($T.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)".Trim() }) -join ' ; ')
            LastRun    = Get-DateText $I.LastRunTime
            LastResult = if ($I) { '0x{0:X}' -f [int64]$I.LastTaskResult } else { '' }
            NextRun    = Get-DateText $I.NextRunTime
        }
    }
    $AllTasks = @(Get-Safe { Get-ScheduledTask } @())
    $PsmTasks = @($AllTasks | Where-Object { $_.TaskPath -like '\PSM\*' } | ForEach-Object { ConvertTo-TaskInfo $_ })
    $OtherTasks = @($AllTasks | Where-Object {
        $_.TaskPath -notlike '\PSM\*' -and $_.TaskPath -notlike '\Microsoft\*' -and
        ((@($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments) $($_.WorkingDirectory)" }) -join ' ') -match '(?i)C:\\SCRIPTS|powershell|pwsh')
    } | ForEach-Object { ConvertTo-TaskInfo $_ })
    #endregion

    #region PSM state
    $FrontVer = Get-JsonVersion (Join-Path $SL 'Applications\PSM\FrontendScriptsSync\Data\PSMFrontendScriptsSync.json')
    $SyncInfo = if ($Sync) {
        [ordered]@{
            Time     = (Get-Date).ToString('s')
            ExitCode = $Sync.ExitCode
            Checked  = $Sync.Checked
            Updated  = $Sync.Updated
            Failed   = $Sync.Failed
            Held     = @($Sync.Held | Where-Object { $_ })
        }
    } else { $null }
    $ShipInfo = if ($Shipping) {
        [ordered]@{ Time = (Get-Date).ToString('s'); Records = $Shipping.Records; Files = $Shipping.Sent; Failed = $Shipping.Failed; Messages = @($Shipping.Messages | Select-Object -First 5 | ForEach-Object { "$_" }) }
    } else { $null }
    $CleanInfo = if ($Cleanup) {
        [ordered]@{
            Time = "$($Cleanup.Time)"; DefaultDays = $Cleanup.DefaultDays; Removed = $Cleanup.Removed; Trimmed = $Cleanup.Trimmed; FreedKB = $Cleanup.FreedKB; Failed = $Cleanup.Failed
            ListPending = $Cleanup.ListPending
            ListItems = @($Cleanup.Targets | Where-Object { $_.Owner -eq 'Cleanup.json' } | ForEach-Object { "$($_.Type) $($_.Path): $($_.Note)" } | Select-Object -First 20)
            Notes = @($Cleanup.Targets | Where-Object { "$($_.Note)" -and "$($_.Note)" -notlike 'kept*' } | ForEach-Object { "$($_.Owner) $($_.Path): $($_.Note)" } | Select-Object -First 5)
        }
    } else { $null }
    # Keep the last known Sync/LogShipping/Cleanup when this run did not pass them (run on its own)
    $LocalPath = Join-Path $SL "Applications\Data\device.$Device.json"
    if ((-not $SyncInfo -or -not $ShipInfo -or -not $CleanInfo) -and (Test-Path -LiteralPath $LocalPath)) {
        $Prev = Get-Safe { Get-Content -LiteralPath $LocalPath -Raw | ConvertFrom-Json }
        if ($Prev -and $Prev.Psm) {
            if (-not $SyncInfo) { $SyncInfo = $Prev.Psm.Sync }
            if (-not $ShipInfo) { $ShipInfo = $Prev.Psm.LogShipping }
            if (-not $CleanInfo) { $CleanInfo = $Prev.Psm.Cleanup }
        }
    }
    #endregion

    # Keys added one at a time: Windows PowerShell 5.1 fails ("Argument types do not match") on an
    # [ordered] literal holding these arrays and lists
    $Psm = [ordered]@{}
    $Psm['Frontend'] = $FrontVer; $Psm['Sync'] = $SyncInfo; $Psm['LogShipping'] = $ShipInfo; $Psm['Cleanup'] = $CleanInfo; $Psm['Tasks'] = [object[]]$PsmTasks
    $Psm['LocalSettings'] = [object[]]@(Get-Safe { Get-ChildItem -Path (Join-Path $SL 'Applications\Data\Settings') -Filter '*.json' -File | ForEach-Object {
        # Which local overrides hold real values (more than the stub's Name/Notes)
        $J = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
        [ordered]@{ Name = $_.BaseName; Keys = @($J.PSObject.Properties.Name | Where-Object { $_ -notin 'Name', 'Notes', 'Description' }) }
    } } @())
    $Record = [ordered]@{}
    $Record['Format']       = 1
    $Record['Device']       = $Device
    $Record['Domain']       = $Domain
    $Record['Fqdn']         = "$Device.$Domain".ToLower()
    $Record['Updated']      = (Get-Date).ToString('s')
    $Record['Os']           = $Os
    $Record['Hardware']     = $Hardware
    $Record['Disks']        = [object[]]$Disks
    $Record['Network']      = [object[]]$Network
    $Record['PowerShell']   = $PowerShell
    $Record['Psm']          = $Psm
    $Record['Applications'] = [object[]]$Applications
    $Record['Modules']      = [object[]]$Modules
    $Record['Unmanaged']    = $Unmanaged.ToArray()
    $Record['OtherTasks']   = [object[]]$OtherTasks
    $Json = ConvertTo-Json -InputObject $Record -Depth 8

    #region Write: local, then the DFS drop folder
    function Write-Atomic {
        param([string]$Path, [string]$Text)
        $Dir = Split-Path -Path $Path -Parent
        if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
        $Tmp = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N').Substring(0, 8)
        [System.IO.File]::WriteAllText($Tmp, $Text, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -Path $Tmp -Destination $Path -Force -ErrorAction Stop
    }
    $Msgs = @()
    try { Write-Atomic -Path $LocalPath -Text $Json; $Out.LocalWritten = $true } catch { $Msgs += "Local: $($_.Exception.Message)" }
    if ($DfsRoot) {
        $Drop = Join-Path -Path $DfsRoot -ChildPath "$InvFolder\device.$Device.json"
        try { Write-Atomic -Path $Drop -Text $Json; $Out.DropWritten = $true } catch { $Msgs += "DFS: $($_.Exception.Message)" }
    }
    else { $Msgs += 'No Dfs transport: written locally only.' }
    $Out.Message = $Msgs -join ' '
    if ($Msgs -and -not $Out.DropWritten -and $DfsRoot) { Write-RecordLog "Device record not written to DFS: $($Out.Message)" -LogType WARNING }
    #endregion
    if ($PassThru) { $Out.Record = $Record }
}
catch {
    $Out.Message = $_.Exception.Message
    Write-RecordLog "Device record failed: $($_.Exception.Message)" -LogType ERROR
}
$Out

# Example usage:
# PS> C:\SCRIPTS\Applications\PSM\FrontendScriptsSync\Write-DeviceRecord.ps1 -Verbose
# PS> (C:\SCRIPTS\Applications\PSM\FrontendScriptsSync\Write-DeviceRecord.ps1 -DfsRoot C:\Temp\FakeDfs -PassThru).Record | ConvertTo-Json -Depth 6


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCALYJg5zfBEt+hR
# hAyj8ZtFurP0JdhTflVCTqevnvwiV6CCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIBERm+MB
# m2+Qen8WqDgSShCuGiCInoZj4bRu9BVQclt7MA0GCSqGSIb3DQEBAQUABIIBABXo
# 7y6fCADklpFQzHVlpsRl7pkjpQztLUuCgWGMp3n+uC2iQhY9rpL8psUjz/rXE5eX
# w4ktVFm6dXwW7Lu7gQyibnPNrybDWUaBwa72ZZ0o6RETK67Bm3R42J3eeA588jsr
# /LHod1l5SolRCyGO3LErNNMPxP2PnwjkfAsIcybfp2h4v7tH2H8bICKAv4VsxCoL
# /j9GElDQ0h7Ta3kfGcDUhRhsrXpjJRuhZ8JjDDbCPi/erXnuBGCBZKa9DLs6X6kI
# 2m1yMMQskHvy3xvPgCkpuqZvsGPhn15G4KCyTHJxkLE7HS+8+JH1pJdzCnOUai3u
# OojqAAfOkWxumnrBZ56hggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDIyMTkz
# OTUyWjAvBgkqhkiG9w0BCQQxIgQg1tckGXB6cZ1et49nkWH9J/wHtoIufA8hqqPw
# GmNuIUIwDQYJKoZIhvcNAQEBBQAEggIAbqgX7B6w16gBGj/Pd7ykdObhfdaDEmRv
# n4aipwis38WrmjxuF0KZSQZOD9IL5AX4IT4yepkzDp4TQnabflaCHTjMT4AtWZJc
# z8QMg6fdetZUsE0W3yCtz0WnThrVENQYjkoo7mS1nAz2463v523BTKAcmBtdQBQB
# EfiMOQmbmcZiiGNWV9zsznPGJLOwVimddQ5Eoi8aXkB3u2/sIasPryxcpFSlRwtd
# hP9UEjfTvZy0c2KB4WxsTffuMib0skRaWGA/mbAk1CMzsm+Bzzdiq3EVRDJVuI8j
# A7vUl7fIIbomGFGGptg93IKZpRH0Wr76CLPicUz2Kh4wffkZj9tz2/Pjs0/1UOJT
# mOsYeIUzLEmHM+VqiHHbF1g0+138+DCA3ewPa/luEtyY7ASeWJ7t5nvWvupL3eBV
# +LlZWVLJyGDQgSZcKVMfjOJVtDgpNxo2gLvt5N8s9zQDYk/nmMv2HYdZMPHtIc2q
# 108QQsn2Jn/k2aOHj9aGcAzhH1ZNyMxfxupVSNRF3yxFVysE0t+qdgXqo9CaW2fd
# 0k6kf9DK5GPqQqaiS4Sr6rMn6EW1TAyk8Xu0dlSp52agWj54w6aMz4vo94gUoiTl
# ZNA2ork0VqWeszZmHYWYJCmBbIZK8XymY45h4jbGmD0a8CKtQxJ/3Ek78QFQDNUp
# wH+EtvnEo64=
# SIG # End signature block
