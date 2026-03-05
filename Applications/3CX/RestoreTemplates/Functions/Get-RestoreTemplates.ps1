<#
.SYNOPSIS
    Extracts restore template entries from Restore Templates configuration.
.DESCRIPTION
    Reads the `tables.restoretemplates` section from a parsed configuration object
    and returns all restore template rows.
.PARAMETER Config
    Parsed configuration object from RESTORE_TEMPLATES_DATA.json.
.EXAMPLE
    PS> $config = Get-Content '.\Data\RESTORE_TEMPLATES_DATA.json' -Raw | ConvertFrom-Json
    PS> Get-RestoreTemplates -Config $config
.INPUTS
    [pscustomobject] Config
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

function Get-RestoreTemplates {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Config
    )

    try {
        $restoreTemplates = $Config.tables | Where-Object { $_.restoretemplates } | Select-Object -ExpandProperty restoretemplates
        if (-not $restoreTemplates) {
            Write-Verbose 'No restore templates found in configuration.'
            return $null
        }

        return $restoreTemplates
    }
    catch {
        Write-Error "Get-RestoreTemplates failed: $($_.Exception.Message)"
        throw
    }
}

# Example usage:
# PS> $config = Get-Content '.\Data\RESTORE_TEMPLATES_DATA.json' -Raw | ConvertFrom-Json
# PS> Get-RestoreTemplates -Config $config
