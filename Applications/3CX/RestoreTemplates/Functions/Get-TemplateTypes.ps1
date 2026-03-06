<#
.SYNOPSIS
    Extracts template type metadata from Restore Templates configuration.
.DESCRIPTION
    Reads the `tables.templatetypes` section from a parsed configuration object
    and returns the template type entries.
.PARAMETER Config
    Parsed configuration object from RESTORE_TEMPLATES_DATA.json.
.PARAMETER LogFileName
    Optional log file base name to pass through to Write-AdvancedLog.
.EXAMPLE
    PS> $config = Get-Content '.\Data\RESTORE_TEMPLATES_DATA.json' -Raw | ConvertFrom-Json
    PS> Get-TemplateTypes -Config $config
.INPUTS
    [pscustomobject] Config, [string] LogFileName
.OUTPUTS
    [pscustomobject[]]
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-03-04
    Time: 18:25:00
    Time Zone: Central Standard Time
    Function Or Application: Function
    Version: 1.0.0
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: GitHub Copilot

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

function Get-TemplateTypes {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Config,

        [Parameter(Mandatory = $false)]
        [string]$LogFileName
    )

    $scriptLabel = 'Get-TemplateTypes.ps1'
    $scriptPath = $MyInvocation.MyCommand.ScriptBlock.File
    if (-not [string]::IsNullOrWhiteSpace($scriptPath)) {
        $scriptLabel = [System.IO.Path]::GetFileName($scriptPath)
    }

    try {
        $templateTypes = $Config.tables | Where-Object { $_.templatetypes } | Select-Object -ExpandProperty templatetypes
        if (-not $templateTypes) {
            if (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue) {
                $logArgs = @{
                    Message    = 'Get-TemplateTypes: No template types found in configuration.'
                    ScriptName = $scriptLabel
                    LogType    = 'WARNING'
                }

                if (-not [string]::IsNullOrWhiteSpace($LogFileName)) {
                    $logArgs.LogFileName = $LogFileName
                }

                Write-AdvancedLog @logArgs
            }
            else {
                Write-Verbose 'No template types found in configuration.'
            }
            return $null
        }

        return $templateTypes
    }
    catch {
        if (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue) {
            $logArgs = @{
                Message    = "Get-TemplateTypes failed: $($_.Exception.Message)"
                ScriptName = $scriptLabel
                LogType    = 'ERROR'
            }

            if (-not [string]::IsNullOrWhiteSpace($LogFileName)) {
                $logArgs.LogFileName = $LogFileName
            }

            Write-AdvancedLog @logArgs
        }
        else {
            Write-Error "Get-TemplateTypes failed: $($_.Exception.Message)"
        }
        throw
    }
}

# Example usage:
# PS> $config = Get-Content '.\Data\RESTORE_TEMPLATES_DATA.json' -Raw | ConvertFrom-Json
# PS> Get-TemplateTypes -Config $config
