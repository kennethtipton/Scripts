function Set-MikrotikDevice {
    <#
    .SYNOPSIS
        Updates an existing MikroTik device record in LiteDB.
    .DESCRIPTION
        Updates one or more fields for an existing device entry identified by RouterIdentityHostname.
    .PARAMETER CurrentRouterIdentityHostname
        Existing router identity/hostname used to locate the record.
    .PARAMETER RouterIdentityHostname
        Updated router identity/hostname.
    .PARAMETER RouterModel
        Updated router model.
    .PARAMETER RouterFirmware
        Updated router firmware version.
    .PARAMETER State
        Updated state or province.
    .PARAMETER City
        Updated city.
    .PARAMETER StreetAddress
        Updated street address.
    .PARAMETER LocationType
        Updated location type.
    .PARAMETER Building
        Updated building.
    .PARAMETER Room
        Updated room.
    .PARAMETER Rack
        Updated rack.
    .PARAMETER Unit
        Updated unit/suite.
    .PARAMETER DatabasePath
        Full path to the LiteDB file. Defaults to Data\MikrotikDevices.db.
    .EXAMPLE
        PS> Set-MikrotikDevice -CurrentRouterIdentityHostname 'R1' -RouterFirmware '7.20.0' -City 'Nashville'
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
        [string]$CurrentRouterIdentityHostname,

        [Parameter(Mandatory = $false)]
        [string]$RouterIdentityHostname,

        [Parameter(Mandatory = $false)]
        [string]$RouterModel,

        [Parameter(Mandatory = $false)]
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
        if (-not $PSBoundParameters.ContainsKey('RouterIdentityHostname') -and
            -not $PSBoundParameters.ContainsKey('RouterModel') -and
            -not $PSBoundParameters.ContainsKey('RouterFirmware') -and
            -not $PSBoundParameters.ContainsKey('State') -and
            -not $PSBoundParameters.ContainsKey('City') -and
            -not $PSBoundParameters.ContainsKey('StreetAddress') -and
            -not $PSBoundParameters.ContainsKey('LocationType') -and
            -not $PSBoundParameters.ContainsKey('Building') -and
            -not $PSBoundParameters.ContainsKey('Room') -and
            -not $PSBoundParameters.ContainsKey('Rack') -and
            -not $PSBoundParameters.ContainsKey('Unit')) {
            throw 'At least one update field must be provided.'
        }

        $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
        $liteDbDllPath = Join-Path -Path $repoRoot -ChildPath 'Libraries\LiteDB\LiteDB.dll'

        if (-not (Test-Path -Path $liteDbDllPath -PathType Leaf)) {
            throw "LiteDB.dll not found at '$liteDbDllPath'."
        }

        if (-not ('LiteDB.LiteDatabase' -as [type])) {
            Add-Type -Path $liteDbDllPath -ErrorAction Stop
        }

        $db = [LiteDB.LiteDatabase]::new($DatabasePath)
        $collection = $db.GetCollection('mikrotik_devices')

        $document = @($collection.FindAll()) | Where-Object {
            (Convert-BsonValueToString -Value $_['RouterIdentityHostname']) -eq $CurrentRouterIdentityHostname -and
            -not (Convert-BsonValueToBoolean -Value $_['IsDeleted'])
        } | Select-Object -First 1
        if ($null -eq $document) {
            throw "No active record found for RouterIdentityHostname '$CurrentRouterIdentityHostname'."
        }

        if ($PSBoundParameters.ContainsKey('RouterIdentityHostname')) {
            $existingWithNewHostname = @($collection.FindAll()) | Where-Object {
                (Convert-BsonValueToString -Value $_['RouterIdentityHostname']) -eq $RouterIdentityHostname -and
                -not (Convert-BsonValueToBoolean -Value $_['IsDeleted']) -and
                (Convert-BsonValueToString -Value $_['_id']) -ne (Convert-BsonValueToString -Value $document['_id'])
            } | Select-Object -First 1

            if ($null -ne $existingWithNewHostname) {
                throw "A record already exists with RouterIdentityHostname '$RouterIdentityHostname'."
            }
        }

        if ($PSBoundParameters.ContainsKey('RouterIdentityHostname')) {
            $document['RouterIdentityHostname'] = [LiteDB.BsonValue]::new($RouterIdentityHostname)
        }
        if ($PSBoundParameters.ContainsKey('RouterModel')) {
            $document['RouterModel'] = [LiteDB.BsonValue]::new($RouterModel)
        }
        if ($PSBoundParameters.ContainsKey('RouterFirmware')) {
            $document['RouterFirmware'] = [LiteDB.BsonValue]::new($RouterFirmware)
        }
        if ($PSBoundParameters.ContainsKey('State')) {
            $document['State'] = [LiteDB.BsonValue]::new($State)
        }
        if ($PSBoundParameters.ContainsKey('City')) {
            $document['City'] = [LiteDB.BsonValue]::new($City)
        }
        if ($PSBoundParameters.ContainsKey('StreetAddress')) {
            $document['StreetAddress'] = [LiteDB.BsonValue]::new($StreetAddress)
        }
        if ($PSBoundParameters.ContainsKey('LocationType')) {
            $document['LocationType'] = [LiteDB.BsonValue]::new($LocationType)
        }
        if ($PSBoundParameters.ContainsKey('Building')) {
            $document['Building'] = [LiteDB.BsonValue]::new($Building)
        }
        if ($PSBoundParameters.ContainsKey('Room')) {
            $document['Room'] = [LiteDB.BsonValue]::new($Room)
        }
        if ($PSBoundParameters.ContainsKey('Rack')) {
            $document['Rack'] = [LiteDB.BsonValue]::new($Rack)
        }
        if ($PSBoundParameters.ContainsKey('Unit')) {
            $document['Unit'] = [LiteDB.BsonValue]::new($Unit)
        }

        $document['ModifiedDate'] = [LiteDB.BsonValue]::new((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
        $document['DeletedDate'] = [LiteDB.BsonValue]::new('')
        $document['IsDeleted'] = [LiteDB.BsonValue]::new($false)

        [void]$collection.Update($document)

        return [PSCustomObject]@{
            RouterIdentityHostname = Convert-BsonValueToString -Value $document['RouterIdentityHostname']
            RouterModel            = Convert-BsonValueToString -Value $document['RouterModel']
            RouterFirmware         = Convert-BsonValueToString -Value $document['RouterFirmware']
            State                  = Convert-BsonValueToString -Value $document['State']
            City                   = Convert-BsonValueToString -Value $document['City']
            StreetAddress          = Convert-BsonValueToString -Value $document['StreetAddress']
            LocationType           = Convert-BsonValueToString -Value $document['LocationType']
            Building               = Convert-BsonValueToString -Value $document['Building']
            Room                   = Convert-BsonValueToString -Value $document['Room']
            Rack                   = Convert-BsonValueToString -Value $document['Rack']
            Unit                   = Convert-BsonValueToString -Value $document['Unit']
            CreatedDate            = Convert-BsonValueToString -Value $document['CreatedDate']
            ModifiedDate           = Convert-BsonValueToString -Value $document['ModifiedDate']
            IsDeleted              = Convert-BsonValueToBoolean -Value $document['IsDeleted']
            DeletedDate            = Convert-BsonValueToString -Value $document['DeletedDate']
        }
    }
    catch {
        throw "Failed to update MikroTik device record: $_"
    }
    finally {
        if ($null -ne $db) {
            $db.Dispose()
        }
    }
}

# Example usage:
# PS> Set-MikrotikDevice -CurrentRouterIdentityHostname 'R1' -RouterFirmware '7.20.0' -City 'Nashville'
