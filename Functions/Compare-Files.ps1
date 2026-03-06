<#
.SYNOPSIS
    Compares two files by SHA256 hash and optionally replaces the destination.
.DESCRIPTION
    Computes hashes for two files and indicates whether they match. If files differ and
    ReplaceWhenDifferent is specified, File2 is copied over File1.
.PARAMETER File1Path
    Path to the primary file.
.PARAMETER File2Path
    Path to the comparison file.
.PARAMETER ReplaceWhenDifferent
    Replaces File1 with File2 when hashes are different.
.EXAMPLE
    PS> Compare-Files -File1Path 'C:\Temp\a.txt' -File2Path 'C:\Temp\b.txt'
.EXAMPLE
    PS> Compare-Files -File1Path 'C:\Temp\a.txt' -File2Path 'C:\Temp\b.txt' -ReplaceWhenDifferent
.INPUTS
    [string] File1Path, [string] File2Path, [switch] ReplaceWhenDifferent
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

function Compare-Files {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$File1Path,

        [Parameter(Mandatory = $true)]
        [string]$File2Path,

        [Parameter(Mandatory = $false)]
        [switch]$ReplaceWhenDifferent
    )

    try {
        if (-not (Test-Path -Path $File1Path -PathType Leaf)) {
            throw "File not found: $File1Path"
        }

        if (-not (Test-Path -Path $File2Path -PathType Leaf)) {
            throw "File not found: $File2Path"
        }

        $hash1 = (Get-FileHash -Path $File1Path -Algorithm SHA256 -ErrorAction Stop).Hash
        $hash2 = (Get-FileHash -Path $File2Path -Algorithm SHA256 -ErrorAction Stop).Hash
        $areEqual = ($hash1 -eq $hash2)

        if (-not $areEqual -and $ReplaceWhenDifferent) {
            if ($PSCmdlet.ShouldProcess($File1Path, "Replace with '$File2Path'")) {
                Copy-Item -Path $File2Path -Destination $File1Path -Force -ErrorAction Stop
            }
        }

        [pscustomobject]@{
            File1Path           = $File1Path
            File2Path           = $File2Path
            AreEqual            = $areEqual
            ReplacedDestination = (-not $areEqual -and $ReplaceWhenDifferent)
        }
    }
    catch {
        Write-Error "Compare-Files failed: $($_.Exception.Message)"
        throw
    }
}

# Example usage:
# PS> Compare-Files -File1Path 'C:\Temp\a.txt' -File2Path 'C:\Temp\b.txt'
# PS> Compare-Files -File1Path 'C:\Temp\a.txt' -File2Path 'C:\Temp\b.txt' -ReplaceWhenDifferent -Verbose
