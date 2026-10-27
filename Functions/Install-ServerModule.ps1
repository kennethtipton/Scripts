<#
.SYNOPSIS
    Checks that a PowerShell module is installed correctly on remote servers and fixes it if not.
.DESCRIPTION
    Looks at the module in the all-users module folder of Windows PowerShell on each server
    (C:\Program Files\WindowsPowerShell\Modules), through the administrative share
    (\\server\C$\...). The account running this must be an administrator on the servers.

    Correct means:
      -RequiredVersion exactly this version (also a prerelease such as 1.0.0-preview3); other
                       versions are left alone
      -LatestOnly      exactly one version, the newest one in -Repository
      otherwise        a version of at least -MinimumVersion (any version if none is given)

    Fixing (skipped with -WhatIf): the needed version is downloaded once on this computer with
    Save-Module (into -CacheFolder) and copied to each server, and with -LatestOnly every other
    version folder of the module is removed. The server needs no internet access. Save-Module
    keeps the PowerShellGet information, so on the server Get-InstalledModule lists the module.

    Some modules keep their code in the modules folder but store the files they create
    somewhere else, named by an environment variable (Posh-ACME: POSHACME_HOME). With
    -DataVariable and -DataFolder the machine-wide variable on the server must point to
    -DataFolder. When fixing, it is set (over WinRM) BEFORE any module is installed, so the
    module never starts using its default data location; if it cannot be set, the module is
    not installed on that server. Whether -DataFolder has data yet is only reported: moving
    existing data is left to the application's own install script.
.PARAMETER ComputerName
    Servers to check.
.PARAMETER Name
    Module name.
.PARAMETER MinimumVersion
    Lowest acceptable version. Ignored with -LatestOnly.
.PARAMETER LatestOnly
    Require exactly one version, the newest in the repository; remove the others when fixing.
.PARAMETER RequiredVersion
    Exact version that must be installed, e.g. 2.14.1 or 1.0.0-preview3 (prereleases are saved
    with -AllowPrerelease). Takes precedence over -LatestOnly and -MinimumVersion.
.PARAMETER DataVariable
    Machine environment variable that tells the module where its data is (POSHACME_HOME).
.PARAMETER DataFolder
    Local path on the server where the module's data should be.
.PARAMETER Repository
    Repository to download from. Defaults to PSGallery.
.PARAMETER CacheFolder
    Folder on this computer the modules are saved to before copying.
    Defaults to $env:TEMP\ServerModules.
.PARAMETER Credential
    Override login for the servers (for example an administrator of another domain), used for
    the admin share (Connect-AdminShare) and for WinRM. Without it the current login is used.
    WinRM to a server outside the domain may also need it in this computer's TrustedHosts.
.PARAMETER LogFileName
    Base name of the text log file in the Logs folder. Defaults to Install-ServerModule.
.EXAMPLE
    PS> Install-ServerModule -ComputerName srv010010050050.generationsgaither.com -Name Posh-ACME -LatestOnly -WhatIf
.EXAMPLE
    PS> Install-ServerModule -ComputerName srv1, srv2 -Name Posh-ACME.Deploy -MinimumVersion 2.0.0
.INPUTS
    [string[]] ComputerName, [string] Name, [string] MinimumVersion, [switch] LatestOnly, [string] DataVariable, [string] DataFolder, [string] Repository, [string] CacheFolder, [string] LogFileName
.OUTPUTS
    [pscustomobject] one row per server: Server, Module, Installed, Required, Action, Data
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-13
    Time: 10:00:00
    Time Zone: Central Standard Time
    Function Or Application: Function
    Version: 1.2.0
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: Claude

    Copyright (c) 2026
    Licensed under the MIT License.
    Full text available at: https://opensource.org/licenses/MIT

    Overide Variables
    Overide Filename:
    Overide Log Filename: Install-ServerModule
    Overide Text Log File Path:
    Overide Log Type:
.LINK
    https://www.tnandc.com
#>

