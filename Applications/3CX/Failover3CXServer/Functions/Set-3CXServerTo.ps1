<##
.SYNOPSIS
    Updates the CNAME record for 3CX SIP failover to a specified server.
.DESCRIPTION
    This function updates the CNAME record in the specified DNS zone to point to the provided server alias. Uses Set-CNameRecord for the update. Includes advanced logging and error handling per current standards.
.PARAMETER NewAlias
    The new CNAME target (FQDN) to set for failover.
.PARAMETER LogFileName
    The log file name for Write-AdvancedLog.
.EXAMPLE
    PS> Set-3CXServerTo -NewAlias "srv010010037051.generationsgaither.com" -Verbose
    PS> Set-3CXServerTo -NewAlias "srv010010050051.generationsgaither.com" -Verbose
.INPUTS
    None
.OUTPUTS
    None
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-04-28
    Time: [CurrentTime] [TIMEZONE]
    Function Or Application: Function
    Version: 1.0.0
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: GitHub Copilot
    Copyright (c) 2026
    Licensed under the MIT License. 
    Full text available at: https://opensource.org/licenses/MIT
#>

function Set-3CXServerTo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$NewAlias,
        [string]$LogFileName = "Set-3CXServerTo.log"
    )
    $settingsPath = Join-Path $PSScriptRoot '../Data/Settings.json'
    $settings = Get-Content $settingsPath | ConvertFrom-Json
    $Zone = $settings.Zone
    $RecordName = $settings.RecordName
    $DnsServer = $settings.DnsServer
    . "$PSScriptRoot/Set-CNameRecord.ps1"
    try {
        Write-Verbose "Invoking Set-CNameRecord for $RecordName.$Zone -> $NewAlias on $DnsServer."
        $ok = Set-CNameRecord -Zone $Zone -RecordName $RecordName -NewAlias $NewAlias -DnsServer $DnsServer -LogFileName $LogFileName -Verbose:$VerbosePreference
        if ($ok) {
            Write-Host "Successfully updated or created CNAME to $NewAlias" -ForegroundColor Green
        } else {
            Write-Error "Failed to update or create CNAME record. See log for details."
        }
    } catch {
        Write-Error "Exception occurred: $_"
    }
}

<#[EXAMPLE USAGE]
PS> Set-3CXServerTo -NewAlias "srv010010037051.generationsgaither.com" -Verbose
PS> Set-3CXServerTo -NewAlias "srv010010050051.generationsgaither.com" -Verbose
#>
