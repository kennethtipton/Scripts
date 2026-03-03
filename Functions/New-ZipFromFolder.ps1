<#
.SYNOPSIS
    Creates a zip file from files, folders, or both in one or more specified folders.
.DESCRIPTION
    Compresses the contents of one or more given folders into a zip archive at the specified
    output path. You can choose to include only files, only folders (with their contents), or
    both. All contents from all specified folders are combined into a single zip file.
.PARAMETER SourceFolder
    One or more folders to zip. Mandatory. Accepts a single path or an array of paths.
.PARAMETER ZipPath
    Optional. The full path for the resulting zip file. If not specified, the zip file will be
    named after the folder being zipped (or 'MultiFolderArchive.zip' if multiple folders) and
    stored in Data/StoredFiles.
.PARAMETER ZipName
    Optional. The name of the zip file (without path). If specified, overrides the default name
    but still stores in Data/StoredFiles unless ZipPath is also specified.
.PARAMETER Mode
    Optional. 'Files', 'Folders', or 'Both'. Determines what to include in the zip. Default is 'Both'.
.EXAMPLE
    PS> New-ZipFromFolder -SourceFolder 'C:\MyFolder' -ZipPath 'C:\MyArchive.zip' -Mode Both
.EXAMPLE
    PS> New-ZipFromFolder -SourceFolder @('C:\Folder1','C:\Folder2') -ZipPath 'C:\Combined.zip' -Mode Both
.EXAMPLE
    PS> New-ZipFromFolder -SourceFolder @('C:\Folder1','C:\Folder2') -ZipName 'MyMultiFolderBackup' -Mode Files
.EXAMPLE
    PS> New-ZipFromFolder -SourceFolder 'C:\MyFolder' -ZipPath 'C:\MyArchive.zip' -Mode Folders
.INPUTS
    [string[]] SourceFolder, [string] ZipPath, [string] ZipName, [string] Mode
.OUTPUTS
    None
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-02-02
    Time: 12:04:00
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


