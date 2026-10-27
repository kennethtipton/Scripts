#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Dell PowerEdge iDRAC9 network isolation and host cleanup: iDRAC on its dedicated port, no OS-to-iDRAC pass-through NIC in Windows.
.DESCRIPTION
    Run on the Dell server itself (local racadm). In order:

      0. Checks: elevation, racadm present; shows the current iDRAC values and every Windows
         adapter (address, gateway, DNS registration).
      1. LifecycleController.LCAttributes.exposeISMInstallerToHost = Disabled, so the iDRAC
         Service Module installer stops mounting itself in the OS. Done first, while the USB link
         that local racadm may use still exists.
      2. iDRAC.NIC.Selection = Dedicated (skip with -SkipDedicated): iDRAC leaves the shared LOM
         ports and uses its own management port. Warns when a VLAN tag is set (usually wrong on a
         dedicated port) and checks afterwards that the iDRAC still answers on its IP.
      3. iDRAC.OS-BMC.AdminState = Disabled: removes the "Remote NDIS Compatible Device" adapter
         (169.254.x / fde1:) from Windows, which otherwise registers unroutable addresses in DNS
         and breaks WinRM and the Exchange Management Shell.
      4. Windows cleanup: any Remote NDIS adapter still present stops registering in DNS; the
         idrac.local / drac.local line the iDRAC Service Module adds to the hosts file is removed
         (the hosts file is backed up first); ipconfig /registerdns.
      5. Final report: adapters that register in DNS without a default gateway or with only a
         169.254 address are flagged, and this server's own name lookup is shown.

    A setting that already has the wanted value is left alone. If racadm reports an error the
    script stops at that step; nothing after it runs.

    -WhatIf shows the current state and what would change, without changing anything.

    Note: if the dedicated port is not cabled, or this model's iDRAC license has no dedicated
    port, the iDRAC drops off the network after step 2. Local racadm still works; switch back with
    racadm set iDRAC.NIC.Selection LOM1. The iDRAC Service Module (iSM), if installed, stops
    working without the pass-through; uninstall it if it is not used.
.PARAMETER SkipDedicated
    Leave iDRAC.NIC.Selection as it is (only remove the pass-through NIC).
.PARAMETER KeepHostsEntry
    Do not remove the idrac.local / drac.local line from the hosts file.
.PARAMETER ReachTimeoutSeconds
    How long to wait for the iDRAC to answer on its IP after moving it to the dedicated port.
    Defaults to 90.
.PARAMETER LogFileName
    Base name of the text log in C:\SCRIPTS\Logs. Defaults to Set-iDRACNetworkIsolation.
.EXAMPLE
    PS> .\Set-iDRACNetworkIsolation.ps1 -WhatIf
.EXAMPLE
    PS> .\Set-iDRACNetworkIsolation.ps1
.EXAMPLE
    PS> .\Set-iDRACNetworkIsolation.ps1 -SkipDedicated
.INPUTS
    None
.OUTPUTS
    Exit code 0 on success, 1 when a step failed.
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-20
    Time: 15:00:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 1.0.1
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: Claude

    Needs local racadm on the server: Dell iDRAC Tools (SysMgt\iDRACTools) or the copy installed with
    OpenManage Server Administrator (SysMgt\OM_iDRACTools). Tested on iDRAC9 (R340/R640) with racadm
    9.3 to 11.2.

    Copyright (c) 2026
    Licensed under the MIT License.
    Full text available at: https://opensource.org/licenses/MIT

    Overide Variables
    Overide Filename:
    Overide Log Filename: Set-iDRACNetworkIsolation
    Overide Text Log File Path:
    Overide Log Type:
.LINK
    https://www.tnandc.com
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$SkipDedicated,

    [switch]$KeepHostsEntry,

    [ValidateRange(0, 600)]
    [int]$ReachTimeoutSeconds = 90,

    [string]$LogFileName = 'Set-iDRACNetworkIsolation'
)

$ErrorActionPreference = 'Stop'
$ScriptName = 'Set-iDRACNetworkIsolation.ps1'

#region Standard locations
$SCA = $PSScriptRoot
$SA  = $SCA
while ($SA -and (Split-Path -Path $SA -Leaf) -ne 'Applications') { $SA = Split-Path -Path $SA -Parent }
if (-not $SA) { throw "$SCA is not inside an 'Applications' folder." }
$SL = Split-Path -Path $SA -Parent
$SF = Join-Path -Path $SL -ChildPath 'Functions'
#endregion

