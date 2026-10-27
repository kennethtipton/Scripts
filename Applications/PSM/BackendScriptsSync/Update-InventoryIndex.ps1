<#
.SYNOPSIS
    Builds Inventory.json from every device's update.<DEVICE>.<Application>.json in the DFS drop folder.
.DESCRIPTION
    Runs on the inventory server only (InventoryServer in C:\SCRIPTS\Data\Settings\Scripts.json),
    as a scheduled task every few minutes (Install-BackendScriptsSync.ps1 creates it). On any other
    computer it logs a warning and stops, unless -Force is used.

    Each run rebuilds Inventory.json from scratch from all update.*.json files, so a bad or partial
    run never damages the inventory; the next run simply produces it again. The new file is written
    under a temporary name and renamed over the old one; the previous version is kept as
    Inventory.json.bak.

    A drop file is used only when:
      - its name is update.<DEVICE>.<Application>.json and its Device/Application values match it;
      - it is valid JSON;
      - its owner is the device itself (DOMAIN\DEVICE$), the local Administrators/SYSTEM of the file
        server, or a member of Domain Admins or the Scripts administrators group (Groups.Administrators).
    Anything else is listed under Skipped in Inventory.json and in the log.

    Devices whose last update is older than StaleDays are marked Stale.

    Device records (device.<DEVICE>.json, written by Write-DeviceRecord.ps1 after every Frontend
    sync: the server, its PSM state, apps and unmanaged content) are checked the same way (name,
    JSON, owner) and listed under Devices, each with MinutesAgo and Stale (no report for more than
    DeviceRecord.StaleMinutes, default 150). A device turning stale is logged as a warning once,
    and again (as information) when it reports again.

    Inventory.json:
      { "Generated": "...", "GeneratedBy": "SRV...", "Source": "\\\\...\\Applications\\Data", "StaleDays": 7,
        "Applications": [ { "Name": "PoshAcme", "Devices": [ { "Device": "...", "Domain": "...", "Version": "...",
          "Updated": "...", "Stale": false, "Actions": { "Installed": {...}, "Copied": {...} } } ] } ],
        "Devices": [ { "Device": "...", "Domain": "...", "Updated": "...", "MinutesAgo": 12, "Stale": false,
          "Record": { device.<DEVICE>.json } } ],
        "Skipped": [ { "File": "...", "Reason": "..." } ] }
.PARAMETER SettingsPath
    Settings file. Defaults to C:\SCRIPTS\Data\Settings\Scripts.json.
.PARAMETER Force
    Run although this computer is not the InventoryServer (for testing).
.PARAMETER LogFileName
    Base name of the text log file in the Logs folder.
.EXAMPLE
    PS> C:\SCRIPTS\Applications\PSM\BackendScriptsSync\Update-InventoryIndex.ps1
.EXAMPLE
    PS> C:\SCRIPTS\Applications\PSM\BackendScriptsSync\Update-InventoryIndex.ps1 -Verbose
.INPUTS
    None
.OUTPUTS
    Exit code 0 on success, 1 on failure.
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-13
    Time: 17:00:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 1.3.0
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: Claude

    Copyright (c) 2026
    Licensed under the MIT License.
    Full text available at: https://opensource.org/licenses/MIT

    Overide Variables
    Overide Filename:
    Overide Log Filename: Update-InventoryIndex
    Overide Text Log File Path:
    Overide Log Type:
.LINK
    https://www.tnandc.com
