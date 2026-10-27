<#
.SYNOPSIS
    Read-only pre-install check for the Posh-ACME core install (Install-PoshAcme.ps1).
.DESCRIPTION
    Run on a server before Install-PoshAcme.ps1. Changes nothing; it only reports.
    Each server role has its own check as well (ExchangeServer\Test-ExchangeLEPrerequisites.ps1).

    Checks:
      Session     Elevated, Windows PowerShell 5.1
      Package     Core files present, signed (Valid), not blocked, no syntax errors
      Shared      $SF (Write-AdvancedLog, Initialize-FileAndFoldersExist), $SG
      Posh-ACME   Data in $SCA\Certs, or the old data in -OldHome that the installer will migrate:
                  LE_PROD account(s), every order with its certificate expiry, order for this server
      Modules     Posh-ACME / Posh-ACME.Deploy versions, installed outside PowerShellGet, NuGet
      Network     TCP 443 to the PowerShell Gallery and Let's Encrypt

    Each result is PASS, WARN, FAIL or INFO. Exit code is 1 if anything FAILs.
.PARAMETER SettingsPath
    Settings file (the same one Install-PoshAcme.ps1 uses). Defaults to Data\PoshAcme.json next to this script.
.PARAMETER OldHome
    Previous POSHACME_HOME folder. Defaults to C:\POSHACME\certs.
.PARAMETER Domain
    Main domain of this server's order. Defaults to Domain in the settings, else this computer's FQDN.
.PARAMETER SkipNetworkTests
    Skips the outbound TCP 443 tests.
.PARAMETER ReportPath
    Optional file to save the results to (text).
.EXAMPLE
    PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\Test-PoshAcmePrerequisites.ps1
.EXAMPLE
    PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\Test-PoshAcmePrerequisites.ps1 -ReportPath "C:\SCRIPTS\Logs\PoshAcme-Preflight-$env:COMPUTERNAME.txt"
.INPUTS
    None
.OUTPUTS
    Exit code 0 when nothing FAILs, otherwise 1.
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-13
    Time: 10:00:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 1.4.1
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
    [string]$SettingsPath,
    [string]$OldHome,
    [string]$Domain,
    [switch]$SkipNetworkTests,
    [string]$ReportPath
)

$ErrorActionPreference = 'Continue'

#region Standard locations
$SCA = $PSScriptRoot                           # C:\SCRIPTS\Applications\OpenSource\PoshAcme
# $SA is the nearest parent folder named 'Applications', however deep the app is nested
$SA  = $SCA
while ($SA -and (Split-Path -Path $SA -Leaf) -ne 'Applications') { $SA = Split-Path -Path $SA -Parent }
if (-not $SA) { throw "$SCA is not inside an 'Applications' folder." }
$SL  = Split-Path -Path $SA -Parent            # C:\SCRIPTS
$SF  = Join-Path -Path $SL -ChildPath 'Functions'
$SG  = Join-Path -Path $SL -ChildPath 'Logs'

