<##
.SYNOPSIS
    Checks the status of a specified Windows service on a local or remote computer.
.DESCRIPTION
    Returns the status (Running, Stopped, etc.) of a given service by name or display name. Supports remote computers. Logs errors using Write-AdvancedLog if the service is not found or an error occurs.
.PARAMETER ServiceName
    The name or display name of the service to check. Mandatory.
.PARAMETER ComputerName
    The target computer. Defaults to 'localhost'.
.PARAMETER LogFileName
    Optional log file name for Write-AdvancedLog.
.EXAMPLE
    PS> Get-ServiceStatus -ServiceName "3CXPhoneSystem01" -ComputerName "srv010010037051"
.INPUTS
    [string] ServiceName, [string] ComputerName, [string] LogFileName
.OUTPUTS
    [string] Service status (e.g., 'Running', 'Stopped') or $null if not found.
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

function Get-ServiceStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName,
        [string]$ComputerName = 'localhost',
        [string]$LogFileName
    )
    # Import logging function
    . "$PSScriptRoot/Write-AdvancedLog.ps1"
    try {
        $service = Get-Service -ComputerName $ComputerName | Where-Object { $_.Name -eq $ServiceName -or $_.DisplayName -eq $ServiceName }
        if ($service) {
            return $service.Status
        } else {
            Write-AdvancedLog -Message "Service '$ServiceName' not found on $ComputerName" -ScriptName $MyInvocation.MyCommand.Name -LogFileName $LogFileName -LogType "ERROR"
            return $null
        }
    } catch {
        Write-AdvancedLog -Message "Error checking service '$ServiceName' on $ComputerName: $_" -ScriptName $MyInvocation.MyCommand.Name -LogFileName $LogFileName -LogType "ERROR"
        return $null
    }
}

<#
.EXAMPLE
PS> Get-ServiceStatus -ServiceName "3CXPhoneSystem01" -ComputerName "srv010010037051"
#>

<#
# Example usage block
# $status = Get-ServiceStatus -ServiceName "wuauserv" -ComputerName "localhost"
#>
