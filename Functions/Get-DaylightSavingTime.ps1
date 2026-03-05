<#
.SYNOPSIS
    Retrieves daylight saving time start and end dates for a specified year.
.DESCRIPTION
    Reads transition rules from the local Windows time zone and returns the resolved
    daylight saving start and end dates for the requested year.
.PARAMETER Year
    The year to evaluate. Defaults to the current year.
.EXAMPLE
    PS> Get-DaylightSavingTime
.EXAMPLE
    PS> Get-DaylightSavingTime -Year 2026
.INPUTS
    [int] Year
.OUTPUTS
    [pscustomobject]
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

function Get-DaylightSavingTime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int]$Year = (Get-Date).Year
    )

    try {
        $timezone = [System.TimeZoneInfo]::Local
        if (-not $timezone.SupportsDaylightSavingTime) {
            Write-Verbose 'Local timezone does not observe Daylight Saving Time.'
            return $null
        }

        $adjustmentRules = $timezone.GetAdjustmentRules()
        $currentRule = $adjustmentRules | Where-Object {
            $_.DateStart.Year -le $Year -and $_.DateEnd.Year -ge $Year
        } | Select-Object -First 1

        if (-not $currentRule) {
            Write-Verbose "No daylight saving rule found for year $Year in timezone $($timezone.Id)."
            return $null
        }

        $transitionStart = $currentRule.DaylightTransitionStart
        $transitionEnd = $currentRule.DaylightTransitionEnd

        if ($transitionStart.IsFixedDateRule) {
            $startDate = Get-Date -Year $Year -Month $transitionStart.Month -Day $transitionStart.Day
        }
        else {
            $firstDay = Get-Date -Year $Year -Month $transitionStart.Month -Day 1
            $daysToAdd = (7 - $firstDay.DayOfWeek + $transitionStart.DayOfWeek) % 7
            $firstOccurrence = $firstDay.AddDays($daysToAdd)
            $startDate = $firstOccurrence.AddDays(7 * ($transitionStart.Week - 1))
        }

        if ($transitionEnd.IsFixedDateRule) {
            $endDate = Get-Date -Year $Year -Month $transitionEnd.Month -Day $transitionEnd.Day
        }
        else {
            $firstDay = Get-Date -Year $Year -Month $transitionEnd.Month -Day 1
            $daysToAdd = (7 - $firstDay.DayOfWeek + $transitionEnd.DayOfWeek) % 7
            $firstOccurrence = $firstDay.AddDays($daysToAdd)
            $endDate = $firstOccurrence.AddDays(7 * ($transitionEnd.Week - 1))
        }

        [pscustomobject]@{
            Year          = $Year
            StartMonth    = $startDate.Month
            StartDate     = $startDate.Day
            EndMonth      = $endDate.Month
            EndDate       = $endDate.Day
            StartFullDate = $startDate
            EndFullDate   = $endDate
        }
    }
    catch {
        Write-Error "Get-DaylightSavingTime failed: $($_.Exception.Message)"
        throw
    }
}

# Example usage:
# PS> Get-DaylightSavingTime
# PS> Get-DaylightSavingTime -Year 2026 -Verbose