# Settings from Data\PoshAcme.json (the same ones Install-PoshAcme.ps1 uses)
if (-not $SettingsPath) { $SettingsPath = Join-Path -Path $SCA -ChildPath 'Data\PoshAcme.json' }
# Settings plus this server's overrides (Data\PoshAcme.<COMPUTERNAME>.json), as the installer reads them
$GetSettingsPath = Join-Path -Path $SF -ChildPath 'Get-ApplicationSettings.ps1'
$Cfg = $null
if (Test-Path -Path $SettingsPath) {
    try {
        if (Test-Path -Path $GetSettingsPath) { . $GetSettingsPath; $Cfg = Get-ApplicationSettings -Path $SettingsPath }
        else { $Cfg = Get-Content -Path $SettingsPath -Raw | ConvertFrom-Json }
    }
    catch { $Cfg = $null }
}
$Migrate = if ($Cfg) { $Cfg.Migrate } else { $null }
if (-not $OldHome) { $OldHome = if ($Migrate -and $Migrate.From) { "$($Migrate.From)" } else { 'C:\POSHACME\certs' } }
$OldTaskPattern  = if ($Migrate -and $Migrate.OldTaskPattern) { "$($Migrate.OldTaskPattern)" } else { 'C:\POSHACME\' }
$ArchiveFolder   = if ($Migrate -and $Migrate.Archive) { "$($Migrate.Archive)" } else { Split-Path -Path $OldHome -Parent }
$ArchiveRenameTo = if ($Migrate -and $Migrate.RenameTo) { "$($Migrate.RenameTo)" } else { "$ArchiveFolder.migrated" }
$RunAs           = if ($Cfg -and $Cfg.RunAs) { "$($Cfg.RunAs)" } else { '' }
if (-not $Domain) { $Domain = if ($Cfg -and $Cfg.Domain) { "$($Cfg.Domain)" } else { ('{0}.{1}' -f $env:COMPUTERNAME, (Get-CimInstance Win32_ComputerSystem).Domain).ToLower() } }
$PoshMod  = if ($Cfg) { $Cfg.Modules | Where-Object { $_.Name -eq 'Posh-ACME' } | Select-Object -First 1 } else { $null }
$CertsDir = if ($PoshMod -and $PoshMod.DataFolder) { "$($PoshMod.DataFolder)" } else { Join-Path -Path $SCA -ChildPath 'Certs' }

$AppFiles = @(
    'Install-PoshAcme.ps1'
    'Test-PoshAcmePrerequisites.ps1'
)
#endregion

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

function Format-Cert {
    param($Cert)
    if (-not $Cert) { return '' }
    $Days = [int]($Cert.NotAfter - (Get-Date)).TotalDays
    '{0} | {1} | expires {2:yyyy-MM-dd} ({3} days)' -f $Cert.Thumbprint, $Cert.Subject, $Cert.NotAfter, $Days
}
#endregion

Write-Host "`nPosh-ACME core pre-install check on $env:COMPUTERNAME ($Domain)" -ForegroundColor Cyan
Write-Host "Application folder: $SCA`n"

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
    Add-Result 'FAIL' 'Session' 'Windows PowerShell 5.1' "This is PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)). Run the installer in powershell.exe."
}
if ($RunAs) {
    if ("$env:USERDOMAIN\$env:USERNAME" -eq $RunAs) { Add-Result 'PASS' 'Session' 'Run as' "$RunAs (owns the saved DNS credentials)." }
    else { Add-Result 'WARN' 'Session' 'Run as' "Running as $env:USERDOMAIN\$env:USERNAME, the settings say $RunAs. Run the installer as ${RunAs}: only that account can read the saved DNS credentials." }
}
#endregion

#region 2. Package
foreach ($Rel in $AppFiles) {
    Test-ScriptFile -Path (Join-Path -Path $SCA -ChildPath $Rel) -Area 'Package' -Label $Rel | Out-Null
}
if ($Cfg) { Add-Result 'PASS' 'Package' 'Data\PoshAcme.json' "Settings v$($Cfg.Version), run as $($Cfg.RunAs), order domain $Domain$(if ($Cfg.OverridePath) { "; overrides from $(Split-Path -Path $Cfg.OverridePath -Leaf)" })." }
elseif (Test-Path -Path $SettingsPath) { Add-Result 'FAIL' 'Package' 'Data\PoshAcme.json' "$SettingsPath (or its override file) is not valid JSON." }
else { Add-Result 'FAIL' 'Package' 'Data\PoshAcme.json' "$SettingsPath missing; copy the application again with SetupApplications.ps1." }
if (-not (Test-Path -Path $GetSettingsPath)) { Add-Result 'WARN' 'Shared' 'Get-ApplicationSettings.ps1' "Missing in $SF; per-server overrides are ignored. Copy the application again (Base copies the common functions)." }
#endregion

#region 3. Shared folders and functions
$WalPath = Join-Path -Path $SF -ChildPath 'Write-AdvancedLog.ps1'
if (Test-ScriptFile -Path $WalPath -Area 'Shared' -Label 'Write-AdvancedLog.ps1' -MissingStatus 'WARN' -MissingDetail 'Missing; scripts will log to the console/transcript only.') {
    $V = Get-ScriptVersion -Path $WalPath
    if ($V -and ([version]$V -lt [version]'1.1.0')) {
        Add-Result 'WARN' 'Shared' 'Write-AdvancedLog version' "v$V. Works, but update to 1.1.0 (INFO events, PS 7 path)."
    }
}
Test-ScriptFile -Path (Join-Path -Path $SF -ChildPath 'Initialize-FileAndFoldersExist.ps1') -Area 'Shared' -Label 'Initialize-FileAndFoldersExist.ps1' -MissingStatus 'WARN' -MissingDetail 'Missing; Write-AdvancedLog needs it to create the log file.' | Out-Null

if (Test-Path -Path $SG) { Add-Result 'PASS' 'Shared' "`$SG $SG" 'Exists.' }
else { Add-Result 'INFO' 'Shared' "`$SG $SG" 'Missing; will be created.' }
#endregion

