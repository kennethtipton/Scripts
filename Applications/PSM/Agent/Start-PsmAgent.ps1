<#
.SYNOPSIS
    The PSM Agent: an HTTPS web service (Pode + Pode.Web) that shows this server's PSM data.
.DESCRIPTION
    Part of Powershell Scripts Management (PSM). Runs on each PSM server as the scheduled task
    \PSM\PsmAgent (SYSTEM, at startup; Install-PsmAgent.ps1 creates it). Read-only.

    https://<server FQDN>:8776/            Pode.Web pages (sign in with your domain account):
                                           Overview, Applications (settings and their layers),
                                           Logs (filter and search), Cleanup
    https://<server FQDN>:8776/api/...     JSON (HTTP Basic sign-in with a domain account):
        GET /api/health                    (no sign-in) device, agent version, time
        GET /api/device                    the device record (Write-DeviceRecord.ps1)
        GET /api/apps                      applications on disk
        GET /api/apps/<name>/settings      merged settings and each layer's changes
        GET /api/logs                      the logs in C:\SCRIPTS\Logs
        GET /api/logs/<name>?since=yyyy-MM-dd[THH:mm]&type=ERROR&search=text&max=200
        GET /api/cleanup                   the cleanup list (Cleanup.json)

    Sign-in: Windows AD (Pode Add-PodeAuthWindowsAd), members of ViewGroups or AdminGroups in
    Data\PSMAgent.json (nested membership counts). Certificate: the newest valid server
    certificate for this server's FQDN in LocalMachine\My (the internal CA's preferred); without
    one, a self-signed certificate when Certificate.AllowSelfSigned is true.

    Settings: Data\PSMAgent.json (with the usual published per-server and local override layers).
    Pode's own error log: C:\SCRIPTS\Logs\PsmAgent\.
.PARAMETER TestMode
    Development only: http://127.0.0.1:<Port> without sign-in and without a certificate.
.PARAMETER ListenAddress
    Address to listen on (HTTPS). Defaults to * (all addresses; needs administrator rights, as the
    SYSTEM task has). 127.0.0.1 tests sign-in and HTTPS locally without elevation.
.EXAMPLE
    PS> C:\SCRIPTS\Applications\PSM\Agent\Start-PsmAgent.ps1
.EXAMPLE
    PS> C:\SCRIPTS\Applications\PSM\Agent\Start-PsmAgent.ps1 -TestMode
.INPUTS
    None
.OUTPUTS
    None (runs until stopped)
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-24
    Time: 10:00:00
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
    Overide Log Filename: PsmAgent
    Overide Text Log File Path:
    Overide Log Type:
.LINK
    https://www.tnandc.com
