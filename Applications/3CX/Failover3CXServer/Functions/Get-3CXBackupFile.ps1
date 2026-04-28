<##
.SYNOPSIS
    Retrieves the 3CX backup file from an FTP server and stores it in the Data folder.
.DESCRIPTION
    Downloads the specified 3CX backup file (e.g., 3CXScheduledBackup.zip) from the given FTP server using provided credentials and saves it to the local Data folder. Logs all actions and errors using Write-AdvancedLog.
.PARAMETER FtpUrl
    The full FTP URL to the backup file (e.g., ftp://server/path/3CXScheduledBackup.zip).
.PARAMETER FtpUser
    The FTP username.
.PARAMETER FtpPassword
    The FTP password.
.PARAMETER LocalPath
    The local path to save the backup file (e.g., Data/3CXScheduledBackup.zip).
.PARAMETER LogFileName
    The log file name for Write-AdvancedLog.
.EXAMPLE
    PS> Get-3CXBackupFile -FtpUrl "ftp://server/path/3CXScheduledBackup.zip" -FtpUser "user" -FtpPassword "pass" -LocalPath "C:\Scripts\Applications\3CX\Failover3CXServer\Data\3CXScheduledBackup.zip" -LogFileName "FailoverToIP010010050051"
.INPUTS
    [string] FtpUrl, [string] FtpUser, [string] FtpPassword, [string] LocalPath, [string] LogFileName
.OUTPUTS
    [bool] $true if download succeeds, $false otherwise.
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

function Get-3CXBackupFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FtpUrl,
        [Parameter(Mandatory)]
        [string]$FtpUser,
        [Parameter(Mandatory)]
        [string]$FtpPassword,
        [Parameter(Mandatory)]
        [string]$LocalPath,
        [Parameter(Mandatory)]
        [string]$LogFileName
    )
    # Import logging function
    . "$PSScriptRoot/../../../../Functions/Write-AdvancedLog.ps1"
    try {
        Write-Verbose "Downloading 3CX backup from FTP: $FtpUrl to $LocalPath"
        $webclient = New-Object System.Net.WebClient
        $webclient.Credentials = New-Object System.Net.NetworkCredential($FtpUser, $FtpPassword)
        $webclient.DownloadFile($FtpUrl, $LocalPath)
        Write-AdvancedLog -Message "Downloaded 3CX backup from FTP: $FtpUrl" -ScriptName $MyInvocation.MyCommand.Name -LogFileName $LogFileName -LogType "INFO"
        return $true
    } catch {
        Write-AdvancedLog -Message "Failed to download 3CX backup from FTP: $_" -ScriptName $MyInvocation.MyCommand.Name -LogFileName $LogFileName -LogType "ERROR"
        return $false
    }
}

<#
.EXAMPLE
PS> Get-3CXBackupFile -FtpUrl "ftp://server/path/3CXScheduledBackup.zip" -FtpUser "user" -FtpPassword "pass" -LocalPath "C:\Scripts\Applications\3CX\Failover3CXServer\Data\3CXScheduledBackup.zip" -LogFileName "FailoverToIP010010050051"
#>

<#
# Example usage block
# $ok = Get-3CXBackupFile -FtpUrl $ftpUrl -FtpUser $ftpUser -FtpPassword $ftpPassword -LocalPath $localBackup -LogFileName $LogFileName
#>