#region 4. Posh-ACME data
$CertsHasData = @(Get-ChildItem -Path $CertsDir -Force -ErrorAction SilentlyContinue).Count -gt 0
if ($CertsHasData) {
    $DataHome = $CertsDir
    Add-Result 'INFO' 'Posh-ACME' 'Certs folder' "$CertsDir already has data; the installer uses it and does not copy from $OldHome."
}
else {
    $DataHome = $OldHome
    Add-Result 'INFO' 'Posh-ACME' 'Certs folder' "$CertsDir is empty or missing; the installer will migrate $OldHome."
}

if (-not (Test-Path -Path $DataHome)) {
    Add-Result 'FAIL' 'Posh-ACME' 'Data folder' "$DataHome not found. Nothing to migrate; a new ACME account and order would be needed."
}
else {
    Add-Result 'PASS' 'Posh-ACME' 'Data folder' $DataHome

    $ServerDir = Get-ChildItem -Path $DataHome -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'LE_PROD' -or $_.Name -like 'acme-v02.api.letsencrypt.org*' } | Select-Object -First 1
    if (-not $ServerDir) {
        Add-Result 'FAIL' 'Posh-ACME' 'LE_PROD data' "No Let's Encrypt folder (LE_PROD or acme-v02.api.letsencrypt.org) in $DataHome."
    }
    else {
        $Accounts = @(Get-ChildItem -Path $ServerDir.FullName -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'acct.json') })
        if ($Accounts.Count -gt 0) { Add-Result 'PASS' 'Posh-ACME' 'ACME account(s)' ($Accounts.Name -join ', ') }
        else { Add-Result 'FAIL' 'Posh-ACME' 'ACME account(s)' "No account folders (acct.json) under $($ServerDir.FullName)." }

        # Every order (a folder with order.json) and its certificate
        $Orders = @(Get-ChildItem -Path $ServerDir.FullName -Recurse -Filter 'order.json' -File -ErrorAction SilentlyContinue)
        if ($Orders.Count -eq 0) { Add-Result 'WARN' 'Posh-ACME' 'Orders' 'No orders found.' }
        foreach ($O in $Orders) {
            $OrderDir = $O.Directory
            # Newer stores name the folder after the order name, not the domain: use MainDomain from order.json
            $Main = try { "$((Get-Content -Path $O.FullName -Raw | ConvertFrom-Json).MainDomain)" } catch { '' }
            if (-not $Main) { $Main = $OrderDir.Name }
            $Label = "Order $($OrderDir.Name) ($Main, account $($OrderDir.Parent.Name))"
            $CertFile = Join-Path -Path $OrderDir.FullName -ChildPath 'cert.cer'
            if (-not (Test-Path -Path $CertFile)) { Add-Result 'WARN' 'Posh-ACME' $Label 'No cert.cer yet.'; continue }
            try {
                $C = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertFile)
                $Days = ($C.NotAfter - (Get-Date)).TotalDays
                $Status = if ($Days -lt 0) { 'FAIL' } elseif ($Days -lt 14) { 'WARN' } else { 'PASS' }
                $Note = ''
                # Only this server's order is renewed here; an old order for another server is not a blocker.
                if ($Main -ne $Domain) {
                    if ($Status -eq 'FAIL') { $Status = 'WARN' }
                    $Note = ' Order for another server; not renewed here (remove it with Remove-PAOrder if unused).'
                }
                Add-Result $Status 'Posh-ACME' $Label "$(Format-Cert $C).$Note"
            }
            catch { Add-Result 'WARN' 'Posh-ACME' $Label "Could not read ${CertFile}: $($_.Exception.Message)" }
        }
        $Mains = @($Orders | ForEach-Object { try { "$((Get-Content -Path $_.FullName -Raw | ConvertFrom-Json).MainDomain)" } catch { $_.Directory.Name } })
        if ($Mains -notcontains $Domain) {
            Add-Result 'WARN' 'Posh-ACME' "Order $Domain" "No order with main domain $Domain (found: $($Mains -join ', ')). Set Domain in Data\PoshAcme.$env:COMPUTERNAME.json to the right one."
        }
    }
}
#endregion

# Data location: Posh-ACME stores its files wherever POSHACME_HOME points (module code is separate).
$MachineHome = [Environment]::GetEnvironmentVariable('POSHACME_HOME', 'Machine')
if ($MachineHome -eq $CertsDir) { Add-Result 'PASS' 'Posh-ACME' 'Machine POSHACME_HOME' $CertsDir }
elseif ($MachineHome) { Add-Result 'WARN' 'Posh-ACME' 'Machine POSHACME_HOME' "$MachineHome. The installer changes it to $CertsDir (before installing the modules)." }
else { Add-Result 'INFO' 'Posh-ACME' 'Machine POSHACME_HOME' "Not set. The installer sets it to $CertsDir (before installing the modules)." }