function Install-ServerModule {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [string]$MinimumVersion,

        [Parameter(Mandatory = $false)]
        [switch]$LatestOnly,

        [Parameter(Mandatory = $false)]
        [string]$RequiredVersion,

        [Parameter(Mandatory = $false)]
        [string]$DataVariable,

        [Parameter(Mandatory = $false)]
        [string]$DataFolder,

        [Parameter(Mandatory = $false)]
        [string]$Repository = 'PSGallery',

        [Parameter(Mandatory = $false)]
        [string]$CacheFolder = (Join-Path -Path $env:TEMP -ChildPath 'ServerModules'),

        [Parameter(Mandatory = $false)]
        [pscredential]$Credential,

        [Parameter(Mandatory = $false)]
        [string]$LogFileName = 'Install-ServerModule'
    )

    #region Logging
    $WriteLogPath = Join-Path -Path $PSScriptRoot -ChildPath 'Write-AdvancedLog.ps1'
    if (Test-Path -Path $WriteLogPath) { . $WriteLogPath }

    function Write-ModuleLog {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Message,
            [ValidateSet('INFO', 'WARNING', 'ERROR')]
            [string]$LogType = 'INFO'
        )
        if ($LogType -eq 'WARNING') { Write-Warning $Message } else { Write-Verbose $Message }
        # -WhatIf only previews; nothing is logged.
        if (-not $WhatIfPreference -and (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue)) {
            try { Write-AdvancedLog -Message $Message -ScriptName 'Install-ServerModule.ps1' -LogFileName $LogFileName -LogType $LogType }
            catch { Write-Warning "Write-AdvancedLog failed: $($_.Exception.Message)" }
        }
    }
    #endregion

    $ModulesRel = 'Program Files\WindowsPowerShell\Modules'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # Windows PowerShell 5.1 needs the NuGet provider for Find-Module / Save-Module and would
    # otherwise stop to ask for it (which fails in a window or non-interactive session).
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -WhatIf:$false -Confirm:$false | Out-Null
        Write-ModuleLog 'Installed the NuGet package provider for the current user (needed by Find-Module / Save-Module).'
    }

    # What "correct" is
    $Latest = $null
    # -RequiredVersion: exactly this version must be there (others are left alone). A prerelease
    # (1.0.0-preview3) is kept in a folder named by its number (1.0.0) with the tag in the module
    # manifest (PrivateData.PSData.Prerelease), so both are compared.
    $WantNumber = $null; $WantTag = ''
    if ($RequiredVersion) {
        $Parts = $RequiredVersion.Split('-', 2)
        if (-not [version]::TryParse($Parts[0], [ref]$WantNumber)) { throw "RequiredVersion '$RequiredVersion' is not a version (1.2.3 or 1.2.3-preview1)." }
        if ($Parts.Count -gt 1) { $WantTag = $Parts[1] }
        $RequiredText = "exactly $RequiredVersion"
    }
    elseif ($LatestOnly) {
        try { $Latest = [version](Find-Module -Name $Name -Repository $Repository -ErrorAction Stop).Version }
        catch { throw "Cannot look up the newest $Name in ${Repository}: $($_.Exception.Message)" }
        $RequiredText = "only $Latest (newest)"
    }
    elseif ($MinimumVersion) { $RequiredText = "$MinimumVersion or later" }
    else { $RequiredText = 'any version' }

    # Versions in a module folder: versioned subfolders, or one flat module folder.
    function Get-ModuleVersions {
        param([string]$ModuleDir, [string]$ModuleName)
        if (-not (Test-Path -Path $ModuleDir -PathType Container)) { return @() }
        $Found = @(Get-ChildItem -Path $ModuleDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $V = $null
            $Psd1 = Join-Path -Path $_.FullName -ChildPath "$ModuleName.psd1"
            if ([version]::TryParse($_.Name, [ref]$V) -and (Test-Path -Path $Psd1)) {
                $Tag = ''
                if ($RequiredVersion) { try { $Tag = "$((Import-PowerShellDataFile -Path $Psd1).PrivateData.PSData.Prerelease)" } catch { } }
                [pscustomobject]@{ Version = $V; Prerelease = $Tag; Path = $_.FullName; Flat = $false }
            }
        })
        $FlatPsd1 = Join-Path -Path $ModuleDir -ChildPath "$ModuleName.psd1"
        if ($Found.Count -eq 0 -and (Test-Path -Path $FlatPsd1)) {
            try { $Found = @([pscustomobject]@{ Version = [version](Import-PowerShellDataFile -Path $FlatPsd1).ModuleVersion; Path = $ModuleDir; Flat = $true }) } catch { }
        }
        @($Found | Sort-Object Version -Descending)
    }

    $Saved = $null   # downloaded once, on first need

    # Override login: open the admin shares first (closed again at the end if opened here),
    # and pass it to every WinRM call.
    $RemoteArgs = @{}
    $Conns = @()
    if ($Credential) {
        $ConnectPath = Join-Path -Path $PSScriptRoot -ChildPath 'Connect-AdminShare.ps1'
        if (-not (Test-Path -Path $ConnectPath)) { throw "Required function file missing: $ConnectPath" }
        . $ConnectPath
        $Conns = @(Connect-AdminShare -ComputerName $ComputerName -Credential $Credential)
        $RemoteArgs.Credential = $Credential
    }

    foreach ($Server in $ComputerName) {
        $Row = [ordered]@{ Server = $Server; Module = $Name; Installed = ''; Required = $RequiredText; Action = ''; Data = '' }
        $Root = '\\{0}\C$' -f $Server
        $Conn = $Conns | Where-Object { $_.Server -eq $Server } | Select-Object -First 1
        if ($Conn -and -not $Conn.Connected) {
            $Row.Action = "Failed: $($Conn.Message)"
            Write-ModuleLog "$Server : $($Conn.Message)" -LogType ERROR
            [pscustomobject]$Row
            continue
        }
        if (-not (Test-Path -Path $Root)) {
            $Row.Action = 'Failed: unreachable'
            Write-ModuleLog "$Server unreachable: cannot open $Root (offline, firewall, or no admin rights)." -LogType ERROR
            [pscustomobject]$Row
            continue
        }

        if ($DataFolder) {
            if ($DataFolder -notmatch '^([A-Za-z]):\\(.*)$') { throw "DataFolder '$DataFolder' must be a full local path such as C:\SCRIPTS\..." }
            $RemoteData = '\\{0}\{1}$\{2}' -f $Server, $Matches[1].ToUpper(), $Matches[2]
            $Row.Data = if (@(Get-ChildItem -Path $RemoteData -Force -ErrorAction SilentlyContinue).Count) { "Data in $DataFolder" } else { "No data in $DataFolder yet (the application's install script moves it there)" }
        }

        # Machine-wide data variable on the server (read over WinRM)
        $VarWrong = $false
        if ($DataVariable -and $DataFolder) {
            try {
                $VarValue = Invoke-Command -ComputerName $Server @RemoteArgs -ErrorAction Stop -ScriptBlock {
                    param($N) [Environment]::GetEnvironmentVariable($N, 'Machine')
                } -ArgumentList $DataVariable
                $VarWrong = ($VarValue -ne $DataFolder)
                $VarText = if ($VarValue) { $VarValue } else { '(not set)' }
                $Row.Data = "$DataVariable = $VarText$(if ($VarWrong) { " (should be $DataFolder)" }). $($Row.Data)"
            }
            catch {
                $VarWrong = $true
                $Row.Data = "$DataVariable could not be read over WinRM: $($_.Exception.Message). $($Row.Data)"
            }
        }

        $ModuleDir = Join-Path -Path (Join-Path -Path $Root -ChildPath $ModulesRel) -ChildPath $Name
        $Have = @(Get-ModuleVersions -ModuleDir $ModuleDir -ModuleName $Name)
        $Row.Installed = if ($Have.Count) { ($Have | ForEach-Object { "$($_.Version)$(if ($_.Prerelease) { "-$($_.Prerelease)" })" }) -join ', ' } else { '(none)' }

        # Work out what is wrong
        if ($RequiredVersion) {
            $NeedInstall = -not ($Have | Where-Object { $_.Version -eq $WantNumber -and "$($_.Prerelease)" -eq $WantTag })
            $Remove = @()
            $Problems = if ($Have.Count -eq 0) { @('missing') } elseif ($NeedInstall) { @("$RequiredVersion not installed") } else { @() }
        }
        elseif ($LatestOnly) {
            $NeedInstall = -not ($Have | Where-Object { $_.Version -eq $Latest })
            $Remove      = @($Have | Where-Object { $_.Version -ne $Latest -and -not $_.Flat })
            $Problems = @()
            if ($Have.Count -eq 0) { $Problems += 'missing' }
            elseif ($NeedInstall) { $Problems += "newest $Latest not installed" }
            if ($Remove.Count) { $Problems += "other versions: $(($Remove | ForEach-Object { "$($_.Version)" }) -join ', ')" }
            if ($Have | Where-Object Flat) { $Problems += 'unversioned copy (remove by hand)' }
        }
        else {
            $Ok = $Have.Count -and (-not $MinimumVersion -or $Have[0].Version -ge [version]$MinimumVersion)
            $NeedInstall = -not $Ok
            $Remove = @()
            $Problems = if ($Have.Count -eq 0) { @('missing') } elseif (-not $Ok) { @("too old ($($Have[0].Version))") } else { @() }
        }

        if ($VarWrong) { $Problems = @("$DataVariable not $DataFolder") + @($Problems) }

        if ($Problems.Count -eq 0) {
            $Row.Action = 'OK'
            [pscustomobject]$Row
            continue
        }

        $Why = $Problems -join '; '
        $Plan = @()
        if ($VarWrong) { $Plan += "set $DataVariable" }
        if ($NeedInstall) { $Plan += "install $(if ($RequiredVersion) { $RequiredVersion } elseif ($Latest) { $Latest } else { 'newest' })" }
        if ($Remove.Count) { $Plan += "remove $(($Remove | ForEach-Object { "$($_.Version)" }) -join ', ')" }
        if (-not $Plan) {
            $Row.Action = "Skipped: $Why"
            [pscustomobject]$Row
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($Server, "Module ${Name}: $($Plan -join ' and ') ($Why)")) {
            $Row.Action = "Would $($Plan -join ' and ') ($Why, WhatIf)"
            [pscustomobject]$Row
            continue
        }

        try {
            $Done = @()
            # Data location first: the module must not run before it knows where its data goes.
            if ($VarWrong) {
                try {
                    Invoke-Command -ComputerName $Server @RemoteArgs -ErrorAction Stop -ScriptBlock {
                        param($N, $V)
                        if (-not (Test-Path -Path $V)) { New-Item -ItemType Directory -Path $V -Force | Out-Null }
                        [Environment]::SetEnvironmentVariable($N, $V, 'Machine')
                    } -ArgumentList $DataVariable, $DataFolder
                }
                catch { throw "could not set $DataVariable first, so the module was not touched: $($_.Exception.Message)" }
                $Done += "set $DataVariable"
                Write-ModuleLog "$Server : machine $DataVariable set to $DataFolder."
            }
            if ($NeedInstall) {
                if (-not $Saved) {
                    $Stage = Join-Path -Path $CacheFolder -ChildPath $Name
                    if (Test-Path -Path $Stage) { Remove-Item -Path $Stage -Recurse -Force }
                    New-Item -ItemType Directory -Path $Stage -Force | Out-Null
                    $SaveArgs = @{ Name = $Name; Repository = $Repository; Path = $Stage; Force = $true; ErrorAction = 'Stop' }
                    if ($RequiredVersion) { $SaveArgs.RequiredVersion = $RequiredVersion; if ($WantTag) { $SaveArgs.AllowPrerelease = $true } }
                    elseif ($Latest) { $SaveArgs.RequiredVersion = "$Latest" } elseif ($MinimumVersion) { $SaveArgs.MinimumVersion = $MinimumVersion }
                    Save-Module @SaveArgs
                    # Every module saved (the module and its dependencies) with its version folders
                    $Saved = @(Get-ChildItem -Path $Stage -Directory | ForEach-Object {
                        $M = $_
                        Get-ChildItem -Path $M.FullName -Directory | ForEach-Object { [pscustomobject]@{ Module = $M.Name; Version = $_.Name; Path = $_.FullName } }
                    })
                    if (-not $Saved) { throw "Save-Module saved nothing for $Name." }
                    Write-ModuleLog "Downloaded $(($Saved | ForEach-Object { "$($_.Module) $($_.Version)" }) -join ', ') from $Repository."
                }
                foreach ($S in $Saved) {
                    $Dest = Join-Path -Path (Join-Path -Path $Root -ChildPath $ModulesRel) -ChildPath "$($S.Module)\$($S.Version)"
                    if (Test-Path -Path $Dest) {
                        # Same number folder: replace it only when it holds another prerelease of the required module
                        if (-not ($RequiredVersion -and $S.Module -eq $Name)) { continue }
                        $DestTag = try { "$((Import-PowerShellDataFile -Path (Join-Path $Dest "$Name.psd1")).PrivateData.PSData.Prerelease)" } catch { '?' }
                        if ($DestTag -eq $WantTag) { continue }
                        Remove-Item -Path $Dest -Recurse -Force -ErrorAction Stop
                        $Done += "removed $($S.Module) $($S.Version)$(if ($DestTag) { "-$DestTag" })"
                    }
                    New-Item -ItemType Directory -Path (Split-Path -Path $Dest -Parent) -Force | Out-Null
                    Copy-Item -Path $S.Path -Destination $Dest -Recurse -Force -ErrorAction Stop
                    $Done += "installed $($S.Module) $($S.Version)$(if ($RequiredVersion -and $S.Module -eq $Name -and $WantTag) { "-$WantTag" })"
                }
            }
            foreach ($R in $Remove) {
                Remove-Item -Path $R.Path -Recurse -Force -ErrorAction Stop
                $Done += "removed $($R.Version)"
            }
            $Row.Action = if ($Done) { "Fixed: $($Done -join ', ')" } else { 'Fixed (nothing to copy)' }
            $Row.Installed = (@(Get-ModuleVersions -ModuleDir $ModuleDir -ModuleName $Name) | ForEach-Object { "$($_.Version)$(if ($_.Prerelease) { "-$($_.Prerelease)" })" }) -join ', '
            Write-ModuleLog "$Server : module $Name $($Row.Action) (was: $Why)."
        }
        catch {
            $Row.Action = "Failed: $($_.Exception.Message)"
            Write-ModuleLog "$Server : could not fix module $Name : $($_.Exception.Message)" -LogType ERROR
        }
        [pscustomobject]$Row
    }
    foreach ($C in @($Conns | Where-Object Created)) { Connect-AdminShare -ComputerName $C.Server -Disconnect | Out-Null }
}

