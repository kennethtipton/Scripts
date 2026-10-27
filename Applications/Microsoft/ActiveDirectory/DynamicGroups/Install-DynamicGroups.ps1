#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets up the DynamicGroups application and its scheduled task.
.DESCRIPTION
    1. Checks prerequisites (Windows PowerShell 5.1, ActiveDirectory module, application files).
    2. Rules: the rules are server-local (Data\Rules\DynamicGroupRules.json) and never part of a
       copy or sync. A rules file from version 1.0.0 (Config\DynamicGroups.json) is moved there,
       with its backups. A server without rules starts from the template, which has no groups:
       add them afterwards with Show-DynamicGroupEditor.ps1.
    3. Permissions: the application folder is restricted to Administrators and SYSTEM (whoever can
       edit the rules decides who lands in the managed groups). A domain or gMSA task account gets
       read/execute on the folder and Modify only on its Logs folder and on C:\SCRIPTS\Logs.
    4. Creates the 'Managed Powershell Scripts' event log source (needs elevation; the task may not
       have it).
    5. Registers the task \ActiveDirectory\DynamicGroups\UpdateDynamicGroups: every IntervalHours
       (Data\DynamicGroups.json, default 2) from the next whole interval, never two runs at once.
    6. Records the install in the PSM inventory (Update-ApplicationInventory), so the PSM Frontend
       keeps the application's files current on this server.
    7. Optionally runs the task once (-RunNow).

    Run from the application folder, in Windows PowerShell 5.1, as an administrator:
      C:\SCRIPTS\Applications\Microsoft\ActiveDirectory\DynamicGroups\Install-DynamicGroups.ps1

    Task account (pick one):
      -RunAsSystem          on a domain controller (SYSTEM acts as the DC's computer account).
      -GmsaAccount NAME$    a group managed service account; no password is stored.
      (neither)             a domain account; you are asked for its password at the console
                            (works over OpenSSH). The password is stored by the Task Scheduler.
    A gMSA or domain account needs, on the group OUs: create group objects, and write member and
    description on the managed groups.
.PARAMETER RunAsSystem
    Run the task as SYSTEM. Intended for domain controllers.
.PARAMETER GmsaAccount
    Run the task as this group managed service account (DOMAIN\name$ or name$). This computer must
    be allowed to retrieve its password (PrincipalsAllowedToRetrieveManagedPassword).
.PARAMETER TaskUser
    Domain account for the task when neither -RunAsSystem nor -GmsaAccount is used. Defaults to
    the current user.
.PARAMETER TaskCredential
    Credential for TaskUser, to skip the password prompt.
.PARAMETER IntervalHours
    Hours between runs. Defaults to IntervalHours in Data\DynamicGroups.json (2).
.PARAMETER RunNow
    Start the task once after registering it.
.EXAMPLE
    PS> .\Install-DynamicGroups.ps1 -RunAsSystem -RunNow
.EXAMPLE
    PS> .\Install-DynamicGroups.ps1 -GmsaAccount 'GENERATIONSGAIT\gmsa-DynGroups$'
.EXAMPLE
    PS> .\Install-DynamicGroups.ps1 -TaskUser 'GENERATIONSGAIT\svc-DynGroups'
.INPUTS
    None
.OUTPUTS
    None
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-19
    Time: 14:00:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 1.1.1
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: Claude

    The repeating trigger without an end date needs Windows Server 2016 or later.

    Copyright (c) 2026
    Licensed under the MIT License.
    Full text available at: https://opensource.org/licenses/MIT

    Overide Variables
    Overide Filename:
    Overide Log Filename: DynamicGroups
    Overide Text Log File Path: C:\SCRIPTS\Logs\DynamicGroups.log
    Overide Log Type:
.LINK
    https://www.tnandc.com
#>
[CmdletBinding(DefaultParameterSetName = 'DomainAccount')]
param(
    [Parameter(ParameterSetName = 'System')]
    [switch]$RunAsSystem,

    [Parameter(ParameterSetName = 'Gmsa', Mandatory = $true)]
    [string]$GmsaAccount,

    [Parameter(ParameterSetName = 'DomainAccount')]
    [string]$TaskUser = "$env:USERDOMAIN\$env:USERNAME",

    [Parameter(ParameterSetName = 'DomainAccount')]
    [pscredential]$TaskCredential,

    [ValidateRange(1, 24)]
    [int]$IntervalHours,

    [switch]$RunNow
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'Install-DynamicGroups.ps1'

#region Standard locations
$SCA = $PSScriptRoot
$SA  = $SCA
while ($SA -and (Split-Path -Path $SA -Leaf) -ne 'Applications') { $SA = Split-Path -Path $SA -Parent }
if (-not $SA) { throw "$SCA is not inside an 'Applications' folder." }
$SL    = Split-Path -Path $SA -Parent
$SF    = Join-Path -Path $SL -ChildPath 'Functions'
$SG    = Join-Path -Path $SL -ChildPath 'Logs'
$SCAPF = Join-Path -Path $SCA -ChildPath 'Functions'

$TaskPath   = '\ActiveDirectory\DynamicGroups\'
$TaskName   = 'UpdateDynamicGroups'
$SyncScript = Join-Path -Path $SCA -ChildPath 'Update-DynamicGroups.ps1'
$AppFiles   = @(
    'Update-DynamicGroups.ps1'
    'Show-DynamicGroupEditor.ps1'
    'Data\DynamicGroups.json'
    'Data\DynamicGroupRules.Template.json'
    'Functions\Get-DynamicGroupSetting.ps1'
    'Functions\ConvertTo-DynamicGroupLdapFilter.ps1'
    'Functions\Get-DynamicGroupConfig.ps1'
    'Functions\Save-DynamicGroupConfig.ps1'
    'Functions\Get-DynamicGroupTargetMember.ps1'
)
#endregion

#region Functions and logging
foreach ($F in 'Write-AdvancedLog.ps1', 'Update-ApplicationInventory.ps1') {
    $P = Join-Path -Path $SF -ChildPath $F
    if (Test-Path -Path $P) { . $P }
}
foreach ($F in 'Get-DynamicGroupSetting.ps1', 'ConvertTo-DynamicGroupLdapFilter.ps1', 'Get-DynamicGroupConfig.ps1') {
    $P = Join-Path -Path $SCAPF -ChildPath $F
    if (-not (Test-Path -Path $P)) { throw "Functions\$F is missing from $SCA." }
    . $P
}
$App = Get-DynamicGroupSetting -ApplicationPath $SCA
$LogFileName = $App.LogFileName
New-Item -ItemType Directory -Path $SG -Force | Out-Null
$TextLog = Join-Path -Path $SG -ChildPath "$LogFileName.log"

function Write-InstallLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR')]
        [string]$LogType = 'INFO'
    )
    if ($LogType -eq 'WARNING') { Write-Warning $Message } else { Write-Host "  $Message" }
    if (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue) {
        $LogArgs = @{ Message = $Message; ScriptName = $ScriptName; LogFileName = $LogFileName; LogFile = $TextLog; LogType = $LogType }
        if ($LogType -ne 'INFO') { $LogArgs.WriteEventLog = $true }
        try { Write-AdvancedLog @LogArgs } catch { Write-Host "  Write-AdvancedLog failed: $($_.Exception.Message)" }
    }
}

