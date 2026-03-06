<#
.SYNOPSIS
    Test utility script for updating Cisco template DST values.
.DESCRIPTION
    Defines Update-CiscoDSTForTimezone and runs a sample invocation against a Cisco
    template XML file. Intended for development/testing in the RestoreTemplates workflow.
.PARAMETER None
    This script does not accept script-level parameters.
.EXAMPLE
    PS> .\TestEditCisco.ps1
.INPUT
    None
.OUTPUT
    [pscustomobject] from Update-CiscoDSTForTimezone when execution succeeds.
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-03-04
    Time: 19:10:00
    Time Zone: Central Standard Time
    Function Or Application: Application
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

function Update-CiscoDSTForTimezone {
    <#
    .SYNOPSIS
        Updates DST values for a specific timezone in Cisco phone template XML.
    
    .DESCRIPTION
        Updates dststartmonth, dststartday, dstendmonth, and dstendday for a specified timezone option.
    
    .PARAMETER FilePath
        Path to the Cisco XML template file.
    
    .PARAMETER TimezoneId
        The timezone ID to update (e.g., "14" for US Central Time).
    
    .PARAMETER StartMonth
        The DST start month (1-12).
    
    .PARAMETER StartDay
        The DST start day (1-31).
    
    .PARAMETER EndMonth
        The DST end month (1-12).
    
    .PARAMETER EndDay
        The DST end day (1-31).
    
    .PARAMETER BackupOriginal
        Creates a backup of the original file before making changes.
    
    .EXAMPLE
        Update-CiscoDSTForTimezone -FilePath "cisco.xml" -TimezoneId "14" -StartMonth 3 -StartDay 9 -EndMonth 11 -EndDay 2 -BackupOriginal
    
    .EXAMPLE
        # Update using Get-DaylightSavingTime function
        $dst = Get-DaylightSavingTime
        Update-CiscoDSTForTimezone -FilePath "cisco.xml" -TimezoneId "14" -StartMonth $dst.StartMonth -StartDay $dst.StartDate -EndMonth $dst.EndMonth -EndDay $dst.EndDate
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath,
        
        [Parameter(Mandatory=$true)]
        [string]$TimezoneId,
        
        [Parameter(Mandatory=$true)]
        [ValidateRange(1,12)]
        [int]$StartMonth,
        
        [Parameter(Mandatory=$true)]
        [ValidateRange(1,31)]
        [int]$StartDay,
        
        [Parameter(Mandatory=$true)]
        [ValidateRange(1,12)]
        [int]$EndMonth,
        
        [Parameter(Mandatory=$true)]
        [ValidateRange(1,31)]
        [int]$EndDay,
        
        [Parameter(Mandatory=$false)]
        [switch]$BackupOriginal
    )
    
    # Check if file exists
    if (-not (Test-Path $FilePath)) {
        Write-Error "File not found: $FilePath"
        return
    }
    
    try {
        # Create backup if requested
        if ($BackupOriginal) {
            $backupPath = "$FilePath.bak"
            Copy-Item -Path $FilePath -Destination $backupPath -Force
            Write-Host "Backup created: $backupPath" -ForegroundColor Green
        }
        
        # Load the XML file
        [xml]$xmlDoc = Get-Content -Path $FilePath
        
        # Find the specific timezone option by id attribute
        $timezoneOption = $xmlDoc.SelectSingleNode("//option[@id='$TimezoneId']")
        
        if (-not $timezoneOption) {
            Write-Warning "Timezone with id='$TimezoneId' not found in the XML"
            return
        }
        
        # Get the displaytext for confirmation
        $displayText = $timezoneOption.GetAttribute("displaytext")
        Write-Host "`nUpdating timezone: $displayText (ID: $TimezoneId)" -ForegroundColor Yellow
        
        # Find and update each DST element within this timezone option
        $updateCount = 0
        
        # Update dststartmonth
        $startMonthNode = $timezoneOption.SelectSingleNode("item[@name='dststartmonth']")
        if ($startMonthNode) {
            $oldValue = $startMonthNode.InnerText
            $startMonthNode.InnerText = $StartMonth.ToString()
            Write-Host "  dststartmonth: '$oldValue' -> '$StartMonth'" -ForegroundColor Cyan
            $updateCount++
        }
        
        # Update dststartday
        $startDayNode = $timezoneOption.SelectSingleNode("item[@name='dststartday']")
        if ($startDayNode) {
            $oldValue = $startDayNode.InnerText
            $startDayNode.InnerText = $StartDay.ToString()
            Write-Host "  dststartday: '$oldValue' -> '$StartDay'" -ForegroundColor Cyan
            $updateCount++
        }
        
        # Update dstendmonth
        $endMonthNode = $timezoneOption.SelectSingleNode("item[@name='dstendmonth']")
        if ($endMonthNode) {
            $oldValue = $endMonthNode.InnerText
            $endMonthNode.InnerText = $EndMonth.ToString()
            Write-Host "  dstendmonth: '$oldValue' -> '$EndMonth'" -ForegroundColor Cyan
            $updateCount++
        }
        
        # Update dstendday
        $endDayNode = $timezoneOption.SelectSingleNode("item[@name='dstendday']")
        if ($endDayNode) {
            $oldValue = $endDayNode.InnerText
            $endDayNode.InnerText = $EndDay.ToString()
            Write-Host "  dstendday: '$oldValue' -> '$EndDay'" -ForegroundColor Cyan
            $updateCount++
        }
        
        # Save the changes
        $xmlDoc.Save($FilePath)
        Write-Host "`nSuccessfully updated $updateCount DST element(s) for timezone ID $TimezoneId" -ForegroundColor Green
        
        # Return summary
        [PSCustomObject]@{
            FilePath = $FilePath
            TimezoneId = $TimezoneId
            TimezoneDisplay = $displayText
            StartMonth = $StartMonth
            StartDay = $StartDay
            EndMonth = $EndMonth
            EndDay = $EndDay
            ElementsUpdated = $updateCount
        }
        
    } catch {
        Write-Error "Error updating XML: $_"
    }
}

# Example usage:
# Update US Central Time (ID 14) with specific dates
# Update-CiscoDSTForTimezone -FilePath "cisco-template.xml" -TimezoneId "14" -StartMonth 3 -StartDay 9 -EndMonth 11 -EndDay 2 -BackupOriginal

# Or combine with Get-DaylightSavingTime function:
# $dst = Get-DaylightSavingTime
# Update-CiscoDSTForTimezone -FilePath "cisco-template.xml" -TimezoneId "14" -StartMonth $dst.StartMonth -StartDay $dst.StartDate -EndMonth $dst.EndMonth -EndDay $dst.EndDate -BackupOriginal


Update-CiscoDSTForTimezone -FilePath "C:\Scripts\3CX\RESTORE_TEMPLATES\TEMPLATES\cisco.ph.xml" -TimezoneId "14" -StartMonth 3 -StartDay 9 -EndMonth 11 -EndDay 10 -BackupOriginal