#>
[CmdletBinding()]
param(
    [switch]$TestMode,

    [string]$ListenAddress = '*'
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'Start-PsmAgent.ps1'

#region Standard locations
$SCA = $PSScriptRoot
$SA  = $SCA
while ($SA -and (Split-Path -Path $SA -Leaf) -ne 'Applications') { $SA = Split-Path -Path $SA -Parent }
if (-not $SA) { throw "$SCA is not inside an 'Applications' folder." }
$SL = Split-Path -Path $SA -Parent
$SF = Join-Path -Path $SL -ChildPath 'Functions'
$SG = Join-Path -Path $SL -ChildPath 'Logs'
#endregion

foreach ($F in 'Write-AdvancedLog.ps1', 'Get-ApplicationSettings.ps1') { . (Join-Path -Path $SF -ChildPath $F) }
function Write-AgentLog {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO', 'WARNING', 'ERROR')][string]$LogType = 'INFO')
    Write-Host "[$LogType] $Message"
    try { Write-AdvancedLog -Message $Message -ScriptName $ScriptName -LogFileName 'PsmAgent' -LogType $LogType -WriteEventLog:($LogType -ne 'INFO') } catch { }
}

#region Settings, modules, certificate
$Cfg = Get-ApplicationSettings -Path (Join-Path -Path $SCA -ChildPath 'Data\PSMAgent.json')
$Port = if ("$($Cfg.Port)" -match '^\d+$') { [int]$Cfg.Port } else { 8776 }
$Groups = @(@($Cfg.ViewGroups) + @($Cfg.AdminGroups) | Where-Object { $_ } | Select-Object -Unique)
foreach ($M in @($Cfg.Modules | Where-Object { $_.Name })) {
    $Want = "$($M.RequiredVersion)".Split('-')[0]
    $ImportArgs = @{ Name = "$($M.Name)"; ErrorAction = 'Stop' }
    if ($Want) { $ImportArgs.RequiredVersion = $Want }
    try { Import-Module @ImportArgs } catch { Write-AgentLog "Module $($M.Name) $($M.RequiredVersion) is not installed: $($_.Exception.Message) (SetupApplications installs it)." -LogType ERROR; throw }
}

$Fqdn = ('{0}.{1}' -f $env:COMPUTERNAME, (Get-CimInstance -ClassName Win32_ComputerSystem).Domain).ToLower()
$Thumb = ''
if (-not $TestMode) {
    $Candidates = @(Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object {
        $_.HasPrivateKey -and $_.NotBefore -le (Get-Date) -and $_.NotAfter -gt (Get-Date).AddDays(1) -and
        (@($_.DnsNameList.Unicode) -contains $Fqdn) -and
        (-not $_.EnhancedKeyUsageList -or (@($_.EnhancedKeyUsageList.ObjectId) -contains '1.3.6.1.5.5.7.3.1')) -and
        $_.Subject -ne $_.Issuer
    })
    $Prefer = "$($Cfg.Certificate.PreferIssuer)"
    # The private key must be readable by this account (SYSTEM in the scheduled task); otherwise every TLS
    # handshake fails with "The credentials supplied to the package were not recognized"
    $Unreadable = @($Candidates | Where-Object {
        try { -not ([System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($_) -or [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($_)) } catch { $true }
    })
    if ($Unreadable) {
        Write-AgentLog "This account ($env:USERNAME) cannot read the private key of $(($Unreadable | ForEach-Object { $_.Thumbprint.Substring(0, 8) }) -join ', '); skipped. The agent normally runs as SYSTEM (scheduled task)." -LogType WARNING
        $Candidates = @($Candidates | Where-Object { $_ -notin $Unreadable })
    }
    $Pick = $Candidates | Sort-Object @{ e = { if ($Prefer -and $_.Issuer -like "*$Prefer*") { 0 } else { 1 } } }, @{ e = { $_.NotAfter }; Descending = $true } | Select-Object -First 1
    if ($Pick) { $Thumb = $Pick.Thumbprint; Write-AgentLog "Certificate $Thumb ($($Pick.Issuer -replace '^CN=([^,]+).*','$1'), expires $($Pick.NotAfter.ToString('yyyy-MM-dd'))) for $Fqdn." }
    elseif ([bool]$Cfg.Certificate.AllowSelfSigned) { Write-AgentLog "No CA certificate for $Fqdn in LocalMachine\My; starting with a self-signed certificate (browsers will warn). Enable certificate auto-enrollment for this server." -LogType WARNING }
    else { Write-AgentLog "No certificate for $Fqdn in LocalMachine\My and AllowSelfSigned is off; not started." -LogType ERROR; throw 'No certificate.' }
}
#endregion

Write-AgentLog "PSM Agent $($Cfg.Version) starting on $(if ($TestMode) { "http://127.0.0.1:$Port (TEST MODE: no sign-in)" } else { "https://${Fqdn}:$Port" }); groups: $($Groups -join ', ')."

Start-PodeServer -Threads $(if ("$($Cfg.Threads)" -match '^\d+$') { [int]$Cfg.Threads } else { 3 }) -ScriptBlock {
    #region Endpoint, logging, shared state
    if ($TestMode) { Add-PodeEndpoint -Address 127.0.0.1 -Port $Port -Protocol Http }
    elseif ($Thumb) { Add-PodeEndpoint -Address $ListenAddress -Port $Port -Protocol Https -CertificateThumbprint $Thumb -CertificateStoreLocation LocalMachine }
    else { Add-PodeEndpoint -Address $ListenAddress -Port $Port -Protocol Https -SelfSigned }

    New-PodeLogFileMethod -Name 'errors' -Path (Join-Path $SG 'PsmAgent') -MaxDays 30 | Enable-PodeErrorLogging

    Set-PodeState -Name 'Root' -Value $SL | Out-Null
    Set-PodeState -Name 'Config' -Value $Cfg | Out-Null
    Set-PodeState -Name 'Device' -Value $env:COMPUTERNAME.ToUpper() | Out-Null
    Use-PodeScript -Path (Join-Path $SF 'Get-ApplicationSettings.ps1')
    Use-PodeScript -Path (Join-Path $SCA 'Functions\Get-PsmAgentData.ps1')
    #endregion

    #region Sign-in
    $ApiAuth = $null
    if (-not $TestMode) {
        Enable-PodeSessionMiddleware -Duration ([int]$Cfg.SessionMinutes * 60) -Extend
        New-PodeAuthScheme -Form | Add-PodeAuthWindowsAd -Name 'PsmLogin' -Groups $Groups
        New-PodeAuthScheme -Basic -Realm 'PSM Agent' | Add-PodeAuthWindowsAd -Name 'PsmApi' -Groups $Groups -Sessionless
        $ApiAuth = 'PsmApi'
    }
    $RouteAuth = @{}; if ($ApiAuth) { $RouteAuth.Authentication = $ApiAuth }
    #endregion

    #region JSON API
    Add-PodeRoute -Method Get -Path '/api/health' -ScriptBlock {
        Write-PodeJsonResponse -Value @{ Device = (Get-PodeState -Name 'Device'); Agent = "$((Get-PodeState -Name 'Config').Version)"; Time = (Get-Date).ToString('s') }
    }
    Add-PodeRoute -Method Get -Path '/api/device' @RouteAuth -ScriptBlock {
        try { Write-PodeJsonResponse -Depth 10 -Value (Get-PsmDevice -Root (Get-PodeState -Name 'Root')) } catch { Write-PodeJsonResponse -StatusCode 500 -Value @{ Error = $_.Exception.Message } }
    }
    Add-PodeRoute -Method Get -Path '/api/apps' @RouteAuth -ScriptBlock {
        try { Write-PodeJsonResponse -Depth 6 -Value @(Get-PsmApps -Root (Get-PodeState -Name 'Root')) } catch { Write-PodeJsonResponse -StatusCode 500 -Value @{ Error = $_.Exception.Message } }
    }
    Add-PodeRoute -Method Get -Path '/api/apps/:name/settings' @RouteAuth -ScriptBlock {
        try {
            $S = Get-PsmAppSettings -Root (Get-PodeState -Name 'Root') -Name $WebEvent.Parameters['name']
            if (-not $S) { Write-PodeJsonResponse -StatusCode 404 -Value @{ Error = "No application '$($WebEvent.Parameters['name'])' on this server." }; return }
            Write-PodeJsonResponse -Depth 12 -Value $S
        } catch { Write-PodeJsonResponse -StatusCode 500 -Value @{ Error = $_.Exception.Message } }
    }
    Add-PodeRoute -Method Get -Path '/api/logs' @RouteAuth -ScriptBlock {
        try { Write-PodeJsonResponse -Value @(Get-PsmLogs -Root (Get-PodeState -Name 'Root')) } catch { Write-PodeJsonResponse -StatusCode 500 -Value @{ Error = $_.Exception.Message } }
    }
    Add-PodeRoute -Method Get -Path '/api/logs/:name' @RouteAuth -ScriptBlock {
        try {
            $Q = $WebEvent.Query
            $Args = @{ Root = (Get-PodeState -Name 'Root'); Name = $WebEvent.Parameters['name'] }
            $Since = [datetime]::MinValue
            if ($Q['since'] -and [datetime]::TryParse("$($Q['since'])", [ref]$Since)) { $Args.Since = $Since }
            if ($Q['type']) { $Args.Type = "$($Q['type'])" }
            if ($Q['search']) { $Args.Search = "$($Q['search'])" }
            $Max = [int](Get-PodeState -Name 'Config').LogMaxEntries; if ("$($Q['max'])" -match '^\d+$') { $Max = [Math]::Min([int]$Q['max'], 5000) }
            $Args.Max = $Max
            Write-PodeJsonResponse -Value @(Read-PsmLog @Args)
        } catch { Write-PodeJsonResponse -StatusCode 400 -Value @{ Error = $_.Exception.Message } }
    }
    Add-PodeRoute -Method Get -Path '/api/cleanup' @RouteAuth -ScriptBlock {
        try { Write-PodeJsonResponse -Depth 6 -Value (Get-PsmCleanupList -Root (Get-PodeState -Name 'Root')) } catch { Write-PodeJsonResponse -StatusCode 500 -Value @{ Error = $_.Exception.Message } }
    }
    #endregion

    #region Pages
    Use-PodeWebTemplates -Title "PSM Agent - $($env:COMPUTERNAME.ToUpper())" -Theme Auto
    if (-not $TestMode) { Set-PodeWebLoginPage -Authentication 'PsmLogin' }
    # The root address opens the Overview (Pode.Web's own -RootRedirect picks the first page by name)
    Add-PodeRoute -Method Get -Path '/' -ScriptBlock { Move-PodeResponseUrl -Url '/pages/Overview' }

    Add-PodeWebPage -Name 'Overview' -Icon 'server' -Index 1 -ScriptBlock {
        $D = Get-PsmDevice -Root (Get-PodeState -Name 'Root')
        $Kv = { param($Pairs) @($Pairs.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Item = $_.Key; Value = "$($_.Value)" } }) }
        $Server = [ordered]@{
            'Device'      = $D.Fqdn
            'Record'      = $(if ($D.Updated) { "written $($D.Updated)" } else { "$($D.Note)" })
            'OS'          = "$($D.Os.Caption) (build $($D.Os.Build))"
            'Last boot'   = "$($D.Os.LastBoot) ($($D.Os.UptimeDays) days)"
            'Hardware'    = "$($D.Hardware.Manufacturer) $($D.Hardware.Model), $($D.Hardware.Cpus) CPUs, $($D.Hardware.MemoryGB) GB"
            'Disks'       = (@($D.Disks) | ForEach-Object { "$($_.Drive) $($_.FreeGB) of $($_.SizeGB) GB free" }) -join '; '
            'Addresses'   = (@($D.Network) | ForEach-Object { $_.Address }) -join ', '
            'PowerShell'  = "$($D.PowerShell.Windows)$(if ($D.PowerShell.Core) { " / 7: $($D.PowerShell.Core)" })"
        }
        $Psm = [ordered]@{
            'Frontend'     = $D.Psm.Frontend
            'Last sync'    = $(if ($D.Psm.Sync) { "$($D.Psm.Sync.Time): exit $($D.Psm.Sync.ExitCode), $($D.Psm.Sync.Checked) checked, $($D.Psm.Sync.Updated) updated, $($D.Psm.Sync.Failed) failed$(if (@($D.Psm.Sync.Held).Count) { "; held: $(@($D.Psm.Sync.Held) -join '; ')" })" } else { '' })
            'Log shipping' = $(if ($D.Psm.LogShipping) { "$($D.Psm.LogShipping.Time): $($D.Psm.LogShipping.Records) entries sent, $($D.Psm.LogShipping.Failed) failed" } else { '' })
            'Cleanup'      = $(if ($D.Psm.Cleanup) { "$($D.Psm.Cleanup.Time): $($D.Psm.Cleanup.Removed) removed, $($D.Psm.Cleanup.Trimmed) log entries trimmed, $($D.Psm.Cleanup.ListPending) on the cleanup list, $($D.Psm.Cleanup.Failed) failed" } else { '' })
            'Local settings' = (@($D.Psm.LocalSettings) | Where-Object { @($_.Keys).Count } | ForEach-Object { "$($_.Name): $(@($_.Keys) -join ', ')" }) -join '; '
        }
        @(
            New-PodeWebCard -Name 'Server' -Content @(New-PodeWebTable -Name 'ServerInfo' -Data (& $Kv $Server) -NoExport)
            New-PodeWebCard -Name 'PSM' -Content @(New-PodeWebTable -Name 'PsmInfo' -Data (& $Kv $Psm) -NoExport)
            New-PodeWebCard -Name 'Applications' -Content @(New-PodeWebTable -Name 'Apps' -Data @($D.Applications | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Version = $_.Version; DFS = $_.DfsVersion; Status = $_.Status } }))
            New-PodeWebCard -Name 'Scheduled tasks' -Content @(New-PodeWebTable -Name 'Tasks' -Data @(@($D.Psm.Tasks) + @($D.OtherTasks) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Task = $_.Path; State = $_.State; RunAs = $_.RunAs; 'Last run' = $_.LastRun; Result = $_.LastResult } }))
            New-PodeWebCard -Name 'Unmanaged content' -Content @(New-PodeWebTable -Name 'Unmanaged' -Data @($D.Unmanaged | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Files = $_.Files; Scripts = $_.Scripts; Changed = $_.Changed } }))
        )
    }

    Add-PodeWebPage -Name 'Applications' -Icon 'apps' -Index 2 -ScriptBlock {
        $Root = Get-PodeState -Name 'Root'
        $Names = @('Scripts') + @(Get-PsmApps -Root $Root | ForEach-Object { $_.Name })
        $Tabs = foreach ($N in $Names) {
            $S = Get-PsmAppSettings -Root $Root -Name $N
            if (-not $S) { continue }
            $Changes = @(foreach ($L in @($S.Layers | Where-Object { $_.Layer -ne 'Published' })) { foreach ($C in @($L.Changes)) { [pscustomobject]@{ Layer = $L.Layer; Setting = $C.Key; Value = $C.Value } } })
            $Shown = $S.Merged | Select-Object * -ExcludeProperty SettingsPath, OverridePath, LocalOverridePath
            New-PodeWebTab -Name $N -Content @(
                New-PodeWebParagraph -Value ("Files: " + ((@($S.Layers) | ForEach-Object { "$($_.Layer): $(if ($_.Exists) { $_.Path } else { '(none)' })" }) -join ' | '))
                New-PodeWebTable -Name "Overrides_$($N -replace '\W','')" -DisplayName 'Values changed for this server' -Data $(if ($Changes) { $Changes } else { @([pscustomobject]@{ Layer = '-'; Setting = '(no overrides: published defaults only)'; Value = '' }) }) -NoExport
                New-PodeWebCodeBlock -Value ($Shown | ConvertTo-Json -Depth 10) -Language json -Scrollable
            )
        }
        New-PodeWebTabs -Tabs @($Tabs)
    }

    Add-PodeWebPage -Name 'Logs' -Icon 'file-document-outline' -Index 3 -ScriptBlock {
        $Root = Get-PodeState -Name 'Root'
        $Logs = @(Get-PsmLogs -Root $Root | ForEach-Object { $_.Name })
        @(
            New-PodeWebForm -Name 'LogFilter' -SubmitText 'Show' -Content @(
                New-PodeWebSelect -Name 'Log' -Options ($Logs | ConvertTo-PodeWebOption)
                New-PodeWebSelect -Name 'Type' -Options (@('(all)', 'INFO', 'WARNING', 'ERROR') | ConvertTo-PodeWebOption)
                New-PodeWebTextbox -Name 'Search' -Placeholder 'text in the message or script name'
                New-PodeWebTextbox -Name 'Days' -Type Number -Value '7' -HelpText 'Entries of the last N days'
            ) -ScriptBlock {
                $Days = 7; if ("$($WebEvent.Data['Days'])" -match '^\d+$') { $Days = [int]$WebEvent.Data['Days'] }
                $Rows = @(Read-PsmLog -Root (Get-PodeState -Name 'Root') -Name "$($WebEvent.Data['Log'])" -Since (Get-Date).AddDays(-$Days) -Type $(if ("$($WebEvent.Data['Type'])" -eq '(all)') { '' } else { "$($WebEvent.Data['Type'])" }) -Search "$($WebEvent.Data['Search'])" -Max ([int](Get-PodeState -Name 'Config').LogMaxEntries))
                if (-not $Rows) { $Rows = @([pscustomobject]@{ Time = ''; Script = ''; Type = ''; Message = '(no entries match)' }) }
                $Rows | Update-PodeWebTable -Name 'Entries'
            }
            New-PodeWebTable -Name 'Entries' -Paginate -PageSize 50 -ScriptBlock {
                $First = @(Get-PsmLogs -Root (Get-PodeState -Name 'Root')) | Select-Object -First 1
                if ($First) { @(Read-PsmLog -Root (Get-PodeState -Name 'Root') -Name $First.Name -Max 200) }
            }
        )
    }

    Add-PodeWebPage -Name 'Cleanup' -Icon 'broom' -Index 4 -ScriptBlock {
        $L = Get-PsmCleanupList -Root (Get-PodeState -Name 'Root')
        @(
            New-PodeWebCard -Name 'Waiting to be deleted' -Content @(New-PodeWebTable -Name 'Pending' -Data $(if (@($L.Items).Count) { @($L.Items | ForEach-Object { [pscustomobject]@{ Type = $_.Type; Path = $_.Path; Due = $_.Due; Reason = $_.Reason; By = $_.By; 'Last error' = $_.LastError } }) } else { @([pscustomobject]@{ Type = ''; Path = '(nothing on the cleanup list)'; Due = ''; Reason = ''; By = ''; 'Last error' = '' }) }))
            New-PodeWebCard -Name 'Done' -Content @(New-PodeWebTable -Name 'DoneItems' -Data $(if (@($L.Done).Count) { @($L.Done | ForEach-Object { [pscustomobject]@{ Time = $_.Time; Type = $_.Type; Path = $_.Path; Result = $_.Result; Reason = $_.Reason } }) } else { @([pscustomobject]@{ Time = ''; Type = ''; Path = '(none yet)'; Result = ''; Reason = '' }) }))
        )
    }
    #endregion
}

