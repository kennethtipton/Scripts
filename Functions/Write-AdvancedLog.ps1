<#
.SYNOPSIS
   Advanced logging function for PowerShell scripts.
.DESCRIPTION
   Writes log entries to a text log file (newest entry at the top) and/or to the Windows Event Log. If WriteEventLog is specified, both logs are written.
   Supports custom event log name/source, works with PowerShell 5 and 7+.
   Verbose output available via -Verbose switch.
.EXAMPLE
   Write-AdvancedLog -Message "Install completed" -ScriptName "MyApp.ps1" -LogType "INFO"
.EXAMPLE
   Write-AdvancedLog -Message "Critical error" -ScriptName "MyApp.ps1" -LogType "ERROR" -WriteEventLog -EventLogName "CustomLog" -EventSource "CustomSource"
.INPUTS
   [string] Message
.OUTPUTS
   None
.NOTES
   Author: Kenneth Tipton
   Company: TNC, Inc
   Date: 2026-01-15
   Time: 21:25:30 CST
   Time Zone: CST
   Function Or Application: Function
   Version: 1.0.0.0
   Website: (https://www.tnandc.com)
   Is AI Used: True
   AI Used: GitHub Copilot
   Copyright (c) 2026
   Licensed under the MIT License.
   Full text available at: https://opensource.org/licenses/MIT
#>

function Write-AdvancedLog {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [string]$ScriptName = $MyInvocation.MyCommand.Name,
        [ValidateSet('INFO', 'WARNING', 'ERROR')]
        [string]$LogType = 'INFO',
        [string]$LogFile,
        [switch]$WriteEventLog,
        [string]$EventLogName = 'Managed Powershell Scripts',
        [string]$EventSource = 'ManagedPSScripts'
    )


    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "$timestamp | Script: $ScriptName | ${LogType}: ${Message}"
    # Set log directory to 'Log' under parent Scripts folder
    if ($LogFile) {
        $logFile = $LogFile
    } else {
        $scriptsRoot = Split-Path -Parent $PSScriptRoot
        $logDir = Join-Path -Path $scriptsRoot -ChildPath 'Logs'
        $logFile = Join-Path -Path $logDir -ChildPath ("$($ScriptName -replace '\.ps1$','').log")
    }

    # Ensure log file and folder exist using Initialize-FileAndFolder
    $initFunc = Join-Path -Path $PSScriptRoot -ChildPath 'Initialize-FileAndFoldersExist.ps1'
    if (Test-Path $initFunc) {
        . $initFunc
        Initialize-FileAndFolder -FilePath $logFile
    }
    $PSCmdlet.WriteVerbose("ScriptName: $ScriptName")
    # Always write to text log
    $header = 'Timestamp | Script | Type | Message'
    $headerMarker = $header

    if (Test-Path $logFile) {
        $existing = Get-Content $logFile -Raw
        $lines = $existing -split "\r?\n"
        if ($lines[0] -eq $headerMarker) {
            # Header exists, insert entry after header
            $newContent = @()
            $newContent += $lines[0]
            $newContent += $entry
            if ($lines.Count -gt 1) {
                $newContent += $lines[1..($lines.Count-1)]
            }
            Set-Content -Path $logFile -Value $newContent
        } else {
            # Header missing, add header and entry at top
            $newContent = @()
            $newContent += $header
            $newContent += $entry
            if ($existing.Trim().Length -gt 0) {
                $newContent += $lines
            }
            Set-Content -Path $logFile -Value $newContent
        }
    } else {
        # New file, add header and entry
        $newContent = @()
        $newContent += $header
        $newContent += $entry
        Set-Content -Path $logFile -Value $newContent
    }

    # Optionally write to Windows Event Log
    if ($WriteEventLog) {
        $eventId = switch ($LogType) {
            'INFO' { 1 }
            'WARNING' { 2 }
            'ERROR' { 3 }
        }
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            # PowerShell 5: Use Write-EventLog
            if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
                try {
                    New-EventLog -LogName $EventLogName -Source $EventSource
                }
                catch {}
            }
            Write-EventLog -LogName $EventLogName -Source $EventSource -EntryType $LogType -EventId $eventId -Message $Message
        }
        else {
            # PowerShell 7+: Use .NET EventLog class
            try {
                $eventLog = [System.Diagnostics.EventLog]::new()
                $eventLog.Log = $EventLogName
                $eventLog.Source = $EventSource
                $eventLog.WriteEntry($Message, [System.Diagnostics.EventLogEntryType]::$LogType, $eventId)
                $eventLog.Dispose()
            }
            catch {
                # Try to create the log/source if missing
                if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
                    try {
                        [System.Diagnostics.EventLog]::CreateEventSource($EventSource, $EventLogName)
                        Start-Sleep -Seconds 1
                        $eventLog = [System.Diagnostics.EventLog]::new()
                        $eventLog.Log = $EventLogName
                        $eventLog.Source = $EventSource
                        $eventLog.WriteEntry($Message, [System.Diagnostics.EventLogEntryType]::$LogType, $eventId)
                        $eventLog.Dispose()
                    }
                    catch {}
                }
            }
        }
    }
    $PSCmdlet.WriteVerbose("Message: $Message")
    $PSCmdlet.WriteVerbose("ScriptName: $ScriptName")
    $PSCmdlet.WriteVerbose("LogType: $LogType")
    $PSCmdlet.WriteVerbose("Timestamp: $timestamp")
    $PSCmdlet.WriteVerbose("Entry: $entry")
    $PSCmdlet.WriteVerbose("LogDir: $logDir")
    $PSCmdlet.WriteVerbose("LogFile: $logFile")
    $PSCmdlet.WriteVerbose("WriteEventLog: $WriteEventLog")
    $PSCmdlet.WriteVerbose("EventLogName: $EventLogName")
    $PSCmdlet.WriteVerbose("EventSource: $EventSource")
}

# Example footer for function testing:
# Write-AdvancedLog -Message "This is a test INFO log entry (text only)." -ScriptName "Write-AdvancedLogTest.ps1" -LogType "INFO" -Verbose
Write-AdvancedLog -Message "This is a test INFO log entry (text only)." -LogType "INFO"
# Write-AdvancedLog -Message "This is a test ERROR log entry (event log)." -ScriptName "Write-AdvancedLogTest.ps1" -LogType "ERROR" -WriteEventLog -Verbose
# Write-AdvancedLog -Message "This is a test WARNING log entry (custom event log)." -ScriptName "Write-AdvancedLogTest.ps1" -LogType "WARNING" -WriteEventLog -EventLogName "CustomPSScriptLog" -EventSource "CustomPSSource" -Verbose
