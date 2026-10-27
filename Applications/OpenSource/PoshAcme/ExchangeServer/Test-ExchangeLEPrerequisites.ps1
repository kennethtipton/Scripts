<#
.SYNOPSIS
    Read-only pre-install check for the Exchange role of the PoshAcme application.
.DESCRIPTION
    Run on each Exchange server after ..\Install-PoshAcme.ps1 and before Install-ExchangeLE.ps1.
    Changes nothing; it only reports. The general Posh-ACME checks (modules, network, old data)
    are in ..\Test-PoshAcmePrerequisites.ps1.

    Checks:
      Session     Elevated, Windows PowerShell 5.1 (not pwsh 7 / not required to be EMS)
      Package     Role files present next to this script, signed (Valid), not blocked, no syntax errors
      Shared      Write-AdvancedLog in $SF
      Posh-ACME   Core installed: Posh-ACME 4.0+ and Posh-ACME.Deploy, shared Certs folder with an
                  LE_PROD account, order for this server, current certificate, validation plugin
      Exchange    Snap-in, Exchange Back End :444 binding, 443/444 certificates, internal transport
                  certificate, certificates Set-ExchangeCertificate would remove, app pools
      Tasks       Old C:\POSHACME tasks (and the account they run as), existing new task
      WinRM       Service, HTTP listener, http.sys URL reservation and IP listen list, firewall
                  rule, Test-WSMan and a real Invoke-Command to this server and to the other
                  Exchange server(s)

    Each result is PASS, WARN, FAIL or INFO. Exit code is 1 if anything outside the WinRM
    section FAILs (WinRM is reported but does not affect the install).

    Read-only unless -RepairWinRM is used. That switch only fixes what is missing: sets the WinRM
    service to Automatic and starts it, creates an HTTP listener on all addresses if there is
    none, and enables the domain/private 'Windows Remote Management (HTTP-In)' firewall rule.
    The checks then run against the repaired state.
.PARAMETER Domain
    Certificate main domain. Defaults to this computer's FQDN.
.PARAMETER InternalTransportThumbprint
    Certificate the renew script pins as the internal transport certificate.
.PARAMETER TaskPath
    Task Scheduler folder of the new renewal task.
.PARAMETER TaskName
    Name of the new renewal task.
.PARAMETER ExchangeServers
    All Exchange servers (FQDN). Every server other than this one gets the remote WinRM tests.
.PARAMETER RepairWinRM
    Fix missing WinRM pieces (service, HTTP listener, firewall rule) before testing.
.PARAMETER SkipWinRMTests
    Skips the WinRM section entirely. The Let's Encrypt scripts run locally and do not need
    WinRM, so WinRM results never block the install verdict either way.
.PARAMETER ReportPath
    Optional file to save the results to (text).
.EXAMPLE
    PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\ExchangeServer\Test-ExchangeLEPrerequisites.ps1
.EXAMPLE
    PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\ExchangeServer\Test-ExchangeLEPrerequisites.ps1 -RepairWinRM
.EXAMPLE
    PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\ExchangeServer\Test-ExchangeLEPrerequisites.ps1 -ReportPath "C:\SCRIPTS\Logs\ExchangeLE-Preflight-$env:COMPUTERNAME.txt"
.INPUTS
    None
.OUTPUTS
    Exit code 0 when nothing outside the WinRM section FAILs, otherwise 1.
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-12
    Time: 17:00:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 2.1.0
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: Claude

    Copyright (c) 2026
    Licensed under the MIT License.
    Full text available at: https://opensource.org/licenses/MIT

    Overide Variables
    Overide Filename:
    Overide Log Filename:
    Overide Text Log File Path:
    Overide Log Type:
.LINK
    https://www.tnandc.com
#>
[CmdletBinding()]
param(
    [string]$Domain,
    [string]$InternalTransportThumbprint,
    [string]$TaskPath,
    [string]$TaskName,
    [string[]]$ExchangeServers,
    [switch]$RepairWinRM,
    [switch]$SkipWinRMTests,
    [string]$ReportPath
)

$ErrorActionPreference = 'Continue'

#region Standard locations
$SCA = $PSScriptRoot                           # C:\SCRIPTS\Applications\OpenSource\PoshAcme\ExchangeServer
# $SA is the nearest parent folder named 'Applications', however deep the app is nested
$SA  = $SCA
while ($SA -and (Split-Path -Path $SA -Leaf) -ne 'Applications') { $SA = Split-Path -Path $SA -Parent }
if (-not $SA) { throw "$SCA is not inside an 'Applications' folder." }
$SL  = Split-Path -Path $SA -Parent            # C:\SCRIPTS
$SF  = Join-Path -Path $SL -ChildPath 'Functions'

$PoshAcmeDir = Split-Path -Path $SCA -Parent   # core: C:\SCRIPTS\Applications\OpenSource\PoshAcme
$CertsDir    = Join-Path -Path $PoshAcmeDir -ChildPath 'Certs'
$CoreHint    = "Run $(Join-Path -Path $PoshAcmeDir -ChildPath 'Install-PoshAcme.ps1') first."

