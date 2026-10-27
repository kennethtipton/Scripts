<#
.SYNOPSIS
    Renews this Exchange server's Let's Encrypt certificate with Posh-ACME and deploys it.
.DESCRIPTION
    1. Renews the certificate (Submit-Renewal). Does nothing if no renewal is due,
       unless -DeployCurrent or -ForceRenewal is used.
    2. Deploys the cert to Exchange front-end services (IIS 443, IMAP, POP, SMTP) with
       Posh-ACME.Deploy's Set-ExchangeCertificate. That function also removes the
       previous LE cert that held the same services.
    3. Binds the cert to the "Exchange Back End" IIS site on port 444
       (Set-ExchangeBackEndCertificate).
    4. Re-pins the default internal transport certificate to a stable, non-LE cert
       (Set-InternalTransportCertificate), because Set-ExchangeCertificate's -Force on SMTP
       takes that role every renewal.
    5. Verifies the 443 and 444 bindings.

    Folder layout (paths are derived from this script's location):
      $SL    C:\SCRIPTS                                                 Script Location
      $SF    C:\SCRIPTS\Functions                                       shared functions (Write-AdvancedLog)
      $SG    C:\SCRIPTS\Logs                                            shared logs (ExchangeLetsEncrypt.log)
      $SA    C:\SCRIPTS\Applications                                    applications (nearest parent of this script)
      $SCA   C:\SCRIPTS\Applications\OpenSource\PoshAcme\ExchangeServer this role
      $SCAPF $SCA\Functions                                             this role's own functions
             ..\Certs                                                   shared Posh-ACME data (POSHACME_HOME)
             $SCA\Logs\Transcripts                                      full console output of each run

    WARNING and ERROR entries also go to the 'Managed Powershell Scripts' event log.

    Run in Windows PowerShell 5.1 (not the Exchange Management Shell), elevated, as the
    account that owns the Posh-ACME data (DPAPI-protected plugin args are tied to it).
.PARAMETER AccountID
    Optional. Posh-ACME ACME account ID. Defaults to the account Posh-ACME already has
    selected for LE_PROD on this server, so the same task works on every server.
.PARAMETER Domain
    Certificate main domain. Defaults to this computer's FQDN.
.PARAMETER DeployCurrent
    Deploy the current certificate even when no renewal is due. Use for testing and to fix bindings.
.PARAMETER ForceRenewal
    Renew the certificate now even when no renewal is due (Submit-Renewal -Force), then deploy it.
    Use to test the full renewal path. Counts against Let's Encrypt's duplicate certificate limit (5 per week).
.PARAMETER InternalTransportThumbprint
    Certificate that should remain the default internal transport (SMTP) certificate.
    Pass an empty string to skip this step.
.PARAMETER ExchangeServices
    Exchange services the LE certificate is enabled for.
.PARAMETER LogFileName
    Base name of the text log file in $SG.
.PARAMETER TranscriptRetentionDays
    Transcripts older than this are deleted.
.EXAMPLE
    PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\ExchangeServer\Renew-ExchangeLE.ps1
.EXAMPLE
    PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\ExchangeServer\Renew-ExchangeLE.ps1 -DeployCurrent
.EXAMPLE
    PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\ExchangeServer\Renew-ExchangeLE.ps1 -ForceRenewal
.INPUTS
    None
.OUTPUTS
    Exit code 0 on success, 1 on warnings or failure.
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-12
    Time: 17:00:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 2.2.0
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: Claude

    Copyright (c) 2026
    Licensed under the MIT License.
    Full text available at: https://opensource.org/licenses/MIT

    Overide Variables
    Overide Filename:
    Overide Log Filename: ExchangeLetsEncrypt
    Overide Text Log File Path: C:\SCRIPTS\Logs\ExchangeLetsEncrypt.log
    Overide Log Type:
.LINK
    https://www.tnandc.com
#>
[CmdletBinding()]
param(
    [string]$AccountID,

    [string]$Domain,

    [switch]$DeployCurrent,

    [switch]$ForceRenewal,

    [string]$InternalTransportThumbprint,

    [string[]]$ExchangeServices,

    [string]$LogFileName = 'ExchangeLetsEncrypt',

    [int]$TranscriptRetentionDays = 90
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'Renew-ExchangeLE.ps1'

#region Standard locations
$SCA  = $PSScriptRoot                          # C:\SCRIPTS\Applications\OpenSource\PoshAcme\ExchangeServer
# $SA is the nearest parent folder named 'Applications', however deep the app is nested
$SA   = $SCA
while ($SA -and (Split-Path -Path $SA -Leaf) -ne 'Applications') { $SA = Split-Path -Path $SA -Parent }
if (-not $SA) { throw "$SCA is not inside an 'Applications' folder." }
$SL   = Split-Path -Path $SA -Parent           # C:\SCRIPTS
$SF   = Join-Path -Path $SL -ChildPath 'Functions'
$SG   = Join-Path -Path $SL -ChildPath 'Logs'
$SCAPF = Join-Path -Path $SCA -ChildPath 'Functions'

# Shared Posh-ACME data, set up by ..\Install-PoshAcme.ps1
$env:POSHACME_HOME = Join-Path -Path (Split-Path -Path $SCA -Parent) -ChildPath 'Certs'
#endregion

#region Settings (core and role settings, each with this server's overrides; parameters win)
# Core: ..\Data\PoshAcme.json (RunAs, Domain). Role: Data\PoshAcmeExchangeServer.json.
# Overrides: <file>.<COMPUTERNAME>.json next to each (Get-ApplicationSettings).
$GetSettingsPath = Join-Path -Path $SF -ChildPath 'Get-ApplicationSettings.ps1'
if (Test-Path -Path $GetSettingsPath) { . $GetSettingsPath }
function Read-Settings {
    param([string]$Path)
    if (-not (Test-Path -Path $Path)) { return $null }
    if (Get-Command -Name Get-ApplicationSettings -ErrorAction SilentlyContinue) { Get-ApplicationSettings -Path $Path }
    else { Get-Content -Path $Path -Raw | ConvertFrom-Json }
}
$CoreCfg = Read-Settings -Path (Join-Path -Path (Split-Path -Path $SCA -Parent) -ChildPath 'Data\PoshAcme.json')
$RoleCfg = Read-Settings -Path (Join-Path -Path $SCA -ChildPath 'Data\PoshAcmeExchangeServer.json')
$Fqdn = ('{0}.{1}' -f $env:COMPUTERNAME, (Get-CimInstance Win32_ComputerSystem).Domain).ToLower()
if (-not $Domain) { $Domain = if ($CoreCfg -and $CoreCfg.Domain) { "$($CoreCfg.Domain)" } else { $Fqdn } }
#endregion
# Thumbprint: parameter (an explicit empty string skips the step), else settings, else skip
if (-not $PSBoundParameters.ContainsKey('InternalTransportThumbprint')) {
    $InternalTransportThumbprint = if ($RoleCfg) { "$($RoleCfg.InternalTransportThumbprint)" } else { '' }
}
if (-not $ExchangeServices) { $ExchangeServices = if ($RoleCfg -and $RoleCfg.ExchangeServices) { @($RoleCfg.ExchangeServices) } else { @('IMAP', 'POP', 'IIS', 'SMTP') } }

#region Logging
$TranscriptDir = Join-Path -Path $SCA -ChildPath 'Logs\Transcripts'
New-Item -ItemType Directory -Path $SG, $TranscriptDir -Force | Out-Null
$TextLog    = Join-Path -Path $SG -ChildPath "$LogFileName.log"
$Transcript = Join-Path -Path $TranscriptDir -ChildPath ('{0}_{1}_{2:yyyyMMdd_HHmmss}.log' -f $LogFileName, $env:COMPUTERNAME, (Get-Date))
Start-Transcript -Path $Transcript | Out-Null

$WriteLogPath = Join-Path -Path $SF -ChildPath 'Write-AdvancedLog.ps1'
if (Test-Path -Path $WriteLogPath) { . $WriteLogPath }
else { Write-Warning "Write-AdvancedLog not found at $WriteLogPath. Logging to transcript only." }

function Write-RenewLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR')]
        [string]$LogType = 'INFO'
    )

    if ($LogType -eq 'WARNING') { Write-Warning $Message } else { Write-Host "[$LogType] $Message" }

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
        try { Write-AdvancedLog @logArgs }
        catch { Write-Host "Write-AdvancedLog failed: $($_.Exception.Message)" }
    }
}
#endregion

