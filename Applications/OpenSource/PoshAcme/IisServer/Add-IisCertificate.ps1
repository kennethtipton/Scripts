#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Adds a Let's Encrypt certificate and the IIS bindings it should serve to this server's mapping, interactively.
.DESCRIPTION
    Asks (or takes as parameters):
      1. The certificate: an existing entry, or a new main DNS name plus any extra names.
         If Posh-ACME has no order for it yet, one is requested from Let's Encrypt, using the DNS
         plugin and saved plugin arguments of an existing order on this server (you pick which).
      2. The IIS site(s) to bind it to, from the list of sites on this server.
      3. For each site: its existing HTTPS bindings (host names and Require SNI are kept), and/or a
         new binding (host name, port, IP address, Require SNI).
    The entry is saved in Data\Deployments\IisCertificates.json (previous version kept in
    Data\Deployments\Backups). Run it again to add another certificate, or more sites/bindings to an
    existing one. Then it offers to deploy straight away (Renew-IisLE.ps1 -DeployCurrent).

    -List shows the mapping. -Remove takes an entry out of the mapping (IIS and the certificate
    store are not changed; the nightly task simply stops managing it).

    Run in Windows PowerShell 5.1, elevated, as the account that owns the Posh-ACME data (RunAs in
    the settings). Prompts use the console, so it works over OpenSSH.
.PARAMETER MainDomain
    Main DNS name of the certificate (Posh-ACME order). Prompted when not given.
.PARAMETER AltName
    Extra DNS names for a new certificate.
.PARAMETER SiteName
    IIS site(s) to bind. Prompted when not given.
.PARAMETER UseExistingBindings
    Bind every existing HTTPS binding of the chosen site(s) (no binding questions).
.PARAMETER HostHeader
    Host name of a new binding ('' = all names). Used with -SiteName when -UseExistingBindings is not.
.PARAMETER Port
    Port of a new binding. Defaults to 443.
.PARAMETER IPAddress
    IP address of a new binding. Defaults to '*' (all unassigned).
.PARAMETER RequireSNI
    Require SNI on a new binding (recommended when a host name is given).
.PARAMETER DeployNow
    Deploy right after saving, without asking.
.PARAMETER List
    Show the mapping and exit.
.PARAMETER Remove
    Remove the -MainDomain entry from the mapping.
.EXAMPLE
    PS> .\Add-IisCertificate.ps1
.EXAMPLE
    PS> .\Add-IisCertificate.ps1 -MainDomain netsolutions.generationsgaither.com -SiteName 'Default Web Site' -HostHeader netsolutions.generationsgaither.com -RequireSNI -DeployNow
.EXAMPLE
    PS> .\Add-IisCertificate.ps1 -List
.INPUTS
    None
.OUTPUTS
    None
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-21
    Time: 16:00:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 1.0.1
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: Claude

    Requesting a new certificate counts against Let's Encrypt's rate limits; you are asked first.

    Copyright (c) 2026
    Licensed under the MIT License.
    Full text available at: https://opensource.org/licenses/MIT

    Overide Variables
    Overide Filename:
    Overide Log Filename: IisLetsEncrypt
    Overide Text Log File Path: C:\SCRIPTS\Logs\IisLetsEncrypt.log
    Overide Log Type:
.LINK
    https://www.tnandc.com