#region Logging
$WriteLogPath = Join-Path -Path $SF -ChildPath 'Write-AdvancedLog.ps1'
if (Test-Path -Path $WriteLogPath) { . $WriteLogPath }
function Write-IsoLog {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO', 'WARNING', 'ERROR')][string]$LogType = 'INFO')
    switch ($LogType) {
        'WARNING' { Write-Warning $Message }
        'ERROR'   { Write-Host "  $Message" -ForegroundColor Red }
        default   { Write-Host "  $Message" }
    }
    if (-not $WhatIfPreference -and (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue)) {
        $LogArgs = @{ Message = $Message; ScriptName = $ScriptName; LogFileName = $LogFileName; LogType = $LogType }
        if ($LogType -ne 'INFO') { $LogArgs.WriteEventLog = $true }
        try { Write-AdvancedLog @LogArgs } catch { Write-Host "  Write-AdvancedLog failed: $($_.Exception.Message)" }
    }
}
function Write-Step { param([string]$Text) Write-Host "`n$Text" -ForegroundColor Cyan }
#endregion

#region racadm helpers
function Find-Racadm {
    $Cmd = Get-Command -Name racadm -ErrorAction SilentlyContinue
    if ($Cmd) { return $Cmd.Source }
    # iDRAC Tools, OpenManage Server Administrator's copy, and the old rac5 location
    foreach ($P in 'C:\Program Files\Dell\SysMgt\iDRACTools\racadm\racadm.exe', 'C:\Program Files\Dell\SysMgt\OM_iDRACTools\racadm\racadm.exe', 'C:\Program Files\Dell\SysMgt\rac5\racadm.exe') {
        if (Test-Path -Path $P) { return $P }
    }
    $null
}

# Runs racadm; throws when it fails (exit code or an ERROR line). Returns the output lines.
function Invoke-Racadm {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $Out = @(& $Script:Racadm @Arguments 2>&1 | ForEach-Object { "$_" })
    $Err = @($Out | Where-Object { $_ -match '^\s*ERROR' })
    if ($LASTEXITCODE -ne 0 -or $Err.Count) {
        throw "racadm $($Arguments -join ' ') failed (exit $LASTEXITCODE): $((@($Err) + @($Out | Select-Object -Last 2) | Select-Object -Unique) -join ' | ')"
    }
    $Out
}

# Value of one attribute, from 'racadm get' output (Name=Value; a #-prefixed line is a read-only note).
# With -Optional, an attribute this iDRAC firmware does not have (SWC0244 invalid FQDD, or an
# invalid/unknown attribute) returns $null instead of stopping the script.
function Get-RacadmValue {
    param([Parameter(Mandatory)][string]$Attribute, [switch]$Optional)
    $Leaf = ($Attribute -split '\.')[-1]
    try { $Out = Invoke-Racadm -Arguments @('get', $Attribute) }
    catch {
        if ($Optional -and $_.Exception.Message -match 'SWC0244|SWC0242|Invalid (Fully Qualified Device Descriptor|attribute|object)') { return $null }
        throw
    }
    $Line = $Out | Where-Object { $_ -match "^\s*#?\s*$([regex]::Escape($Leaf))\s*=" } | Select-Object -First 1
    if ($Line) { (($Line -split '=', 2)[1]).Trim() } else { '' }
}

# Sets an attribute unless it already has one of the wanted values (text or number).
# -Optional: skipped (not an error) when this iDRAC firmware does not have the attribute.
function Set-RacadmValue {
    param([string]$Attribute, [string]$Value, [string[]]$Already, [string]$What, [switch]$Optional)
    $Now = Get-RacadmValue -Attribute $Attribute -Optional:$Optional
    if ($null -eq $Now) { Write-IsoLog "${What}: not available on this iDRAC firmware; skipped."; return $false }
    if ($Already | Where-Object { $_ -eq $Now }) { Write-IsoLog "${What}: already $Now."; return $false }
    if (-not $PSCmdlet.ShouldProcess("$Attribute (now '$Now')", "Set to $Value")) { return $false }
    Invoke-Racadm -Arguments @('set', $Attribute, $Value) | Out-Null
    $After = Get-RacadmValue -Attribute $Attribute
    Write-IsoLog "${What}: $Now -> $After."
    $true
}
#endregion

