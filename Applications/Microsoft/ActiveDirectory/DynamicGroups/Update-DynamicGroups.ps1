<#
.SYNOPSIS
    Keeps Active Directory "dynamic" groups in sync with the server's rules (Data\Rules\DynamicGroupRules.json).
.DESCRIPTION
    For each enabled rule:
      1. Finds the group by sAMAccountName anywhere in the domain. If it does not exist, creates
         it in the rule's Path (OU) with the rule's scope, category and description.
      2. Finds the users that match the rule (LDAP filter built from the criteria, searched
         below SearchBase, disabled users excluded unless IncludeDisabledUsers, ExcludeUsers
         removed).
      3. Adds matching users that are missing and removes user members that no longer match.
         Members that are not users (nested groups, computers, contacts) are left alone.

    Safety checks:
      - If a rule matches nobody but the group has user members, nothing is removed unless the
        rule has AllowEmpty = true (protects against a typo or a failed query emptying a group).
      - A query or AD error skips that group only; other groups still run.
      - Only one run at a time (a scheduled run and a manual "run now" cannot overlap).
      - -WhatIf shows every change without making it.

    Run by the scheduled task \ActiveDirectory\DynamicGroups\UpdateDynamicGroups every 2 hours,
    or on demand (from the editor's "Run Now" button, Start-ScheduledTask, or directly).

    Folder layout (paths are derived from this script's location):
      $SL     C:\SCRIPTS
      $SF     C:\SCRIPTS\Functions                       shared functions (Write-AdvancedLog)
      $SG     C:\SCRIPTS\Logs                            DynamicGroups.log
      $SA     C:\SCRIPTS\Applications                    nearest parent of this script
      $SCA    ...\Microsoft\ActiveDirectory\DynamicGroups this application
      $SCAPF  $SCA\Functions                             this application's functions
              $SCA\Data\DynamicGroups.json               settings and Version (copied with the application)
              $SCA\Data\Rules\DynamicGroupRules.json     the rules (server-local, never copied over)
              $SCA\Logs\Transcripts                      full output of each run
.PARAMETER GroupName
    Only process these groups (names from the rules). Default: all enabled rules.
.PARAMETER IncludeDisabled
    With -GroupName: also run named rules that are disabled (Enabled = false). Without it a
    disabled rule is skipped with a warning, so pausing a rule always holds.
.PARAMETER ConfigPath
    Rules file. Defaults to RulesFile in Data\DynamicGroups.json (Data\Rules\DynamicGroupRules.json).
.PARAMETER Server
    Domain controller to use. Defaults to Server in Data\DynamicGroups.json, otherwise a writable
    DC is discovered. One DC is used for the whole run.
.PARAMETER TranscriptRetentionDays
    Transcripts older than this are deleted. Defaults to TranscriptRetentionDays in the settings (30).
.EXAMPLE
    PS> .\Update-DynamicGroups.ps1 -WhatIf
.EXAMPLE
    PS> .\Update-DynamicGroups.ps1 -GroupName DEPT-ExecutiveDirectors
.INPUTS
    None
.OUTPUTS
    Exit code 0 on success, 1 if any group had a warning or error.
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-19
    Time: 09:45:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 1.1.0
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: Claude

    The account that runs this needs, on the group OUs: create group objects, and write the
    member and description attributes of the managed groups.

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
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]]$GroupName,

    [switch]$IncludeDisabled,

    [string]$ConfigPath,

    [string]$Server,

    [int]$TranscriptRetentionDays
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'Update-DynamicGroups.ps1'

#region Standard locations
$SCA = $PSScriptRoot
$SA  = $SCA
while ($SA -and (Split-Path -Path $SA -Leaf) -ne 'Applications') { $SA = Split-Path -Path $SA -Parent }
if (-not $SA) { throw "$SCA is not inside an 'Applications' folder." }
$SL    = Split-Path -Path $SA -Parent
$SF    = Join-Path -Path $SL -ChildPath 'Functions'
$SG    = Join-Path -Path $SL -ChildPath 'Logs'
$SCAPF = Join-Path -Path $SCA -ChildPath 'Functions'
#endregion