# Example usage:
# PS> . C:\SCRIPTS\Functions\Install-ServerModule.ps1
# PS> Install-ServerModule -ComputerName srv010010050050.generationsgaither.com -Name Posh-ACME -LatestOnly -DataVariable POSHACME_HOME -DataFolder 'C:\SCRIPTS\Applications\OpenSource\PoshAcme\Certs' -WhatIf
# PS> Install-ServerModule -ComputerName srv010010037050.generationsgaither.com, srv010010050050.generationsgaither.com -Name Posh-ACME.Deploy -LatestOnly -Verbose


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD8/Ow7Mz2Iqa+q
# QPipKIW3LxUyMCX4hejecp3k2mDhGqCCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIBVavXob
# 4aTDtVvdFZI27wdW/3JGCxcmajuvGg761sG+MA0GCSqGSIb3DQEBAQUABIIBALhs
# arwgGFvjq5/OV23nWy+wA+PVqcKQFZ0so2B0jHM6Pbw4nwIW1eLXb9niH4dIQDj7
# lDOspIvr/s4WaUrBx/WOu7V+PLG8M3qh2qOXN2aMFvpDkjfOAaby++L5NsUDURYC
# /AP3ZYAbAWFETIhe6Zc5xFni5ZMMlCTViI5DTTEfgruXd6nhcwc/2Jk3l/qp7RdZ
# MvOxsTHoleBYbl+d3Pt57wiuef73jC2iYVsmL0rMMLIcdzfWc0sW8PB3qiv+gna8
# AqKQNmvgsCBAbbfZsl3mOjp8oHw9loOUtP3TOwzJI4/QraMRHEleOHMbPtPPZ/so
# A/cS8sJu+26BwjQYwwmhggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDI1MDI0
# NDA4WjAvBgkqhkiG9w0BCQQxIgQgPFQAz9eatGOY82HV6s0i3JOKY7gn1pxJRGh5
# Jd6cWDowDQYJKoZIhvcNAQEBBQAEggIAUUvfyTY/qDmmBKiax7si5R1TwOWCZLJU
# uw/vjoZGG3aHN0lHNqsEXoQ1jNPRnUG9LcqjikpoBNTOkHWXdN9MLRvZtj+49Kgw
# /dTLy7irthmOdQIt+oLWqt71K2kTw14jw4HRfCjTpGceUrhbvVX2mj2wuQabsz1b
# fzJYyfzqqOr4bMaJPD8CsIwzYUmOIp4izPo4vWd9igDY8jnZaUtr8vBlFhmC7lKp
# BUCJfoFEU7/8+xZWHDh27iYR0HCT6Z7i7pnx8kDZYS4sbxMizr4i+T3a+0pbU+Cw
# kOUYMS933bkY5w2xo77/p7iz07HjQQM0CD7KPCHjqS0zobVzEnvp11x+l2IRq3mR
# dhDUEv/HEQGgq6TU0MaElOU3nf5vI7FQ4DMQ0pOlfVaLzRxx/CzaNYEkRJS8X7je
# xK0lrJ1tiSBhNfHnoBnuJEzN9lDgOQ4kBGB5C2lzOxmd0vjrIQX+9DAAVPHEHMds
# /tw0+QWvrnyH9jjEYvWPyCpNjccndJxA20ko+eaM4PxoR7caF/hjLCua3SLQ70DN
# dwKzggdQilnl8p9UF34Xujmfs2HRCXp04T6y0VSmrBrMYHdQv6HE3BFBmHK6jkkf
# xDTZ46o7pyhkJZjIbs1bYvEmfuKZ9SXiKgG9kTWQuvCHLzOMA2Bq1ukxKnoOHI5c
# y2H/eWhGt1Y=
# SIG # End signature block
