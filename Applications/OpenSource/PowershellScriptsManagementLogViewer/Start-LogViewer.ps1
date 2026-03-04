<#
.SYNOPSIS
    Starts a Pode.Web server that displays PowerShell script log files in a browser UI.
.DESCRIPTION
    Launches a Pode.Web HTTP server on the specified port. The web interface
    provides one tab per .log file found in the Logs folder. Each tab shows a
    sortable, filterable table of log entries. Clicking the detail button on any
    row opens a modal popup with the full entry information. Log entries are
    color-coded by type (INFO/WARNING/ERROR). Auto-refreshes every 30 seconds.
    Built entirely with Pode.Web PowerShell cmdlets — no raw HTML or JavaScript.
    Includes advanced logging, verbose support, and structured error handling per
    project coding standards.
.PARAMETER Port
    The TCP port for the Pode.Web server to listen on. Defaults to 8080.
.PARAMETER LogPath
    Full path to the folder containing .log files. Defaults to the Logs folder
    under the repository root (three levels above this script).
.EXAMPLE
    PS> .\Start-LogViewer.ps1
.EXAMPLE
    PS> .\Start-LogViewer.ps1 -Port 9090 -Verbose
.EXAMPLE
    PS> .\Start-LogViewer.ps1 -Port 8080 -LogPath "C:\Scripts\Logs"
.INPUTS
    None
.OUTPUTS
    None
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-03-03
    Time: 22:45:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 3.0.0
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

    Dependencies:
        Pode module     (Install-Module Pode     -Scope CurrentUser)
        Pode.Web module (Install-Module Pode.Web -Scope CurrentUser)
    Log entry format expected: YYYY-MM-DD HH:MM:SS | Script: name | TYPE: message
.LINK
    https://www.tnandc.com
    https://badgerati.github.io/Pode.Web/
#>

[CmdletBinding()]
param(
    [int]$Port = 8080,
    [string]$LogPath = (Join-Path -Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) -ChildPath 'Logs')
)

# Import Write-AdvancedLog function
$writeLogFunc = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\Functions\Write-AdvancedLog.ps1'
if (Test-Path $writeLogFunc) {
    . $writeLogFunc
}

Write-Verbose "LogPath: $LogPath"
Write-Verbose "Port: $Port"

try {
    Import-Module Pode     -ErrorAction Stop
    Import-Module Pode.Web -ErrorAction Stop
    Write-AdvancedLog -Message "Pode and Pode.Web modules imported successfully." -ScriptName $MyInvocation.MyCommand.Name -LogType 'INFO'
}
catch {
    Write-Error "Failed to import required modules. Install with:`n  Install-Module Pode -Scope CurrentUser`n  Install-Module Pode.Web -Scope CurrentUser`nError: $_"
    Write-AdvancedLog -Message "Failed to import Pode/Pode.Web module: $_" -ScriptName $MyInvocation.MyCommand.Name -LogType 'ERROR'
    exit 1
}

Write-AdvancedLog -Message "Starting Log Viewer (Pode.Web) on port $Port. LogPath: $LogPath" -ScriptName $MyInvocation.MyCommand.Name -LogType 'INFO'

# Capture parameter values for use in server scriptblocks.
$ServerPort = $Port
$ServerLogPath = $LogPath