$OtherStores = @(Get-ChildItem -Path 'C:\Users\*\AppData\Local\Posh-ACME' -Directory -ErrorAction SilentlyContinue |
    Where-Object { Get-ChildItem -Path $_.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'LE_PROD' -or $_.Name -like 'acme-v02.api.letsencrypt.org*' } })
foreach ($O in $OtherStores) {
    Add-Result 'WARN' 'Posh-ACME' 'Other data folder' "$($O.FullName) (Posh-ACME default when POSHACME_HOME is not set). Not used by these scripts and not migrated; check it holds nothing needed."
}
#endregion

#region 5. Modules
foreach ($M in 'Posh-ACME', 'Posh-ACME.Deploy') {
    $Avail     = @(Get-Module -ListAvailable -Name $M)
    $Installed = @(Get-InstalledModule -Name $M -AllVersions -ErrorAction SilentlyContinue)
    if ($Avail.Count -eq 0) {
        Add-Result 'INFO' 'Modules' $M 'Not installed; the installer will install it.'
        continue
    }
    $Versions = ($Avail | Sort-Object Version -Descending | ForEach-Object { "$($_.Version)" }) -join ', '
    $Outside = @($Avail | Where-Object { $V = $_.Version; -not ($Installed | Where-Object { $_.Version -eq $V }) })
    if ($Outside.Count -gt 0) {
        Add-Result 'WARN' 'Modules' $M "Versions $Versions. Not installed through PowerShellGet, so the installer cannot remove: $(($Outside.ModuleBase) -join '; ')"
    }
    else {
        Add-Result 'PASS' 'Modules' $M "Versions $Versions. The installer keeps them only if this is a single version and the newest."
    }
    $Distinct = @($Avail | ForEach-Object { "$($_.Version)" } | Select-Object -Unique)
    if (-not $SkipNetworkTests) {
        $Newest = try { "$((Find-Module -Name $M -Repository PSGallery -ErrorAction Stop).Version)" } catch { '' }
        if ($Newest -and ($Distinct.Count -ne 1 -or $Distinct[0] -ne $Newest)) {
            Add-Result 'WARN' 'Modules' "$M installed correctly" "Expected only $Newest; found $($Distinct -join ', '). The installer (or SetupApplications.ps1) removes the others and installs $Newest."
        }
    }
    elseif ($Distinct.Count -gt 1) {
        Add-Result 'WARN' 'Modules' "$M installed correctly" "$($Distinct.Count) versions side by side ($($Distinct -join ', ')); the installer replaces them with the newest."
    }
    if ($M -eq 'Posh-ACME' -and (($Avail | Sort-Object Version -Descending | Select-Object -First 1).Version.Major -lt 4)) {
        Add-Result 'WARN' 'Modules' 'Posh-ACME 4.0+' 'Role scripts need 4.0 or later. Do not run the installer with -SkipModuleReinstall.'
    }
}

if (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue) {
    Add-Result 'PASS' 'Modules' 'NuGet provider' 'Installed.'
}
else {
    Add-Result 'INFO' 'Modules' 'NuGet provider' 'Not installed; the installer will install it.'
}
#endregion

# Old tasks and the old folder (the installer disables, zips and renames them once the copy checks out)
foreach ($T in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -match [regex]::Escape($OldTaskPattern) })) {
    $I = $T | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
    Add-Result 'INFO' 'Old setup' "Old task $($T.TaskPath)$($T.TaskName)" "State $($T.State), last run $($I.LastRunTime), next $($I.NextRunTime). The installer disables it before copying."
}
if (Test-Path -Path $ArchiveFolder) { Add-Result 'INFO' 'Old setup' 'Old folder' "${ArchiveFolder}: zipped to $SCA\Backups and renamed to $ArchiveRenameTo once the copied data checks out." }
elseif (Test-Path -Path $ArchiveRenameTo) { Add-Result 'INFO' 'Old setup' 'Old folder' "Already retired as $ArchiveRenameTo. Delete it after the first successful renewal by the new task." }
#endregion