#>
[CmdletBinding()]
param(
    [string]$MainDomain,
    [string[]]$AltName,
    [string[]]$SiteName,
    [switch]$UseExistingBindings,
    [string]$HostHeader,
    [ValidateRange(1, 65535)]
    [int]$Port = 443,
    [string]$IPAddress = '*',
    [switch]$RequireSNI,
    [switch]$DeployNow,
    [switch]$List,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'Add-IisCertificate.ps1'

#region Standard locations
$SCA = $PSScriptRoot
$SA  = $SCA
while ($SA -and (Split-Path -Path $SA -Leaf) -ne 'Applications') { $SA = Split-Path -Path $SA -Parent }
if (-not $SA) { throw "$SCA is not inside an 'Applications' folder." }
$SL    = Split-Path -Path $SA -Parent
$SF    = Join-Path -Path $SL -ChildPath 'Functions'
$SG    = Join-Path -Path $SL -ChildPath 'Logs'
$SCAPF = Join-Path -Path $SCA -ChildPath 'Functions'
$env:POSHACME_HOME = Join-Path -Path (Split-Path -Path $SCA -Parent) -ChildPath 'Certs'
#endregion

foreach ($F in 'Get-IisCertificateConfig.ps1', 'Save-IisCertificateConfig.ps1', 'Get-IisHttpsBinding.ps1') { . (Join-Path -Path $SCAPF -ChildPath $F) }
$P = Join-Path -Path $SF -ChildPath 'Write-AdvancedLog.ps1'; if (Test-Path $P) { . $P }
function Write-AddLog {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO', 'WARNING', 'ERROR')][string]$LogType = 'INFO')
    if ($LogType -eq 'WARNING') { Write-Warning $Message } elseif ($LogType -eq 'ERROR') { Write-Host "  $Message" -ForegroundColor Red } else { Write-Host "  $Message" }
    if (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue) {
        $LogArgs = @{ Message = $Message; ScriptName = $ScriptName; LogFileName = 'IisLetsEncrypt'; LogFile = (Join-Path $SG 'IisLetsEncrypt.log'); LogType = $LogType }
        if ($LogType -ne 'INFO') { $LogArgs.WriteEventLog = $true }
        try { Write-AdvancedLog @LogArgs } catch { }
    }
}

# Console prompts (work over OpenSSH)
function Read-Value { param([string]$Prompt, [string]$Default = '') $A = Read-Host -Prompt $(if ($Default) { "$Prompt [$Default]" } else { $Prompt }); if ("$A".Trim()) { "$A".Trim() } else { $Default } }
function Read-YesNo { param([string]$Prompt, [bool]$Default = $true) $A = Read-Host -Prompt "$Prompt $(if ($Default) { '[Y/n]' } else { '[y/N]' })"; if (-not "$A".Trim()) { return $Default }; "$A".Trim() -match '^(y|yes)$' }
function Read-Numbers { param([string]$Prompt, [int]$Max) $A = Read-Host -Prompt $Prompt; @("$A" -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Where-Object { $_ -ge 1 -and $_ -le $Max } | Select-Object -Unique) }

function Show-Mapping {
    param($Certificates, $Bindings)
    if (-not @($Certificates).Count) { Write-Host '  (no certificates in the mapping yet)'; return }
    $i = 0
    foreach ($C in $Certificates) {
        $i++
        $Pa = Get-PACertificate -MainDomain $C.MainDomain -ErrorAction SilentlyContinue
        Write-Host ("  {0}) {1}{2}  names: {3}  cert: {4}" -f $i, $C.MainDomain, $(if (-not $C.Enabled) { ' (disabled)' }), ($C.Names -join ', '), $(if ($Pa) { "$($Pa.Thumbprint) expires $($Pa.NotAfter.ToString('yyyy-MM-dd'))" } else { 'no Posh-ACME certificate' }))
        foreach ($B in $C.Bindings) {
            $Now = $Bindings | Where-Object { $_.SiteName -eq $B.SiteName -and $_.Key -eq $B.Key } | Select-Object -First 1
            $State = if (-not $Now) { 'not created yet' } elseif ($Pa -and $Now.Thumbprint -eq "$($Pa.Thumbprint)".ToUpper()) { 'current' } else { "on $($Now.Thumbprint)" }
            Write-Host ("       {0,-28} https {1,-50} {2,-4} {3}" -f $B.SiteName, $B.Key, $(if ($B.RequireSNI) { 'SNI' } else { '' }), $State)
        }
    }
}

try {
    if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Run this in Windows PowerShell 5.1 (powershell.exe), not pwsh.' }
    Import-Module Posh-ACME, WebAdministration
    Set-PAServer LE_PROD
    if (-not (Get-PAAccount)) { throw "No Posh-ACME account for LE_PROD in $env:POSHACME_HOME. Create it with ..\Show-PoshAcmeCertificateManagement.ps1 (Account tab)." }

    $Cfg = Get-IisCertificateConfig -ApplicationPath $SCA
    $Me = "$env:USERDOMAIN\$env:USERNAME"
    if ($Cfg.RunAs -and $Me -ne $Cfg.RunAs) { Write-AddLog "Running as $Me, not $($Cfg.RunAs) (the account the task uses). New DNS plugin settings would be encrypted for $Me." -LogType WARNING }
    $Certs = New-Object System.Collections.Generic.List[object]
    foreach ($C in $Cfg.Certificates) { $Certs.Add($C) }
    $Live = @(Get-IisHttpsBinding)

    Write-Host "`nIIS certificates on $env:COMPUTERNAME ($($Cfg.DeploymentsPath)):" -ForegroundColor Cyan
    Show-Mapping -Certificates $Certs -Bindings $Live
    if ($List) { return }

    #region Remove
    if ($Remove) {
        if (-not $MainDomain) {
            $n = Read-Numbers -Prompt 'Number of the certificate entry to remove' -Max $Certs.Count
            if (-not $n) { Write-Host '  Nothing removed.'; return }
            $MainDomain = $Certs[$n[0] - 1].MainDomain
        }
        $E = $Certs | Where-Object { $_.MainDomain -eq $MainDomain.ToLower() } | Select-Object -First 1
        if (-not $E) { throw "$MainDomain is not in the mapping." }
        if (-not (Read-YesNo "Remove $($E.MainDomain) from the mapping? IIS and the certificate store are not changed; the task stops managing it." $false)) { return }
        [void]$Certs.Remove($E)
        Save-IisCertificateConfig -Certificates $Certs -Path $Cfg.DeploymentsPath -KeepBackups $Cfg.KeepBackups
        Write-AddLog "Removed $($E.MainDomain) from the IIS certificate mapping."
        return
    }
    #endregion

    #region 1. Certificate
    Write-Host "`n[1/3] Certificate" -ForegroundColor Cyan
    $Entry = $null
    if (-not $MainDomain -and $Certs.Count) {
        $Pick = Read-Value -Prompt "Number of an existing certificate to add bindings to, or Enter for a new certificate"
        if ($Pick -match '^\d+$' -and [int]$Pick -ge 1 -and [int]$Pick -le $Certs.Count) { $Entry = $Certs[[int]$Pick - 1]; $MainDomain = $Entry.MainDomain }
    }
    if (-not $MainDomain) {
        $Fqdn = ('{0}.{1}' -f $env:COMPUTERNAME, (Get-CimInstance Win32_ComputerSystem).Domain).ToLower()
        $MainDomain = Read-Value -Prompt 'Main DNS name for the certificate' -Default $Fqdn
    }
    $MainDomain = $MainDomain.Trim().ToLower()
    if (-not $Entry) { $Entry = $Certs | Where-Object { $_.MainDomain -eq $MainDomain } | Select-Object -First 1 }

    $Order = Get-PAOrder -MainDomain $MainDomain
    if (-not $Entry) {
        if (-not $AltName -and -not $Order) {
            $AltText = Read-Value -Prompt 'Extra DNS names (comma separated, Enter for none)'
            $AltName = @($AltText -split '[,\s]+' | Where-Object { $_ })
        }
        $Names = @(@($MainDomain) + @($AltName | ForEach-Object { $_.Trim().ToLower() }) | Where-Object { $_ } | Select-Object -Unique)
        if ($Order) { $Names = @(@($Order.MainDomain) + @($Order.SANs) | Where-Object { $_ } | ForEach-Object { "$_".ToLower() } | Select-Object -Unique) }
        $Entry = [pscustomobject]@{ MainDomain = $MainDomain; Names = $Names; Enabled = $true; Bindings = @() }
    }

    if ($Order) {
        $Pa = Get-PACertificate -MainDomain $MainDomain
        Write-AddLog "Posh-ACME order $MainDomain exists ($($Order.status)); names: $((@($Order.MainDomain) + @($Order.SANs) | Where-Object { $_ }) -join ', '); certificate $(if ($Pa) { "$($Pa.Thumbprint), expires $($Pa.NotAfter)" } else { 'none yet' })."
    }
    else {
        $Sources = @(Get-PAOrder -List | Where-Object { $_.Plugin })
        if (-not $Sources) { throw "Posh-ACME has no order on this server to copy DNS plugin settings from. Request the first certificate with ..\Show-PoshAcmeCertificateManagement.ps1 (Certificates tab, any DNS provider), then run this again or assign it there." }
        Write-Host '  No Posh-ACME order for this name yet. Copy the DNS validation settings from:'
        $i = 0; foreach ($S in $Sources) { $i++; Write-Host ("   {0}) {1}  plugin {2}" -f $i, $S.MainDomain, ($S.Plugin -join ',')) }
        $n = if ($Sources.Count -eq 1) { @(1) } else { Read-Numbers -Prompt 'Number' -Max $Sources.Count }
        if (-not $n) { throw 'No DNS settings chosen; nothing requested.' }
        $Src = $Sources[$n[0] - 1]
        if (-not (Read-YesNo "Request a Let's Encrypt certificate for $($Entry.Names -join ', ') now (DNS validation via $($Src.Plugin -join ','), like $($Src.MainDomain))?" $true)) { throw 'Not requested; nothing saved.' }
        $PluginArgs = Get-PAPluginArgs -MainDomain $Src.MainDomain
        $New = New-PACertificate -Domain $Entry.Names -Plugin $Src.Plugin -PluginArgs $PluginArgs -AcceptTOS
        if (-not $New) { throw "Let's Encrypt did not issue a certificate for $($Entry.Names -join ', '). See the messages above." }
        Write-AddLog "Requested certificate $($New.Thumbprint) for $($Entry.Names -join ', ') (expires $($New.NotAfter)), DNS settings copied from $($Src.MainDomain)."
    }
    #endregion

    #region 2. Sites
    Write-Host "`n[2/3] IIS sites" -ForegroundColor Cyan
    $Sites = @(Get-Website | Sort-Object Name)
    if (-not $Sites) { throw 'No IIS sites on this server.' }
    if (-not $SiteName) {
        $i = 0
        foreach ($S in $Sites) {
            $i++
            $Https = @($Live | Where-Object SiteName -eq $S.Name)
            Write-Host ("   {0}) {1,-30} {2}" -f $i, $S.Name, $(if ($Https) { "https: $(($Https | ForEach-Object { $_.Key }) -join ' | ')" } else { 'no https binding yet' }))
        }
        $n = Read-Numbers -Prompt 'Site number(s) to bind this certificate to (comma separated)' -Max $Sites.Count
        if (-not $n) { throw 'No site chosen; nothing saved.' }
        $SiteName = @($n | ForEach-Object { $Sites[$_ - 1].Name })
    }
    foreach ($S in $SiteName) { if (@($Sites.Name) -notcontains $S) { throw "IIS site '$S' does not exist on this server." } }
    #endregion

    #region 3. Bindings per site
    Write-Host "`n[3/3] Bindings" -ForegroundColor Cyan
    $Bindings = New-Object System.Collections.Generic.List[object]
    foreach ($B in @($Entry.Bindings)) { $Bindings.Add($B) }
    $Interactive = -not ($UseExistingBindings -or $PSBoundParameters.ContainsKey('HostHeader'))
    function Add-Binding {
        param([string]$Site, [string]$Ip, [int]$P, [string]$HostName, [bool]$Sni)
        $Key = '{0}:{1}:{2}' -f $Ip, $P, $HostName.ToLower()
        if ($Bindings | Where-Object { $_.SiteName -eq $Site -and $_.Key -eq $Key }) { Write-Host "   (already mapped: $Site $Key)"; return }
        $Other = $Certs | Where-Object { $_.MainDomain -ne $Entry.MainDomain -and ($_.Bindings | Where-Object { $_.SiteName -eq $Site -and $_.Key -eq $Key }) }
        if ($Other) { Write-AddLog "$Site $Key is mapped to $($Other[0].MainDomain); it now moves to $($Entry.MainDomain)." -LogType WARNING; foreach ($O in $Other) { $O.Bindings = @($O.Bindings | Where-Object { -not ($_.SiteName -eq $Site -and $_.Key -eq $Key) }) } }
        $Bindings.Add([pscustomobject]@{ SiteName = $Site; IPAddress = $Ip; Port = $P; HostHeader = $HostName.ToLower(); RequireSNI = $Sni; Key = $Key })
        Write-Host "   + $Site https $Key$(if ($Sni) { ' (SNI)' })"
    }
    foreach ($S in $SiteName) {
        $Existing = @($Live | Where-Object SiteName -eq $S)
        $UseExisting = $UseExistingBindings
        if ($Interactive -and $Existing) {
            Write-Host "  $S has $($Existing.Count) HTTPS binding(s): $(($Existing | ForEach-Object { $_.Key + $(if ($_.RequireSNI) { ' (SNI)' }) }) -join ' | ')"
            $UseExisting = Read-YesNo "  Use $(if ($Existing.Count -gt 1) { 'all of them' } else { 'it' }) for $($Entry.MainDomain)?" $true
        }
        if ($UseExisting) { foreach ($E in $Existing) { Add-Binding -Site $S -Ip $E.IPAddress -P $E.Port -HostName $E.HostHeader -Sni $E.RequireSNI } }
        if ($Interactive) {
            $More = -not ($UseExisting -and $Existing)
            if (-not $More) { $More = Read-YesNo "  Add another binding on $S?" $false }
            while ($More) {
                $H = Read-Value -Prompt "  Host name for the binding (Enter = all names)" -Default $(if (-not $Existing) { $Entry.MainDomain } else { '' })
                $P2 = [int](Read-Value -Prompt '  Port' -Default '443')
                $I2 = Read-Value -Prompt '  IP address (* = all unassigned)' -Default '*'
                $Sni = if ($H) { Read-YesNo '  Require SNI?' $true } else { $false }
                Add-Binding -Site $S -Ip $I2 -P $P2 -HostName $H -Sni $Sni
                $More = Read-YesNo "  Add another binding on $S?" $false
            }
        }
        elseif (-not $UseExistingBindings) {
            Add-Binding -Site $S -Ip $IPAddress -P $Port -HostName "$HostHeader" -Sni ([bool]$RequireSNI)
        }
    }
    if (-not $Bindings.Count) { throw 'No bindings chosen; nothing saved.' }
    $Entry.Bindings = @($Bindings)
    #endregion

    #region Save and deploy
    if (-not ($Certs | Where-Object { $_.MainDomain -eq $Entry.MainDomain })) { $Certs.Add($Entry) }
    Save-IisCertificateConfig -Certificates $Certs -Path $Cfg.DeploymentsPath -KeepBackups $Cfg.KeepBackups
    Write-AddLog "Mapping saved: $($Entry.MainDomain) -> $(($Entry.Bindings | ForEach-Object { "$($_.SiteName) $($_.Key)" }) -join '; ')."
    $Renew = Join-Path -Path $SCA -ChildPath 'Renew-IisLE.ps1'
    if ($DeployNow -or (Read-YesNo "`nDeploy $($Entry.MainDomain) to these bindings now?" $true)) {
        & $Renew -MainDomain $Entry.MainDomain -DeployCurrent
    }
    else { Write-Host "  Not deployed now; the nightly task (or: & '$Renew' -MainDomain $($Entry.MainDomain) -DeployCurrent) will do it." }
    #endregion
}
catch {
    Write-AddLog "Add-IisCertificate: $($_.Exception.Message)" -LogType ERROR
    throw
}

# Example usage:
# PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\IisServer\Add-IisCertificate.ps1
# PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\IisServer\Add-IisCertificate.ps1 -List
# PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\IisServer\Add-IisCertificate.ps1 -MainDomain netsolutions.generationsgaither.com -SiteName 'Default Web Site' -HostHeader netsolutions.generationsgaither.com -RequireSNI -DeployNow


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCL1w5YYLdgLg/P
# Bf2j4dwRyqhl394Afjj95JPg0YXt8qCCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIHlZeWjG
# +XbyKLtvbXxOZEbpkp/2ASkXKkJB/IdOa743MA0GCSqGSIb3DQEBAQUABIIBAFzI
# NiM+HZR2zI3kJbWJbqAZVKQO0mT6sQRHMfVv8AVma5M+RKlVdLYHxJEYHdtgU1Qa
# ghxWGpozIaMcClINhkzl488oSePMTGg/n9fqIz1R/dzCqosDGhAmJ4k0snhMt/Kf
# l6pNa4OYrCPGb1fopQ7Rt2gdI5YBaG1FlcA2f87P6H3lRPA0EN0LYE3C6dT5qi8c
# tvdbQF0v886ox1sOaEPckvktxAcpkRKfxilsEjNqKhDB3GyMxB2Y2jrG3o6KvIlW
# zs3sMoIiD3nX9EOFQo4fkbbSutTbavgjbeURvXKGUnSkzakUNsfMwuku8ky6g0y9
# h6/2B8estMhVCpa973uhggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDIxMjA0
# OTQ4WjAvBgkqhkiG9w0BCQQxIgQg6E+L0hBG85V0L4MEp+14Mo2ebrW7TcYKaa9B
# 33aOCS8wDQYJKoZIhvcNAQEBBQAEggIAaHcNMeDi5R8Xme1esxexUxw8ZhJPmRIT
# tUDy+V9in5w1FC/10Fau5yLSoUlA6D1t81vl2y0njVq2WVKTcw4xaUDIzvcNZFFV
# A8el0VIpveXdp3fBqAYHDBY+zCSM78fGOuSVI01VanAfF/IV4cRf51gO/fbxMOuP
# NsSSmX2N/ZM5989p8HDg4T1TzQ+3pwayTK89E38QFaO2p6uKTHtkn/hWowLmWyif
# 6nMz98XTjGdOZ26roW8H2UmkdJMEtFq24i6Tf280wAP2HzjWJvwct13kCQ5p0J5x
# 2fbD/fd0EF0CGpvrOfLjd+y4sWfY2MGshUlb/GJmGPCeXGE3LSwzZZgP/ppK+35c
# x/1nikJxLYHkvGnakqVNVxDyUHi0wX5rmhejCK3PfFXUEwa+3MfhxOFW9pKa7SPz
# EiULxeY0tvOcx72aP2mvQ//TD7MM22ej9BzKQRHyPpq12fCsZ98JOmpVFgusazDR
# Y59tSStFdlD1Yii5sT5nZQNUjQo6VHr+rlnr0sRdxItsqq/NxTQRBuMMccbh6ZvG
# bIS3ejAVdFjn7q1XZm598Bih/OXu2RxuU8wGjRNjazn97+ojhHtLqclZlaYF1KNt
# +n+xlhDnJP2nR+7MsaLGefXQ74I8LjbeE/84XgMA8MnbqT2XL9X7FBW454ge+a9L
# QWjnaFRTkVc=
# SIG # End signature block
