<#
.SYNOPSIS
    Installs the Microsoft.PowerShell.SecretManagement module.
.DESCRIPTION
    Ensures required package infrastructure is available and installs or updates the
    Microsoft.PowerShell.SecretManagement module from PSGallery.
.PARAMETER Scope
    Install scope: CurrentUser or AllUsers. Defaults to AllUsers.
.PARAMETER Force
    Forces reinstallation/update and bypasses prompts where supported.
.PARAMETER AllowPrerelease
    Installs prerelease versions when specified.
.PARAMETER LogFileName
    Optional log file base name passed to Write-AdvancedLog.
.EXAMPLE
    PS> Install-SecretManagementModule
.EXAMPLE
    PS> Install-SecretManagementModule -Scope CurrentUser -Force -Verbose
.INPUTS
    [string] Scope, [switch] Force, [switch] AllowPrerelease, [string] LogFileName
.OUTPUTS
    [pscustomobject]
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-03-06
    Time: 13:28:09
    Time Zone: Central Standard Time
    Function Or Application: Function
    Version: 1.0.0
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: GitHub Copilot (GPT-5.3-Codex)

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

function Install-SecretManagementModule {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet('CurrentUser', 'AllUsers')]
        [string]$Scope = 'AllUsers',

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [switch]$AllowPrerelease,

        [Parameter(Mandatory = $false)]
        [string]$LogFileName
    )

    $writeAdvancedLogPath = Join-Path -Path $PSScriptRoot -ChildPath 'Write-AdvancedLog.ps1'
    if (Test-Path -Path $writeAdvancedLogPath) {
        . $writeAdvancedLogPath
    }

    function Write-SecretManagementInstallLog {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Message,
            [ValidateSet('INFO', 'WARNING', 'ERROR')]
            [string]$LogType = 'INFO'
        )

        if (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue) {
            try {
                $logArgs = @{
                    Message    = $Message
                    ScriptName = 'Install-SecretManagementModule.ps1'
                    LogType    = $LogType
                }

                if (-not [string]::IsNullOrWhiteSpace($LogFileName)) {
                    $logArgs.LogFileName = $LogFileName
                }

                Write-AdvancedLog @logArgs
            }
            catch {
                Write-Verbose "Write-AdvancedLog failed: $($_.Exception.Message)"
            }
        }

        Write-Verbose $Message
    }

    try {
        $isSimulation = [bool]$WhatIfPreference
        $moduleName = 'Microsoft.PowerShell.SecretManagement'

        if (-not (Get-Command -Name Install-Module -ErrorAction SilentlyContinue)) {
            throw 'Install-Module command is not available. Install or update PowerShellGet first.'
        }

        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            if ($PSCmdlet.ShouldProcess('NuGet provider', 'Install NuGet package provider')) {
                Write-SecretManagementInstallLog -Message 'NuGet package provider missing. Installing provider.'
                Install-PackageProvider -Name NuGet -MinimumVersion '2.8.5.201' -Force -ErrorAction Stop | Out-Null
            }
        }

        $psGallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
        if ($null -ne $psGallery -and $psGallery.InstallationPolicy -ne 'Trusted') {
            if ($PSCmdlet.ShouldProcess('PSGallery', "Set installation policy to 'Trusted'")) {
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
                Write-SecretManagementInstallLog -Message 'Set PSGallery installation policy to Trusted.'
            }
        }

        $existingModule = Get-Module -Name $moduleName -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1

        $installParams = @{
            Name         = $moduleName
            Scope        = $Scope
            Repository   = 'PSGallery'
            ErrorAction  = 'Stop'
            AllowClobber = $true
        }

        if ($Force) {
            $installParams.Force = $true
        }

        if ($AllowPrerelease) {
            $installParams.AllowPrerelease = $true
        }

        if ($PSCmdlet.ShouldProcess($moduleName, "Install/Update in scope '$Scope'")) {
            Install-Module @installParams
        }

        if ($isSimulation) {
            Write-SecretManagementInstallLog -Message "Simulation mode enabled. Installation plan prepared for '$moduleName'."
            return [pscustomobject]@{
                ModuleName = $moduleName
                Version    = if ($null -ne $existingModule) { $existingModule.Version.ToString() } else { $null }
                Scope      = $Scope
                Success    = $true
                Simulated  = $true
            }
        }

        $installedModule = Get-Module -Name $moduleName -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
        if ($null -eq $installedModule) {
            throw "Module '$moduleName' was not found after install attempt."
        }

        $action = if ($null -eq $existingModule) { 'Installed' } else { 'Installed/Updated' }
        Write-SecretManagementInstallLog -Message "$action module '$moduleName' version $($installedModule.Version)."

        return [pscustomobject]@{
            ModuleName = $moduleName
            Version    = $installedModule.Version.ToString()
            Scope      = $Scope
            Success    = $true
            Simulated  = $false
        }
    }
    catch {
        Write-SecretManagementInstallLog -Message "Install-SecretManagementModule failed: $($_.Exception.Message)" -LogType 'ERROR'
        throw
    }
}

# Example usage:
# PS> Install-SecretManagementModule
# PS> Install-SecretManagementModule -Scope CurrentUser -Force -Verbose
# PS> Install-SecretManagementModule -AllowPrerelease -Verbose