$AppFiles = @(
    'Install-ExchangeLE.ps1'
    'Renew-ExchangeLE.ps1'
    'Test-ExchangeLEPrerequisites.ps1'
    'Functions\Set-ExchangeBackEndCertificate.ps1'
    'Functions\Set-InternalTransportCertificate.ps1'
)
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
if (-not $PSBoundParameters.ContainsKey('InternalTransportThumbprint')) {
    $InternalTransportThumbprint = if ($RoleCfg) { "$($RoleCfg.InternalTransportThumbprint)" } else { '' }
}
$TaskPath = if ($TaskPath) { $TaskPath } elseif ($RoleCfg -and $RoleCfg.TaskPath) { "$($RoleCfg.TaskPath)" } else { '\Exchange\LetsEncrypt\' }
$TaskName = if ($TaskName) { $TaskName } elseif ($RoleCfg -and $RoleCfg.TaskName) { "$($RoleCfg.TaskName)" } else { 'RenewExchangeCertificate' }
if (-not $ExchangeServers) { $ExchangeServers = if ($RoleCfg -and $RoleCfg.ExchangeServers) { @($RoleCfg.ExchangeServers) } else { @($Fqdn) } }

#region Helpers
$Results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')]
        [string]$Status,
        [string]$Area,
        [string]$Check,
        [string]$Detail = ''
    )
    $Results.Add([pscustomobject]@{ Status = $Status; Area = $Area; Check = $Check; Detail = $Detail })
}

function Get-ScriptVersion {
    param([string]$Path)
    $M = Select-String -Path $Path -Pattern '^\s*Version:\s*([\d\.]+)' -List -ErrorAction SilentlyContinue
    if ($M) { $M.Matches[0].Groups[1].Value } else { '' }
}

function Test-ScriptFile {
    # Existence, syntax, signature, blocked (Zone.Identifier), version
    param([string]$Path, [string]$Area, [string]$Label, [string]$MissingStatus = 'FAIL', [string]$MissingDetail = 'Not found.')

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        Add-Result $MissingStatus $Area $Label "$MissingDetail ($Path)"
        return $false
    }

    $Tokens = $null; $Errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$Errors) | Out-Null
    if ($Errors) {
        $E = $Errors[0]
        Add-Result 'FAIL' $Area $Label "Syntax error line $($E.Extent.StartLineNumber): $($E.Message)"
        return $false
    }

    $Ver = Get-ScriptVersion -Path $Path
    $VerText = if ($Ver) { "v$Ver" } else { 'no version' }
    $Sig = "$((Get-AuthenticodeSignature -FilePath $Path).Status)"
    if (Get-Item -Path $Path -Stream Zone.Identifier -ErrorAction SilentlyContinue) {
        Add-Result 'WARN' $Area $Label "$VerText. Blocked (downloaded from the internet): run Unblock-File '$Path'."
    }
    elseif ($Sig -ne 'Valid') {
        Add-Result 'WARN' $Area $Label "$VerText, syntax OK, signature $Sig. Re-sign with Set-ScriptSignature and copy again."
    }
    else {
        Add-Result 'PASS' $Area $Label "$VerText, signed, syntax OK."
    }
    return $true
}

function Test-TcpPort {
    param([string]$HostName, [int]$Port = 443, [int]$TimeoutMs = 4000)
    $Client = New-Object System.Net.Sockets.TcpClient
    try {
        $Ar = $Client.BeginConnect($HostName, $Port, $null, $null)
        if ($Ar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $Client.Connected) { $Client.EndConnect($Ar); return $true }
        return $false
    }
    catch { return $false }
    finally { $Client.Close() }
}

function Get-StoreCert {
    param([string]$Thumbprint)
    if (-not $Thumbprint) { return $null }
    Get-Item -Path "Cert:\LocalMachine\My\$Thumbprint" -ErrorAction SilentlyContinue
}

function Get-SslBindingHash {
    param([int]$Port)
    $Line = netsh http show sslcert ipport=0.0.0.0:$Port | Select-String 'Certificate Hash'
    if ($Line) { ($Line.ToString() -replace '.*:\s*', '').Trim().ToUpper() } else { '' }
}

function Format-Cert {
    param($Cert)
    if (-not $Cert) { return '' }
    $Days = [int]($Cert.NotAfter - (Get-Date)).TotalDays
    '{0} | {1} | expires {2:yyyy-MM-dd} ({3} days)' -f $Cert.Thumbprint, $Cert.Subject, $Cert.NotAfter, $Days
}
#endregion

Write-Host "`nExchange Let's Encrypt pre-install check on $env:COMPUTERNAME ($Domain)" -ForegroundColor Cyan
Write-Host "Package folder: $PSScriptRoot`n"

#region 1. Session
$Principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Add-Result 'PASS' 'Session' 'Elevated' "Running as $env:USERDOMAIN\$env:USERNAME."
}
else {
    Add-Result 'FAIL' 'Session' 'Elevated' 'Not elevated. The installer requires Run as administrator (and some checks below are incomplete).'
}

