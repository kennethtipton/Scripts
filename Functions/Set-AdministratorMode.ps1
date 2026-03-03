<#
.SYNOPSIS
    Ensures the current PowerShell session is running as Administrator; relaunches if not.
.DESCRIPTION
    Checks if the current session is elevated. If not, relaunches the script with Administrator
    privileges and exits the current session.
.EXAMPLE
    PS> Set-AdministratorMode
.EXAMPLE
    PS> Set-AdministratorMode -Verbose
.INPUTS
    None
.OUTPUTS
    None
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-02-02
    Time: 10:04:46
    Time Zone: Central Standard Time
    Function Or Application: Function
    Version: 1.0.0
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: GitHub Copilot (GPT-4.1)

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

function Set-AdministratorMode {
    [CmdletBinding()]
    param()

    try {
        # Check if the current session is running as Administrator
        $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Write-Verbose "Script is not running as Administrator. Attempting to relaunch with elevated privileges..."
            # Relaunch the script as Administrator
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'powershell.exe'
            $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $MyInvocation.PSCommandPath + '"'
            $psi.Verb = 'runas'
            try {
                [System.Diagnostics.Process]::Start($psi) | Out-Null
            }
            catch {
                Write-Error "Failed to relaunch script as Administrator. $_"
                throw
            }
            exit 0
        }
        else {
            Write-Verbose "Script is already running as Administrator."
        }
    }
    catch {
        Write-Error "Set-AdministratorMode failed: $_"
        throw
    }
}

# Example usage:
# PS> Set-AdministratorMode
# PS> Set-AdministratorMode -Verbose