#region Windows helpers
function Get-AdapterReport {
    foreach ($C in @(Get-NetIPConfiguration -ErrorAction SilentlyContinue)) {
        $V4 = @($C.IPv4Address | ForEach-Object { $_.IPAddress })
        [pscustomobject]@{
            Adapter     = $C.InterfaceAlias
            Description = $C.InterfaceDescription
            IPv4        = $V4 -join ', '
            Gateway     = [bool]$C.IPv4DefaultGateway
            Registers   = [bool](Get-DnsClient -InterfaceIndex $C.InterfaceIndex -ErrorAction SilentlyContinue).RegisterThisConnectionsAddress
            Suspect     = $false
        } | ForEach-Object {
            # Registers in DNS without being a routable connection
            $Only169 = $V4.Count -and -not @($V4 | Where-Object { $_ -notlike '169.254.*' }).Count
            $_.Suspect = $_.Registers -and ((-not $_.Gateway) -or $Only169) -and ($_.Description -notmatch 'Failover Cluster')
            $_
        }
    }
}
#endregion

$ExitCode = 0
try {
    Write-IsoLog "iDRAC network isolation started on $env:COMPUTERNAME$(if ($WhatIfPreference) { ' (WhatIf: nothing is changed)' })."

    #region 0. Checks and current state
    Write-Step '[0/5] Current state'
    $Script:Racadm = Find-Racadm
    if (-not $Script:Racadm) { throw 'racadm not found (PATH, SysMgt\iDRACTools, SysMgt\OM_iDRACTools, SysMgt\rac5). Install Dell iDRAC Tools on this server.' }
    $Model = (Get-CimInstance -ClassName Win32_ComputerSystem).Model
    $Firmware = ((Invoke-Racadm -Arguments @('getversion') | Where-Object { $_ -match 'iDRAC Version' } | Select-Object -First 1) -split '=', 2)[-1].Trim()
    Write-IsoLog "$Model | iDRAC firmware $Firmware | racadm $((Get-Item -Path $Script:Racadm).VersionInfo.FileVersion) ($Script:Racadm)"
    if (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object DisplayName -match 'iDRAC Service Module') {
        Write-IsoLog 'The iDRAC Service Module is installed; it stops working once the pass-through is disabled. Uninstall it afterwards if its alerts are not used.' -LogType WARNING
    }

    $IdracIp   = Get-RacadmValue -Attribute 'iDRAC.IPv4.Address'
    $Selection = Get-RacadmValue -Attribute 'iDRAC.NIC.Selection'
    $Vlan      = "$(Get-RacadmValue -Attribute 'iDRAC.NIC.VLanEnable' -Optional)"
    $OsBmc     = Get-RacadmValue -Attribute 'iDRAC.OS-BMC.AdminState'
    $IsmExpose = Get-RacadmValue -Attribute 'LifecycleController.LCAttributes.exposeISMInstallerToHost' -Optional
    if ($null -eq $IsmExpose) { $IsmExpose = 'n/a (not on this firmware)' }
    Write-IsoLog "iDRAC IP $IdracIp | NIC selection $Selection | VLAN $Vlan | OS-BMC pass-through $OsBmc | iSM installer exposed $IsmExpose"
    Get-AdapterReport | Format-Table Adapter, Description, IPv4, Gateway, Registers, Suspect -AutoSize | Out-String -Width 200 | Write-Host
    #endregion

    #region 1. iSM installer exposure (before the pass-through goes away)
    Write-Step '[1/5] Lifecycle Controller: iSM installer exposure'
    [void](Set-RacadmValue -Attribute 'LifecycleController.LCAttributes.exposeISMInstallerToHost' -Value '0' -Already 'Disabled', '0' -What 'iSM installer exposed to host' -Optional)
    #endregion

    #region 2. Dedicated port
    Write-Step '[2/5] iDRAC NIC selection'
    if ($SkipDedicated) { Write-IsoLog "Skipped (-SkipDedicated); NIC selection stays $Selection." }
    else {
        if ($Vlan -match 'Enabled|^1$') {
            Write-IsoLog "A VLAN tag is enabled on the iDRAC NIC (iDRAC.NIC.VLanEnable = $Vlan). A dedicated port is normally untagged; check the switch port before relying on it." -LogType WARNING
        }
        $Changed = Set-RacadmValue -Attribute 'iDRAC.NIC.Selection' -Value 'Dedicated' -Already 'Dedicated', '1' -What 'iDRAC NIC selection'
        if ($Changed -and $IdracIp -and $IdracIp -ne '0.0.0.0' -and $ReachTimeoutSeconds -gt 0) {
            Write-IsoLog "Waiting up to $ReachTimeoutSeconds s for the iDRAC to answer on $IdracIp through the dedicated port..."
            $Deadline = (Get-Date).AddSeconds($ReachTimeoutSeconds); $Up = $false
            while (-not $Up -and (Get-Date) -lt $Deadline) {
                Start-Sleep -Seconds 5
                $Up = Test-Connection -ComputerName $IdracIp -Count 1 -Quiet -ErrorAction SilentlyContinue
            }
            if ($Up) { Write-IsoLog "iDRAC answers on $IdracIp." }
            else { Write-IsoLog "iDRAC does not answer on $IdracIp after $ReachTimeoutSeconds s. Check that the dedicated port is cabled and licensed; to go back: racadm set iDRAC.NIC.Selection LOM1" -LogType WARNING; $ExitCode = 1 }
        }
    }
    #endregion

    #region 3. OS-to-iDRAC pass-through
    Write-Step '[3/5] OS-to-iDRAC pass-through'
    $Removed = Set-RacadmValue -Attribute 'iDRAC.OS-BMC.AdminState' -Value '0' -Already 'Disabled', '0' -What 'OS-to-iDRAC pass-through'
    if ($Removed) { Start-Sleep -Seconds 10 }   # give Windows time to remove the USB adapter
    #endregion

    #region 4. Windows cleanup
    Write-Step '[4/5] Windows cleanup'
    foreach ($A in @(Get-NetAdapter -InterfaceDescription 'Remote NDIS*' -ErrorAction SilentlyContinue)) {
        $Dns = Get-DnsClient -InterfaceIndex $A.ifIndex -ErrorAction SilentlyContinue
        if ($Dns -and $Dns.RegisterThisConnectionsAddress -and $PSCmdlet.ShouldProcess("$($A.Name) ($($A.InterfaceDescription))", 'Stop registering in DNS')) {
            Set-DnsClient -InterfaceIndex $A.ifIndex -RegisterThisConnectionsAddress $false
            Write-IsoLog "$($A.Name) ($($A.InterfaceDescription)) still present: DNS registration turned off."
        }
    }
    if (-not @(Get-NetAdapter -InterfaceDescription 'Remote NDIS*' -ErrorAction SilentlyContinue).Count) { Write-IsoLog 'No Remote NDIS (iDRAC pass-through) adapter in Windows.' }

    $Hosts = Join-Path -Path $env:SystemRoot -ChildPath 'System32\drivers\etc\hosts'
    $Lines = @(Get-Content -Path $Hosts)
    $Drac = @($Lines | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\b(idrac|drac)\.local\b' })
    if ($KeepHostsEntry) { Write-IsoLog 'hosts file left as is (-KeepHostsEntry).' }
    elseif (-not $Drac.Count) { Write-IsoLog 'hosts file has no idrac.local / drac.local line.' }
    elseif ($PSCmdlet.ShouldProcess($Hosts, "Remove: $($Drac -join ' | ')")) {
        $Backup = '{0}.{1:yyyyMMdd_HHmmss}.bak' -f $Hosts, (Get-Date)
        Copy-Item -Path $Hosts -Destination $Backup
        Set-Content -Path $Hosts -Value @($Lines | Where-Object { $Drac -notcontains $_ }) -Encoding ASCII
        Write-IsoLog "Removed from hosts: $($Drac -join ' | ') (backup $Backup)."
    }

    if ($PSCmdlet.ShouldProcess('DNS', 'ipconfig /registerdns')) {
        & ipconfig.exe /registerdns | Out-Null
        Clear-DnsClientCache
        Write-IsoLog 'ipconfig /registerdns done; DNS client cache cleared.'
    }
    #endregion

    #region 5. Final report
    Write-Step '[5/5] Result'
    $Report = @(Get-AdapterReport)
    $Report | Format-Table Adapter, Description, IPv4, Gateway, Registers, Suspect -AutoSize | Out-String -Width 200 | Write-Host
    foreach ($S in @($Report | Where-Object Suspect)) {
        Write-IsoLog "$($S.Adapter) ($($S.Description), $($S.IPv4)) registers in DNS without a gateway or with only a 169.254 address. Check whether it should: Set-DnsClient -InterfaceIndex <n> -RegisterThisConnectionsAddress `$false" -LogType WARNING
    }
    $Own = @((Resolve-DnsName -Name $env:COMPUTERNAME -ErrorAction SilentlyContinue | Where-Object IPAddress).IPAddress)
    $Bad = @($Own | Where-Object { $_ -like '169.254.*' -or $_ -like 'fd*' })
    Write-IsoLog "$env:COMPUTERNAME resolves to: $($Own -join ', ')"
    if ($Bad.Count) { Write-IsoLog "Still resolves to unroutable address(es): $($Bad -join ', '). Re-run after the adapter is gone, or check the adapters flagged above." -LogType WARNING; $ExitCode = 1 }
    Write-IsoLog "iDRAC network isolation finished on $env:COMPUTERNAME$(if ($ExitCode) { ' with warnings' })."
    #endregion
}
catch {
    $ExitCode = 1
    Write-IsoLog "Stopped: $($_.Exception.Message)" -LogType ERROR
}

exit $ExitCode

# Example usage:
# PS> C:\SCRIPTS\Applications\Dell\iDRACNetworkIsolation\Set-iDRACNetworkIsolation.ps1 -WhatIf
# PS> C:\SCRIPTS\Applications\Dell\iDRACNetworkIsolation\Set-iDRACNetworkIsolation.ps1
# PS> C:\SCRIPTS\Applications\Dell\iDRACNetworkIsolation\Set-iDRACNetworkIsolation.ps1 -SkipDedicated


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBTERcOEffDtOSo
# yAig421mcfdjB4BQoneHDFAobAGaoKCCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIO5zyXU0
# 9fArTP5nGMgyYF6qLqm6801tvLEJiIMMJTlfMA0GCSqGSIb3DQEBAQUABIIBABYv
# zD4fBv9e4CPd1BnMxfYmjR79EDycQNdY2iYppS6NRjF21W90SeDPhqolzmV5QkMb
# 4lTuc10hOXc8V2V4ZVn2gJpKq6isIfbyeldumE6SsCklAfTq7dfUVyRUreKHz5e5
# cJCOsmw9NVXFmTPvbHwN4/YLSKbGaHQWEF7gh+16RCo3aVEqGqTTUUKWTebZpvgK
# U6FdqMW3QxH1KD9UQI/Aj0ipMi8qWWZ81WVGPMU7CxSOGtx7MRrJ9YFFiAtBE7UU
# C5/0f13tVVTy574x5VqO84bHkjjFKgRPeSWZtU7ZP4ti4Hl7xT99DLR1GAE935h4
# eFc6GDnKrwj+VXrToUOhggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDIwMTk0
# MzExWjAvBgkqhkiG9w0BCQQxIgQg6RbVSmT9/qX6Z4QJgLAqe1RhFGvuCKQQ2sy2
# E6DAoSIwDQYJKoZIhvcNAQEBBQAEggIARfk9UHQu/H636rBxA9h80Q+ne5rVj656
# yaHQevWm1Dz6EPiWoJ4NILTx95B4D6d/YpvhZmAof7UUdr7LbfZ7t0yuUX6F0hef
# ZiKg50Y9iDBVpc/5uiFDx9eDiVbLt7RIt1o+1fbM3xdGg87B1pi+HfqngA0ySk7j
# GuTvm9RHmoBWEL2zwNwP2TbcAdq+PxQ1umDNokBwfaUIbAt5+aeQNEEyhBR/6wm0
# +C7cXcZ++Lq6egsW/Qxhkdy+466MYpAO4f+4i3N0ddj91K5BS1OJMNE7CjylvWHb
# NxjdDEpVkDKRn3J7GQxYFJoyVIC2qMElIhXG5VyuNxembmp5u2ptaYPfF2nk7VTS
# uXSU3hvRlEvoCESYXvKBskEcJofm4UwQVFOQgiIfSs5aQkWYk3B6lYP6o1xDLlmS
# hZDPVo92v5paW/jSJ1/HoRcuhPvYDK6MDU/WmfiebMDba7YxIKqEk+V8aWlgS2Wr
# P9JteEIgoUH25jI+hOzx6XEdHdcj0Nm5VKw/auSUzDzYdpjPBjRhMBKQO1A/N0wx
# guVI4Nl1bf3sND/mRgiHrgcphYfCiegvAsrWIiM6dxHsyk/AwzvDAHdAdBjEaMxl
# JDUFAfG476N0mRzchJPXLTjN2HYYk/BeRKq7WUC7Hgh2B5Dgxsdgxxqf1E+QIrvz
# SQN/MJE+JRI=
# SIG # End signature block