function New-ZipFromFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$SourceFolder,
        [string]$ZipPath,
        [string]$ZipName,
        [ValidateSet('Files','Folders','Both')]
        [string]$Mode = 'Both'
    )
    # Import Write-AdvancedLog if available
    $logFunc = Join-Path $PSScriptRoot '../Functions/Write-AdvancedLog.ps1'
    if (Test-Path $logFunc) { . $logFunc }
    $scriptName = 'New-ZipFromFolder.ps1'

    # Helper for verbose output
    function Write-ZipVerbose {
        param([string]$Message)
        Write-Verbose -Message $Message
    }
    foreach ($folder in $SourceFolder) {
        if (-not (Test-Path $folder)) {
            $errMsg = "Source folder not found: $folder"
            if (Get-Command Write-AdvancedLog -ErrorAction SilentlyContinue) {
                Write-AdvancedLog -Message $errMsg -ScriptName $scriptName -LogType 'ERROR'
            }
            throw $errMsg
        }
        # Determine zip path for each folder
        $thisZipPath = $null
        if ($ZipPath -and $SourceFolder.Count -eq 1) {
            $thisZipPath = $ZipPath
        } elseif ($ZipName -and $SourceFolder.Count -eq 1) {
            $thisZipPath = Join-Path $PSScriptRoot ("../Data/StoredFiles/$ZipName.zip")
        } else {
            $rootFolderName = Split-Path -Path (Resolve-Path $folder) -Leaf
            $thisZipPath = Join-Path $PSScriptRoot ("../Data/StoredFiles/$rootFolderName.zip")
        }
        $resolvedZipPath = $thisZipPath
        if (-not (Split-Path $resolvedZipPath -Parent | Test-Path)) {
            New-Item -Path (Split-Path $resolvedZipPath -Parent) -ItemType Directory | Out-Null
            if (Get-Command Write-AdvancedLog -ErrorAction SilentlyContinue) {
                Write-AdvancedLog -Message "Created directory: $(Split-Path $resolvedZipPath -Parent)" -ScriptName $scriptName -LogType 'INFO'
            }
            Write-ZipVerbose "Created directory: $(Split-Path $resolvedZipPath -Parent)"
        }
        if (Test-Path $resolvedZipPath) {
            # Backup existing file to Backups with timestamp
            $backupsDir = Join-Path $PSScriptRoot '../Backups'
            if (-not (Test-Path $backupsDir)) {
                New-Item -Path $backupsDir -ItemType Directory | Out-Null
            }
            $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $zipBaseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedZipPath)
            $zipExt = [System.IO.Path]::GetExtension($resolvedZipPath)
            $backupName = "$zipBaseName-$timestamp$zipExt"
            $backupPath = Join-Path $backupsDir $backupName
            Copy-Item $resolvedZipPath $backupPath -Force
            if (Get-Command Write-AdvancedLog -ErrorAction SilentlyContinue) {
                Write-AdvancedLog -Message "Backed up existing zip: $resolvedZipPath to $backupPath" -ScriptName $scriptName -LogType 'WARNING'
            }
            Write-ZipVerbose "Backed up existing zip: $resolvedZipPath to $backupPath"
            Remove-Item $resolvedZipPath -Force
            if (Get-Command Write-AdvancedLog -ErrorAction SilentlyContinue) {
                Write-AdvancedLog -Message "Removed existing zip: $resolvedZipPath" -ScriptName $scriptName -LogType 'WARNING'
            }
            Write-ZipVerbose "Removed existing zip: $resolvedZipPath"
        }
        $items = @()
        switch ($Mode) {
            'Files'   { $items += Get-ChildItem -Path $folder -File -Recurse }
            'Folders' { $items += Get-ChildItem -Path $folder -Directory -Recurse }
            'Both'    { $items += Get-ChildItem -Path $folder -Recurse }
        }
        if ($items.Count -eq 0) {
            $errMsg = "No items found to zip in $folder with mode $Mode."
            if (Get-Command Write-AdvancedLog -ErrorAction SilentlyContinue) {
                Write-AdvancedLog -Message $errMsg -ScriptName $scriptName -LogType 'WARNING'
            }
            throw $errMsg
        }
        try {
            Compress-Archive -Path $items.FullName -DestinationPath $resolvedZipPath -Force
            if (Get-Command Write-AdvancedLog -ErrorAction SilentlyContinue) {
                Write-AdvancedLog -Message "Created zip: $resolvedZipPath from $folder ($Mode)" -ScriptName $scriptName -LogType 'INFO'
            }
            Write-ZipVerbose "Created zip: $resolvedZipPath from $folder ($Mode)"
        } catch {
            $errMsg = "Failed to create zip: $_"
            if (Get-Command Write-AdvancedLog -ErrorAction SilentlyContinue) {
                Write-AdvancedLog -Message $errMsg -ScriptName $scriptName -LogType 'ERROR'
            }
            throw $errMsg
        }
    }
}

# Example usage:
# PS> New-ZipFromFolder -SourceFolder 'C:\Path\To\Folder' -ZipPath 'C:\Path\To\Archive.zip' -Mode Both
# PS> New-ZipFromFolder -SourceFolder @('C:\Folder1','C:\Folder2') -ZipPath 'C:\Path\To\Archive.zip' -Mode Both
# PS> New-ZipFromFolder -SourceFolder @('C:\Folder1','C:\Folder2') -ZipName 'MyMultiFolderBackup' -Mode Files
# PS> New-ZipFromFolder -SourceFolder 'C:\Path\To\Folder' -ZipPath 'C:\Path\To\Archive.zip' -Mode Folders
# PS> New-ZipFromFolder -SourceFolder @('C:\Scripts\Installs\PodeWeb','C:\Scripts\Installs\PoshAcme','C:\Scripts\Installs\PoshAcmeDeploy') -Mode Both