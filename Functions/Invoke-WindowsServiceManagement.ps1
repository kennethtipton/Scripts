<#
.SYNOPSIS
    Checks and manages a Windows service on local or remote servers.
.DESCRIPTION
    Verifies whether a service is installed on one or more Windows servers and returns
    its current status. Optionally changes startup type and performs start, stop, or
    restart actions.
.PARAMETER ComputerName
    One or more local or remote Windows server names. Defaults to localhost.
.PARAMETER ServiceName
    One or more service names or display names to check and manage. Supports wildcards (* and ?).
.PARAMETER StartupType
    Optional startup type change. Use NoChange to leave startup type as-is.
.PARAMETER Action
    Optional service action to perform. Use None to only query status.
.PARAMETER Credential
    Optional credential for remote operations.
.EXAMPLE
    PS> Invoke-WindowsServiceManagement -ServiceName 'Spooler'
.EXAMPLE
    PS> Invoke-WindowsServiceManagement -ComputerName 'Server01' -ServiceName 'W32Time' -StartupType Automatic -Action Restart
.EXAMPLE
    PS> Invoke-WindowsServiceManagement -ComputerName 'Server01','Server02' -ServiceName 'DHCP' -Action Start -Verbose
.EXAMPLE
    PS> Invoke-WindowsServiceManagement -ComputerName 'Server01' -ServiceName 'Win*' -Verbose
.EXAMPLE
    PS> Invoke-WindowsServiceManagement -ComputerName 'Server01' -ServiceName @('Spooler','W32Time','Win*')
.INPUTS
    [string[]] ComputerName, [string[]] ServiceName, [string] StartupType, [string] Action, [pscredential] Credential
.OUTPUTS
    [pscustomobject]
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-03-04
    Time: 17:30:56
    Time Zone: (UTC-06:00) Central Time (US & Canada)
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