if ($PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5) {
    Add-Result 'PASS' 'Session' 'Windows PowerShell 5.1' "$($PSVersionTable.PSVersion)"
}
else {
    Add-Result 'FAIL' 'Session' 'Windows PowerShell 5.1' "This is PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)). Run the installer in powershell.exe: the task and the Exchange snap-in use 5.1."
}
#endregion

#region 2. Package
foreach ($Rel in $AppFiles) {
    Test-ScriptFile -Path (Join-Path -Path $SCA -ChildPath $Rel) -Area 'Package' -Label $Rel | Out-Null
}
#endregion

#region 3. Shared functions
$WalPath = Join-Path -Path $SF -ChildPath 'Write-AdvancedLog.ps1'
if (Test-ScriptFile -Path $WalPath -Area 'Shared' -Label 'Write-AdvancedLog.ps1' -MissingStatus 'WARN' -MissingDetail 'Missing; scripts will log to the transcript only.') {
    $V = Get-ScriptVersion -Path $WalPath
    if ($V -and ([version]$V -lt [version]'1.1.0')) {
        Add-Result 'WARN' 'Shared' 'Write-AdvancedLog version' "v$V. Works for these scripts, but update to 1.1.0 (INFO events, PS 7 path)."
    }
}
#endregion

#region 4. Posh-ACME core
$OrderCert = $null

$PoshAcme = Get-Module -ListAvailable -Name Posh-ACME | Sort-Object Version -Descending | Select-Object -First 1
if (-not $PoshAcme) { Add-Result 'FAIL' 'Posh-ACME' 'Posh-ACME module' "Not installed. $CoreHint" }
elseif ($PoshAcme.Version.Major -lt 4) { Add-Result 'FAIL' 'Posh-ACME' 'Posh-ACME module' "$($PoshAcme.Version) is too old (4.0+ needed). $CoreHint" }
else { Add-Result 'PASS' 'Posh-ACME' 'Posh-ACME module' "$($PoshAcme.Version)" }

$Deploy = Get-Module -ListAvailable -Name Posh-ACME.Deploy | Sort-Object Version -Descending | Select-Object -First 1
if ($Deploy) { Add-Result 'PASS' 'Posh-ACME' 'Posh-ACME.Deploy module' "$($Deploy.Version)" }
else { Add-Result 'FAIL' 'Posh-ACME' 'Posh-ACME.Deploy module' "Not installed. $CoreHint" }

if (@(Get-ChildItem -Path $CertsDir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
    Add-Result 'FAIL' 'Posh-ACME' 'Shared Certs folder' "$CertsDir is missing or empty. $CoreHint"
}
else {
    Add-Result 'PASS' 'Posh-ACME' 'Shared Certs folder' $CertsDir

    $ServerDir = Get-ChildItem -Path $CertsDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'LE_PROD' -or $_.Name -like 'acme-v02.api.letsencrypt.org*' } | Select-Object -First 1
    if (-not $ServerDir) {
        Add-Result 'FAIL' 'Posh-ACME' 'LE_PROD data' "No Let's Encrypt folder (LE_PROD or acme-v02.api.letsencrypt.org) in $CertsDir."
    }
    else {
        $Accounts = @(Get-ChildItem -Path $ServerDir.FullName -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'acct.json') })
        if ($Accounts.Count -gt 0) {
            Add-Result 'PASS' 'Posh-ACME' 'ACME account(s)' ($Accounts.Name -join ', ')
        }
        else {
            Add-Result 'FAIL' 'Posh-ACME' 'ACME account(s)' "No account folders (acct.json) under $($ServerDir.FullName)."
        }

        # Newer stores name the order folder after the order name, so match on MainDomain in order.json
        $OrderDir = Get-ChildItem -Path $ServerDir.FullName -Recurse -Filter 'order.json' -File -ErrorAction SilentlyContinue |
            Where-Object { try { "$((Get-Content -Path $_.FullName -Raw | ConvertFrom-Json).MainDomain)" -eq $Domain } catch { $_.Directory.Name -eq $Domain } } |
            Select-Object -First 1 | ForEach-Object { $_.Directory }
        if (-not $OrderDir) {
            Add-Result 'FAIL' 'Posh-ACME' "Order $Domain" "No order with main domain $Domain. Set Domain in ..\Data\PoshAcme.$env:COMPUTERNAME.json to the main domain of this server's order."
        }
        else {
            $AcctOfOrder = Split-Path -Path $OrderDir.Parent.FullName -Leaf
            Add-Result 'PASS' 'Posh-ACME' "Order $Domain" "Found under account $AcctOfOrder."

            $CertFile = Join-Path -Path $OrderDir.FullName -ChildPath 'cert.cer'
            if (Test-Path -Path $CertFile) {
                try {
                    $OrderCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertFile)
                    $Days = ($OrderCert.NotAfter - (Get-Date)).TotalDays
                    $Status = if ($Days -lt 0) { 'FAIL' } elseif ($Days -lt 14) { 'WARN' } else { 'PASS' }
                    Add-Result $Status 'Posh-ACME' 'Current LE certificate' (Format-Cert $OrderCert)
                    if (-not (Get-StoreCert -Thumbprint $OrderCert.Thumbprint)) {
                        Add-Result 'WARN' 'Posh-ACME' 'LE certificate in LocalMachine\My' 'Not installed in the machine store; -DeployCurrent will import it.'
                    }
                }
                catch {
                    Add-Result 'WARN' 'Posh-ACME' 'Current LE certificate' "Could not read ${CertFile}: $($_.Exception.Message)"
                }
            }
            else {
                Add-Result 'WARN' 'Posh-ACME' 'Current LE certificate' "cert.cer not found in $($OrderDir.FullName)."
            }

            $OrderJson = Join-Path -Path $OrderDir.FullName -ChildPath 'order.json'
            if (Test-Path -Path $OrderJson) {
                try {
                    $Order = Get-Content -Path $OrderJson -Raw | ConvertFrom-Json
                    $Plugin = ((@($Order.Plugin) | Select-Object -Unique) -join ', ')
                    if (-not $Plugin) { $Plugin = '(not recorded)' }
                    $HasArgs = Test-Path -Path (Join-Path -Path $OrderDir.FullName -ChildPath 'pluginargs.json')
                    $Note = if ($HasArgs) { ' Plugin args saved; the task must run as the account that created them.' } else { '' }
                    Add-Result 'INFO' 'Posh-ACME' 'Validation plugin' "$Plugin.$Note"
                }
                catch {
                    Add-Result 'WARN' 'Posh-ACME' 'Validation plugin' "Could not read order.json: $($_.Exception.Message)"
                }
            }
        }
    }
}
#endregion

