<#
.SYNOPSIS
   Updates the CNAME record for 3CX SIP failover.
.DESCRIPTION
   This script updates the CNAME record in the specified DNS zone to point to the new failover server. It uses CIM to connect to the DNS server and modify the record. Includes advanced logging and error handling per current standards.
.EXAMPLE
   PS> .\FailoverToIP010010037051.ps1 -Verbose
.INPUTS
   None
.OUTPUTS
   None
.PARAMETER Zone
   DNS zone to update (default: "3cx.us")
.PARAMETER RecordName
   DNS record name to update (default: "siptest")
.PARAMETER NewAlias
   New CNAME target
.PARAMETER DnsServer
   DNS server to connect to
.NOTES
   Author: Kenneth Tipton
   Company: TNC
   Date: 2026-03-03
   Time: 13:45:00 CST
   Time Zone: CST
   Function Or Application: Application
   Version: 1.0.0
   Website: (https://www.tnandc.com)
   Is AI Used: True
   AI Used: GitHub Copilot
   Copyright (c) 2026
   Licensed under the MIT License. 
   Full text available at: https://opensource.org/licenses/MIT
#>

[CmdletBinding()]
param(
    [string]$Zone = "3cx.us",
    [string]$RecordName = "srv010010037051",
    [string]$NewAlias = "srv010010037051.generationsgaither.com",
    [string]$DnsServer = "srv010010037041.generationsgaither.com"
)

# Import Write-AdvancedLog function

. ..\..\..\Functions\Write-AdvancedLog.ps1

try {
    Write-Verbose "Connecting to DNS server $DnsServer for zone $Zone and record $RecordName."
    $dnsRecord = Get-CimInstance -Namespace "root\MicrosoftDNS" `
                                 -ClassName "MicrosoftDNS_CNAMEType" `
                                 -ComputerName $DnsServer `
                                 -Filter "OwnerName = '$RecordName.$Zone'"

    if ($dnsRecord) {
        Write-Verbose "CNAME record found. Updating PrimaryName to $NewAlias."
        Invoke-CimMethod -InputObject $dnsRecord -MethodName "Modify" -Arguments @{ PrimaryName = $NewAlias }
        Write-Host "Successfully updated CNAME to $NewAlias" -ForegroundColor Green
        Write-AdvancedLog -Message "CNAME updated to $NewAlias" -ScriptName $MyInvocation.MyCommand.Name -LogType "INFO"
    } else {
        Write-Error "CNAME record not found."
        Write-AdvancedLog -Message "CNAME record not found for $RecordName.$Zone" -ScriptName $MyInvocation.MyCommand.Name -LogType "ERROR"
    }
} catch {
    Write-Error "Failed to update CNAME: $_"
    Write-AdvancedLog -Message "Failed to update CNAME: $_" -ScriptName $MyInvocation.MyCommand.Name -LogType "ERROR"
}

<#
.EXAMPLE
PS> .\FailoverToIP010010037051.ps1 -Zone "3cx.us" -RecordName "siptest" -NewAlias "srv010010037051.generationsgaither.com" -DnsServer "srv010010037041.generationsgaither.com" -Verbose
#>