#region 6. Network
if ($SkipNetworkTests) {
    Add-Result 'INFO' 'Network' 'Outbound 443' 'Skipped (-SkipNetworkTests).'
}
else {
    if (Test-TcpPort -HostName 'www.powershellgallery.com') { Add-Result 'PASS' 'Network' 'PowerShell Gallery :443' 'Reachable.' }
    else { Add-Result 'WARN' 'Network' 'PowerShell Gallery :443' 'Not reachable; module reinstall will fail (use -SkipModuleReinstall if modules are current).' }

    if (Test-TcpPort -HostName 'acme-v02.api.letsencrypt.org') { Add-Result 'PASS' 'Network' "Let's Encrypt :443" 'Reachable.' }
    else { Add-Result 'FAIL' 'Network' "Let's Encrypt :443" 'Not reachable; renewals will fail.' }
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
Write-Host "`n$Summary" -ForegroundColor $(if ($FailCount) { 'Red' } elseif (& $N 'WARN') { 'Yellow' } else { 'Green' })
if ($FailCount) { Write-Host 'Fix the FAIL items before running Install-PoshAcme.ps1.' -ForegroundColor Red }
else { Write-Host 'Ready to run Install-PoshAcme.ps1. Review any WARN items first.' -ForegroundColor Green }

if ($ReportPath) {
    $ReportDir = Split-Path -Path $ReportPath -Parent
    if ($ReportDir) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
    @(
        "Posh-ACME core pre-install check - $env:COMPUTERNAME ($Domain) - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        ''
        ($Results | Format-Table Status, Area, Check, Detail -AutoSize -Wrap | Out-String -Width 250)
        $Summary
    ) | Set-Content -Path $ReportPath
    Write-Host "Report saved to $ReportPath"
}
#endregion

exit $(if ($FailCount) { 1 } else { 0 })

# Example usage:
# PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\Test-PoshAcmePrerequisites.ps1
# PS> C:\SCRIPTS\Applications\OpenSource\PoshAcme\Test-PoshAcmePrerequisites.ps1 -SkipNetworkTests


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCACGNg5LbUeCEj6
# TybuucTI+80k2YNsHSrItjGQ59/g36CCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIAmjjiQk
# P8kJS1nzD6hwUz98oG7oWlqW0cPMNObMhIIbMA0GCSqGSIb3DQEBAQUABIIBACYI
# 8QZfonT1D9sAJyw5jVLu8zpqFB8G/ZvzDevXTRLzBeLJzf0RPCnppAMoffWngDQn
# RKtTbdipqqR03Ut8WsQWq7NwEGCFmf2XDfZXAlIsDhCG5AQvP54qTJ5clHyv8ZKS
# L/+zxW1w2P5xS/Fy57pxVuzgia4IX9u1UKYKYysw0UYhaLSB8US+pJNK1GL0n/fW
# 9cBCDsXDt7PJ1f4DK/75weIWiXctm+vu5kr4Pw+OwcWwe7+GzjXo0aY/RMyVgTY/
# p9PQe8wFMSdYhW5YnRHSInA5j7CMnpLsEU6sSnHIW3hH2KnUdH6/r/+8HRGOZuGb
# wSUClPKCmApTYCYwV9+hggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDEzMTcx
# NTEzWjAvBgkqhkiG9w0BCQQxIgQgjFxSeBxS0NKRvYLiIXDfA1dlqsPUz4Gj0wKj
# zb+AMI4wDQYJKoZIhvcNAQEBBQAEggIAdKvxqHEUsMSdVTfCsIMUpBUHvCWRUXWg
# 8itLJLAm2xwHCT2m5UOMbHMxr9EZkJE18yKW/oFAlSi0ZrcdzKrD4z80LRT145Gx
# DNh5XiNCl9wOROtQ3N7zPvYI6rAWI5g6IGIJIlV1d6f79oRs3A3gdccgxm/K5Mw+
# NDayM/OZCFgaf7w/Ut121OXYbIfGPAvATO/zBmQ7GIUeFH8s3PLF272+JUcC9XNF
# zSm757sHN/Oz/GM1c1zJsdSHH4lqRQZJGRo17i+WSK6NBg2+o3rkj3mHJ1va33Ve
# zHwXfhxrMUvF+KehordE915EF0urTRx3+HfqJVxO2S70r52grHKl1huKkN0sc76v
# rrRyrd8ULfEhBM39p32pF1w4btWJQ863Y6zNyL0dS08XwtdZ+soSjfrJwAH1RKff
# sCUdOuFiPpnSZxsgPpPWQOk7jC154jeKtxLiuHmLy1daD+DR0SmQecUpOe0aF7w7
# AmRNIgDiwB+DNChwXBDcMKmvWIhVupu0aRamlONQxUv19jYxJ9CqlWIxD/r69uFI
# dHjyRy4TXJc2RbdzAMLNQv30hTqLpZ6IjNoxLCuqj6pYSAdiKFxZieS5H7L43Dn4
# M+0k69r/JBNRDAJgnn4HC6MhbJmYLn4U9GnFBO8qegKOXNXKdEJF94FrVYcjyCVi
# GPX0EP39vGI=
# SIG # End signature block