#region 5. Exchange and IIS
$Snapin = Get-PSSnapin -Registered -Name Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction SilentlyContinue
if ($Snapin) { Add-Result 'PASS' 'Exchange' 'Exchange snap-in' 'Registered.' }
else { Add-Result 'FAIL' 'Exchange' 'Exchange snap-in' 'Microsoft.Exchange.Management.PowerShell.SnapIn is not registered. Is this an Exchange server?' }

$HaveWebAdmin = $false
try { Import-Module WebAdministration -ErrorAction Stop; $HaveWebAdmin = $true; Add-Result 'PASS' 'Exchange' 'WebAdministration module' 'Available.' }
catch { Add-Result 'FAIL' 'Exchange' 'WebAdministration module' $_.Exception.Message }

if ($HaveWebAdmin) {
    $Binding = Get-WebBinding -Name 'Exchange Back End' -Protocol https -Port 444 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($Binding) { Add-Result 'PASS' 'Exchange' 'Exchange Back End https:444' 'Binding exists.' }
    else { Add-Result 'FAIL' 'Exchange' 'Exchange Back End https:444' "No https:444 binding on 'Exchange Back End'." }

    $Pools = @(Get-ChildItem -Path IIS:\AppPools | Where-Object Name -like 'MSExchange*')
    $BadPools = @($Pools | Where-Object { $_.State -ne 'Started' -or -not $_.autoStart })
    if ($BadPools.Count -eq 0) {
        Add-Result 'PASS' 'Exchange' 'Exchange app pools' "$($Pools.Count) pools started with autoStart on."
    }
    else {
        Add-Result 'WARN' 'Exchange' 'Exchange app pools' (($BadPools | ForEach-Object { "$($_.Name) [$($_.State), autoStart=$($_.autoStart)]" }) -join '; ')
    }
}

foreach ($Port in 443, 444) {
    $Hash = Get-SslBindingHash -Port $Port
    if (-not $Hash) { Add-Result 'FAIL' 'Exchange' "0.0.0.0:$Port certificate" 'No SSL binding found.'; continue }
    $C = Get-StoreCert -Thumbprint $Hash
    if (-not $C) {
        Add-Result 'WARN' 'Exchange' "0.0.0.0:$Port certificate" "$Hash is NOT in LocalMachine\My (missing cert). -DeployCurrent will rebind it."
    }
    elseif ($OrderCert -and $Hash -ne $OrderCert.Thumbprint.ToUpper()) {
        Add-Result 'WARN' 'Exchange' "0.0.0.0:$Port certificate" "$(Format-Cert $C). Not the current LE cert; -DeployCurrent will rebind it."
    }
    else {
        Add-Result 'PASS' 'Exchange' "0.0.0.0:$Port certificate" (Format-Cert $C)
    }
}

if (-not $InternalTransportThumbprint) {
    Add-Result 'INFO' 'Exchange' 'Pinned transport cert' 'No InternalTransportThumbprint in the settings: the renew script leaves internal transport alone (Set-ExchangeCertificate will make the LE cert the SMTP default).'
}
$ItCert = Get-StoreCert -Thumbprint $InternalTransportThumbprint
if (-not $InternalTransportThumbprint) { }
elseif ($ItCert) { Add-Result 'PASS' 'Exchange' 'Pinned transport cert present' (Format-Cert $ItCert) }
else { Add-Result 'WARN' 'Exchange' 'Pinned transport cert present' "$InternalTransportThumbprint not in LocalMachine\My; the renew script will warn and leave transport alone." }