#region Application functions and settings
foreach ($F in 'Get-DynamicGroupSetting.ps1', 'ConvertTo-DynamicGroupLdapFilter.ps1', 'Get-DynamicGroupConfig.ps1', 'Get-DynamicGroupTargetMember.ps1') {
    . (Join-Path -Path $SCAPF -ChildPath $F)
}
$App = Get-DynamicGroupSetting -ApplicationPath $SCA
# Rules: -ConfigPath, else the server's rules file (or the 1.0.0 location until the installer moves it)
$RulesProblem = ''
if (-not $ConfigPath) {
    if ($App.RulesSource -in 'Rules', 'Legacy') { $ConfigPath = $App.ReadPath }
    else { $RulesProblem = "No rules on this server ($($App.RulesPath)). Run Install-DynamicGroups.ps1, then add rules with Show-DynamicGroupEditor.ps1." }
}
$Config      = Get-DynamicGroupConfig -Path $ConfigPath -AppSetting $App
$LogFileName = $Config.Settings.LogFileName
if (-not $PSBoundParameters.ContainsKey('TranscriptRetentionDays')) { $TranscriptRetentionDays = $App.TranscriptRetentionDays }
#endregion

#region Logging
$TranscriptDir = Join-Path -Path $SCA -ChildPath 'Logs\Transcripts'
New-Item -ItemType Directory -Path $SG, $TranscriptDir -Force -WhatIf:$false | Out-Null
$TextLog    = Join-Path -Path $SG -ChildPath "$LogFileName.log"
$Transcript = Join-Path -Path $TranscriptDir -ChildPath ('{0}_{1:yyyyMMdd_HHmmss}.log' -f $LogFileName, (Get-Date))
Start-Transcript -Path $Transcript -WhatIf:$false | Out-Null

$WriteLogPath = Join-Path -Path $SF -ChildPath 'Write-AdvancedLog.ps1'
if (Test-Path -Path $WriteLogPath) { . $WriteLogPath }
else { Write-Warning "Write-AdvancedLog not found at $WriteLogPath. Logging to transcript only." }

$Script:ExitCode = 0
$Prefix = if ($WhatIfPreference) { '[WhatIf] ' } else { '' }

function Write-RunLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR')]
        [string]$LogType = 'INFO'
    )

    if ($LogType -ne 'INFO') { $Script:ExitCode = 1 }
    $Message = "$Prefix$Message"
    if ($LogType -eq 'WARNING') { Write-Warning $Message } else { Write-Host "[$LogType] $Message" }

    if (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue) {
        $LogArgs = @{
            Message     = $Message
            ScriptName  = $ScriptName
            LogFileName = $LogFileName
            LogFile     = $TextLog
            LogType     = $LogType
        }
        if ($LogType -ne 'INFO') { $LogArgs.WriteEventLog = $true }
        # Logging must happen even under -WhatIf (Write-AdvancedLog has no -WhatIf parameter)
        $WhatIfPreference = $false
        try { Write-AdvancedLog @LogArgs }
        catch { Write-Host "Write-AdvancedLog failed: $($_.Exception.Message)" }
    }
}

function Format-NameList {
    param([string[]]$Names, [int]$Max = 15)
    $List = @($Names | Sort-Object)
    if ($List.Count -le $Max) { return ($List -join ', ') }
    '{0} and {1} more' -f (($List | Select-Object -First $Max) -join ', '), ($List.Count - $Max)
}
#endregion

# Only one run at a time
$Mutex = New-Object System.Threading.Mutex($false, 'Global\GGI_UpdateDynamicGroups')
$HaveMutex = $false
try { $HaveMutex = $Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $HaveMutex = $true }