$ExitCode = 0

try {
    Write-RenewLog "Run started. Domain: $Domain | DeployCurrent: $DeployCurrent | ForceRenewal: $ForceRenewal"

    #region Application functions
    foreach ($F in 'Set-ExchangeBackEndCertificate.ps1', 'Set-InternalTransportCertificate.ps1') {
        $P = Join-Path -Path $SCAPF -ChildPath $F
        if (-not (Test-Path -Path $P)) { throw "Required function file missing: $P" }
        . $P
    }
    #endregion

    Import-Module Posh-ACME, Posh-ACME.Deploy, WebAdministration
    if (-not (Get-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction SilentlyContinue)) {
        Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn
    }

    Set-PAServer LE_PROD
    if ($AccountID) { Set-PAAccount -ID $AccountID }
    $Account = Get-PAAccount
    if (-not $Account) { throw "No Posh-ACME account selected for LE_PROD in $env:POSHACME_HOME." }

    #region 1. Renew
    $Cert = Submit-Renewal $Domain -Force:$ForceRenewal

    if ($Cert) {
        Write-RenewLog "Renewed certificate $($Cert.Thumbprint), expires $($Cert.NotAfter) (account $($Account.id))."
    }
    elseif ($DeployCurrent) {
        $Cert = Get-PACertificate $Domain
        if (-not $Cert) { throw "No Posh-ACME certificate found for $Domain." }
        Write-RenewLog "No renewal due. Redeploying current certificate $($Cert.Thumbprint), expires $($Cert.NotAfter)."
    }
    else {
        $Current = Get-PACertificate $Domain
        if (-not $Current) { throw "No Posh-ACME certificate found for $Domain." }
        if ($Current.NotAfter -lt (Get-Date).AddDays(14)) {
            Write-RenewLog "No renewal performed, but certificate $($Current.Thumbprint) expires $($Current.NotAfter). Check the Posh-ACME order." -LogType WARNING
            $ExitCode = 1
        }
        else {
            Write-RenewLog "No renewal due. Current certificate $($Current.Thumbprint) expires $($Current.NotAfter)."
        }
        $Cert = $null   # nothing to deploy
    }
    #endregion

    if ($Cert) {
        if (-not $Cert.PfxPass) {
            throw 'Certificate object has no PfxPass property (requires Posh-ACME 4.0 or later).'
        }
        $Thumb = $Cert.Thumbprint.ToUpper()

        #region 2. Front end / Exchange services
        $Cert | Set-ExchangeCertificate -ExchangeServices $ExchangeServices
        Write-RenewLog "Front end: $Thumb enabled for $($ExchangeServices -join ', ')."
        #endregion

        #region 3. Exchange Back End :444
        $BackEnd = Set-ExchangeBackEndCertificate -Thumbprint $Thumb
        if ($BackEnd.Changed) {
            Write-RenewLog "Back end: $($BackEnd.Site) :$($BackEnd.Port) changed from '$($BackEnd.PreviousThumbprint)' to $Thumb."
        }
        else {
            Write-RenewLog "Back end: $($BackEnd.Site) :$($BackEnd.Port) already uses $Thumb."
        }
        #endregion

        #region 4. Internal transport certificate
        if ($InternalTransportThumbprint) {
            try {
                $Transport = Set-InternalTransportCertificate -Thumbprint $InternalTransportThumbprint
                if ($Transport.Changed) {
                    Write-RenewLog "Internal transport certificate changed from '$($Transport.PreviousThumbprint)' to $($Transport.Thumbprint)."
                }
                else {
                    Write-RenewLog "Internal transport certificate already $($Transport.Thumbprint)."
                }
            }
            catch {
                Write-RenewLog "Internal transport certificate not changed: $($_.Exception.Message)" -LogType WARNING
                $ExitCode = 1
            }
        }
        #endregion

        #region 5. Verify
        foreach ($Port in 443, 444) {
            $Line = netsh http show sslcert ipport=0.0.0.0:$Port | Select-String 'Certificate Hash'
            $Hash = if ($Line) { ($Line.ToString() -replace '.*:\s*', '').Trim().ToUpper() } else { '(none)' }
            if ($Hash -ne $Thumb) {
                Write-RenewLog "Verify: 0.0.0.0:$Port is bound to $Hash, expected $Thumb." -LogType WARNING
                $ExitCode = 1
            }
        }

        if ($ExitCode -eq 0) {
            Write-RenewLog "Deployment complete. $Thumb is bound to 443 and 444 (expires $($Cert.NotAfter))."
        }
        else {
            Write-RenewLog "Deployment finished with warnings. See the transcript: $Transcript" -LogType WARNING
        }
        #endregion
    }
}
catch {
    Write-RenewLog "Run failed: $($_.Exception.Message)" -LogType ERROR
    Write-Host $_.ScriptStackTrace
    $ExitCode = 1
}
finally {
    Get-ChildItem -Path $TranscriptDir -Filter "$LogFileName*.log" -ErrorAction SilentlyContinue |
        Where-Object LastWriteTime -lt (Get-Date).AddDays(-$TranscriptRetentionDays) |
        Remove-Item -ErrorAction SilentlyContinue
    Stop-Transcript | Out-Null
}

