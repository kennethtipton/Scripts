<#
.SYNOPSIS
    Copies a file to a destination with optional overwrite behavior.
.DESCRIPTION
    Copies SourceFilePath to DestinationFilePath. If the destination exists and Overwrite
    is not specified, the copy is skipped. Supports verbose output and optional logging
    through Write-AdvancedLog when available.
.PARAMETER SourceFilePath
    Source file path (including filename) to copy.
.PARAMETER DestinationFilePath
    Destination file path (including filename).
.PARAMETER Overwrite
    Overwrites the destination file if it already exists.
.PARAMETER LogIt
    Writes operational log messages through Write-AdvancedLog when available.
.PARAMETER CallingScript
    Optional script name to include in log entries. Defaults to this function file name.
.PARAMETER LogFileName
    Optional log file base name to pass through to Write-AdvancedLog.
.EXAMPLE
    PS> Copy-FileWithOverwrite -SourceFilePath 'C:\Temp\source.txt' -DestinationFilePath 'C:\Temp\destination.txt'
.EXAMPLE
    PS> Copy-FileWithOverwrite -SourceFilePath 'C:\Temp\source.txt' -DestinationFilePath 'C:\Temp\destination.txt' -Overwrite -LogIt
.INPUTS
    [string] SourceFilePath, [string] DestinationFilePath, [switch] Overwrite, [switch] LogIt, [string] CallingScript, [string] LogFileName
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

function Copy-FileWithOverwrite {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$SourceFilePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationFilePath,

        [switch]$Overwrite,

        [Parameter(Mandatory = $false)]
        [Alias('logit')]
        [switch]$LogIt,

        [Parameter(Mandatory = $false)]
        [string]$CallingScript = 'Copy-FileWithOverwrite.ps1',

        [Parameter(Mandatory = $false)]
        [string]$LogFileName
    )

    if (-not $PSBoundParameters.ContainsKey('CallingScript')) {
        $scriptPath = $MyInvocation.MyCommand.ScriptBlock.File
        if (-not [string]::IsNullOrWhiteSpace($scriptPath)) {
            $CallingScript = [System.IO.Path]::GetFileName($scriptPath)
        }
    }

    $writeAdvancedLogPath = Join-Path -Path $PSScriptRoot -ChildPath 'Write-AdvancedLog.ps1'
    if (Test-Path -Path $writeAdvancedLogPath) {
        . $writeAdvancedLogPath
    }

    function Write-CopyLog {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Message,
            [ValidateSet('INFO', 'WARNING', 'ERROR')]
            [string]$Type = 'INFO'
        )

        if ($LogIt -and (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue)) {
            $logArgs = @{
                Message    = $Message
                ScriptName = $CallingScript
                LogType    = $Type
            }

            if (-not [string]::IsNullOrWhiteSpace($LogFileName)) {
                $logArgs.LogFileName = $LogFileName
            }

            Write-AdvancedLog @logArgs
        }

        Write-Verbose -Message $Message
    }

    try {
        if (-not (Test-Path -Path $SourceFilePath -PathType Leaf)) {
            $message = "Source file not found: $SourceFilePath"
            Write-CopyLog -Message $message -Type 'ERROR'
            throw $message
        }

        $destinationParent = Split-Path -Path $DestinationFilePath -Parent
        if (-not [string]::IsNullOrWhiteSpace($destinationParent) -and -not (Test-Path -Path $destinationParent -PathType Container)) {
            New-Item -Path $destinationParent -ItemType Directory -Force | Out-Null
            Write-CopyLog -Message "Created destination directory: $destinationParent"
        }

        $destinationExists = Test-Path -Path $DestinationFilePath -PathType Leaf
        if ($destinationExists -and -not $Overwrite) {
            Write-CopyLog -Message "Destination exists and overwrite not requested: $DestinationFilePath" -Type 'WARNING'
            return $false
        }

        $actionText = if ($destinationExists) { 'Overwrite destination file' } else { 'Create destination file' }
        if ($PSCmdlet.ShouldProcess($DestinationFilePath, $actionText)) {
            Copy-Item -Path $SourceFilePath -Destination $DestinationFilePath -Force:$Overwrite -ErrorAction Stop
            Write-CopyLog -Message "Copied '$SourceFilePath' to '$DestinationFilePath'."
            return $true
        }

        return $false
    }
    catch {
        $message = "Copy-FileWithOverwrite failed: $($_.Exception.Message)"
        Write-CopyLog -Message $message -Type 'ERROR'
        throw
    }
}

# Example usage:
# PS> Copy-FileWithOverwrite -SourceFilePath 'C:\Temp\source.txt' -DestinationFilePath 'C:\Temp\destination.txt'
# PS> Copy-FileWithOverwrite -SourceFilePath 'C:\Temp\source.txt' -DestinationFilePath 'C:\Temp\destination.txt' -Overwrite -LogIt -Verbose
# PS> Copy-FileWithOverwrite -SourceFilePath 'C:\Temp\source.txt' -DestinationFilePath 'C:\Temp\destination.txt' -Overwrite -LogIt -LogFileName '3CX_Template_Restore'