#>
[CmdletBinding()]
param(
    [string]$SettingsPath,
    [switch]$Force,
    [string]$LogFileName = 'Update-InventoryIndex'
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'Update-InventoryIndex.ps1'

#region Standard locations
$SCA = $PSScriptRoot                           # C:\SCRIPTS\Applications\PSM\BackendScriptsSync
$SA  = $SCA
while ($SA -and (Split-Path -Path $SA -Leaf) -ne 'Applications') { $SA = Split-Path -Path $SA -Parent }
if (-not $SA) { throw "$SCA is not inside an 'Applications' folder." }
$SL  = Split-Path -Path $SA -Parent            # C:\SCRIPTS
$SF  = Join-Path -Path $SL -ChildPath 'Functions'
if (-not $SettingsPath) { $SettingsPath = Join-Path -Path $SL -ChildPath 'Data\Settings\Scripts.json' }
#endregion

#region Functions and logging
foreach ($F in 'Write-AdvancedLog.ps1', 'Get-ApplicationSettings.ps1', 'Get-ScriptsTransport.ps1') {
    $P = Join-Path -Path $SF -ChildPath $F
    if (Test-Path -Path $P) { . $P }
}
function Write-IndexLog {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO', 'WARNING', 'ERROR')][string]$LogType = 'INFO')
    if ($LogType -eq 'WARNING') { Write-Warning $Message } elseif ($LogType -eq 'ERROR') { Write-Host $Message -ForegroundColor Red } else { Write-Verbose $Message }
    if (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue) {
        $LogArgs = @{ Message = $Message; ScriptName = $ScriptName; LogFileName = $LogFileName; LogType = $LogType }
        if ($LogType -ne 'INFO') { $LogArgs.WriteEventLog = $true }
        try { Write-AdvancedLog @LogArgs } catch { Write-Warning "Write-AdvancedLog failed: $($_.Exception.Message)" }
    }
}
#endregion

#region Trusted writers
# Owner of a drop file must be the device, the file server's own admins, or a Scripts/Domain admin.
$TrustCache = @{}
function Get-GroupDn {
    param([string]$Filter)
    try { $R = ([adsisearcher]$Filter).FindOne(); if ($R) { "$($R.Properties.distinguishedname)" } } catch { $null }
}
$AdminGroupDns = @()
function Test-TrustedWriter {
    param([string]$Owner, [string]$Device)
    if (-not $Owner) { return $false }
    $Key = "$Owner|$Device"
    if ($TrustCache.ContainsKey($Key)) { return $TrustCache[$Key] }
    $Sam = ($Owner -split '\\')[-1]
    $Ok = $false
    if ($Owner -match '^(BUILTIN\\Administrators|NT AUTHORITY\\SYSTEM)$') { $Ok = $true }
    elseif ($Sam -ieq "$Device`$") { $Ok = $true }
    else {
        foreach ($Dn in $AdminGroupDns) {
            try {
                $Hit = ([adsisearcher]"(&(sAMAccountName=$Sam)(memberOf:1.2.840.113556.1.4.1941:=$Dn))").FindOne()
                if ($Hit) { $Ok = $true; break }
            }
            catch { }
        }
    }
    $TrustCache[$Key] = $Ok
    $Ok
}
#endregion

$ExitCode = 0
try {
    #region Settings and server check
    if (-not (Test-Path -Path $SettingsPath)) { throw "Settings file not found: $SettingsPath" }
    $Cfg = if (Get-Command -Name Get-ApplicationSettings -ErrorAction SilentlyContinue) { Get-ApplicationSettings -Path $SettingsPath } else { Get-Content -Path $SettingsPath -Raw | ConvertFrom-Json }

    $MyFqdn = ('{0}.{1}' -f $env:COMPUTERNAME, (Get-CimInstance -ClassName Win32_ComputerSystem).Domain).ToLower()
    $Target = "$($Cfg.InventoryServer)".ToLower()
    $IsServer = $Target -and ($Target -eq $MyFqdn -or ($Target -split '\.')[0] -eq $env:COMPUTERNAME.ToLower())
    if (-not $IsServer -and -not $Force) {
        Write-IndexLog "$env:COMPUTERNAME is not the inventory server ($($Cfg.InventoryServer) in $SettingsPath); nothing done. Use -Force to run anyway." -LogType WARNING
        exit 0
    }
    $DfsRoot = "$((Get-ScriptsTransport -Settings $Cfg -Type Dfs | Select-Object -First 1).Root)"
    if (-not $DfsRoot) { throw "No enabled Dfs transport in $SettingsPath (Transports)." }
    $Drop = Join-Path -Path $DfsRoot -ChildPath "$($Cfg.InventoryFolder)"
    if (-not (Test-Path -Path $Drop)) { throw "Drop folder $Drop is not reachable." }
    $StaleDays = if ($Cfg.StaleDays) { [int]$Cfg.StaleDays } else { 7 }

    $AdminGroupDns = @(
        # Domain Admins: the domain's SID + -512 (a wildcard search on objectSid is not supported)
        try {
            $DomainEntry = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().GetDirectoryEntry()
            $DomainSid = New-Object System.Security.Principal.SecurityIdentifier($DomainEntry.Properties['objectSid'][0], 0)
            "$(([adsi]"LDAP://<SID=$($DomainSid.Value)-512>").Properties['distinguishedName'])"
        }
        catch { Write-IndexLog "Cannot find the Domain Admins group: $($_.Exception.Message)" -LogType WARNING }
        if ($Cfg.Groups -and $Cfg.Groups.Administrators) { Get-GroupDn -Filter "(&(objectCategory=group)(sAMAccountName=$($Cfg.Groups.Administrators)))" }
    ) | Where-Object { $_ }
    #endregion

    #region Read the drop files
    $Devices = New-Object System.Collections.Generic.List[object]
    $Skipped = New-Object System.Collections.Generic.List[object]
    $Now = Get-Date
    foreach ($F in Get-ChildItem -Path $Drop -Filter 'update.*.json' -File -ErrorAction Stop) {
        if ($F.Name -notmatch '^update\.([^.]+)\.(.+)\.json$') { $Skipped.Add([pscustomobject]@{ File = $F.Name; Reason = 'Name is not update.<DEVICE>.<Application>.json' }); continue }
        $NameDevice = $Matches[1]; $NameApp = $Matches[2]
        try { $R = Get-Content -Path $F.FullName -Raw | ConvertFrom-Json }
        catch { $Skipped.Add([pscustomobject]@{ File = $F.Name; Reason = "Not valid JSON: $($_.Exception.Message)" }); continue }
        if ("$($R.Device)" -ne $NameDevice -or "$($R.Application)" -ne $NameApp) {
            $Skipped.Add([pscustomobject]@{ File = $F.Name; Reason = "Content is for $($R.Device)/$($R.Application), not $NameDevice/$NameApp" }); continue
        }
        $Owner = try { (Get-Acl -Path $F.FullName).Owner } catch { '' }
        if (-not (Test-TrustedWriter -Owner $Owner -Device $NameDevice)) {
            $Skipped.Add([pscustomobject]@{ File = $F.Name; Reason = "Owner '$Owner' is neither the device nor a Scripts/Domain admin" }); continue
        }
        # PowerShell 7 already turns the ISO date into a DateTime; 5.1 leaves a string
        [datetime]$Updated = [datetime]::MinValue
        if ($R.Updated -is [datetime]) { $Updated = $R.Updated } else { [void][datetime]::TryParse("$($R.Updated)", [ref]$Updated) }
        $Devices.Add([pscustomobject]@{
            Application = $NameApp
            Device      = $NameDevice
            Domain      = "$($R.Domain)"
            Version     = "$($R.Version)"
            Updated     = "$($R.Updated)"
            Stale       = ($Updated -eq [datetime]::MinValue) -or (($Now - $Updated).TotalDays -gt $StaleDays)
            Actions     = $R.Actions
        })
    }
    #endregion

    #region Device records (device.<DEVICE>.json, Write-DeviceRecord.ps1 on each Frontend)
    $DeviceStaleMinutes = if ($Cfg.DeviceRecord -and "$($Cfg.DeviceRecord.StaleMinutes)" -match '^\d+$') { [int]$Cfg.DeviceRecord.StaleMinutes } else { 150 }
    $DeviceList = New-Object System.Collections.Generic.List[object]
    foreach ($F in Get-ChildItem -Path $Drop -Filter 'device.*.json' -File -ErrorAction Stop) {
        if ($F.Name -notmatch '^device\.([^.]+)\.json$') { $Skipped.Add([pscustomobject]@{ File = $F.Name; Reason = 'Name is not device.<DEVICE>.json' }); continue }
        $NameDevice = $Matches[1]
        try { $R = Get-Content -Path $F.FullName -Raw | ConvertFrom-Json }
        catch { $Skipped.Add([pscustomobject]@{ File = $F.Name; Reason = "Not valid JSON: $($_.Exception.Message)" }); continue }
        if ("$($R.Device)" -ne $NameDevice) { $Skipped.Add([pscustomobject]@{ File = $F.Name; Reason = "Content is for $($R.Device), not $NameDevice" }); continue }
        $Owner = try { (Get-Acl -Path $F.FullName).Owner } catch { '' }
        if (-not (Test-TrustedWriter -Owner $Owner -Device $NameDevice)) {
            $Skipped.Add([pscustomobject]@{ File = $F.Name; Reason = "Owner '$Owner' is neither the device nor a Scripts/Domain admin" }); continue
        }
        [datetime]$Updated = [datetime]::MinValue
        if ($R.Updated -is [datetime]) { $Updated = $R.Updated } else { [void][datetime]::TryParse("$($R.Updated)", [ref]$Updated) }
        $Minutes = if ($Updated -eq [datetime]::MinValue) { -1 } else { [int]($Now - $Updated).TotalMinutes }
        $DeviceList.Add([pscustomobject]@{
            Device     = $NameDevice
            Domain     = "$($R.Domain)"
            Updated    = "$($R.Updated)"
            MinutesAgo = $Minutes
            Stale      = ($Minutes -lt 0) -or ($Minutes -gt $DeviceStaleMinutes)
            Record     = $R
        })
    }
    #endregion

    #region Write Inventory.json
    $Apps = @($Devices | Group-Object Application | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{
            Name    = $_.Name
            Devices = @($_.Group | Sort-Object Device | Select-Object Device, Domain, Version, Updated, Stale, Actions)
        }
    })
    # Built as a table first: Windows PowerShell 5.1 cannot cast [ordered] with a List value directly
    $IndexTable = [ordered]@{
        Generated    = $Now.ToString('s')
        GeneratedBy  = $env:COMPUTERNAME
        Source       = $Drop
        StaleDays    = $StaleDays
        DeviceStaleMinutes = $DeviceStaleMinutes
        Applications = [object[]]$Apps
        Devices      = [object[]]@($DeviceList | Sort-Object Device)
        Skipped      = [object[]]$Skipped.ToArray()
    }
    $Index = New-Object -TypeName PSObject -Property $IndexTable
    $Json = $Index | ConvertTo-Json -Depth 14

    $IndexPath = Join-Path -Path $Drop -ChildPath 'Inventory.json'
    # Log only when the content changed (ignoring the Generated time), so a quiet run leaves no noise
    $Changed = $true
    $WasStale = @(); $WasKnown = @()
    if (Test-Path -Path $IndexPath) {
        try {
            $Old = Get-Content -Path $IndexPath -Raw | ConvertFrom-Json
            $Changed = (($Old.Applications | ConvertTo-Json -Depth 10 -Compress) -ne ($Apps | ConvertTo-Json -Depth 10 -Compress)) -or (@($Old.Skipped).Count -ne $Skipped.Count)
            $WasKnown = @($Old.Devices | ForEach-Object { "$($_.Device)" })
            $WasStale = @($Old.Devices | Where-Object Stale | ForEach-Object { "$($_.Device)" })
        }
        catch { $Changed = $true }
        Copy-Item -Path $IndexPath -Destination "$IndexPath.bak" -Force
    }
    # A device that stops reporting is logged once when it turns stale, and once when it is back
    foreach ($D in $DeviceList) {
        if ($D.Stale -and $WasStale -notcontains $D.Device) { Write-IndexLog "Device $($D.Device) has not reported for $($D.MinutesAgo) minutes (last $($D.Updated)); more than DeviceStaleMinutes $DeviceStaleMinutes." -LogType WARNING }
        elseif (-not $D.Stale -and $WasStale -contains $D.Device) { Write-IndexLog "Device $($D.Device) reports again (last $($D.Updated))." }
        elseif ($WasKnown.Count -and $WasKnown -notcontains $D.Device) { Write-IndexLog "New device record: $($D.Device)." }
    }
    # Ends in .tmp: DFS Replication skips *.tmp (and *.bak) by default
    $Tmp = '{0}.{1}.tmp' -f $IndexPath, [guid]::NewGuid().ToString('N').Substring(0, 8)
    [System.IO.File]::WriteAllText($Tmp, $Json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Path $Tmp -Destination $IndexPath -Force

    $StaleCount = @($Devices | Where-Object Stale).Count
    $Summary = "Inventory.json: $($Apps.Count) application(s), $($Devices.Count) application record(s), $StaleCount stale, $($DeviceList.Count) device(s) ($(@($DeviceList | Where-Object Stale).Count) not reporting), $($Skipped.Count) skipped."
    if ($Changed) { Write-IndexLog $Summary }
    foreach ($S in $Skipped) { Write-IndexLog "Skipped $($S.File): $($S.Reason)" -LogType WARNING }
    Write-Verbose $Summary
    #endregion
}
catch {
    Write-IndexLog "Inventory index failed: $($_.Exception.Message)" -LogType ERROR
    $ExitCode = 1
}

# Central logs: merge what the devices sent (Merge-LogUpdates.ps1); does not change the exit code
$MergeScript = Join-Path -Path $PSScriptRoot -ChildPath 'Merge-LogUpdates.ps1'
if (Test-Path -Path $MergeScript) {
    try {
        $MergeArgs = @{ SettingsPath = $SettingsPath }
        if ($DfsRoot) { $MergeArgs.DfsRoot = $DfsRoot }
        $Merged = & $MergeScript @MergeArgs
        Write-Verbose "Log merge: $($Merged.Records) record(s) from $($Merged.Files) file(s), $($Merged.Failed) failed."
    }
    catch { Write-IndexLog "Log merge failed: $($_.Exception.Message)" -LogType WARNING }
}
exit $ExitCode

# Example usage:
# PS> C:\SCRIPTS\Applications\PSM\BackendScriptsSync\Update-InventoryIndex.ps1 -Verbose
# PS> C:\SCRIPTS\Applications\PSM\BackendScriptsSync\Update-InventoryIndex.ps1 -SettingsPath C:\Temp\Scripts.json -Force -Verbose


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAAdzrKR9U0cDel
# 5q94yDr6yBy4Vgv2dVqmL9mUoj58PaCCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIPdHypoQ
# In4R7sE2q7dieW5TpUEun9YtUIcijTOLSr4lMA0GCSqGSIb3DQEBAQUABIIBAJe8
# rytmXk8jLX1Wm5droUwAO7ph9zRI4lkoRKcxmapODJkuEXE4h3vT4LPe0kPCLHr7
# guW3kYfG45UXF3TJ/rYEQCVXQ8JvcOpkstZR0xWzX0xRGpGEKv3Cjwgsa+Tp6d+m
# QRU1g8IYTTA9qOb9sUirZ5zYig4FbiN565dHWTWpyf1FP3CIqzR3KsVPWP2+g8tQ
# E5T0jNtcwPMfEuynMLNk1IKQYGOG2U7Ql+wRtgKVtdVFRe1MIudXrB0llDv2+4sE
# HBzRhdjmOdonLb4Vv1sIjuTGmDQgzHZTPxqY5+hZS9rqXIfG7F1xHetbQPoKjc4s
# +TUix68Ht6I+M59ulgehggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDIyMTgy
# MjMxWjAvBgkqhkiG9w0BCQQxIgQgajh8ZIqikQxI91P+g9ACVwqaYtTYdfNqDb6N
# CUSAU5wwDQYJKoZIhvcNAQEBBQAEggIAfzPZhUxUQR7rNuy1y7qXNmODNsEzfIOx
# A0dAs35N0dErtknUSu1so9rFMtAfvKJFFtwurjkRWA+PjxxuNiJhoA1iAJuMpJ3q
# EoPtGwEwza+XvCzvkIAn0gvhK9DKZQxbY+Iy9Spc6AXOJpdUsqUbqDSne5EF6vR0
# GOZ68IhWQ6XYoAIlIkmzqAzpdxd1n4gVI/Pf1MHy6k684WydavNcrc84e+R/M3/i
# wB44b+DtAR2YqawRQQEQV5S5v9sNnyRhDpdK9fPnhmvBB2GniPxo6cLwSKEwcGrs
# ViWl4IgSPWYU5JCiBRD6d/VbSib4E8fzvN7Whf21Emp5L8PRR/mhHZKxhlVYSnEi
# gHgi376I10uXDvCckXX8Guvv2HZRKKj3AEgu3tLXJf7R3pU1f6npgpEuGEz4klf1
# z2aplWYyesMidzS+av8FALFFKhbiGSbOTz5N4JK9gMENhmKEE8/takwvmTXZBFXo
# igTCJhXqDwVjSYouIa3xOYyDyP/ylmFsEb4YzbYbh1RCL8xKA+Y+QoXtKYZpMOUu
# l/4ejUoxGxx4e+AUv7dyJP4xV9VqNfO0hdG1HfrQuGrbfPVzDUC9J2/2c6HD16Rk
# +ndhzzACQcFkrfmR0O5msNtzxl4pDX9lRuX44ZdWSlSCcc+WcgMUbqJvttzMBMWL
# 9usd3XLP9qI=
# SIG # End signature block
