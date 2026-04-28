<#
.SYNOPSIS
    3CX Failover Passive Mode Monitor for srv010010050051
.DESCRIPTION
    Monitors the primary 3CX server (srv010010037051.generationsgaither.com) for network and service health. If reachable and all required 3CX services are running, triggers passive mode on this server using RestoreCmd.exe. Includes advanced logging and error handling per TNC standards.
.EXAMPLE
    PS> .\Monitor-3CXFailoverPassive.ps1 -Verbose
.INPUTS
    None
.OUTPUTS
    None
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-04-28
    Time: 00:00:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 1.0.0
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: GitHub Copilot
    Copyright (c) 2026
    Licensed under the MIT License. 
    Full text available at: https://opensource.org/licenses/MIT
#>


[CmdletBinding()]
param()

# Import logging and service status functions
. ..\..\..\Functions\Write-AdvancedLog.ps1
. ..\..\..\Functions\Get-ServiceStatus.ps1

# Load settings from JSON
$settingsPath = Join-Path $PSScriptRoot 'Data/Settings.json'
$settings = Get-Content $settingsPath | ConvertFrom-Json
$PrimaryServer = $settings.PrimaryServer
$RequiredServices = $settings.RequiredServices

# Set log file name locally
$LogFileName = "FailoverToIP010010050051"
$RestoreCmdPath = $settings.RestoreCmdPath


# Test if primary server is reachable
function Test-PrimaryServer {
    try {
        Write-Verbose "Pinging $PrimaryServer..."
        if (Test-Connection -ComputerName $PrimaryServer -Count 2 -Quiet) {
            Write-Verbose "$PrimaryServer is reachable."
            return $true
        } else {
            Write-Verbose "$PrimaryServer is NOT reachable."
            return $false
        }
    } catch {
        Write-AdvancedLog -Message "Ping failed: $_" -ScriptName $MyInvocation.MyCommand.Name -LogFileName $LogFileName -LogType "ERROR"
        return $false
    }
}

# Use shared Get-ServiceStatus for all service checks
function Test-3CXServices {
    $allRunning = $true
    $notRunning = @()
    foreach ($svc in $RequiredServices) {
        $status = Get-ServiceStatus -ServiceName $svc -ComputerName $PrimaryServer -LogFileName $LogFileName
        if ($status -ne 'Running') {
            $allRunning = $false
            $notRunning += $svc
        }
    }
    if ($allRunning) {
        Write-Verbose "All required 3CX services are running."
        return $true
    } else {
        if ($notRunning.Count -gt 0) {
            Write-AdvancedLog -Message "Services not running: $($notRunning -join ', ')" -ScriptName $MyInvocation.MyCommand.Name -LogFileName $LogFileName -LogType "ERROR"
        }
        return $false
    }
}


# Download backup from FTP before restore
function Get-3CXBackupFromFTP {
    param(
        [string]$FtpUrl,
        [string]$FtpUser,
        [string]$FtpPassword,
        [string]$LocalPath
    )
    try {
        Write-Verbose "Downloading backup from FTP: $FtpUrl to $LocalPath"
        $webclient = New-Object System.Net.WebClient
        $webclient.Credentials = New-Object System.Net.NetworkCredential($FtpUser, $FtpPassword)
        $webclient.DownloadFile($FtpUrl, $LocalPath)
        Write-AdvancedLog -Message "Downloaded backup from FTP: $FtpUrl" -ScriptName $MyInvocation.MyCommand.Name -LogFileName $LogFileName -LogType "INFO"
        return $true
    } catch {
        Write-AdvancedLog -Message "Failed to download backup from FTP: $_" -ScriptName $MyInvocation.MyCommand.Name -LogFileName $LogFileName -LogType "ERROR"
        return $false
    }
}

# Set passive mode by restoring backup in failover mode
function Set-PassiveMode {
    $backupFile = Join-Path $PSScriptRoot 'Data/3CXScheduledBackup.zip'
    $logFile = Join-Path $PSScriptRoot 'Data/restore_cmd.log'
    $restoreCmd = $RestoreCmdPath
    if (-not (Test-Path $backupFile)) {
        Write-AdvancedLog -Message "Backup file not found: $backupFile" -ScriptName $MyInvocation.MyCommand.Name -LogFileName $LogFileName -LogType "ERROR"
        return
    }
    if (Test-Path $restoreCmd) {
        Write-Verbose "Restoring backup in failover mode using RestoreCmd.exe..."
        & $restoreCmd --file=$backupFile --log=$logFile --failover | Out-Null
        Write-AdvancedLog -Message "Passive mode triggered via RestoreCmd.exe with failover mode" -ScriptName $MyInvocation.MyCommand.Name -LogFileName $LogFileName -LogType "INFO"
    } else {
        Write-AdvancedLog -Message "RestoreCmd.exe not found at $restoreCmd" -ScriptName $MyInvocation.MyCommand.Name -LogFileName $LogFileName -LogType "ERROR"
    }
}


# Import Set-3CXServerTo function
. "$PSScriptRoot/Functions/Set-3CXServerTo.ps1"

# FTP settings (update password and server as needed)
$ftpUrl = "ftp://your-ftp-server/path/to/3CXScheduledBackup.zip"
$ftpUser = "srv010010037051"
$ftpPassword = "your-ftp-password"
$localBackup = Join-Path $PSScriptRoot 'Data/3CXScheduledBackup.zip'

# Function to update CNAME to a specified server
function Set-3CXCnameToServer {
    param(
        [Parameter(Mandatory)]
        [string]$TargetAlias
    )
    Set-3CXServerTo -NewAlias $TargetAlias -LogFileName $LogFileName -Verbose:$VerbosePreference
}

# Example usage:
# Set-3CXCnameToServer -TargetAlias "srv010010037051.generationsgaither.com"
# Set-3CXCnameToServer -TargetAlias "srv010010050051.generationsgaither.com"

if (Test-PrimaryServer) {
    if (Test-3CXServices) {
        if (Get-3CXBackupFromFTP -FtpUrl $ftpUrl -FtpUser $ftpUser -FtpPassword $ftpPassword -LocalPath $localBackup) {
            Set-PassiveMode
            # Example: Update CNAME to failover server after restore
            # Set-3CXCnameToServer -TargetAlias "srv010010050051.generationsgaither.com"
        } else {
            Write-AdvancedLog -Message "Failed to retrieve backup from FTP. Passive mode not triggered." -ScriptName $MyInvocation.MyCommand.Name -LogFileName $LogFileName -LogType "ERROR"
        }
    } else {
        Write-AdvancedLog -Message "Not all 3CX services running on $PrimaryServer" -ScriptName $MyInvocation.MyCommand.Name -LogFileName $LogFileName -LogType "WARNING"
    }
} else {
    Write-AdvancedLog -Message "$PrimaryServer not reachable" -ScriptName $MyInvocation.MyCommand.Name -LogFileName $LogFileName -LogType "WARNING"
}

<#
.EXAMPLE
PS> .\Monitor-3CXFailoverPassive.ps1 -Verbose
#>

# Example usage block
<#
# To run as a scheduled task or service, configure Windows Task Scheduler or NSSM to run this script at desired intervals.
#>