try {
    if (-not $HaveMutex) {
        Write-RunLog 'Another run is already in progress; this run was skipped.'
        return
    }
    if ($RulesProblem) {
        Write-RunLog $RulesProblem -LogType WARNING
        exit 1   # the finally block below still runs (mutex, transcript)
    }
    if ($App.RulesSource -eq 'Legacy' -and $ConfigPath -eq $App.LegacyPath) {
        Write-RunLog "Rules read from the 1.0.0 location $ConfigPath. Run Install-DynamicGroups.ps1 to move them to $($App.RulesPath)." -LogType WARNING
    }

    Import-Module ActiveDirectory -ErrorAction Stop

    if (-not $Server) { $Server = $Config.Settings.Server }
    if (-not $Server) { $Server = "$((Get-ADDomainController -Discover -Writable -ErrorAction Stop).HostName)" }
    $AD = @{ Server = $Server; ErrorAction = 'Stop' }

    $Rules = @($Config.Groups | Where-Object { $_.Enabled })
    if ($GroupName) {
        $Missing = @($GroupName | Where-Object { $_ -notin @($Config.Groups.Name) })
        foreach ($M in $Missing) { Write-RunLog "Group '$M' is not in $ConfigPath." -LogType WARNING }
        $Rules = @($Config.Groups | Where-Object { $_.Name -in $GroupName })
        if (-not $IncludeDisabled) {
            foreach ($D in @($Rules | Where-Object { -not $_.Enabled })) {
                Write-RunLog "$($D.Name): rule is disabled; skipped. Add -IncludeDisabled to run it anyway." -LogType WARNING
            }
            $Rules = @($Rules | Where-Object { $_.Enabled })
        }
    }

    Write-RunLog ("Run started on {0} by {1}. DC {2}. {3} rule(s)." -f $env:COMPUTERNAME, "$env:USERDOMAIN\$env:USERNAME", $Server, $Rules.Count)

    $Totals = @{ Added = 0; Removed = 0; Created = 0; Failed = 0 }

    foreach ($Rule in $Rules) {
        $Name = $Rule.Name
        try {
            if (-not $Name) { throw 'Rule has no Name.' }
            if (-not $Rule.Path) { throw 'Rule has no Path (OU for the group).' }
            if ($Rule.GroupScope -notin 'Global', 'Universal', 'DomainLocal') { throw "GroupScope '$($Rule.GroupScope)' is not Global, Universal or DomainLocal." }
            if ($Rule.GroupCategory -notin 'Security', 'Distribution') { throw "GroupCategory '$($Rule.GroupCategory)' is not Security or Distribution." }

            # 1. Target members (query first: a bad rule should not create an empty group)
            $Targets = @(Get-DynamicGroupTargetMember -Rule $Rule -Server $Server)
            $TargetByDn = @{}
            foreach ($U in $Targets) { $TargetByDn[$U.DistinguishedName.ToLower()] = $U }

            # 2. The group
            $SafeName = $Name -replace '\\', '\5c' -replace '\*', '\2a' -replace '\(', '\28' -replace '\)', '\29'
            $Group = Get-ADGroup @AD -LDAPFilter "(sAMAccountName=$SafeName)" -Properties member, description

            if (-not $Group) {
                Get-ADObject @AD -Identity $Rule.Path | Out-Null   # the OU must exist
                if ($PSCmdlet.ShouldProcess("$Name in $($Rule.Path)", 'Create group')) {
                    $Group = New-ADGroup @AD -Name $Name -SamAccountName $Name -Path $Rule.Path `
                        -GroupScope $Rule.GroupScope -GroupCategory $Rule.GroupCategory `
                        -Description $Rule.Description -PassThru
                    $Group = Get-ADGroup @AD -Identity $Group.ObjectGUID -Properties member, description
                }
                $Totals.Created++
                Write-RunLog "${Name}: created in $($Rule.Path)."
            }
            else {
                $ParentDn = $Group.DistinguishedName -replace '^CN=(\\,|[^,])+,', ''
                if ($ParentDn -ne $Rule.Path) {
                    Write-RunLog "${Name}: group is in $ParentDn, not the configured $($Rule.Path). Managing it where it is." -LogType WARNING
                }
                if ($Rule.Description -and "$($Group.Description)" -ne $Rule.Description) {
                    if ($PSCmdlet.ShouldProcess($Name, 'Update description')) {
                        Set-ADGroup @AD -Identity $Group.ObjectGUID -Description $Rule.Description
                    }
                }
            }

            # 3. Current direct members
            $CurrentDns = @(if ($Group) { $Group.member })
            $CurrentSet = @{}
            foreach ($Dn in $CurrentDns) { $CurrentSet[$Dn.ToLower()] = $Dn }

            # Users to add
            $ToAdd = @($TargetByDn.Keys | Where-Object { -not $CurrentSet.ContainsKey($_) } | ForEach-Object { $TargetByDn[$_] })

            # Members that no longer match: remove users only
            $ToRemove = @()
            $Kept = @()
            foreach ($Key in @($CurrentSet.Keys | Where-Object { -not $TargetByDn.ContainsKey($_) })) {
                $Obj = Get-ADObject @AD -Identity $CurrentSet[$Key] -Properties objectClass, sAMAccountName
                $Classes = @($Obj.objectClass)
                if ($Classes -contains 'user' -and $Classes -notcontains 'computer') { $ToRemove += $Obj }
                else { $Kept += $Obj }
            }

            $CurrentUserCount = $CurrentDns.Count - $Kept.Count
            if ($Targets.Count -eq 0 -and $CurrentUserCount -gt 0 -and -not $Rule.AllowEmpty) {
                Write-RunLog ("{0}: rule matched no users but the group has {1} user member(s). Nothing removed. Check the rule, or set AllowEmpty to true if the group really should be empty." -f $Name, $CurrentUserCount) -LogType WARNING
                $ToRemove = @()
            }

            if ($ToAdd.Count -gt 0 -and $PSCmdlet.ShouldProcess($Name, "Add $($ToAdd.Count) member(s)")) {
                if ($Group) { Add-ADGroupMember @AD -Identity $Group.ObjectGUID -Members @($ToAdd | ForEach-Object { $_.DistinguishedName }) }
            }
            if ($ToRemove.Count -gt 0 -and $PSCmdlet.ShouldProcess($Name, "Remove $($ToRemove.Count) member(s)")) {
                Remove-ADGroupMember @AD -Identity $Group.ObjectGUID -Members @($ToRemove | ForEach-Object { $_.DistinguishedName }) -Confirm:$false
            }

            $Totals.Added   += $ToAdd.Count
            $Totals.Removed += $ToRemove.Count

            $Msg = '{0}: {1} matching user(s); added {2}, removed {3}.' -f $Name, $Targets.Count, $ToAdd.Count, $ToRemove.Count
            if ($ToAdd.Count)    { $Msg += ' Added: '   + (Format-NameList -Names @($ToAdd | ForEach-Object { $_.SamAccountName })) + '.' }
            if ($ToRemove.Count) { $Msg += ' Removed: ' + (Format-NameList -Names @($ToRemove | ForEach-Object { $_.sAMAccountName })) + '.' }
            if ($Kept.Count)     { $Msg += " Left alone (not users): $($Kept.Count)." }
            Write-RunLog $Msg
        }
        catch {
            $Totals.Failed++
            Write-RunLog "${Name}: skipped. $($_.Exception.Message)" -LogType ERROR
        }
    }

    Write-RunLog ('Run finished. Groups: {0} processed, {1} created, {2} failed. Members: +{3} / -{4}.' -f $Rules.Count, $Totals.Created, $Totals.Failed, $Totals.Added, $Totals.Removed)
}
catch {
    Write-RunLog "Run failed: $($_.Exception.Message)" -LogType ERROR
}
finally {
    $WhatIfPreference = $false   # cleanup below must run even under -WhatIf
    if ($HaveMutex) { $Mutex.ReleaseMutex() }
    $Mutex.Dispose()
    Get-ChildItem -Path $TranscriptDir -Filter "$LogFileName*.log" -ErrorAction SilentlyContinue |
        Where-Object LastWriteTime -lt (Get-Date).AddDays(-$TranscriptRetentionDays) |
        Remove-Item -ErrorAction SilentlyContinue -WhatIf:$false
    Stop-Transcript | Out-Null
}