function Invoke-WindowsServiceManagement {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$ComputerName = @('localhost'),

        [Parameter(Mandatory = $true)]
        [string[]]$ServiceName,

        [ValidateSet('NoChange', 'Automatic', 'Manual', 'Disabled', 'AutomaticDelayedStart')]
        [string]$StartupType = 'NoChange',

        [ValidateSet('None', 'Start', 'Stop', 'Restart')]
        [string]$Action = 'None',

        [Parameter(Mandatory = $false)]
        [pscredential]$Credential
    )

    begin {
        $script:ScriptLabel = $MyInvocation.MyCommand.Name
        $writeAdvancedLogPath = Join-Path -Path $PSScriptRoot -ChildPath 'Write-AdvancedLog.ps1'
        if (Test-Path -Path $writeAdvancedLogPath) {
            . $writeAdvancedLogPath
        }

        function Write-InternalLog {
            param(
                [Parameter(Mandatory = $true)]
                [string]$Message,

                [ValidateSet('INFO', 'WARNING', 'ERROR')]
                [string]$LogType = 'INFO'
            )

            if (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue) {
                try {
                    Write-AdvancedLog -Message $Message -ScriptName $script:ScriptLabel -LogType $LogType
                }
                catch {
                    Write-Verbose "Write-AdvancedLog failed: $($_.Exception.Message)"
                }
            }
            else {
                Write-Verbose $Message
            }
        }

        function Get-ServiceRecord {
            param(
                [Parameter(Mandatory = $true)]
                [string]$TargetComputer,

                [Parameter(Mandatory = $true)]
                [string]$TargetService,

                [Parameter(Mandatory = $false)]
                [pscredential]$TargetCredential
            )

            $isWildcardPattern = [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($TargetService)

            $safeServiceName = $TargetService.Replace("'", "''")
            $queryByName = "Name='$safeServiceName'"
            $queryByDisplayName = "DisplayName='$safeServiceName'"

            $cimArgs = @{
                ClassName    = 'Win32_Service'
                ComputerName = $TargetComputer
                ErrorAction  = 'Stop'
            }

            if ($TargetCredential) {
                $cimArgs.Credential = $TargetCredential
            }

            try {
                if ($isWildcardPattern) {
                    $records = Get-CimInstance @cimArgs | Where-Object {
                        $_.Name -like $TargetService -or $_.DisplayName -like $TargetService
                    }
                    return @($records)
                }

                $cimArgs.Filter = $queryByName
                $record = Get-CimInstance @cimArgs

                if (-not $record) {
                    $cimArgs.Filter = $queryByDisplayName
                    $record = Get-CimInstance @cimArgs
                }

                return @($record)
            }
            catch {
                throw $_
            }
        }
    }

    process {
        foreach ($server in $ComputerName) {
            $serviceLookup = @{}
            $services = @()

            foreach ($serviceFilter in $ServiceName) {
                try {
                    $matchedServices = @(Get-ServiceRecord -TargetComputer $server -TargetService $serviceFilter -TargetCredential $Credential)
                }
                catch {
                    $message = "Unable to query service '$serviceFilter' on '$server': $($_.Exception.Message)"
                    Write-InternalLog -Message $message -LogType 'ERROR'
                    [pscustomobject]@{
                        ComputerName                = $server
                        ServiceName                 = $serviceFilter
                        DisplayName                 = $null
                        Installed                   = $false
                        State                       = 'Unknown'
                        StartupType                 = 'Unknown'
                        StartupTypeRequested        = $StartupType
                        ActionRequested             = $Action
                        StartupTypeChanged          = $false
                        ActionPerformed             = $false
                        ErrorMessage                = $message
                    }
                    continue
                }

                if (-not $matchedServices -or $matchedServices.Count -eq 0) {
                    $message = "Service '$serviceFilter' is not installed on '$server'."
                    Write-InternalLog -Message $message -LogType 'WARNING'
                    [pscustomobject]@{
                        ComputerName                = $server
                        ServiceName                 = $serviceFilter
                        DisplayName                 = $null
                        Installed                   = $false
                        State                       = 'NotInstalled'
                        StartupType                 = 'NotInstalled'
                        StartupTypeRequested        = $StartupType
                        ActionRequested             = $Action
                        StartupTypeChanged          = $false
                        ActionPerformed             = $false
                        ErrorMessage                = $message
                    }
                    continue
                }

                foreach ($matchedService in $matchedServices) {
                    if (-not $serviceLookup.ContainsKey($matchedService.Name)) {
                        $serviceLookup[$matchedService.Name] = $true
                        $services += $matchedService
                    }
                }
            }

            foreach ($service in $services) {
                $errorMessages = @()
                $startupTypeChanged = $false
                $actionPerformed = $false
                $resolvedServiceName = $service.Name

                if ($StartupType -ne 'NoChange') {
                    if ($PSCmdlet.ShouldProcess("$server/$resolvedServiceName", "Set startup type to '$StartupType'")) {
                        try {
                            $startupScript = {
                                param(
                                    [string]$InnerServiceName,
                                    [string]$InnerStartupType
                                )

                                if ($InnerStartupType -eq 'AutomaticDelayedStart') {
                                    Set-Service -Name $InnerServiceName -StartupType Automatic -ErrorAction Stop
                                    & sc.exe config $InnerServiceName start= delayed-auto | Out-Null
                                }
                                else {
                                    Set-Service -Name $InnerServiceName -StartupType $InnerStartupType -ErrorAction Stop
                                }
                            }

                            if ($server -in @('localhost', '.', $env:COMPUTERNAME)) {
                                & $startupScript $resolvedServiceName $StartupType
                            }
                            else {
                                $invokeArgs = @{
                                    ComputerName = $server
                                    ScriptBlock  = $startupScript
                                    ArgumentList = @($resolvedServiceName, $StartupType)
                                    ErrorAction  = 'Stop'
                                }

                                if ($Credential) {
                                    $invokeArgs.Credential = $Credential
                                }

                                Invoke-Command @invokeArgs | Out-Null
                            }

                            $startupTypeChanged = $true
                            Write-InternalLog -Message "Startup type changed to '$StartupType' for service '$resolvedServiceName' on '$server'."
                        }
                        catch {
                            $errorMessages += "Failed to change startup type: $($_.Exception.Message)"
                            Write-InternalLog -Message "Failed startup type update for '$resolvedServiceName' on '$server': $($_.Exception.Message)" -LogType 'ERROR'
                        }
                    }
                }

                if ($Action -ne 'None') {
                    if ($PSCmdlet.ShouldProcess("$server/$resolvedServiceName", "Perform action '$Action'")) {
                        try {
                            $actionScript = {
                                param(
                                    [string]$InnerServiceName,
                                    [string]$InnerAction
                                )

                                switch ($InnerAction) {
                                    'Start' { Start-Service -Name $InnerServiceName -ErrorAction Stop }
                                    'Stop' { Stop-Service -Name $InnerServiceName -Force -ErrorAction Stop }
                                    'Restart' { Restart-Service -Name $InnerServiceName -Force -ErrorAction Stop }
                                    default { }
                                }
                            }

                            if ($server -in @('localhost', '.', $env:COMPUTERNAME)) {
                                & $actionScript $resolvedServiceName $Action
                            }
                            else {
                                $invokeArgs = @{
                                    ComputerName = $server
                                    ScriptBlock  = $actionScript
                                    ArgumentList = @($resolvedServiceName, $Action)
                                    ErrorAction  = 'Stop'
                                }

                                if ($Credential) {
                                    $invokeArgs.Credential = $Credential
                                }

                                Invoke-Command @invokeArgs | Out-Null
                            }

                            $actionPerformed = $true
                            Write-InternalLog -Message "Action '$Action' completed for service '$resolvedServiceName' on '$server'."
                        }
                        catch {
                            $errorMessages += "Failed to perform action '$Action': $($_.Exception.Message)"
                            Write-InternalLog -Message "Failed action '$Action' for '$resolvedServiceName' on '$server': $($_.Exception.Message)" -LogType 'ERROR'
                        }
                    }
                }

                try {
                    $service = @(Get-ServiceRecord -TargetComputer $server -TargetService $resolvedServiceName -TargetCredential $Credential)[0]
                }
                catch {
                    $errorMessages += "Failed to refresh service state: $($_.Exception.Message)"
                }

                $startupTypeValue = switch ($service.StartMode) {
                    'Auto' { if ($service.DelayedAutoStart) { 'AutomaticDelayedStart' } else { 'Automatic' } }
                    'Manual' { 'Manual' }
                    'Disabled' { 'Disabled' }
                    default { $service.StartMode }
                }

                [pscustomobject]@{
                    ComputerName                = $server
                    ServiceName                 = $service.Name
                    DisplayName                 = $service.DisplayName
                    Installed                   = $true
                    State                       = $service.State
                    StartupType                 = $startupTypeValue
                    StartupTypeRequested        = $StartupType
                    ActionRequested             = $Action
                    StartupTypeChanged          = $startupTypeChanged
                    ActionPerformed             = $actionPerformed
                    ErrorMessage                = if ($errorMessages.Count -gt 0) { $errorMessages -join '; ' } else { $null }
                }
            }
        }
    }
}

# Example usage:
# PS> Invoke-WindowsServiceManagement -ServiceName 'Spooler'
# PS> Invoke-WindowsServiceManagement -ComputerName 'Server01' -ServiceName 'W32Time' -StartupType Automatic
# PS> Invoke-WindowsServiceManagement -ComputerName 'Server01' -ServiceName 'W32Time' -Action Restart -Verbose
# PS> Invoke-WindowsServiceManagement -ComputerName 'Server01','Server02' -ServiceName 'DHCP' -Action Start -Credential (Get-Credential)
# PS> Invoke-WindowsServiceManagement -ComputerName 'Server01' -ServiceName 'Win*' -Verbose
# PS> Invoke-WindowsServiceManagement -ComputerName 'Server01' -ServiceName @('Spooler','W32Time','Win*')