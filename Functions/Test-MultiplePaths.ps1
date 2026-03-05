<#
.SYNOPSIS
    Tests multiple file system paths for existence.
.DESCRIPTION
    Evaluates an array of paths using Test-PathExists and returns a result object per path.
.PARAMETER Paths
    One or more paths to test.
.PARAMETER Type
    Expected path type: Any, File, or Directory.
.EXAMPLE
    PS> Test-MultiplePaths -Paths @('C:\Windows','C:\Temp') -Type Directory
.INPUTS
    [string[]] Paths, [string] Type
.OUTPUTS
    [pscustomobject[]]
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-03-04
    Time: 18:15:00
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

function Test-MultiplePaths {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Paths,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Any', 'File', 'Directory')]
        [string]$Type = 'Any'
    )

    try {
        $results = foreach ($path in $Paths) {
            $exists = Test-PathExists -Path $path -Type $Type -Quiet
            [pscustomobject]@{
                Path   = $path
                Exists = $exists
                Type   = $Type
                Status = if ($exists) { 'Found' } else { 'Missing' }
            }
        }

        return $results
    }
    catch {
        Write-Error "Test-MultiplePaths failed: $($_.Exception.Message)"
        throw
    }
}

# Example usage:
# PS> Test-MultiplePaths -Paths @('C:\Windows','C:\Temp') -Type Directory