exit $Script:ExitCode

# Example usage:
# PS> C:\SCRIPTS\Applications\Microsoft\ActiveDirectory\DynamicGroups\Update-DynamicGroups.ps1 -WhatIf
# PS> C:\SCRIPTS\Applications\Microsoft\ActiveDirectory\DynamicGroups\Update-DynamicGroups.ps1 -GroupName DEPT-ExecutiveDirectors
# PS> C:\SCRIPTS\Applications\Microsoft\ActiveDirectory\DynamicGroups\Update-DynamicGroups.ps1 -GroupName DEPT-Test -IncludeDisabled -WhatIf


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDP54QKBwW51ine
# btC0qTIKbLBG5p9XhE+/kigt/tcG+6CCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIMNv3y/u
# X+h5So9iq489iuiNmMcpkuvDGyUOIME8H9S8MA0GCSqGSIb3DQEBAQUABIIBAALg
# EoOlPb2xU9jIMX3G1cJg9n9hFtQ6/lnfy33uuC27V1Ldllpc3Wx+Oi7ECE4fYOO6
# p5Djz8PYQr76Ss3WAGc4xOSq6dckelYrqkNuJV0MnF7PfKq6sLFZoDP8xJ3qIYWY
# SNRH3nZ9Y4trgmBNufnJQkn99KaP44QOy95u4SLbwsXouqy1mD2aPmqyz4+SbBuo
# t50hSarF3p8I5+rtyxVDBFpOCl3+PaBK+VoAYi75O9Qgbm9fg9LErYSpLfr/vb8R
# rXu6nIJFWMR/0AZcgZiKEgyEwfqEBYlDWoDaEryYFht9Vmlxg4bHmUhBxpa4/7Y5
# tNshdw2bdL1OM8zvZnmhggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDE5MTc1
# ODA5WjAvBgkqhkiG9w0BCQQxIgQgjkmwMHuA/rT+xJ7Nqkm7WfwXDRp7SZ6LE1jS
# 0cLFniIwDQYJKoZIhvcNAQEBBQAEggIAcOrYPCtOMSMHPuVMyAiNTtERaPYNAiM4
# rMnyT++wP0GSZ+6l3qzQ4bQI5M2X0tgAQR5ZxOX8u54i6KCmDzuGVyyfy0kF0Pqy
# jQt/4oCYerD6LN0RGmL+g3cLpJesjbDZIhHTS4h2uZrL2b6iGX3BsoZzHeA1Ea8o
# A+LeZJ8YVC1yvIyDCAV0moNVm7EHGuFt7GYPIc4boXbbeCUfOeTZYTYgNYybxjTa
# 7cj3gB2ZxTB1JlcNaeiLX0P9FLf1QEtrPNwJSzpBy9BgtahiVFej4SsTV8h1oVRo
# ijatib+z4JgJ7AGtLU4Qvenu8MIiXtm3jRMAox2ZGnCg/nwpiIeVCvsiEL1axZZy
# An63n6efC4dRAhJl44ECgQi8TMD8DxpNFPFp9YehDwiGJysdB7Bm+/z5RaI4Sxt7
# JAT5FnpDQ5suiIZLvNVbQHX6rO+SbltNunt4e5vKOgXGQdRUCDvn16y8yK09jKku
# WWqbAP/V3y+mXjGOinR2HIH0B7zdlEq9r+PQdo6qlWV0eMGwgxmp3wDAWYqV3pRa
# 6D08P1n8ChIe7CVX+8FJS5iRLSNpTPNPTBR0QpXYcE6GuhaVsr/cok3dfXlUbY1X
# WC0iP0zy9u+eWbSscKMB3FdvQXfe0djk3HTV9iTuNMroFT51xe9h0OMQa4+YMgoW
# UJ2qaJhtnPM=
# SIG # End signature block
