<#
.SYNOPSIS
    Installs KeePass and configures a default vault storage path for automation workflows.
.DESCRIPTION
    Installs KeePass using Winget (preferred) or Chocolatey (fallback), ensures the default
    vault storage directory exists, and sets KEEPASS_DEFAULT_VAULT_PATH in the requested
    environment scope.
.PARAMETER VaultPath
    Default KeePass vault storage path. Defaults to C:\ProgramData\Scripts\KeePass.
.PARAMETER EnvironmentScope
    Environment variable target scope: Machine or User. Defaults to Machine.
.PARAMETER SkipUpgrade
    Skips package upgrade when KeePass is already installed.
.PARAMETER LogFileName
    Optional log file base name passed to Write-AdvancedLog.
.EXAMPLE
    PS> Install-KeePass
.EXAMPLE
    PS> Install-KeePass -VaultPath 'C:\ProgramData\Scripts\KeePass' -EnvironmentScope Machine -Verbose
.INPUTS
    [string] VaultPath, [string] EnvironmentScope, [switch] SkipUpgrade, [string] LogFileName
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

function Install-KeePass {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$VaultPath = 'C:\ProgramData\Scripts\KeePass',

        [Parameter(Mandatory = $false)]
        [ValidateSet('Machine', 'User')]
        [string]$EnvironmentScope = 'Machine',

        [Parameter(Mandatory = $false)]
        [switch]$SkipUpgrade,

        [Parameter(Mandatory = $false)]
        [string]$LogFileName
    )

    $writeAdvancedLogPath = Join-Path -Path $PSScriptRoot -ChildPath 'Write-AdvancedLog.ps1'
    if (Test-Path -Path $writeAdvancedLogPath) {
        . $writeAdvancedLogPath
    }

    function Write-KeePassInstallLog {
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
                    ScriptName = 'Install-KeePass.ps1'
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

        if ($PSCmdlet.ShouldProcess($VaultPath, 'Create KeePass vault storage directory if missing')) {
            if (-not (Test-Path -Path $VaultPath -PathType Container)) {
                New-Item -Path $VaultPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
                Write-KeePassInstallLog -Message "Created vault directory: $VaultPath"
            }
            else {
                Write-KeePassInstallLog -Message "Vault directory already exists: $VaultPath"
            }
        }

        if ($PSCmdlet.ShouldProcess("Environment:$EnvironmentScope", "Set KEEPASS_DEFAULT_VAULT_PATH to '$VaultPath'")) {
            [System.Environment]::SetEnvironmentVariable('KEEPASS_DEFAULT_VAULT_PATH', $VaultPath, $EnvironmentScope)
            Write-KeePassInstallLog -Message "Set KEEPASS_DEFAULT_VAULT_PATH at $EnvironmentScope scope to '$VaultPath'."
        }

        $keepassInstalled = $false
        $packageManagerUsed = $null

        if (Get-Command -Name winget -ErrorAction SilentlyContinue) {
            $packageManagerUsed = 'winget'
            $wingetListOutput = & winget list --id DominikReichl.KeePass --exact --accept-source-agreements 2>$null
            $keepassInstalled = [bool]($wingetListOutput -match 'DominikReichl.KeePass')

            if (-not $keepassInstalled) {
                if ($PSCmdlet.ShouldProcess('DominikReichl.KeePass', 'Install KeePass with winget')) {
                    Write-KeePassInstallLog -Message 'KeePass not detected. Installing with winget.'
                    & winget install --id DominikReichl.KeePass --exact --silent --accept-package-agreements --accept-source-agreements
                    if ($LASTEXITCODE -ne 0) {
                        throw "winget install failed with exit code $LASTEXITCODE"
                    }
                    $keepassInstalled = $true
                }
            }
            elseif (-not $SkipUpgrade) {
                if ($PSCmdlet.ShouldProcess('DominikReichl.KeePass', 'Upgrade KeePass with winget')) {
                    Write-KeePassInstallLog -Message 'KeePass already installed. Attempting upgrade with winget.'
                    & winget upgrade --id DominikReichl.KeePass --exact --silent --accept-package-agreements --accept-source-agreements
                    if ($LASTEXITCODE -ne 0) {
                        Write-KeePassInstallLog -Message "winget upgrade returned exit code $LASTEXITCODE. Continuing with installed version." -LogType 'WARNING'
                    }
                }
                $keepassInstalled = $true
            }
            else {
                Write-KeePassInstallLog -Message 'KeePass already installed and -SkipUpgrade provided.'
            }
        }
        elseif (Get-Command -Name choco -ErrorAction SilentlyContinue) {
            $packageManagerUsed = 'choco'
            $chocoListOutput = & choco list --local-only keepass 2>$null
            $keepassInstalled = [bool]($chocoListOutput -match '^keepass')

            if (-not $keepassInstalled) {
                if ($PSCmdlet.ShouldProcess('keepass', 'Install KeePass with choco')) {
                    Write-KeePassInstallLog -Message 'KeePass not detected. Installing with choco.'
                    & choco install keepass -y
                    if ($LASTEXITCODE -ne 0) {
                        throw "choco install failed with exit code $LASTEXITCODE"
                    }
                    $keepassInstalled = $true
                }
            }
            elseif (-not $SkipUpgrade) {
                if ($PSCmdlet.ShouldProcess('keepass', 'Upgrade KeePass with choco')) {
                    Write-KeePassInstallLog -Message 'KeePass already installed. Attempting upgrade with choco.'
                    & choco upgrade keepass -y
                    if ($LASTEXITCODE -ne 0) {
                        Write-KeePassInstallLog -Message "choco upgrade returned exit code $LASTEXITCODE. Continuing with installed version." -LogType 'WARNING'
                    }
                }
                $keepassInstalled = $true
            }
            else {
                Write-KeePassInstallLog -Message 'KeePass already installed and -SkipUpgrade provided.'
            }
        }
        else {
            throw 'Neither winget nor choco is available. Install one package manager to continue.'
        }

        if (-not $keepassInstalled -and -not $isSimulation) {
            throw 'KeePass installation state could not be verified.'
        }

        $result = [pscustomobject]@{
            KeepassInstalled            = $keepassInstalled
            PackageManager              = $packageManagerUsed
            DefaultVaultPath            = $VaultPath
            EnvironmentScope            = $EnvironmentScope
            DefaultVaultEnvironmentName = 'KEEPASS_DEFAULT_VAULT_PATH'
            Simulated                   = $isSimulation
        }

        if ($isSimulation) {
            Write-KeePassInstallLog -Message "Install-KeePass simulation completed. VaultPath='$VaultPath'."
        }
        else {
            Write-KeePassInstallLog -Message "Install-KeePass completed successfully. VaultPath='$VaultPath'."
        }
        return $result
    }
    catch {
        Write-KeePassInstallLog -Message "Install-KeePass failed: $($_.Exception.Message)" -LogType 'ERROR'
        throw
    }
}

# Example usage:
# PS> Install-KeePass
# PS> Install-KeePass -VaultPath 'C:\ProgramData\Scripts\KeePass' -EnvironmentScope Machine -Verbose
# PS> Install-KeePass -SkipUpgrade -Verbose