exit $ExitCode


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAfLXN+5jXwbgd1
# dOvzbp6HdHHgwlz45E0wvDdL0sSsXKCCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEID6fp6VG
# hlPQkWrEgCuLBNW2wPWMcXKjLHXFfZFFpKCWMA0GCSqGSIb3DQEBAQUABIIBAIti
# 0wJqklJHMjBSEom0d644e8uzdkGhO2i54YnX3kWtraTnKAHHIheu9l/3p13jtlTc
# zlobjYxB7Eaus4azitG8JJIcJtrIAYJMSUEnB3c2IQeILJZG1fCV/tdIDFyv4o5I
# PML7QRIjv1EnyDiY1RtyAec9HPtC7huj/Bzdx5El5K76K8VxiZG4iOU9CUqm4FuK
# W7LmhvUgnX4VFdhmL83yAqK70j41LBj1ax/DUmMhB4ojeiVxvBGYTS1BKJig+O39
# gFIBTQaBDRnFMLicWX0abbkEufVffh/Hc/wYe/6wQheP5o9XGL/LFntnLe5tVhXf
# TH/sy+GZAhPqHE3kCrChggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDE1MTMx
# NzE4WjAvBgkqhkiG9w0BCQQxIgQglJrMjEN1C4ugqiIMKGYPaa1o/eAeeGePtJeo
# bC5ekWcwDQYJKoZIhvcNAQEBBQAEggIAry/KO0gobOlobgl+9r+A9073pyg0a1Xq
# 6hmg7Jttp3r/bC6dd8IFWEAiRtKtiJs1klx4/3ZoUw9hMekyjjI6rGUvsP3Iv7jN
# n9Z0yJOEyPAy6EoLCgcMAc4Gn556pM8tGyjX/HNmtS7rVOcQpsDS9UVm/vzXs3Z9
# WQSupG4Fj0A4J4eSmn1WqDzUW6YrlXR1AJ6Y0j9dCbEmZOLcuFBczombacLSBsfp
# zbTqAwoLCGkAS0rEPMq4zxfo104n94MppmkloCjvSvIkXX2+I08BTebZrpLdq/LD
# Nfp1r8DsfrUICFR75HhS23rrR+wMTt0fAlgtDK+4LzdHhi5j+CFg4Sp0Yuq8hko7
# 1k07ykg40BB48XvNnHcpOs7rk+MqsPHALzo5YeYTitYIz6G4KkbAzJwaOvjtdIvG
# UQF+LjaJtmcJrmeZSim/rrWActrThgEME80lmTraqukC1NELdGePZJgW6JFcvVD/
# lNX0YbclyWQZtAg7mzLQRIGzuzr/DuYFkXKLNdiRHkVMm3OjxThisBd9e3fD4nce
# qu5ZWqc9mhXUnez/Ad9a8//V+PjvG/v6YI6ULi9B2sCbRd0tqzeA7d1ZrWjaxEsd
# 9K7ojHFPhW0fPq8DW+UPvf8Zbw42n58prmrjLhGbcEUPKvCafiq/oSWQ0P/kyG/F
# a0znND2DjPA=
# SIG # End signature block
