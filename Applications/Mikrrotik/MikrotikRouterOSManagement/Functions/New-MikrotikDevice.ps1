function New-MikrotikDevice {
    <#
    .SYNOPSIS
        Creates a new MikroTik device record in LiteDB.
    .DESCRIPTION
        Inserts a new device inventory entry into the mikrotik_devices
        collection in the local LiteDB database.
    .PARAMETER RouterIdentityHostname
        Router identity/hostname.
    .PARAMETER RouterModel
        Router hardware model.
    .PARAMETER RouterFirmware
        Router firmware version.
    .PARAMETER State
        State or province.
    .PARAMETER City
        City name.
    .PARAMETER StreetAddress
        Street address.
    .PARAMETER LocationType
        Location type (for example, Office, DataCenter, Branch).
    .PARAMETER Building
        Building identifier.
    .PARAMETER Room
        Room identifier.
    .PARAMETER Rack
        Rack identifier.
    .PARAMETER Unit
        Unit/suite identifier.
    .PARAMETER DatabasePath
        Full path to the LiteDB file. Defaults to Data\MikrotikDevices.db.
    .EXAMPLE
        PS> New-MikrotikDevice -RouterIdentityHostname 'R1' -RouterModel 'RB5009' -RouterFirmware '7.19.1' -State 'TN' -City 'Nashville'
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
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RouterIdentityHostname,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RouterModel,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RouterFirmware,

        [Parameter(Mandatory = $false)]
        [string]$State,

        [Parameter(Mandatory = $false)]
        [string]$City,

        [Parameter(Mandatory = $false)]
        [string]$StreetAddress,

        [Parameter(Mandatory = $false)]
        [string]$LocationType,

        [Parameter(Mandatory = $false)]
        [string]$Building,

        [Parameter(Mandatory = $false)]
        [string]$Room,

        [Parameter(Mandatory = $false)]
        [string]$Rack,

        [Parameter(Mandatory = $false)]
        [string]$Unit,

        [Parameter(Mandatory = $false)]
        [string]$DatabasePath = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Data\MikrotikDevices.db')
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

        $existing = @($collection.FindAll()) | Where-Object {
            (Convert-BsonValueToString -Value $_['RouterIdentityHostname']) -eq $RouterIdentityHostname -and
            -not (Convert-BsonValueToBoolean -Value $_['IsDeleted'])
        } | Select-Object -First 1
        if ($null -ne $existing) {
            throw "A record already exists with RouterIdentityHostname '$RouterIdentityHostname'."
        }

        $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $id = [Guid]::NewGuid().ToString()

        $document = [LiteDB.BsonDocument]::new()
        $document['_id'] = [LiteDB.BsonValue]::new($id)
        $document['RouterIdentityHostname'] = [LiteDB.BsonValue]::new($RouterIdentityHostname)
        $document['RouterModel'] = [LiteDB.BsonValue]::new($RouterModel)
        $document['RouterFirmware'] = [LiteDB.BsonValue]::new($RouterFirmware)
        $document['State'] = [LiteDB.BsonValue]::new($State)
        $document['City'] = [LiteDB.BsonValue]::new($City)
        $document['StreetAddress'] = [LiteDB.BsonValue]::new($StreetAddress)
        $document['LocationType'] = [LiteDB.BsonValue]::new($LocationType)
        $document['Building'] = [LiteDB.BsonValue]::new($Building)
        $document['Room'] = [LiteDB.BsonValue]::new($Room)
        $document['Rack'] = [LiteDB.BsonValue]::new($Rack)
        $document['Unit'] = [LiteDB.BsonValue]::new($Unit)
        $document['CreatedDate'] = [LiteDB.BsonValue]::new($timestamp)
        $document['ModifiedDate'] = [LiteDB.BsonValue]::new($timestamp)
        $document['IsDeleted'] = [LiteDB.BsonValue]::new($false)
        $document['DeletedDate'] = [LiteDB.BsonValue]::new('')

        [void]$collection.Insert($document)

        return [PSCustomObject]@{
            RouterIdentityHostname = $RouterIdentityHostname
            RouterModel            = $RouterModel
            RouterFirmware         = $RouterFirmware
            State                  = $State
            City                   = $City
            StreetAddress          = $StreetAddress
            LocationType           = $LocationType
            Building               = $Building
            Room                   = $Room
            Rack                   = $Rack
            Unit                   = $Unit
            CreatedDate            = $timestamp
            ModifiedDate           = $timestamp
            IsDeleted              = $false
            DeletedDate            = ''
        }
    }
    catch {
        throw "Failed to create MikroTik device record: $_"
    }
    finally {
        if ($null -ne $db) {
            $db.Dispose()
        }
    }
}

# Example usage:
# PS> New-MikrotikDevice -RouterIdentityHostname 'R1' -RouterModel 'RB5009' -RouterFirmware '7.19.1' -State 'TN' -City 'Nashville'
