function Get-MikrotikDevice {
    <#
    .SYNOPSIS
        Gets MikroTik device records from the local LiteDB database.
    .DESCRIPTION
        Reads device inventory records from the mikrotik_devices collection
        in the LiteDB database under this application Data folder.
    .PARAMETER DatabasePath
        Full path to the LiteDB file. Defaults to Data\MikrotikDevices.db.
    .PARAMETER RouterIdentityHostname
        Optional router identity/hostname filter.
    .PARAMETER IncludeDeleted
        Includes soft-deleted records when specified.
    .EXAMPLE
        PS> Get-MikrotikDevice
    .EXAMPLE
        PS> Get-MikrotikDevice -RouterIdentityHostname 'Mikrotik-Core-01'
    .INPUTS
        None.
    .OUTPUTS
        PSCustomObject.
    .NOTES
        Author: Kenneth Tipton
        Company: TNC
        Date: 2026-03-06
        Version: 1.0.0
        Function Or Application: Function
    .LINK
        https://www.tnandc.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$DatabasePath = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Data\MikrotikDevices.db'),

        [Parameter(Mandatory = $false)]
        [string]$RouterIdentityHostname,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeDeleted
    )

    $db = $null

    function Convert-BsonValueToString {
        param([LiteDB.BsonValue]$Value)

        if ($null -eq $Value -or $Value.IsNull) {
            return ''
        }

        if ($Value.IsString) {
            return $Value.AsString
        }

        return $Value.ToString()
    }

    function Convert-BsonValueToBoolean {
        param([LiteDB.BsonValue]$Value)

        if ($null -eq $Value -or $Value.IsNull) {
            return $false
        }

        if ($Value.IsBoolean) {
            return $Value.AsBoolean
        }

        $parsed = $false
        if ([bool]::TryParse($Value.ToString(), [ref]$parsed)) {
            return $parsed
        }

        return $false
    }

    try {
        $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
        $liteDbDllPath = Join-Path -Path $repoRoot -ChildPath 'Libraries\LiteDB\LiteDB.dll'

        if (-not (Test-Path -Path $liteDbDllPath -PathType Leaf)) {
            throw "LiteDB.dll not found at '$liteDbDllPath'."
        }

        if (-not ('LiteDB.LiteDatabase' -as [type])) {
            Add-Type -Path $liteDbDllPath -ErrorAction Stop
        }

        $dbDirectory = Split-Path -Parent $DatabasePath
        if (-not (Test-Path -Path $dbDirectory -PathType Container)) {
            New-Item -Path $dbDirectory -ItemType Directory -Force | Out-Null
        }

        $db = [LiteDB.LiteDatabase]::new($DatabasePath)
        $collection = $db.GetCollection('mikrotik_devices')

        $records = @()

        $allRecords = @($collection.FindAll())

        if (-not [string]::IsNullOrWhiteSpace($RouterIdentityHostname)) {
            $records = @(
                $allRecords | Where-Object {
                    (Convert-BsonValueToString -Value $_['RouterIdentityHostname']) -eq $RouterIdentityHostname
                }
            )
        }
        else {
            $records = $allRecords
        }

        if (-not $IncludeDeleted.IsPresent) {
            $records = @(
                $records | Where-Object {
                    -not (Convert-BsonValueToBoolean -Value $_['IsDeleted'])
                }
            )
        }

        foreach ($record in $records) {
            [PSCustomObject]@{
                RouterIdentityHostname = Convert-BsonValueToString -Value $record['RouterIdentityHostname']
                RouterModel            = Convert-BsonValueToString -Value $record['RouterModel']
                RouterFirmware         = Convert-BsonValueToString -Value $record['RouterFirmware']
                State                  = Convert-BsonValueToString -Value $record['State']
                City                   = Convert-BsonValueToString -Value $record['City']
                StreetAddress          = Convert-BsonValueToString -Value $record['StreetAddress']
                LocationType           = Convert-BsonValueToString -Value $record['LocationType']
                Building               = Convert-BsonValueToString -Value $record['Building']
                Room                   = Convert-BsonValueToString -Value $record['Room']
                Rack                   = Convert-BsonValueToString -Value $record['Rack']
                Unit                   = Convert-BsonValueToString -Value $record['Unit']
                CreatedDate            = Convert-BsonValueToString -Value $record['CreatedDate']
                ModifiedDate           = Convert-BsonValueToString -Value $record['ModifiedDate']
                IsDeleted              = Convert-BsonValueToBoolean -Value $record['IsDeleted']
                DeletedDate            = Convert-BsonValueToString -Value $record['DeletedDate']
            }
        }
    }
    catch {
        throw "Failed to get MikroTik device data: $_"
    }
    finally {
        if ($null -ne $db) {
            $db.Dispose()
        }
    }
}

# Example usage:
# PS> Get-MikrotikDevice
# PS> Get-MikrotikDevice -RouterIdentityHostname 'Mikrotik-Core-01'
# PS> Get-MikrotikDevice -IncludeDeleted
