<#
.SYNOPSIS
    Sends the new entries of this device's script logs (C:\SCRIPTS\Logs\*.log) to the DFS drop folder,
    where the PSM Backend merges them into the central log store.
.DESCRIPTION
    Part of Powershell Scripts Management (PSM), Frontend. Runs at the end of every
    Sync-ScriptsFromDfs.ps1 run (task \PSM\SyncScriptsFromDfs), or on its own.

    For each top-level *.log in C:\SCRIPTS\Logs (Write-AdvancedLog format
    "yyyy-MM-dd HH:mm:ss | Script: <name> | <TYPE>: <message>"):
      1. Reads and parses the whole file into entries: Time (ISO 8601 with this server's UTC offset),
         Server, Log, Script, Type, Message. Lines that do not start with a timestamp belong to the
         entry above them (multi-line messages). The header line and blank lines are skipped.
      2. Works whatever the order of the lines: Write-AdvancedLog writes newest first (each entry is
         inserted under the header), other writers append. A file that is rewritten or rotated is
         handled the same way.
      3. Sends the entries not sent before. The state file (Logs\Shipping\LogShipping.state.json)
         keeps, per log, the newest time sent and a fingerprint (SHA-1 of time, script, type and
         message, with a count for identical entries) of every entry of the last WindowHours before
         it. An entry is new when it is in that window or later and its fingerprint was not counted
         yet; the window also covers the hour that repeats when daylight saving time ends.
         On a log's first run, entries older than RetentionDays are skipped.
      4. Writes one JSON-lines file per log per run to <DfsRoot>\Logs\Updates\<DEVICE>\ (oldest
         entry first; written as .tmp, then renamed), and only then updates the state. If DFS cannot
         be written, nothing is lost: the same entries are sent next run.

    It never changes the local logs. It writes its own log only for warnings and errors (an INFO
    line every run would itself be shipped every run).

    Settings: LogShipping in C:\SCRIPTS\Data\Settings\Scripts.json (Enabled, UpdatesFolder, Include,
    Exclude, RetentionDays, WindowHours). The computer account needs Modify on
    <DfsRoot>\Logs\Updates (FLD-SCRIPTS.Logs.Updates.EDITORS, through APP-PowershellScriptsManagement.Frontend).
.PARAMETER SettingsPath
    Settings file. Defaults to C:\SCRIPTS\Data\Settings\Scripts.json.
.PARAMETER DfsRoot
    DFS scripts root. Defaults to the Dfs transport's Root in the settings.
.PARAMETER LogFolder
    Folder with the logs to send. Defaults to C:\SCRIPTS\Logs.
.PARAMETER StatePath
    Where the sent-state is kept. Defaults to <LogFolder>\Shipping\LogShipping.state.json.
.EXAMPLE
    PS> C:\SCRIPTS\Applications\PSM\FrontendScriptsSync\Send-LogsToDfs.ps1 -Verbose
.EXAMPLE
    PS> C:\SCRIPTS\Applications\PSM\FrontendScriptsSync\Send-LogsToDfs.ps1 -WhatIf
.INPUTS
    None
.OUTPUTS
    [pscustomobject] Summary: Files, Lines, Records (sent), Sent (update files written), Failed, Messages.
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-22
    Time: 11:45:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 1.1.0
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: Claude

    1.1.0 replaces the byte offsets of 1.0.0 (which assumed appended lines) with fingerprints,
    because Write-AdvancedLog writes newest first.

    Copyright (c) 2026
    Licensed under the MIT License.
    Full text available at: https://opensource.org/licenses/MIT

    Overide Variables
    Overide Filename:
    Overide Log Filename: Send-LogsToDfs
    Overide Text Log File Path:
    Overide Log Type:
.LINK
    https://www.tnandc.com
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SettingsPath,
    [string]$DfsRoot,
    [string]$LogFolder,
    [string]$StatePath
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'Send-LogsToDfs.ps1'

#region Standard locations
$SCA = $PSScriptRoot
$SA  = $SCA
while ($SA -and (Split-Path -Path $SA -Leaf) -ne 'Applications') { $SA = Split-Path -Path $SA -Parent }
if (-not $SA) { throw "$SCA is not inside an 'Applications' folder." }
$SL = Split-Path -Path $SA -Parent
$SF = Join-Path -Path $SL -ChildPath 'Functions'
if (-not $SettingsPath) { $SettingsPath = Join-Path -Path $SL -ChildPath 'Data\Settings\Scripts.json' }
if (-not $LogFolder) { $LogFolder = Join-Path -Path $SL -ChildPath 'Logs' }
if (-not $StatePath) { $StatePath = Join-Path -Path $LogFolder -ChildPath 'Shipping\LogShipping.state.json' }
#endregion

foreach ($F in 'Write-AdvancedLog.ps1', 'Get-ApplicationSettings.ps1', 'Get-ScriptsTransport.ps1') {
    $P = Join-Path -Path $SF -ChildPath $F
    if (Test-Path -Path $P) { . $P }
}
function Write-ShipLog {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO', 'WARNING', 'ERROR')][string]$LogType = 'INFO')
    if ($LogType -eq 'INFO') { Write-Verbose $Message; return }
    Write-Warning $Message
    if (-not $WhatIfPreference -and (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue)) {
        try { Write-AdvancedLog -Message $Message -ScriptName $ScriptName -LogFileName 'Send-LogsToDfs' -LogType $LogType -WriteEventLog } catch { }
    }
}

$LineRx = [regex]'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \| Script: (.*?) \| ([A-Za-z]+): ?(.*)$'
$Sha = New-Object System.Security.Cryptography.SHA1Managed
function Get-Fingerprint {
    param($R)
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes(('{0}|{1}|{2}|{3}' -f $R.Local, $R.Script, $R.Type, $R.Message))
    [System.Convert]::ToBase64String($Sha.ComputeHash($Bytes)).Substring(0, 16)
}

# Whole file -> entries in file order. Each entry: Local (datetime), Script, Type, Message.
function Read-LogEntries {
    param([string]$Path)
    $Fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
    try { $Sr = New-Object System.IO.StreamReader($Fs, [System.Text.Encoding]::Default, $true); $Text = $Sr.ReadToEnd() }
    finally { $Fs.Dispose() }
    $Entries = New-Object System.Collections.Generic.List[object]
    $Last = $null
    $Lines = 0
    foreach ($Line in $Text -split "`r?`n") {
        if (-not $Line.Trim()) { continue }
        $Lines++
        if ($Line -match '^Timestamp \| Script \| Type \| Message') { continue }
        $M = $LineRx.Match($Line)
        if ($M.Success) {
            $Last = [pscustomobject]@{
                Local   = [datetime]::ParseExact($M.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
                Script  = $M.Groups[2].Value
                Type    = $M.Groups[3].Value.ToUpper()
                Message = $M.Groups[4].Value
            }
            $Entries.Add($Last)
        }
        elseif ($Last) { $Last.Message = "$($Last.Message)`n$Line" }
        # text before the first entry (no timestamp) cannot be placed in time; it is skipped
    }
    [pscustomobject]@{ Entries = $Entries; Lines = $Lines }
}

$Summary = [pscustomobject]@{ Files = 0; Lines = 0; Records = 0; Sent = 0; Failed = 0; Messages = New-Object System.Collections.Generic.List[string] }

try {
    #region Settings
    $Cfg = if (Get-Command -Name Get-ApplicationSettings -ErrorAction SilentlyContinue) { Get-ApplicationSettings -Path $SettingsPath } else { Get-Content -Path $SettingsPath -Raw | ConvertFrom-Json }
    $S = $Cfg.LogShipping
    $Get = { param($Name, $Default) if ($S -and $S.PSObject.Properties[$Name] -and "$($S.$Name)" -ne '') { $S.$Name } else { $Default } }
    if (-not [bool](& $Get 'Enabled' $true)) { Write-Verbose 'Log shipping is disabled (LogShipping.Enabled).'; return $Summary }
    $UpdatesFolder = "$(& $Get 'UpdatesFolder' 'Logs\Updates')"
    $Include       = @(& $Get 'Include' @('*.log'))
    $Exclude       = @(& $Get 'Exclude' @())
    $RetentionDays = [int](& $Get 'RetentionDays' 90)
    $WindowHours   = [int](& $Get 'WindowHours' 48)
    if (-not $DfsRoot) {
        $Dfs = @(Get-ScriptsTransport -Settings $Cfg) | Where-Object { $_.Type -eq 'Dfs' } | Select-Object -First 1
        if (-not $Dfs) { Write-Verbose 'No enabled Dfs transport: logs are kept locally only.'; return $Summary }
        $DfsRoot = $Dfs.Root
    }
    $Device = $env:COMPUTERNAME.ToUpper()
    $Target = Join-Path -Path (Join-Path -Path $DfsRoot.TrimEnd('\') -ChildPath $UpdatesFolder) -ChildPath $Device
    #endregion

    #region State: per log { Last = newest local time sent; Seen = { fingerprint = count } }
    $State = @{}
    if (Test-Path -Path $StatePath -PathType Leaf) {
        try {
            $Raw = Get-Content -Path $StatePath -Raw | ConvertFrom-Json
            if ("$($Raw.Format)" -eq 'fingerprints') {
                foreach ($P in $Raw.Files.PSObject.Properties) {
                    $Seen = @{}
                    if ($P.Value.Seen) { foreach ($Q in $P.Value.Seen.PSObject.Properties) { $Seen[$Q.Name] = [int]$Q.Value } }
                    $State[$P.Name] = @{ Last = [datetime]::ParseExact("$($P.Value.Last)", 's', [Globalization.CultureInfo]::InvariantCulture); Seen = $Seen }
                }
            }
            else { Write-Verbose "State file $StatePath is from 1.0.0 (byte offsets); starting over with fingerprints." }
        }
        catch { Write-ShipLog "State file $StatePath unreadable ($($_.Exception.Message)); every log is read as new (entries older than $RetentionDays days skipped)." -LogType WARNING }
    }
    function Save-State {
        if ($WhatIfPreference) { return }
        $Dir = Split-Path -Path $StatePath -Parent
        if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
        $Files = [ordered]@{}
        foreach ($K in $State.Keys | Sort-Object) {
            $Seen = [ordered]@{}; foreach ($Q in $State[$K].Seen.Keys | Sort-Object) { $Seen[$Q] = $State[$K].Seen[$Q] }
            $Files[$K] = [ordered]@{ Last = $State[$K].Last.ToString('s'); Seen = $Seen }
        }
        $Out = [ordered]@{ Format = 'fingerprints'; Device = $Device; Updated = (Get-Date).ToString('s'); WindowHours = $WindowHours; Files = $Files }
        $Tmp = "$StatePath.tmp"
        [System.IO.File]::WriteAllText($Tmp, ($Out | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $Tmp -Destination $StatePath -Force
    }
    #endregion

    if (-not (Test-Path -Path $Target -PathType Container) -and $PSCmdlet.ShouldProcess($Target, 'Create folder')) {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
    }

    $Files = @(Get-ChildItem -Path $LogFolder -File -ErrorAction Stop | Where-Object {
        $N = $_.Name
        ($Include | Where-Object { $N -like $_ }) -and -not ($Exclude | Where-Object { $N -like $_ })
    })

    foreach ($File in $Files) {
        $Summary.Files++
        $Key = $File.Name.ToLower()
        $Log = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
        try {
            $Read = Read-LogEntries -Path $File.FullName
            $Summary.Lines += $Read.Lines
            $Prev = $State[$Key]
            $Floor = if ($Prev) { $Prev.Last.AddHours(-$WindowHours) } else { (Get-Date).AddDays(-$RetentionDays) }
            $Left = @{}; if ($Prev) { foreach ($Q in $Prev.Seen.Keys) { $Left[$Q] = $Prev.Seen[$Q] } }

            $New = New-Object System.Collections.Generic.List[object]
            $Newest = if ($Prev) { $Prev.Last } else { [datetime]::MinValue }
            foreach ($E in $Read.Entries) {
                if ($E.Local -lt $Floor) { continue }
                $Fp = Get-Fingerprint $E
                if ($Left[$Fp] -gt 0) { $Left[$Fp]--; continue }
                $New.Add($E)
                if ($E.Local -gt $Newest) { $Newest = $E.Local }
            }

            if ($New.Count) {
                $Name = '{0}_{1}_{2}.jsonl' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $Log, [guid]::NewGuid().ToString('N').Substring(0, 6)
                $Dest = Join-Path -Path $Target -ChildPath $Name
                if ($PSCmdlet.ShouldProcess($Dest, "Send $($New.Count) entr$(if ($New.Count -eq 1) { 'y' } else { 'ies' }) of $($File.Name)")) {
                    $Json = ($New | Sort-Object Local | ForEach-Object {
                        [pscustomobject][ordered]@{
                            Time    = ([DateTimeOffset]::new($_.Local, [TimeZoneInfo]::Local.GetUtcOffset($_.Local))).ToString('yyyy-MM-ddTHH:mm:sszzz')
                            Server  = $Device; Log = $Log; Script = $_.Script; Type = $_.Type; Message = $_.Message
                        } | ConvertTo-Json -Compress
                    }) -join "`n"
                    $Tmp = "$Dest.tmp"
                    [System.IO.File]::WriteAllText($Tmp, $Json + "`n", (New-Object System.Text.UTF8Encoding($false)))
                    Move-Item -LiteralPath $Tmp -Destination $Dest -Force
                    $Summary.Sent++
                }
                $Summary.Records += $New.Count
            }

            # New state: everything now in the file inside the window counts as sent
            if (-not $WhatIfPreference -and ($New.Count -or -not $Prev)) {
                if ($Newest -eq [datetime]::MinValue) { $Newest = (Get-Date).AddDays(-$RetentionDays) }
                $Keep = $Newest.AddHours(-$WindowHours)
                $Seen = @{}
                foreach ($E in $Read.Entries) { if ($E.Local -ge $Keep) { $Fp = Get-Fingerprint $E; $Seen[$Fp] = 1 + [int]$Seen[$Fp] } }
                $State[$Key] = @{ Last = $Newest; Seen = $Seen }
            }
            Write-Verbose "$($File.Name): $($Read.Entries.Count) entr(ies) in the file, $($New.Count) new."
        }
        catch {
            $Summary.Failed++
            $Summary.Messages.Add("$($File.Name): $($_.Exception.Message)")
            Write-ShipLog "Could not send $($File.Name) to ${Target}: $($_.Exception.Message)" -LogType WARNING
        }
    }
    Save-State
    Write-Verbose ("Log shipping to {0}: {1} file(s) checked, {2} entr(ies) in {3} update file(s), {4} failed." -f $Target, $Summary.Files, $Summary.Records, $Summary.Sent, $Summary.Failed)
}
catch {
    $Summary.Failed++
    $Summary.Messages.Add($_.Exception.Message)
    Write-ShipLog "Log shipping failed: $($_.Exception.Message)" -LogType ERROR
}
$Summary

# Example usage:
# PS> C:\SCRIPTS\Applications\PSM\FrontendScriptsSync\Send-LogsToDfs.ps1 -Verbose
# PS> C:\SCRIPTS\Applications\PSM\FrontendScriptsSync\Send-LogsToDfs.ps1 -DfsRoot C:\Temp\FakeDfs -LogFolder C:\Temp\Logs -StatePath C:\Temp\state.json -Verbose


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCGdOaUTVft9EKO
# vlwNgF04ExTOmDw3WJI6sf8CBPWnrKCCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIFAO2oh0
# 2uoRdqpVWLv8YBseoFsR5n8BHBwdANPhHx0tMA0GCSqGSIb3DQEBAQUABIIBAJhE
# 9nG9H9xuRmN7z+hLVssizUOeicxbChvfpKp3srrL5FYr5LRnntloZx8i1V9MIr49
# rh7RbrMBkSTPLDTV45OSWCmsHiJIu/gXs35avIuyVofm3Af9s0hPnJVA8HtI/maE
# TYOlo+b/PFszY4nes1uihZQqQE4rtZMkiYC1AGXMJlAn8cyUgn2zpKnM0MN/qVc5
# l0IPjKmTs9msfx/JBHg8z+YrVipgAZp6AgCVoSNt6i6trYccBPEtjFjKrovo6tZ2
# uIGQ7/HOS50TbiJ/qzNrZoxOAd+/oA125CEDBdMFpHn7ep/qtO4RfllK1txTXVEK
# hI/UYjR0lDAeQS9GiRahggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDIyMTYy
# ODI5WjAvBgkqhkiG9w0BCQQxIgQgrOPiSvhs9WrEu0xkPF7nk6qpcC0jn9fBE/vz
# m5memU0wDQYJKoZIhvcNAQEBBQAEggIArWcCZQqFODfKyB26LG6C+dQuxzSIMLQ3
# 9BbRGIrjkBr8B3ejTCOhrzqxYz5iMTNAFQ4yGptEWup6x8P4Io6u1zcDXxksD7f6
# 3gzm+hs1OPfs4IJkbp1Evgb1XVbU8St7igmKpJ+h6XfXawMyjEAQpJifJXXYPrJP
# 2xDHd7PMbSdk40nqoNIney2aSQUBlYWXUQj+JDkTqOS8vgQ/eGICGME7l7V0pz37
# SZXrtGX06PBPoT6I6S0Y2yDP9Xx4x73t9HLiIj+oB9vKCtWtbalC0FnDr9o7IC99
# CyinIF3Rzygx6KfObLpr0wfK1Req+rrXJFWGcOGYeMf9ArV5Y2zSftpwbNSvIg6W
# vqNWzHIO/4RVhup3xpI5uNaYDMmNRUcG45pp47LKCor0SNifCX1FF+o/Dlj+jllK
# y8Snd8zh8CxakhxvAXwTu31b0YZo9y+GtmD0oEMLy+MYN6Tn5OzqQe5KwwU89wSZ
# mQ7UqLGjerzXmtZkuWzIL+kpqOvbZoi36U/yzANO+Gho0IDsh60C1Kj/KXae7icP
# OVvvlmQCWL4vJz62Cwa3UoqovjdjobHK/7kMlSALH0D3kuql7gYKmPR/mgI9/xZk
# vxviK/slZZuo3OG+cNR04gkrsjpVHThaSIBAg7dzZ7oyUosj+D4oDKgEycum3HeB
# KCVEpv5L5cY=
# SIG # End signature block
