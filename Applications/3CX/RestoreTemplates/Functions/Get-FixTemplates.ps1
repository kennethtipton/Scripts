<#
.SYNOPSIS
    Extracts fix template entries from Restore Templates configuration.
.DESCRIPTION
    Reads the `tables.fixtemplates` section from a parsed configuration object and
    returns all fix template rows with function mappings.
.PARAMETER Config
    Parsed configuration object from RESTORE_TEMPLATES_DATA.json.
.EXAMPLE
    PS> $config = Get-Content '.\Data\RESTORE_TEMPLATES_DATA.json' -Raw | ConvertFrom-Json
    PS> Get-FixTemplates -Config $config
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

function Get-FixTemplates {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Config
    )

    try {
        $fixTemplates = $Config.tables | Where-Object { $_.fixtemplates } | Select-Object -ExpandProperty fixtemplates
        if (-not $fixTemplates) {
            Write-Verbose 'No fix templates found in configuration.'
            return $null
        }

        return $fixTemplates
    }
    catch {
        Write-Error "Get-FixTemplates failed: $($_.Exception.Message)"
        throw
    }
}

# Example usage:
# PS> $config = Get-Content '.\Data\RESTORE_TEMPLATES_DATA.json' -Raw | ConvertFrom-Json
# PS> Get-FixTemplates -Config $config
