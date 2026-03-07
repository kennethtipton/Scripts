function Set-MikrotikContactLocation {
    <#
    .SYNOPSIS
        Updates an existing contact location and optional contact link metadata.
    .DESCRIPTION
        Updates a contact_locations record and maintains contact_location_index
        relationship metadata such as IsPrimary and ContactId link target.
    .PARAMETER DatabasePath
        Full path to the LiteDB file. Defaults to Data\MikrotikDevices.db.
    .PARAMETER LocationId
        Required location id to update.
    .PARAMETER ContactId
        Optional contact id to re-link this location.
    .PARAMETER LocationName
        Optional location display name.
    .PARAMETER AddressLine1
        Address line 1.
    .PARAMETER AddressLine2
        Address line 2.
    .PARAMETER City
        City.
    .PARAMETER State
        State.
    .PARAMETER PostalCode
        Postal code.
    .PARAMETER Country
        Country.
    .PARAMETER PhoneNumber
        Main phone number for the location.
    .PARAMETER MobileNumber
        Mobile number for the location.
    .PARAMETER WorkPhoneNumber
        Work phone number for the location.
    .PARAMETER IsPrimary
        Sets this location as primary for ContactId.
    .EXAMPLE
        PS> Set-MikrotikContactLocation -LocationId 'loc1' -PhoneNumber '+1-555-0101'
    .INPUTS
        None.
    .OUTPUTS
        PSCustomObject.
    .NOTES
        Author: Kenneth Tipton
        Company: TNC
        Date: 2026-03-07
        Version: 2.0.0
        Function Or Application: Function
    .LINK
        https://www.tnandc.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$DatabasePath = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Data\MikrotikDevices.db'),

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LocationId,

        [Parameter(Mandatory = $false)]
        [string]$ContactId,

        [Parameter(Mandatory = $false)]
        [string]$LocationName,

        [Parameter(Mandatory = $false)]
        [string]$AddressLine1,

        [Parameter(Mandatory = $false)]
        [string]$AddressLine2,

        [Parameter(Mandatory = $false)]
        [string]$City,

        [Parameter(Mandatory = $false)]
        [string]$State,

        [Parameter(Mandatory = $false)]
        [string]$PostalCode,

        [Parameter(Mandatory = $false)]
        [string]$Country,

        [Parameter(Mandatory = $false)]
        [string]$PhoneNumber,

        [Parameter(Mandatory = $false)]
        [string]$MobileNumber,

        [Parameter(Mandatory = $false)]
        [string]$WorkPhoneNumber,

        [Parameter(Mandatory = $false)]
        [switch]$IsPrimary
    )

    $db = $null

    function Convert-BsonValueToString {
        param([LiteDB.BsonValue]$Value)
        if ($null -eq $Value -or $Value.IsNull) { return '' }
        if ($Value.IsString) { return $Value.AsString }
        return $Value.ToString()
    }

    function Convert-BsonValueToBoolean {
        param([LiteDB.BsonValue]$Value)
        if ($null -eq $Value -or $Value.IsNull) { return $false }
        if ($Value.IsBoolean) { return $Value.AsBoolean }
        $parsed = $false
        if ([bool]::TryParse($Value.ToString(), [ref]$parsed)) { return $parsed }
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

        $db = [LiteDB.LiteDatabase]::new($DatabasePath)
        $contacts = $db.GetCollection('contacts')
        $locations = $db.GetCollection('contact_locations')
        $links = $db.GetCollection('contact_location_index')

        $location = @(
            @($locations.FindAll()) | Where-Object {
                -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                (Convert-BsonValueToString -Value $_['_id']) -eq $LocationId
            }
        ) | Select-Object -First 1

        if ($null -eq $location) {
            throw "LocationId '$LocationId' was not found."
        }

        if (-not [string]::IsNullOrWhiteSpace($ContactId)) {
            $contactExists = @(
                @($contacts.FindAll()) | Where-Object {
                    -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                    -not (Convert-BsonValueToBoolean -Value $_['IsDeleted']) -and
                    (Convert-BsonValueToString -Value $_['_id']) -eq $ContactId
                }
            ) | Select-Object -First 1

            if ($null -eq $contactExists) {
                throw "ContactId '$ContactId' does not exist or is deleted."
            }
        }

        $now = [DateTime]::UtcNow.ToString('o')

        if ($PSBoundParameters.ContainsKey('LocationName')) {
            $location['LocationName'] = [LiteDB.BsonValue]::new(([string]$LocationName).Trim())
        }

        if ($PSBoundParameters.ContainsKey('AddressLine1')) {
            $location['AddressLine1'] = [LiteDB.BsonValue]::new(([string]$AddressLine1).Trim())
        }

        if ($PSBoundParameters.ContainsKey('AddressLine2')) {
            $location['AddressLine2'] = [LiteDB.BsonValue]::new(([string]$AddressLine2).Trim())
        }

        if ($PSBoundParameters.ContainsKey('City')) {
            $location['City'] = [LiteDB.BsonValue]::new(([string]$City).Trim())
        }

        if ($PSBoundParameters.ContainsKey('State')) {
            $location['State'] = [LiteDB.BsonValue]::new(([string]$State).Trim())
        }

        if ($PSBoundParameters.ContainsKey('PostalCode')) {
            $location['PostalCode'] = [LiteDB.BsonValue]::new(([string]$PostalCode).Trim())
        }

        if ($PSBoundParameters.ContainsKey('Country')) {
            $location['Country'] = [LiteDB.BsonValue]::new(([string]$Country).Trim())
        }

        if ($PSBoundParameters.ContainsKey('PhoneNumber')) {
            $location['PhoneNumber'] = [LiteDB.BsonValue]::new(([string]$PhoneNumber).Trim())
        }

        if ($PSBoundParameters.ContainsKey('MobileNumber')) {
            $location['MobileNumber'] = [LiteDB.BsonValue]::new(([string]$MobileNumber).Trim())
        }

        if ($PSBoundParameters.ContainsKey('WorkPhoneNumber')) {
            $location['WorkPhoneNumber'] = [LiteDB.BsonValue]::new(([string]$WorkPhoneNumber).Trim())
        }

        $location['ModifiedDate'] = [LiteDB.BsonValue]::new($now)
        [void]$locations.Update($location)

        $locationLinks = @(
            @($links.FindAll()) | Where-Object {
                -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                -not (Convert-BsonValueToBoolean -Value $_['IsDeleted']) -and
                (Convert-BsonValueToString -Value $_['LocationId']) -eq $LocationId
            }
        )

        $targetLink = $null
        if (-not [string]::IsNullOrWhiteSpace($ContactId)) {
            $targetLink = $locationLinks | Where-Object {
                (Convert-BsonValueToString -Value $_['ContactId']) -eq $ContactId
            } | Select-Object -First 1

            if ($null -eq $targetLink) {
                $targetLink = [LiteDB.BsonDocument]::new()
                $targetLink['ContactId'] = [LiteDB.BsonValue]::new($ContactId)
                $targetLink['LocationId'] = [LiteDB.BsonValue]::new($LocationId)
                $targetLink['IsPrimary'] = [LiteDB.BsonValue]::new($false)
                $targetLink['CreatedDate'] = [LiteDB.BsonValue]::new($now)
                $targetLink['ModifiedDate'] = [LiteDB.BsonValue]::new($now)
                $targetLink['IsDeleted'] = [LiteDB.BsonValue]::new($false)
                $targetLink['DeletedDate'] = [LiteDB.BsonValue]::new('')
                [void]$links.Insert($targetLink)
                $locationLinks += $targetLink
            }
        }
        else {
            $targetLink = $locationLinks | Select-Object -First 1
        }

        if ($IsPrimary.IsPresent -and $null -ne $targetLink) {
            $primaryContactId = Convert-BsonValueToString -Value $targetLink['ContactId']
            $contactLinks = @(
                @($links.FindAll()) | Where-Object {
                    -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                    -not (Convert-BsonValueToBoolean -Value $_['IsDeleted']) -and
                    (Convert-BsonValueToString -Value $_['ContactId']) -eq $primaryContactId
                }
            )

            foreach ($row in $contactLinks) {
                $row['IsPrimary'] = [LiteDB.BsonValue]::new($false)
                $row['ModifiedDate'] = [LiteDB.BsonValue]::new($now)
                [void]$links.Update($row)
            }

            $targetLink['IsPrimary'] = [LiteDB.BsonValue]::new($true)
            $targetLink['ModifiedDate'] = [LiteDB.BsonValue]::new($now)
            [void]$links.Update($targetLink)
        }

        $activeLink = @(
            @($links.FindAll()) | Where-Object {
                -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                -not (Convert-BsonValueToBoolean -Value $_['IsDeleted']) -and
                (Convert-BsonValueToString -Value $_['LocationId']) -eq $LocationId
            }
        ) | Select-Object -First 1

        [PSCustomObject]@{
            LocationId      = $LocationId
            ContactId       = if ($null -ne $activeLink) { Convert-BsonValueToString -Value $activeLink['ContactId'] } else { '' }
            LocationName    = Convert-BsonValueToString -Value $location['LocationName']
            AddressLine1    = Convert-BsonValueToString -Value $location['AddressLine1']
            AddressLine2    = Convert-BsonValueToString -Value $location['AddressLine2']
            City            = Convert-BsonValueToString -Value $location['City']
            State           = Convert-BsonValueToString -Value $location['State']
            PostalCode      = Convert-BsonValueToString -Value $location['PostalCode']
            Country         = Convert-BsonValueToString -Value $location['Country']
            PhoneNumber     = Convert-BsonValueToString -Value $location['PhoneNumber']
            MobileNumber    = Convert-BsonValueToString -Value $location['MobileNumber']
            WorkPhoneNumber = Convert-BsonValueToString -Value $location['WorkPhoneNumber']
            IsPrimary       = if ($null -ne $activeLink) { Convert-BsonValueToBoolean -Value $activeLink['IsPrimary'] } else { $false }
            ModifiedDate    = Convert-BsonValueToString -Value $location['ModifiedDate']
            IsDeleted       = Convert-BsonValueToBoolean -Value $location['IsDeleted']
            DeletedDate     = Convert-BsonValueToString -Value $location['DeletedDate']
        }
    }
    catch {
        throw "Failed to update contact location: $_"
    }
    finally {
        if ($null -ne $db) { $db.Dispose() }
    }
}

# Example usage:
# PS> Set-MikrotikContactLocation -LocationId 'loc1' -City 'Dallas' -IsPrimary
