<#
.SYNOPSIS
    Initializes the MikroTik RouterOS Management LiteDB database from scratch.
.DESCRIPTION
    Rebuilds the database file and creates required collections/indexes for the
    Mikrotik RouterOS Management web application.

    This script can optionally back up an existing database file before it is
    removed and recreated.
.PARAMETER DatabasePath
    Full path to the LiteDB file. Defaults to Data\MikrotikDevices.db.
.PARAMETER Force
    Allows removing/recreating an existing database file.
.PARAMETER BackupExisting
    Backs up the existing database before recreation. Enabled by default.
.PARAMETER BackupDirectory
    Optional backup directory. Defaults to Data\Backups.
.EXAMPLE
    PS> .\InitializeMikrotikRouterOSManagementDatabase.ps1 -Force
.EXAMPLE
    PS> .\InitializeMikrotikRouterOSManagementDatabase.ps1 -Force -Verbose
.EXAMPLE
    PS> .\InitializeMikrotikRouterOSManagementDatabase.ps1 -DatabasePath 'C:\Scripts\Applications\Mikrrotik\MikrotikRouterOSManagement\Data\MikrotikDevices.db' -Force
.INPUTS
    None.
.OUTPUTS
    PSCustomObject.
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-03-07
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
.LINK
    https://www.tnandc.com
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)]
    [string]$DatabasePath = (Join-Path -Path $PSScriptRoot -ChildPath 'Data\MikrotikDevices.db'),

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [bool]$BackupExisting = $true,

    [Parameter(Mandatory = $false)]
    [string]$BackupDirectory = (Join-Path -Path $PSScriptRoot -ChildPath 'Data\Backups')
)

$script:CurrentScriptName = $MyInvocation.MyCommand.Name
$script:CanUseAdvancedLog = $false
$db = $null
$backupPath = ''
$recreatedFromScratch = $false

function Write-SafeAdvancedLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARNING', 'ERROR')]
        [string]$LogType = 'INFO'
    )

    if ($script:CanUseAdvancedLog) {
        try {
            Write-AdvancedLog -Message $Message -ScriptName $script:CurrentScriptName -LogType $LogType
            return
        }
        catch {
            Write-Verbose "Write-AdvancedLog failed: $_"
        }
    }

    Write-Verbose "[$LogType] $Message"
}

try {
    $writeLogFunc = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\Functions\Write-AdvancedLog.ps1'
    if (Test-Path -Path $writeLogFunc -PathType Leaf) {
        . $writeLogFunc
    }

    if (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue) {
        $script:CanUseAdvancedLog = $true
    }

    $dbDirectory = Split-Path -Parent $DatabasePath
    if (-not (Test-Path -Path $dbDirectory -PathType Container)) {
        New-Item -Path $dbDirectory -ItemType Directory -Force | Out-Null
    }

    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $liteDbDllPath = Join-Path -Path $repoRoot -ChildPath 'Libraries\LiteDB\LiteDB.dll'
    if (-not (Test-Path -Path $liteDbDllPath -PathType Leaf)) {
        throw "LiteDB.dll not found at '$liteDbDllPath'."
    }

    if (-not ('LiteDB.LiteDatabase' -as [type])) {
        Add-Type -Path $liteDbDllPath -ErrorAction Stop
    }

    $contactInitializerPath = Join-Path -Path $PSScriptRoot -ChildPath 'Functions\Initialize-MikrotikContactCollection.ps1'
    if (-not (Test-Path -Path $contactInitializerPath -PathType Leaf)) {
        throw "Contact initializer function file not found: '$contactInitializerPath'."
    }

    . $contactInitializerPath

    $dbExists = Test-Path -Path $DatabasePath -PathType Leaf
    if ($dbExists -and -not $Force.IsPresent) {
        Write-Warning "Database already exists at '$DatabasePath'. Continuing in initialize/repair mode. Use -Force to recreate from scratch."
        Write-SafeAdvancedLog -Message "Database exists at '$DatabasePath'. Running initialize/repair mode (no recreate)." -LogType 'WARNING'
    }

    if ($dbExists -and $Force.IsPresent -and $PSCmdlet.ShouldProcess($DatabasePath, 'Recreate database from scratch')) {
        if ($BackupExisting) {
            if (-not (Test-Path -Path $BackupDirectory -PathType Container)) {
                New-Item -Path $BackupDirectory -ItemType Directory -Force | Out-Null
            }

            $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupPath = Join-Path -Path $BackupDirectory -ChildPath ("MikrotikDevices-$timestamp.db")
            Copy-Item -Path $DatabasePath -Destination $backupPath -Force
            Write-SafeAdvancedLog -Message "Backed up existing database to '$backupPath'." -LogType 'INFO'
        }

        Remove-Item -Path $DatabasePath -Force
        Write-SafeAdvancedLog -Message "Removed existing database at '$DatabasePath'." -LogType 'INFO'
        $recreatedFromScratch = $true
    }

    $db = [LiteDB.LiteDatabase]::new($DatabasePath)
    $deviceCollection = $db.GetCollection('mikrotik_devices')

    [void]$deviceCollection.EnsureIndex('RouterIdentityHostname')
    [void]$deviceCollection.EnsureIndex('RouterModel')
    [void]$deviceCollection.EnsureIndex('RouterFirmware')
    [void]$deviceCollection.EnsureIndex('State')
    [void]$deviceCollection.EnsureIndex('City')
    [void]$deviceCollection.EnsureIndex('IsDeleted')

    Write-SafeAdvancedLog -Message 'Initialized mikrotik_devices collection and indexes.' -LogType 'INFO'
}
catch {
    Write-SafeAdvancedLog -Message "Database initialization failed: $_" -LogType 'ERROR'
    throw
}
finally {
    if ($null -ne $db) {
        $db.Dispose()
    }
}

$contactInitResult = Initialize-MikrotikContactCollection -DatabasePath $DatabasePath
Write-SafeAdvancedLog -Message 'Initialized contact collections and relationships.' -LogType 'INFO'

$result = [PSCustomObject]@{
    DatabasePath           = $DatabasePath
    RecreatedFromScratch   = $recreatedFromScratch
    BackupCreated          = -not [string]::IsNullOrWhiteSpace($backupPath)
    BackupPath             = $backupPath
    DeviceCollection       = 'mikrotik_devices'
    ContactCollections     = @('contacts', 'contact_locations', 'contact_location_index')
    ContactInitializerInfo = $contactInitResult
    Completed              = $true
}

Write-SafeAdvancedLog -Message "Database initialization complete for '$DatabasePath'." -LogType 'INFO'
$result

# Example usage:
# PS> .\InitializeMikrotikRouterOSManagementDatabase.ps1 -Force
# PS> .\InitializeMikrotikRouterOSManagementDatabase.ps1 -Force -Verbose
