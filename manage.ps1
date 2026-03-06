
<#
.SYNOPSIS
    PowerShell Script Management Application
.DESCRIPTION
    Lists available PowerShell scripts in the scripts folder, prompts user to select one, runs the script, and logs output using Write-AdvancedLog.
.PARAMETER Verbose
    Enables verbose output.
.EXAMPLE
    PS> .\Manage.ps1 -Verbose
    Lists and runs scripts with verbose logging.
.INPUTS
    None
.OUTPUTS
    None
.NOTES
    Author: Kenneth Tipton
    Company: TNC, Inc
    Date: 2026-02-24
    Time: 21:25:30 CST
    Time Zone: CST
    ScriptType: Application
    Version: 1.0.0.0
    Website: (https://www.tnandc.com)
    IsAIUsed: True
    AIUsed: GitHub Copilot
    Copyright (c) 2026
    LicenseName: MIT
    URLToLicense: https://opensource.org/licenses/MIT
#>

[CmdletBinding()]
param()

$scriptFolder = Join-Path -Path $PSScriptRoot -ChildPath 'scripts'
$logFolder = Join-Path -Path $PSScriptRoot -ChildPath 'logs'

# Import Write-AdvancedLog if available
$logFunc = Join-Path -Path $PSScriptRoot -ChildPath 'Functions/Write-AdvancedLog.ps1'
if (Test-Path $logFunc) {
    . $logFunc
}

try {
    $scriptFiles = Get-ChildItem -Path $scriptFolder -Filter *.ps1 | Select-Object -ExpandProperty Name
    if ($scriptFiles.Count -eq 0) {
        Write-AdvancedLog -Message "No PowerShell scripts found in $scriptFolder." -ScriptName "Manage.ps1" -LogType "WARNING" -Verbose:$VerbosePreference
        Write-Host "No PowerShell scripts found in $scriptFolder."
        exit
    }

    Write-Host "Available Scripts:"
    for ($i = 0; $i -lt $scriptFiles.Count; $i++) {
        Write-Host "$($i+1): $($scriptFiles[$i])"
    }

    $selection = Read-Host "Enter the number of the script to run"
    if ($selection -match '^[0-9]+$' -and $selection -ge 1 -and $selection -le $scriptFiles.Count) {
        $scriptToRun = $scriptFiles[$selection-1]
        $logFile = Join-Path -Path $logFolder -ChildPath ("$scriptToRun.log")
        Write-AdvancedLog -Message "Running $scriptToRun..." -ScriptName "Manage.ps1" -LogType "INFO" -Verbose:$VerbosePreference
        try {
            & (Join-Path $scriptFolder $scriptToRun) 2>&1 | Tee-Object -FilePath $logFile
            Write-AdvancedLog -Message "Execution complete. Log saved to $logFile." -ScriptName "Manage.ps1" -LogType "INFO" -Verbose:$VerbosePreference
            Write-Host "Execution complete. Log saved to $logFile."
        } catch {
            Write-AdvancedLog -Message "Error running script: $_" -ScriptName "Manage.ps1" -LogType "ERROR" -Verbose:$VerbosePreference
            Write-Host "Error running script: $_"
        }
    } else {
        Write-AdvancedLog -Message "Invalid selection. Exiting." -ScriptName "Manage.ps1" -LogType "WARNING" -Verbose:$VerbosePreference
        Write-Host "Invalid selection. Exiting."
    }
} catch {
    Write-AdvancedLog -Message "Unexpected error: $_" -ScriptName "Manage.ps1" -LogType "ERROR" -Verbose:$VerbosePreference
    Write-Host "Unexpected error: $_"
}

# Example usage:
# PS> .\Manage.ps1 -Verbose
# PS> .\Manage.ps1