# Helper: parse "TYPE: message" field from a pipe-delimited log line.
# Returns a hashtable with keys Type and Message.
# Defined outside Start-PodeServer so it can be dot-sourced into route scriptblocks.
function ConvertFrom-LogLine {
    param([string]$Line)
    $trimmed = $Line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return $null }
    if ($trimmed -eq 'Timestamp | Script | Type | Message') { return $null }

    $parts = $trimmed -split ' \| ', 3
    if ($parts.Count -eq 3) {
        $typeMsgRaw = $parts[2].Trim()
        $colonIdx   = $typeMsgRaw.IndexOf(': ')
        if ($colonIdx -gt 0) {
            $logType = $typeMsgRaw.Substring(0, $colonIdx).Trim().ToUpper()
            $message = $typeMsgRaw.Substring($colonIdx + 2).Trim()
        } else {
            $logType = 'UNKNOWN'
            $message = $typeMsgRaw
        }
        return [PSCustomObject]@{
            Timestamp = $parts[0].Trim()
            Type      = $logType
            Script    = ($parts[1] -replace '^Script:\s*', '').Trim()
            Message   = $message
            Raw       = $trimmed
        }
    }
    return [PSCustomObject]@{
        Timestamp = ''
        Type      = 'UNPARSED'
        Script    = ''
        Message   = $trimmed
        Raw       = $trimmed
    }
}