if ($Snapin) {
    try {
        if (-not (Get-PSSnapin -Name Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction SilentlyContinue)) {
            Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction Stop
        }

        $Current = "$((Get-TransportService -Identity $env:COMPUTERNAME -ErrorAction Stop).InternalTransportCertificateThumbprint)".ToUpper()
        if (-not $InternalTransportThumbprint) {
            Add-Result 'INFO' 'Exchange' 'Internal transport certificate' "Currently $Current; not pinned (no InternalTransportThumbprint in the settings)."
        }
        elseif ($Current -eq $InternalTransportThumbprint.ToUpper()) {
            Add-Result 'PASS' 'Exchange' 'Internal transport certificate' "$Current (already pinned)."
        }
        else {
            Add-Result 'INFO' 'Exchange' 'Internal transport certificate' "Currently $Current; the renew script will change it to $InternalTransportThumbprint."
        }

        # Set-ExchangeCertificate removes OTHER certs whose services are exactly IMAP, POP, IIS, SMTP
        $LeThumb = if ($OrderCert) { $OrderCert.Thumbprint.ToUpper() } else { '' }
        $Target = @('IMAP', 'POP', 'IIS', 'SMTP')
        $AtRisk = @(Get-ExchangeCertificate -Server $env:COMPUTERNAME -ErrorAction Stop | Where-Object {
            $Svc = @("$($_.Services)" -split ',\s*' | Where-Object { $_ })
            -not (Compare-Object -ReferenceObject $Target -DifferenceObject $Svc) -and $_.Thumbprint.ToUpper() -ne $LeThumb
        })
        if ($AtRisk.Count -eq 0) {
            Add-Result 'PASS' 'Exchange' 'Certs Set-ExchangeCertificate would remove' 'None besides the current LE cert.'
        }
        else {
            Add-Result 'WARN' 'Exchange' 'Certs Set-ExchangeCertificate would remove' ((($AtRisk | ForEach-Object { Format-Cert $_ })) -join ' ; ')
        }
    }
    catch {
        Add-Result 'WARN' 'Exchange' 'Exchange cmdlet checks' "Could not run Exchange cmdlets: $($_.Exception.Message)"
    }
}
#endregion

#region 6. Scheduled tasks
$OldTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -match [regex]::Escape('C:\POSHACME\')
})
if ($OldTasks.Count -eq 0) {
    Add-Result 'INFO' 'Tasks' 'Old C:\POSHACME tasks' 'None found.'
}
foreach ($T in $OldTasks) {
    $User = $T.Principal.UserId
    try { $User = (New-Object System.Security.Principal.SecurityIdentifier($User)).Translate([System.Security.Principal.NTAccount]).Value } catch { }
    Add-Result 'INFO' 'Tasks' "Old task $($T.TaskPath)$($T.TaskName)" "State $($T.State), runs as $User. Give the installer this same account."
}

$NewTask = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
if ($NewTask) { Add-Result 'INFO' 'Tasks' "$TaskPath$TaskName" "Already exists (State $($NewTask.State)); the installer will replace it." }
else { Add-Result 'INFO' 'Tasks' "$TaskPath$TaskName" 'Not present yet; the installer will create it.' }
#endregion

