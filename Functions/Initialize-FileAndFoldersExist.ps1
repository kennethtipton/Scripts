<#
.SYNOPSIS
    Ensures a folder and/or file (with folder structure) exist.
.DESCRIPTION
    Checks if a folder exists and creates it if missing, or checks if a file exists
    and creates both the folder structure and file if missing (optionally with initial content).
.PARAMETER FilePath
    The full path to the file to check or create. If specified, the folder structure is also checked/created.
.PARAMETER FolderPath
    The full path to the folder to check or create. If specified, only the folder is checked/created.
.PARAMETER InitialContent
    Optional initial content to write to the file if it is created.
.EXAMPLE
    PS> Initialize-FileAndFolder -FilePath "C:\Scripts\Log\MyApp.log"
.EXAMPLE
    PS> Initialize-FileAndFolder -FilePath "C:\Scripts\Data\settings.json" -InitialContent "{}"
.EXAMPLE
    PS> Initialize-FileAndFolder -FolderPath "C:\Scripts\Backups"
.INPUTS
    [string] FilePath, [string] FolderPath, [string] InitialContent
.OUTPUTS
    None
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-01-15
    Time: 20:48:22
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
function Initialize-FileAndFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        [string]$FolderPath,

        [string]$InitialContent = ''
    )

    try {
        if ($FolderPath) {
            if (!(Test-Path $FolderPath)) {
                New-Item -ItemType Directory -Path $FolderPath -Force | Out-Null
                Write-Verbose "Created folder: $FolderPath"
            }
            else {
                Write-Verbose "Folder already exists: $FolderPath"
            }
        }
        elseif ($FilePath) {
            $folder = Split-Path -Parent $FilePath
            if (!(Test-Path $folder)) {
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
                Write-Verbose "Created folder: $folder"
            }
            if (!(Test-Path $FilePath)) {
                Set-Content -Path $FilePath -Value $InitialContent
                Write-Verbose "Created file: $FilePath"
            }
            else {
                Write-Verbose "File already exists: $FilePath"
            }
        }
        else {
            throw 'You must specify either -FilePath or -FolderPath.'
        }
    }
    catch {
        Write-Error "Initialize-FileAndFolder failed: $_"
        throw
    }
}

# Example usage:
# PS> Initialize-FileAndFolder -FilePath "C:\Scripts\Logs\MyApp.log"
# PS> Initialize-FileAndFolder -FilePath "C:\Scripts\Data\settings.json" -InitialContent "{}"
# PS> Initialize-FileAndFolder -FolderPath "C:\Scripts\Backups"