# Example usage:
# PS> C:\SCRIPTS\Applications\PSM\Agent\Start-PsmAgent.ps1 -TestMode


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAWzUpfrn7gb8jw
# iIeNvDYr7ZuHly13okuYaPKLL1J1p6CCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIGkvg805
# YQTNFgvvVenG/L2L7DB6Lf9PiFl2ROinchlgMA0GCSqGSIb3DQEBAQUABIIBACQg
# 4yMetCfNpnya2YS6af1bGN9xM1Vj+X1xWeuCuyLHtTgBsIOvFg3NBnx7c0G+UBdH
# LvqjP1S4MXbOG1K3AvyXAyP96WvVqNuoUnxWSH6e5Tdu8jk+HjXtxSn60nxqXRwN
# 6lpgxGfw7RfbnXONwUO9xOyFgURXqMqZ4tWJUKyNjDh1PLgIyA7ZreQuO8AYSNlD
# Pjtn68vh2ExeE6+vjikZ1ZyQhuN7AHUXqeG8dQKKUc5v9nWTDYY7yUR+Y+hIkwaJ
# 8W/wSXHENkWzzhxfDNmeOyfSbhtPhNxNNd9YGrsnd78glCvUMEEZKVBeZG5JjMSx
# 3Mpx5qHfGfAR0uQFFd6hggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDI1MDI0
# NDA3WjAvBgkqhkiG9w0BCQQxIgQgQiSGbmiuDdtGO4ovBwAWjpn/fcgYqrhdz9Pm
# pDLC8qcwDQYJKoZIhvcNAQEBBQAEggIAEVB4x/zLs1WnobVwNdePAVF2KBZrEJ3Y
# ub0BDJt3ysYQ5t1yTzRjLKBSosSMrjLcE+5RHdg6NXRsaALgh9dMq8SWRHdxT8Yr
# sWeQGxbRfu0JZDFhnwc1TurM4ESwlHPCj3FDOFsVqMEOnYvEd6FJw8m5r1DsE+tZ
# rIRokk/NX0t1ZQjB3XkI5FcNqLHp9hRdWskSm8dQXTxVvvoRyKuIDJEbVej3pjRV
# OsJBZa7eRKS7zQW72A9fYb4Yxv63ZvFd1hlU4fsobs2+w00N5apFvkAKCezAJ/4V
# 0E7bTTcNWeA5U9aKZP54AFng+b0c9T9dBSZXXl67MELp4Oz7Ol1tjmdMAVc/TjiU
# Rg6tsjsg4OQmS0Vs4g/GIQ4wTBSt3EICh4tC4UFbTDUCI1quhcFS1/RSMJOvDxbg
# weWPZbaZCz/OybdWvXb2dORgyedUC7pv15YHo9N/N0hccnTq/muiyQ41NZ4lWcUh
# RaHpNtxQuIeUzu7I3pH2WmGPxL68KL9oiyI35+izjU9QpSEIwyxpT4VGO0ctbcSR
# AOJxrpmOR3W0hwpPd8FB3pnD02avDFZUkz6fwM3+fBD2WQV8PlBgdUojWLrH1gB9
# B2oEF+B//p26Q/mvTduudNIEEawah2FeoPKC9nzP+SZOO6KTkETGG3OHvenYvHPb
# FffxJI+dmCk=
# SIG # End signature block