#region 7. WinRM
if ($SkipWinRMTests) {
    Add-Result 'INFO' 'WinRM' 'WinRM tests' 'Skipped (-SkipWinRMTests).'
}
else {
$IsAdmin = $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# 7-0. Group Policy. A GPO that controls the listener means the missing listener is a policy
#      decision; local changes would be overridden at the next policy refresh.
$PolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WinRM\Service'
$Policy = Get-ItemProperty -Path $PolicyKey -ErrorAction SilentlyContinue
$GpoControlsListener = $false
if ($Policy -and ($null -ne $Policy.AllowAutoConfig)) {
    $GpoControlsListener = $true
    $Filters = 'IPv4Filter "{0}", IPv6Filter "{1}"' -f $Policy.IPv4Filter, $Policy.IPv6Filter
    if ($Policy.AllowAutoConfig -eq 0) {
        Add-Result 'WARN' 'WinRM' 'Group Policy' "Remote management through WinRM is DISABLED by Group Policy ($Filters). The missing listener is a policy decision; change the GPO rather than the server."
    }
    elseif (-not $Policy.IPv4Filter -and -not $Policy.IPv6Filter) {
        Add-Result 'WARN' 'WinRM' 'Group Policy' "Enabled by Group Policy but with empty IP filters, so no listener gets created. Set the filters (e.g. *) in the GPO."
    }
    else {
        Add-Result 'INFO' 'WinRM' 'Group Policy' "Listener managed by Group Policy ($Filters)."
    }
}
else {
    Add-Result 'INFO' 'WinRM' 'Group Policy' 'No WinRM listener policy; the listener is configured locally.'
}

# 7a. Optional repair (only what is missing)
if ($RepairWinRM -and $GpoControlsListener) {
    Add-Result 'WARN' 'WinRM' 'Repair' 'Skipped: the listener is controlled by Group Policy. Change the GPO instead.'
}
elseif ($RepairWinRM) {
    if (-not $IsAdmin) {
        Add-Result 'FAIL' 'WinRM' 'Repair' '-RepairWinRM needs an elevated session. Nothing changed.'
    }
    else {
        try {
            $Svc = Get-Service -Name WinRM -ErrorAction Stop
            if ("$($Svc.StartType)" -ne 'Automatic') {
                Set-Service -Name WinRM -StartupType Automatic -ErrorAction Stop
                Add-Result 'INFO' 'WinRM' 'Repair: service startup' "Changed from $($Svc.StartType) to Automatic."
            }
            if ($Svc.Status -ne 'Running') {
                Start-Service -Name WinRM -ErrorAction Stop
                Add-Result 'INFO' 'WinRM' 'Repair: service' 'Started.'
            }

            $HttpListener = @(Get-ChildItem -Path WSMan:\localhost\Listener -ErrorAction Stop | Where-Object { $_.Keys -contains 'Transport=HTTP' })
            if ($HttpListener.Count -eq 0) {
                New-Item -Path WSMan:\localhost\Listener -Transport HTTP -Address * -Force -ErrorAction Stop | Out-Null
                Add-Result 'INFO' 'WinRM' 'Repair: HTTP listener' 'Created HTTP listener on all addresses (port 5985).'
            }

            $FwRule = Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP' -ErrorAction SilentlyContinue
            if ($FwRule -and "$($FwRule.Enabled)" -ne 'True') {
                Enable-NetFirewallRule -Name 'WINRM-HTTP-In-TCP' -ErrorAction Stop
                Add-Result 'INFO' 'WinRM' 'Repair: firewall' "Enabled 'Windows Remote Management (HTTP-In)' (domain/private)."
            }
        }
        catch {
            Add-Result 'FAIL' 'WinRM' 'Repair' $_.Exception.Message
        }
    }
}

# 7b. Service
$Svc = Get-Service -Name WinRM -ErrorAction SilentlyContinue
if (-not $Svc) {
    Add-Result 'FAIL' 'WinRM' 'Service' 'WinRM service not found.'
}
elseif ($Svc.Status -eq 'Running' -and "$($Svc.StartType)" -eq 'Automatic') {
    Add-Result 'PASS' 'WinRM' 'Service' 'Running, Automatic.'
}
else {
    Add-Result 'FAIL' 'WinRM' 'Service' "Status $($Svc.Status), startup $($Svc.StartType). -RepairWinRM sets Automatic and starts it."
}

# 7c. Listeners
$ListenerOk = $false
try {
    $Listeners = @(Get-ChildItem -Path WSMan:\localhost\Listener -ErrorAction Stop)
    if ($Listeners.Count -eq 0) {
        Add-Result 'FAIL' 'WinRM' 'Listener' 'No WinRM listeners configured. This matches the "HTTP URL was not available" error. -RepairWinRM creates one.'
    }
    foreach ($L in $Listeners) {
        $Props = @{}
        Get-ChildItem -Path $L.PSPath | ForEach-Object { $Props[$_.Name] = "$($_.Value)" }
        $Detail = 'Transport {0}, Address {1}, Port {2}, Enabled {3}, URLPrefix {4}' -f $Props.Transport, $Props.Address, $Props.Port, $Props.Enabled, $Props.URLPrefix
        if ($Props.Transport -eq 'HTTP' -and $Props.Enabled -eq 'true' -and $Props.Address -eq '*' -and $Props.URLPrefix -eq 'wsman') {
            $ListenerOk = $true
            Add-Result 'PASS' 'WinRM' 'Listener' $Detail
        }
        elseif ($Props.Transport -eq 'HTTP') {
            Add-Result 'WARN' 'WinRM' 'Listener' "$Detail. Expected Address *, Enabled true, URLPrefix wsman."
        }
        elseif ($Props.Transport -eq 'HTTPS' -and $Props.Port -eq '443') {
            Add-Result 'WARN' 'WinRM' 'Listener' "$Detail. WinRM shares port 443 with OWA/IIS: if 443 is published to the internet, https://<server>/wsman is reachable from outside. Remove it unless something needs it."
        }
        else {
            Add-Result 'INFO' 'WinRM' 'Listener' $Detail
        }
    }
}
catch {
    Add-Result 'FAIL' 'WinRM' 'Listener' "Cannot read WSMan:\localhost\Listener: $($_.Exception.Message)"
}

$Compat = Get-Item -Path WSMan:\localhost\Service\EnableCompatibilityHttpsListener -ErrorAction SilentlyContinue
if ($Compat -and "$($Compat.Value)" -eq 'true') {
    Add-Result 'WARN' 'WinRM' 'Compatibility HTTPS listener' 'EnableCompatibilityHttpsListener is on: WinRM also answers on https://<server>:443/wsman. Turn it off unless something needs it.'
}

# 7d. http.sys: URL reservation and IP listen list
$Urlacl = (netsh http show urlacl url=http://+:5985/wsman/) -join ' '
if ($Urlacl -match 'Reserved URL') { Add-Result 'PASS' 'WinRM' 'http.sys URL reservation' 'http://+:5985/wsman/ is reserved.' }
else { Add-Result 'WARN' 'WinRM' 'http.sys URL reservation' 'http://+:5985/wsman/ is not reserved; WinRM may not be able to register its URL.' }

$IpListen = @(netsh http show iplisten | Select-String -Pattern '^\s*(\d{1,3}(\.\d{1,3}){3}|[0-9a-fA-F:]+:[0-9a-fA-F:]*)\s*$' | ForEach-Object { $_.ToString().Trim() })
if ($IpListen.Count -gt 0) {
    Add-Result 'WARN' 'WinRM' 'http.sys IP listen list' "http.sys only listens on: $($IpListen -join ', '). WinRM (and IIS) are unreachable on other addresses."
}
else {
    Add-Result 'PASS' 'WinRM' 'http.sys IP listen list' 'Empty (listens on all addresses).'
}

# 7e. Firewall
$Fw = Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP' -ErrorAction SilentlyContinue
if (-not $Fw) { Add-Result 'WARN' 'WinRM' 'Firewall rule' "'WINRM-HTTP-In-TCP' not found; check the inbound rule for TCP 5985 manually." }
elseif ("$($Fw.Enabled)" -eq 'True') { Add-Result 'PASS' 'WinRM' 'Firewall rule' "'Windows Remote Management (HTTP-In)' enabled (profiles: $($Fw.Profile))." }
else { Add-Result 'FAIL' 'WinRM' 'Firewall rule' "'Windows Remote Management (HTTP-In)' disabled. -RepairWinRM enables it." }

# 7f. Functional tests
#     This server: by its real IPv4 address. Looking up its own name can return its link-local,
#     unique-local or APIPA addresses (whatever it registered in DNS), which are outside the
#     WinRM filter, so a by-name self-test fails even when WinRM is fine.
#     Other Exchange servers: by name, with a real Invoke-Command (the definitive test).
$PsOpt = New-PSSessionOption -OpenTimeout 15000 -OperationTimeout 15000
$Peers = @($ExchangeServers | Where-Object { ($_ -split '\.')[0] -ne $env:COMPUTERNAME })

$SelfIp = @(Resolve-DnsName -Name $Domain -Type A -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -and $_.IPAddress -notlike '169.254.*' } |
    Select-Object -ExpandProperty IPAddress) | Select-Object -First 1

if ($SelfIp) {
    try {
        Test-WSMan -ComputerName $SelfIp -ErrorAction Stop | Out-Null
        Add-Result 'PASS' 'WinRM' "Test-WSMan this server ($SelfIp)" 'WS-Management responds on its own address.'
    }
    catch {
        Add-Result 'FAIL' 'WinRM' "Test-WSMan this server ($SelfIp)" $_.Exception.Message
    }
}
else {
    Add-Result 'WARN' 'WinRM' 'Test-WSMan this server' "No usable A record for $Domain."
}

try {
    Test-WSMan -ComputerName $Domain -ErrorAction Stop | Out-Null
    Add-Result 'PASS' 'WinRM' "Test-WSMan this server by name" 'WS-Management responds.'
}
catch {
    $Own = @(Resolve-DnsName -Name $Domain -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like '169.254.*' -or $_.IPAddress -like 'fe80:*' -or $_.IPAddress -like 'fd*' } |
        Select-Object -ExpandProperty IPAddress)
    $Why = if ($Own) { "DNS returns addresses outside the WinRM filter for this name: $($Own -join ', '). Clean up DNS registration on this server." } else { $_.Exception.Message }
    Add-Result 'INFO' 'WinRM' "Test-WSMan this server by name" "Fails locally. $Why Remote access by name is tested below."
}