function Invoke-Icacls {
    param([string[]]$Arguments, [string]$What)
    & icacls @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed: $What." }
}
#endregion

try {
    Write-InstallLog "Install started on $env:COMPUTERNAME. Application folder: $SCA"

    #region 1. Prerequisites
    Write-Host "`n[1/5] Prerequisites" -ForegroundColor Cyan
    if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Run this in Windows PowerShell 5.1 (powershell.exe), not pwsh.' }
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        throw 'The ActiveDirectory module is not installed. On a server: Install-WindowsFeature RSAT-AD-PowerShell'
    }
    foreach ($Rel in $AppFiles) {
        if (-not (Test-Path -Path (Join-Path -Path $SCA -ChildPath $Rel))) { throw "$Rel is missing from $SCA." }
    }
    if (-not $PSBoundParameters.ContainsKey('IntervalHours')) { $IntervalHours = [Math]::Min([Math]::Max($App.IntervalHours, 1), 24) }
    Write-InstallLog "Prerequisites OK. DynamicGroups $($App.Version)."
    #endregion

    #region 2. Rules (server-local)
    Write-Host "`n[2/5] Rules" -ForegroundColor Cyan
    $RulesDir = Split-Path -Path $App.RulesPath -Parent
    New-Item -ItemType Directory -Path $RulesDir -Force | Out-Null
    if (Test-Path -Path $App.RulesPath -PathType Leaf) {
        Write-InstallLog "Rules kept: $($App.RulesPath)."
    }
    elseif (Test-Path -Path $App.LegacyPath -PathType Leaf) {
        # 1.0.0 layout: Config\DynamicGroups.json (Settings + Groups) and Config\Backups
        $Legacy = Get-DynamicGroupConfig -Path $App.LegacyPath -AppSetting $App
        . (Join-Path -Path $SCAPF -ChildPath 'Save-DynamicGroupConfig.ps1')
        Save-DynamicGroupConfig -Config $Legacy -Path $App.RulesPath -KeepBackups $App.KeepRuleBackups
        $OldBackups = Join-Path -Path (Split-Path -Path $App.LegacyPath -Parent) -ChildPath 'Backups'
        if (Test-Path -Path $OldBackups) {
            $NewBackups = Join-Path -Path $RulesDir -ChildPath 'Backups'
            New-Item -ItemType Directory -Path $NewBackups -Force | Out-Null
            Get-ChildItem -Path $OldBackups -File | Move-Item -Destination $NewBackups -Force
        }
        $Old = Split-Path -Path $App.LegacyPath -Parent
        Move-Item -Path $App.LegacyPath -Destination (Join-Path -Path $RulesDir -ChildPath 'Backups\DynamicGroups_1.0.0.json') -Force
        if (-not @(Get-ChildItem -Path $Old -Recurse -File -ErrorAction SilentlyContinue).Count) { Remove-Item -Path $Old -Recurse -Force }
        Write-InstallLog "Moved $(@($Legacy.Groups).Count) rule(s) from $($App.LegacyPath) to $($App.RulesPath) (1.0.0 file kept in Backups as DynamicGroups_1.0.0.json)."
    }
    else {
        Copy-Item -Path $App.TemplatePath -Destination $App.RulesPath
        Write-InstallLog "No rules on this server yet: created $($App.RulesPath) from the template (no groups). Add rules with Show-DynamicGroupEditor.ps1."
    }
    $Rules = Get-DynamicGroupConfig -Path $App.RulesPath -AppSetting $App
    $RuleCount = @($Rules.Groups).Count
    #endregion

    #region 3. Task account and permissions
    Write-Host "`n[3/5] Task account and permissions" -ForegroundColor Cyan
    $Principal = $null; $Cred = $null
    switch ($PSCmdlet.ParameterSetName) {
        'System' {
            if ((Get-CimInstance -ClassName Win32_ComputerSystem).DomainRole -lt 4) {
                Write-InstallLog "-RunAsSystem on a computer that is not a domain controller: SYSTEM acts as $env:COMPUTERNAME`$ in AD, which needs delegated rights on the group OUs." -LogType WARNING
            }
            $Account = 'NT AUTHORITY\SYSTEM'
            $Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        }
        'Gmsa' {
            $Account = if ($GmsaAccount -match '\\') { $GmsaAccount } else { "$env:USERDOMAIN\$GmsaAccount" }
            if ($Account -notmatch '\$$') { $Account += '$' }
            $Principal = New-ScheduledTaskPrincipal -UserId $Account -LogonType Password -RunLevel Highest
        }
        default {
            $Account = $TaskUser
            # Console prompt instead of Get-Credential: the credential dialog cannot open over OpenSSH.
            $Cred = $TaskCredential
            if (-not $Cred) {
                $Pass = Read-Host -Prompt "Password for $Account (the account the dynamic group task runs as)" -AsSecureString
                if (-not $Pass -or $Pass.Length -eq 0) { throw 'No password supplied; task not registered.' }
                $Cred = New-Object System.Management.Automation.PSCredential($Account, $Pass)
            }
        }
    }

    # Administrators + SYSTEM full control on the application (the rules decide group membership)
    Invoke-Icacls -Arguments @($SCA, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F', '/T', '/Q') -What "restricting $SCA"
    $Granted = "Administrators, SYSTEM"
    if ($PSCmdlet.ParameterSetName -ne 'System') {
        # The task account: read/execute on the application, Modify only where it writes
        $AppLogs = Join-Path -Path $SCA -ChildPath 'Logs'
        New-Item -ItemType Directory -Path $AppLogs -Force | Out-Null
        Invoke-Icacls -Arguments @($SCA, '/grant', "${Account}:(OI)(CI)RX", '/T', '/Q') -What "granting $Account read on $SCA"
        Invoke-Icacls -Arguments @($AppLogs, '/grant', "${Account}:(OI)(CI)M", '/T', '/Q') -What "granting $Account Modify on $AppLogs"
        Invoke-Icacls -Arguments @($SG, '/grant', "${Account}:(OI)(CI)M", '/Q') -What "granting $Account Modify on $SG"
        $Granted += "; $Account read/execute, Modify on Logs and $SG"
    }
    Write-InstallLog "Permissions on ${SCA}: $Granted."
    #endregion

    #region 4. Event log source
    Write-Host "`n[4/5] Event log source" -ForegroundColor Cyan
    $EventSource = 'ManagedPSScripts'; $EventLog = 'Managed Powershell Scripts'
    if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
        [System.Diagnostics.EventLog]::CreateEventSource($EventSource, $EventLog)
        Write-InstallLog "Created event log source $EventSource in '$EventLog'."
    }
    else { Write-InstallLog "Event log source $EventSource already exists." }
    #endregion

    #region 5. Scheduled task
    Write-Host "`n[5/5] Scheduled task $TaskPath$TaskName" -ForegroundColor Cyan
    $Now   = Get-Date
    $Start = $Now.Date.AddHours([Math]::Ceiling(($Now.Hour + 1) / $IntervalHours) * $IntervalHours)
    $Action   = New-ScheduledTaskAction -Execute 'powershell.exe' -WorkingDirectory $SCA `
                -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$SyncScript`""
    $Trigger  = New-ScheduledTaskTrigger -Once -At $Start -RepetitionInterval (New-TimeSpan -Hours $IntervalHours)
    $Settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1) -StartWhenAvailable -MultipleInstances IgnoreNew

    $Reg = @{
        TaskPath    = $TaskPath
        TaskName    = $TaskName
        Action      = $Action
        Trigger     = $Trigger
        Settings    = $Settings
        Description = "Syncs Active Directory dynamic groups from $($App.RulesPath) every $IntervalHours hours. Edit rules with Show-DynamicGroupEditor.ps1. Log: $TextLog"
        Force       = $true
    }
    if ($Principal) { $Reg.Principal = $Principal }
    else { $Reg.User = $Cred.UserName; $Reg.Password = $Cred.GetNetworkCredential().Password; $Reg.RunLevel = 'Highest' }

    Register-ScheduledTask -ErrorAction Stop @Reg | Out-Null
    Write-InstallLog ("Registered task {0}{1} as {2}: every {3} hours from {4:yyyy-MM-dd HH:mm}. {5} rule(s)." -f $TaskPath, $TaskName, $Account, $IntervalHours, $Start, $RuleCount)

    if ($RunNow) {
        Start-ScheduledTask -ErrorAction Stop -TaskPath $TaskPath -TaskName $TaskName
        Write-InstallLog 'Task started once now.'
    }
    #endregion

    if (Get-Command -Name Update-ApplicationInventory -ErrorAction SilentlyContinue) {
        Update-ApplicationInventory -Application 'DynamicGroups' -Action Installed -Version $App.Version `
            -Details @{ Task = "$TaskPath$TaskName"; RunAs = $Account; IntervalHours = $IntervalHours; Rules = $RuleCount } | Out-Null
    }

    Write-InstallLog 'Install completed.'
    Write-Host "`nNext:" -ForegroundColor Green
    if (-not $RuleCount) { Write-Host "  Add rules (none yet)     : & '$(Join-Path $SCA 'Show-DynamicGroupEditor.ps1')'" }
    Write-Host "  Preview what it would do : & '$SyncScript' -WhatIf"
    Write-Host "  Edit the rules           : & '$(Join-Path $SCA 'Show-DynamicGroupEditor.ps1')'"
    Write-Host "  Run on demand            : Start-ScheduledTask -TaskPath '$TaskPath' -TaskName '$TaskName'"
    Write-Host "  Log                      : $TextLog"
}
catch {
    Write-InstallLog "Install failed: $($_.Exception.Message)" -LogType ERROR
    throw
}

