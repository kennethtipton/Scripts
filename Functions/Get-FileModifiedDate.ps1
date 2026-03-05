<#
.SYNOPSIS
    Gets the last modified timestamp of a file.
.DESCRIPTION
    Returns a file's LastWriteTime value or a formatted string if Format is provided.
.PARAMETER FilePath
    Path to the file.
.PARAMETER Format
    Optional .NET date format string.
.EXAMPLE
    PS> Get-FileModifiedDate -FilePath 'C:\Temp\a.txt'
.EXAMPLE
    PS> Get-FileModifiedDate -FilePath 'C:\Temp\a.txt' -Format 'yyyy-MM-dd HH:mm:ss'
.INPUTS
    [string] FilePath, [string] Format
.OUTPUTS
    [datetime] or [string]
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

function Get-FileModifiedDate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        [string]$Format
    )

    try {
        if (-not (Test-Path -Path $FilePath -PathType Leaf)) {
            throw "File not found: $FilePath"
        }

        $modifiedDate = (Get-Item -Path $FilePath -ErrorAction Stop).LastWriteTime
        if ($Format) {
            return $modifiedDate.ToString($Format)
        }

        return $modifiedDate
    }
    catch {
        Write-Error "Get-FileModifiedDate failed: $($_.Exception.Message)"
        throw
    }
}

# Example usage:
# PS> Get-FileModifiedDate -FilePath 'C:\Temp\a.txt'
# PS> Get-FileModifiedDate -FilePath 'C:\Temp\a.txt' -Format 'yyyy-MM-dd HH:mm:ss'
