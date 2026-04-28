<##
.SYNOPSIS
    Sets or updates a CNAME record in a specified DNS zone on a DNS server.
.DESCRIPTION
    Uses CIM to connect to the DNS server and set or update a CNAME record in the specified zone. Logs all actions and errors using Write-AdvancedLog. Creates the record if it does not exist, or updates the target if it does.
.PARAMETER Zone
    The DNS zone (e.g., "3cx.us").
.PARAMETER RecordName
    The DNS record name to set (e.g., "siptest").
.PARAMETER NewAlias
    The new CNAME target (FQDN).
.PARAMETER DnsServer
    The DNS server to connect to.
.PARAMETER LogFileName
    The log file name for Write-AdvancedLog.
.EXAMPLE
    PS> Set-CNameRecord -Zone "3cx.us" -RecordName "siptest" -NewAlias "srv010010050051.generationsgaither.com" -DnsServer "srv010010037041.generationsgaither.com" -LogFileName "FailoverToIP010010050051"
.INPUTS
    [string] Zone, [string] RecordName, [string] NewAlias, [string] DnsServer, [string] LogFileName
.OUTPUTS
    [bool] $true if successful, $false otherwise.
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-04-28
    Time: 00:00:00
    Time Zone: Central Standard Time
    Function Or Application: Function
    Version: 1.0.0
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: GitHub Copilot
    Copyright (c) 2026
    Licensed under the MIT License. 
    Full text available at: https://opensource.org/licenses/MIT
#>

function Set-CNameRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Zone,
        [Parameter(Mandatory)]
        [string]$RecordName,
        [Parameter(Mandatory)]
        [string]$NewAlias,
        [Parameter(Mandatory)]
        [string]$DnsServer,
        [Parameter(Mandatory)]
        [string]$LogFileName
    )
    # Import logging function
    . "$PSScriptRoot/Write-AdvancedLog.ps1"
    try {
        Write-Verbose "Connecting to DNS server $DnsServer for zone $Zone and record $RecordName."
        $dnsRecord = Get-CimInstance -Namespace "root\MicrosoftDNS" -ClassName "MicrosoftDNS_CNAMEType" -ComputerName $DnsServer -Filter "OwnerName = '$RecordName.$Zone'"
        if ($dnsRecord) {
            Write-Verbose "CNAME record found. Updating PrimaryName to $NewAlias."
            Invoke-CimMethod -InputObject $dnsRecord -MethodName "Modify" -Arguments @{ PrimaryName = $NewAlias }
            Write-AdvancedLog -Message "CNAME updated to $NewAlias for $RecordName.$Zone" -ScriptName $MyInvocation.MyCommand.Name -LogFileName $LogFileName -LogType "INFO"
            return $true
        } else {
            Write-Verbose "CNAME record not found. Creating new CNAME record."
            $zoneObj = Get-CimInstance -Namespace "root\MicrosoftDNS" -ClassName "MicrosoftDNS_Zone" -ComputerName $DnsServer -Filter "Name = '$Zone'"
            if ($zoneObj) {
                $null = Invoke-CimMethod -ClassName "MicrosoftDNS_CNAMEType" -Namespace "root\MicrosoftDNS" -ComputerName $DnsServer -MethodName "CreateInstanceFromPropertyData" -Arguments @{
                    DnsServerName = $DnsServer;
                    ContainerName = $Zone;
                    OwnerName = "$RecordName.$Zone";
                    PrimaryName = $NewAlias;
                    TTL = 3600
                }
                Write-AdvancedLog -Message "CNAME record created: $RecordName.$Zone -> $NewAlias" -ScriptName $MyInvocation.MyCommand.Name -LogFileName $LogFileName -LogType "INFO"
                return $true
            } else {
                Write-AdvancedLog -Message "DNS zone $Zone not found on $DnsServer" -ScriptName $MyInvocation.MyCommand.Name -LogFileName $LogFileName -LogType "ERROR"
                return $false
            }
        }
    } catch {
        Write-AdvancedLog -Message "Failed to set CNAME: $_" -ScriptName $MyInvocation.MyCommand.Name -LogFileName $LogFileName -LogType "ERROR"
        return $false
    }
}

<#
.EXAMPLE
PS> Set-CNameRecord -Zone "3cx.us" -RecordName "siptest" -NewAlias "srv010010050051.generationsgaither.com" -DnsServer "srv010010037041.generationsgaither.com" -LogFileName "FailoverToIP010010050051"
#>

<#
# Example usage block
# $ok = Set-CNameRecord -Zone $Zone -RecordName $RecordName -NewAlias $NewAlias -DnsServer $DnsServer -LogFileName $LogFileName
#>