foreach ($Target in $Peers) {
    if (-not (Test-TcpPort -HostName $Target -Port 5985)) {
        Add-Result 'FAIL' 'WinRM' "TCP 5985 $Target" 'Not reachable (service stopped, no listener, or firewall).'
        continue
    }

    try {
        Test-WSMan -ComputerName $Target -ErrorAction Stop | Out-Null
        Add-Result 'PASS' 'WinRM' "Test-WSMan $Target" 'WS-Management responds.'
    }
    catch {
        Add-Result 'FAIL' 'WinRM' "Test-WSMan $Target" $_.Exception.Message
        continue
    }

    try {
        $Answer = Invoke-Command -ComputerName $Target -SessionOption $PsOpt -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
        Add-Result 'PASS' 'WinRM' "Invoke-Command $Target" "Remote command ran on $Answer."
    }
    catch {
        Add-Result 'FAIL' 'WinRM' "Invoke-Command $Target" $_.Exception.Message
    }
}
if ($Peers.Count -eq 0) {
    Add-Result 'INFO' 'WinRM' 'Other Exchange servers' 'None in -ExchangeServers besides this one.'
}
}
#endregion

#region Report
$Colors = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Gray' }
$Area = ''
foreach ($R in $Results) {
    if ($R.Area -ne $Area) { $Area = $R.Area; Write-Host "`n[$Area]" -ForegroundColor Cyan }
    Write-Host ('  {0,-4}  ' -f $R.Status) -ForegroundColor $Colors[$R.Status] -NoNewline
    Write-Host ('{0}: {1}' -f $R.Check, $R.Detail)
}

