<#
.SYNOPSIS
    Returns created, modified, and accessed timestamps for a file.
.DESCRIPTION
    Reads file metadata and returns a custom object containing common date fields.
.PARAMETER FilePath
    Path to the file.
.EXAMPLE
    PS> Get-FileDates -FilePath 'C:\Temp\a.txt'
.INPUTS
    [string] FilePath
.OUTPUTS
    [pscustomobject]
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

function Get-FileDates {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    try {
        if (-not (Test-Path -Path $FilePath -PathType Leaf)) {
            throw "File not found: $FilePath"
        }

        $file = Get-Item -Path $FilePath -ErrorAction Stop
        [pscustomobject]@{
            FilePath = $file.FullName
            FileName = $file.Name
            Created  = $file.CreationTime
            Modified = $file.LastWriteTime
            Accessed = $file.LastAccessTime
        }
    }
    catch {
        Write-Error "Get-FileDates failed: $($_.Exception.Message)"
        throw
    }
}

# Example usage:
# PS> Get-FileDates -FilePath 'C:\Temp\a.txt'
