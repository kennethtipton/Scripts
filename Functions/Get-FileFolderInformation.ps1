<#
.SYNOPSIS
    Tests whether a path exists and optionally validates its type.
.DESCRIPTION
    Validates that a file system path exists and can enforce file/directory type checks.
    Returns a boolean value and can optionally emit details when not running in quiet mode.
.PARAMETER Path
    The file or directory path to test.
.PARAMETER Type
    The expected path type: Any, File, or Directory.
.PARAMETER Quiet
    Suppresses non-error output and returns only true/false.
.PARAMETER ShowDetails
    Emits basic item details when the path exists and Quiet is not specified.
.EXAMPLE
    PS> Test-PathExists -Path 'C:\Windows' -Type Directory
.EXAMPLE
    PS> Test-PathExists -Path 'C:\Temp\app.log' -Type File -Quiet
.INPUTS
    [string] Path, [string] Type, [switch] Quiet, [switch] ShowDetails
.OUTPUTS
    [bool]
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-03-04
    Time: 18:15:00
    Time Zone: Central Standard Time
    Function Or Application: Function
    Version: 1.1.0
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

function Test-PathExists {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, Position = 0)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Any', 'File', 'Directory')]
        [string]$Type = 'Any',

        [Parameter(Mandatory = $false)]
        [switch]$Quiet,

        [Parameter(Mandatory = $false)]
        [switch]$ShowDetails
    )

    try {
        $exists = Test-Path -Path $Path
        if (-not $exists) {
            if (-not $Quiet) {
                Write-Verbose "Path does not exist: $Path"
            }
            return $false
        }

        $item = Get-Item -Path $Path -ErrorAction Stop
        $typeMatch = switch ($Type) {
            'File' { -not $item.PSIsContainer }
            'Directory' { $item.PSIsContainer }
            default { $true }
        }

        if (-not $typeMatch) {
            if (-not $Quiet) {
                $actualType = if ($item.PSIsContainer) { 'Directory' } else { 'File' }
                Write-Verbose "Path exists but is '$actualType' instead of '$Type': $Path"
            }
            return $false
        }

        if ($ShowDetails -and -not $Quiet) {
            $itemType = if ($item.PSIsContainer) { 'Directory' } else { 'File' }
            Write-Verbose "Path: $($item.FullName)"
            Write-Verbose "Type: $itemType"
            Write-Verbose "Created: $($item.CreationTime)"
            Write-Verbose "Modified: $($item.LastWriteTime)"
            Write-Verbose "Attributes: $($item.Attributes)"
        }

        return $true
    }
    catch {
        if (-not $Quiet) {
            Write-Warning "Error checking path '$Path': $($_.Exception.Message)"
        }
        return $false
    }
}

# Example usage:
# PS> Test-PathExists -Path 'C:\Windows' -Type Directory
# PS> Test-PathExists -Path 'C:\Temp\app.log' -Type File -Quiet