# Example usage:
# PS> C:\SCRIPTS\Applications\Microsoft\ActiveDirectory\DynamicGroups\Install-DynamicGroups.ps1 -RunAsSystem -RunNow
# PS> C:\SCRIPTS\Applications\Microsoft\ActiveDirectory\DynamicGroups\Install-DynamicGroups.ps1 -GmsaAccount 'gmsa-DynGroups$'
# PS> C:\SCRIPTS\Applications\Microsoft\ActiveDirectory\DynamicGroups\Install-DynamicGroups.ps1 -TaskUser 'GENERATIONSGAIT\svc-DynGroups'


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAaeenx0KcKJQJ8
# PfFuUtFwYu0PFy+l1ushkIKue1n3DKCCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIBXSEX9O
# PBoWUEpFOMytwfRO49DurqRktOU5gElBPA4uMA0GCSqGSIb3DQEBAQUABIIBAJXU
# 6fCleTHeTgmeiKWLefqirtGbHtAyW+U5VVRLloe6kWErm02bWhldJMsw5RAxHKUb
# 9GOrjDl9MajPofpUmz0CuqP+1i556Ssu5r6YoPjyYZDX+UeVp8JjGHfpGZZaf2yJ
# eGOOyG0MrX1YlLy22QWDr+2c2uzVpL1kF0+LBKhSVZGLTomDi5Nh5J4Xem3wEcvr
# fEs1A+1WD+02u5VsLKl057tyOA271rCZh6kggN4H2tlE4IZ4fyorhhamQEOPva/U
# 7apJjN8k3fhaXf30Ytg5BmC9DSe6tzMlCmGr9HIt+yU9ZuuWYkDVpMl6/IUKQkg0
# aMSghzyVqpPZ8cMhIZChggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDIwMTcx
# MDU4WjAvBgkqhkiG9w0BCQQxIgQg6ad70iuqZLK0N9LVTcaEkYL7LuTOyPPa0cRw
# ZeHqJvcwDQYJKoZIhvcNAQEBBQAEggIAHv0Vi2t6NzVaEIpT3muTIniFEXeVeVL+
# QU3Oopup0K5fNlzse0mNniW6pn93/gQ796lTG9x41hecgbl26CHgirOHFvD22+f0
# i7LELZgZWlHf9FWx2+AW356Sh5nBesM5L0DoczCDUoP7DAYMG9FOJiMDte54J0eK
# aZx1XbSni/Ga96nlVUPR3UCn2Jge2jxK59eEuR0KnWvAZ3xU7YAFgUgtH9mhRtIF
# m2jym4/0vrMo5eGavUkQExFMbzLOt2MTnYAEIR4rpxqP4AmmA2X72OnzJeyyA7L1
# 8KgzrV9vYPXUEr7QlErZmOTYsQyBTg1GOW7r19t27M8lf5JWC6ffMP50fOvMSM3D
# wPbvkk4lGNFzJNbIljVFspZELzWsjKIZCsLQbU9Vj/LV4xUGLtaEaWhhvijc3vDy
# 1ZXrfOHFKb+i4lTB9ymG/UG5QibgfpqFz3McgCEUhgjmcovG68U9JNhOnh7/GD2o
# AKtKioXNhjEr9/s+yLJD1e14Lrsl4frEaEi2rUTnoMCndidxZ8Ss39qG7Ur5tqx1
# BrKjT3HLxwQPiRI3/1wCsdXCLkbCjIZ8ta3aOrPjMEh6w+A1N3pMPUXCi3pDybe7
# pKemgXGlXLU36/YIczwFzbR06tGjzEb8ZTkCa8RSB0xdgbFrHSnpy8U8qpCdtnV+
# nMWCM9IzsYY=
# SIG # End signature block