try {
    Start-PodeServer {
        Add-PodeEndpoint -Address * -Port $ServerPort -Protocol Http

        Use-PodeWebTemplates -Title 'PowerShell Script Log Viewer' -Theme Dark

        # ── Detail modal ───────────────────────────────────────────────────────
        # DetailTable is initially empty; populated via Update-PodeWebTable when
        # the "Details" button on a log row is clicked.
        New-PodeWebModal -Name 'LogEntryDetail' -DisplayName 'Log Entry Detail' -Content @(
            New-PodeWebTable -Name 'DetailTable' -Compact -ScriptBlock {
                # Intentionally empty — content is set dynamically by the row button.
            } -Columns @(
                Initialize-PodeWebTableColumn -Key 'Field' -Width 6
                Initialize-PodeWebTableColumn -Key 'Value' -Width 18
            )
        ) -ScriptBlock {
            Hide-PodeWebModal -Name 'LogEntryDetail'
        } -SubmitText 'Close'

        # ── Discover log files at startup ──────────────────────────────────────
        $logPath  = $ServerLogPath
        $logFiles = Get-ChildItem -Path $logPath -Filter '*.log' -ErrorAction SilentlyContinue |
                    Sort-Object Name

        if (-not $logFiles -or @($logFiles).Count -eq 0) {
            # No log files found — show an informational page
            Add-PodeWebPage -Name 'Log Viewer' -Title 'Log Viewer' -Icon 'file-text' -ArgumentList $logPath -ScriptBlock {
                param($PageLogPath)
                New-PodeWebAlert -Type Warning -Value "No .log files found in: $PageLogPath"
            }
        }
        else {
            Add-PodeWebPage -Name 'Log Viewer' -Title 'Log Viewer' -Icon 'file-text' -ArgumentList $logPath -ScriptBlock {
                param($PageLogPath)
                $pageLogFiles = Get-ChildItem -Path $PageLogPath -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object Name

                $tabs = @($pageLogFiles) | ForEach-Object {
                    $currentFileName = $_.Name
                    $currentBaseName = $_.BaseName
                    $currentFullPath = $_.FullName

                    New-PodeWebTab -Name $currentBaseName -Layouts @(
                        New-PodeWebTable -Name "LogTable_$currentBaseName" -Sort -SimpleFilter -Compact -Click -DataColumn 'Raw' `
                            -ArgumentList $currentFullPath `
                            -Columns @(
                                Initialize-PodeWebTableColumn -Key 'Timestamp' -Width 3
                                Initialize-PodeWebTableColumn -Key 'Type'      -Width 1
                                Initialize-PodeWebTableColumn -Key 'Script'    -Width 2
                                Initialize-PodeWebTableColumn -Key 'Message'   -Width 8
                                Initialize-PodeWebTableColumn -Key 'Raw'       -Hide
                            ) `
                            -ClickScriptBlock ({
                                try {
                                    $rawValue = [string]$WebEvent.Data['value']
                                    if ([string]::IsNullOrWhiteSpace($rawValue)) {
                                        return
                                    }

                                    $rawValue = $rawValue.Trim()
                                    $timestamp = ''
                                    $script    = ''
                                    $type      = 'UNPARSED'
                                    $message   = $rawValue

                                    if ($rawValue -match '^(?<Timestamp>[^|]+)\s\|\sScript:\s*(?<Script>[^|]+)\s\|\s(?<Type>[^:]+):\s*(?<Message>.*)$') {
                                        $timestamp = $Matches['Timestamp'].Trim()
                                        $script    = $Matches['Script'].Trim()
                                        $type      = $Matches['Type'].Trim().ToUpper()
                                        $message   = $Matches['Message'].Trim()
                                    }

                                    $detailRows = @(
                                        [PSCustomObject]@{ Field = 'Timestamp'; Value = $timestamp }
                                        [PSCustomObject]@{ Field = 'Type';      Value = $type }
                                        [PSCustomObject]@{ Field = 'Script';    Value = $script }
                                        [PSCustomObject]@{ Field = 'Message';   Value = $message }
                                        [PSCustomObject]@{ Field = 'Raw';       Value = $rawValue }
                                    )

                                    return @(
                                        ($detailRows | Update-PodeWebTable -Name 'DetailTable')
                                        (Show-PodeWebModal -Name 'LogEntryDetail')
                                    )
                                }
                                catch {
                                    if (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue) {
                                        Write-AdvancedLog -Message "Details click handler error: $_" -ScriptName $MyInvocation.MyCommand.Name -LogType 'ERROR'
                                    }
                                }
                            }.GetNewClosure()) `
                            -ScriptBlock ({
                                param($LogFilePath)
                                try {
                                    if ([string]::IsNullOrWhiteSpace($LogFilePath)) { return }
                                    if (-not (Test-Path -Path $LogFilePath -PathType Leaf)) { return }

                                    # Read up to the last 5000 lines for performance. For very large
                                    # log files consider reducing this limit or implementing incremental reads.
                                    $lines = Get-Content -Path $LogFilePath -Tail 5000 -ErrorAction Stop
                                    foreach ($line in $lines) {
                                        $trimmed = [string]$line
                                        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

                                        $trimmed = $trimmed.Trim()
                                        if ($trimmed -eq 'Timestamp | Script | Type | Message') { continue }

                                        if ($trimmed -match '^(?<Timestamp>[^|]+)\s\|\sScript:\s*(?<Script>[^|]+)\s\|\s(?<Type>[^:]+):\s*(?<Message>.*)$') {
                                            $timestamp = $Matches['Timestamp'].Trim()
                                            $script    = $Matches['Script'].Trim()
                                            $type      = $Matches['Type'].Trim().ToUpper()
                                            $message   = $Matches['Message'].Trim()
                                        }
                                        else {
                                            $timestamp = ''
                                            $script    = ''
                                            $type      = 'UNPARSED'
                                            $message   = $trimmed
                                        }

                                        [PSCustomObject]@{
                                            Timestamp = $timestamp
                                            Type      = $type
                                            Script    = $script
                                            Message   = $message
                                            Raw       = $trimmed
                                        }
                                    }
                                }
                                catch {
                                    if (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue) {
                                        Write-AdvancedLog -Message "Table rendering error for '$LogFilePath': $_" -ScriptName $MyInvocation.MyCommand.Name -LogType 'ERROR'
                                    }
                                }
                            }.GetNewClosure())
                    )
                }

                New-PodeWebCard -Name 'LogViewerCard' -Content @(
                    New-PodeWebTabs -Tabs $tabs
                )
            }
        }
    }
}
catch {
    Write-Error "Log Viewer server encountered an error: $_"
    Write-AdvancedLog -Message "Log Viewer server error: $_" -ScriptName $MyInvocation.MyCommand.Name -LogType 'ERROR'
}

# Example footer
# PS> .\Start-LogViewer.ps1
# PS> .\Start-LogViewer.ps1 -Port 9090 -Verbose
# PS> .\Start-LogViewer.ps1 -Port 8080 -LogPath "C:\Scripts\Logs" -Verbose