$Counts = $Results | Group-Object Status -AsHashTable -AsString
$N = { param($S) if ($Counts -and $Counts.ContainsKey($S)) { $Counts[$S].Count } else { 0 } }
$Summary = 'Summary for {0}: {1} PASS, {2} WARN, {3} FAIL, {4} INFO' -f $env:COMPUTERNAME, (& $N 'PASS'), (& $N 'WARN'), (& $N 'FAIL'), (& $N 'INFO')
$FailCount = & $N 'FAIL'
# WinRM is reported but does not gate the install: the Let's Encrypt scripts run locally.
$InstallFails = @($Results | Where-Object { $_.Status -eq 'FAIL' -and $_.Area -ne 'WinRM' }).Count
$WinrmFails   = @($Results | Where-Object { $_.Status -eq 'FAIL' -and $_.Area -eq 'WinRM' }).Count
Write-Host "`n$Summary" -ForegroundColor $(if ($FailCount) { 'Red' } elseif (& $N 'WARN') { 'Yellow' } else { 'Green' })
if ($InstallFails) { Write-Host 'Fix the FAIL items before running Install-ExchangeLE.ps1.' -ForegroundColor Red }
else { Write-Host 'Ready to run Install-ExchangeLE.ps1. Review any WARN items first.' -ForegroundColor Green }
if ($WinrmFails) { Write-Host "WinRM has $WinrmFails FAIL item(s). This does not affect the Let's Encrypt install." -ForegroundColor Yellow }

if ($ReportPath) {
    $ReportDir = Split-Path -Path $ReportPath -Parent
    if ($ReportDir) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
    @(
        "Exchange Let's Encrypt pre-install check - $env:COMPUTERNAME ($Domain) - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        ''
        ($Results | Format-Table Status, Area, Check, Detail -AutoSize -Wrap | Out-String -Width 250)
        $Summary
    ) | Set-Content -Path $ReportPath
    Write-Host "Report saved to $ReportPath"
}
#endregion

exit $(if ($InstallFails) { 1 } else { 0 })



# Example usage:
# PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\ExchangeServer\Test-ExchangeLEPrerequisites.ps1
# PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\ExchangeServer\Test-ExchangeLEPrerequisites.ps1 -RepairWinRM


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDo1XzxUudlCLCy
# GeFaiCdpfUU7rWREJGwPjeAFViTFfqCCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIDD4gWg0
# uLI+CVjVYSVSMDqrZfp6+6LJdn5dzfa1AzqXMA0GCSqGSIb3DQEBAQUABIIBAKN/
# PSe+1VDSNaJRpvY0ToGV4Lw8S8SbPhNkWKbsNrBtfvapaerkkteBVxoWf+I+URTX
# 8EoV5/s9Tew35HgSIM2lBL73R3LEqC4b196g2+A3vIRYTdEZHsXpvbxLPnN2mOvJ
# nr7xB7KPEYmNtJfm4zAtnm9SqsuDvtnWlFzotTjLErYoIpH5d39spIncIUV4XEDe
# Cki4d7e1Y1c0zI/QSRAENt1PkgBXdbY+Av4W3Kcy+FF/HVuZUHaqXDHDpfndNBBy
# NRsMreFXlsIWBhd263zR0y/AdSCbOvAYG+0wZR0Yw0v3BjLwtF7Ub2zBOA64YYLR
# fGYOjdNJfZnH+u9pVbuhggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDEzMTY0
# MTI3WjAvBgkqhkiG9w0BCQQxIgQgiN0nBJ/zeieKw+kiUDe40qBUL65eWsPMNxTY
# 7L3cNd8wDQYJKoZIhvcNAQEBBQAEggIArVlp2sjHnGvXGcwGryzv/EOCTI0ziFqM
# tYdN/+9rOA9lumKtMeUTOoAOSF2A9+D+7iE00RLrIeHFys8Ow39T9QglLm0WB3+0
# rrCNYPR0BVFSg8JCkKcFW3pijxmoH+eCjicRV8zuMrxzhiWRfSgrtRWZljcZJiSs
# Kw4r5LXCuY6bIZUX42I2HH34cO7V98pwnnNXnPD7nQC1mnndWj2DgZfkd4K7IdAC
# DaqHNuAkAKQisRlHdW/qqjRM3hJcTcWhB1NBRh0ZMpqIr5edA5OwjpIAVMnL7UKu
# NwZFVP33I3/RqZ8D9/8498/xEN3zxnKdEqYYX1qi6rWzCiMHLYm5pl2VWxftuhn9
# 3lmdkLLzhAp0DSXpmNO8jSYG1SeQq/fIb7vCT0MNS3p+LVWsELcj3Jh1CwCxNSkp
# 1bxKpFOizDc992PhOiDy04DLwU8lfY7uyvaP2TLW2xpE91rA/2/f+Mj6baL/+Z80
# FHQLWAzTq3lw6x2+Ejcl6UrQzg2hIRP0COpj5UkxskTOzozwkVWTT42YOaPtEFig
# G3mKT3yFUahsa5ezps0LcGW0klKhVe1H5U/HtPYa8Hb9dLIXxey2ZM2NisE5nCyf
# 3whaLj4yloKxvMbpryNxBzuo+PirH0Y+maUPz7nosdzwwrw1vLsUTNet3tmfFoE/
# D6x6J29gBnc=
# SIG # End signature block
