<#
.SYNOPSIS
    Updates DST values for a timezone entry in Cisco SPA5XX XML templates.
.DESCRIPTION
    Updates `dststartmonth`, `dststartday`, `dstendmonth`, and `dstendday` for the
    selected timezone option in a Cisco template XML file.
.PARAMETER FilePath
    Path to the Cisco XML template file.
.PARAMETER TimezoneId
    Timezone option ID to update, for example `14` for Central Time in many templates.
.PARAMETER StartMonth
    DST start month (1-12). Defaults to local DST month from Get-DaylightSavingTime.
.PARAMETER StartDay
    DST start day (1-31). Defaults to local DST day from Get-DaylightSavingTime.
.PARAMETER EndMonth
    DST end month (1-12). Defaults to local DST month from Get-DaylightSavingTime.
.PARAMETER EndDay
    DST end day (1-31). Defaults to local DST day from Get-DaylightSavingTime.
.PARAMETER BackupOriginal
    Creates a `.bak` backup before writing changes.
.EXAMPLE
    PS> Update-CiscoDSTForTimezone -FilePath '.\Templates\cisco.ph.xml' -TimezoneId '14' -BackupOriginal
.INPUTS
    [string] FilePath, [string] TimezoneId, [int] StartMonth, [int] StartDay, [int] EndMonth, [int] EndDay, [switch] BackupOriginal
.OUTPUTS
    [pscustomobject]
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-03-04
    Time: 18:25:00
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

function Update-CiscoDSTForTimezone {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        [string]$TimezoneId = '14',

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 12)]
        [int]$StartMonth = (Get-DaylightSavingTime).StartMonth,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 31)]
        [int]$StartDay = (Get-DaylightSavingTime).StartDate,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 12)]
        [int]$EndMonth = (Get-DaylightSavingTime).EndMonth,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 31)]
        [int]$EndDay = (Get-DaylightSavingTime).EndDate,

        [Parameter(Mandatory = $false)]
        [switch]$BackupOriginal
    )

    try {
        if (-not (Test-Path -Path $FilePath -PathType Leaf)) {
            throw "File not found: $FilePath"
        }

        if ($BackupOriginal) {
            Copy-Item -Path $FilePath -Destination "$FilePath.bak" -Force -ErrorAction Stop
            Write-Verbose "Backup created: $FilePath.bak"
        }

        [xml]$xmlDoc = Get-Content -Path $FilePath -ErrorAction Stop
        $timezoneOption = $xmlDoc.SelectSingleNode("//option[@id='$TimezoneId']")
        if (-not $timezoneOption) {
            throw "Timezone option id '$TimezoneId' was not found in file '$FilePath'."
        }

        $displayText = $timezoneOption.GetAttribute('displaytext')
        $updateCount = 0

        $startMonthNode = $timezoneOption.SelectSingleNode("item[@name='dststartmonth']")
        if ($startMonthNode) {
            $startMonthNode.InnerText = $StartMonth.ToString()
            $updateCount++
        }

        $startDayNode = $timezoneOption.SelectSingleNode("item[@name='dststartday']")
        if ($startDayNode) {
            $startDayNode.InnerText = $StartDay.ToString()
            $updateCount++
        }

        $endMonthNode = $timezoneOption.SelectSingleNode("item[@name='dstendmonth']")
        if ($endMonthNode) {
            $endMonthNode.InnerText = $EndMonth.ToString()
            $updateCount++
        }

        $endDayNode = $timezoneOption.SelectSingleNode("item[@name='dstendday']")
        if ($endDayNode) {
            $endDayNode.InnerText = $EndDay.ToString()
            $updateCount++
        }

        $xmlDoc.Save($FilePath)
        Write-Verbose "Updated $updateCount DST element(s) for timezone '$TimezoneId' in '$FilePath'."

        [pscustomobject]@{
            FilePath        = $FilePath
            TimezoneId      = $TimezoneId
            TimezoneDisplay = $displayText
            StartMonth      = $StartMonth
            StartDay        = $StartDay
            EndMonth        = $EndMonth
            EndDay          = $EndDay
            ElementsUpdated = $updateCount
        }
    }
    catch {
        Write-Error "Update-CiscoDSTForTimezone failed: $($_.Exception.Message)"
        throw
    }
}

# Example usage:
# PS> Update-CiscoDSTForTimezone -FilePath '.\Templates\cisco.ph.xml' -TimezoneId '14' -BackupOriginal -Verbose
