function New-MikrotikContactLocation {
    <#
    .SYNOPSIS
        Creates a new contact location and links it to a contact.
    .DESCRIPTION
        Inserts into contact_locations and creates a row in
        contact_location_index using ContactId and LocationId.
    .PARAMETER DatabasePath
        Full path to the LiteDB file. Defaults to Data\MikrotikDevices.db.
    .PARAMETER ContactId
        Optional contact id to link the location to.
    .PARAMETER DisplayName
        Optional contact display name used to resolve ContactId.
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
        Marks this location as primary for the contact.
    .EXAMPLE
        PS> New-MikrotikContactLocation -ContactId 'abc123' -LocationName 'HQ' -PhoneNumber '+1-555-0100' -IsPrimary
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

        [Parameter(Mandatory = $false)]
        [string]$ContactId,

        [Parameter(Mandatory = $false)]
        [string]$DisplayName,

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

        if ([string]::IsNullOrWhiteSpace($ContactId) -and [string]::IsNullOrWhiteSpace($DisplayName)) {
            throw 'Either ContactId or DisplayName must be provided.'
        }

        if ([string]::IsNullOrWhiteSpace($ContactId) -and -not [string]::IsNullOrWhiteSpace($DisplayName)) {
            $resolvedContact = @(
                @($contacts.FindAll()) | Where-Object {
                    -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                    -not (Convert-BsonValueToBoolean -Value $_['IsDeleted']) -and
                    (Convert-BsonValueToString -Value $_['DisplayName']) -eq $DisplayName
                }
            ) | Select-Object -First 1

            if ($null -eq $resolvedContact) {
                throw "DisplayName '$DisplayName' does not resolve to an active contact."
            }

            $ContactId = Convert-BsonValueToString -Value $resolvedContact['_id']
        }

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

        $now = [DateTime]::UtcNow.ToString('o')

        if ($IsPrimary.IsPresent) {
            $existingLinks = @(
                @($links.FindAll()) | Where-Object {
                    -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                    -not (Convert-BsonValueToBoolean -Value $_['IsDeleted']) -and
                    (Convert-BsonValueToString -Value $_['ContactId']) -eq $ContactId
                }
            )

            foreach ($row in $existingLinks) {
                $row['IsPrimary'] = [LiteDB.BsonValue]::new($false)
                $row['ModifiedDate'] = [LiteDB.BsonValue]::new($now)
                [void]$links.Update($row)
            }
        }

        $locationDocument = [LiteDB.BsonDocument]::new()
        $locationDocument['LocationName'] = [LiteDB.BsonValue]::new(([string]$LocationName).Trim())
        $locationDocument['AddressLine1'] = [LiteDB.BsonValue]::new(([string]$AddressLine1).Trim())
        $locationDocument['AddressLine2'] = [LiteDB.BsonValue]::new(([string]$AddressLine2).Trim())
        $locationDocument['City'] = [LiteDB.BsonValue]::new(([string]$City).Trim())
        $locationDocument['State'] = [LiteDB.BsonValue]::new(([string]$State).Trim())
        $locationDocument['PostalCode'] = [LiteDB.BsonValue]::new(([string]$PostalCode).Trim())
        $locationDocument['Country'] = [LiteDB.BsonValue]::new(([string]$Country).Trim())
        $locationDocument['PhoneNumber'] = [LiteDB.BsonValue]::new(([string]$PhoneNumber).Trim())
        $locationDocument['MobileNumber'] = [LiteDB.BsonValue]::new(([string]$MobileNumber).Trim())
        $locationDocument['WorkPhoneNumber'] = [LiteDB.BsonValue]::new(([string]$WorkPhoneNumber).Trim())
        $locationDocument['CreatedDate'] = [LiteDB.BsonValue]::new($now)
        $locationDocument['ModifiedDate'] = [LiteDB.BsonValue]::new($now)
        $locationDocument['IsDeleted'] = [LiteDB.BsonValue]::new($false)
        $locationDocument['DeletedDate'] = [LiteDB.BsonValue]::new('')

        $locationBsonId = $locations.Insert($locationDocument)
        $locationId = Convert-BsonValueToString -Value $locationBsonId

        $linkDocument = [LiteDB.BsonDocument]::new()
        $linkDocument['ContactId'] = [LiteDB.BsonValue]::new($ContactId)
        $linkDocument['LocationId'] = [LiteDB.BsonValue]::new($locationId)
        $linkDocument['IsPrimary'] = [LiteDB.BsonValue]::new($IsPrimary.IsPresent)
        $linkDocument['CreatedDate'] = [LiteDB.BsonValue]::new($now)
        $linkDocument['ModifiedDate'] = [LiteDB.BsonValue]::new($now)
        $linkDocument['IsDeleted'] = [LiteDB.BsonValue]::new($false)
        $linkDocument['DeletedDate'] = [LiteDB.BsonValue]::new('')

        [void]$links.Insert($linkDocument)

        [PSCustomObject]@{
            ContactId       = $ContactId
            LocationId      = $locationId
            LocationName    = Convert-BsonValueToString -Value $locationDocument['LocationName']
            AddressLine1    = Convert-BsonValueToString -Value $locationDocument['AddressLine1']
            AddressLine2    = Convert-BsonValueToString -Value $locationDocument['AddressLine2']
            City            = Convert-BsonValueToString -Value $locationDocument['City']
            State           = Convert-BsonValueToString -Value $locationDocument['State']
            PostalCode      = Convert-BsonValueToString -Value $locationDocument['PostalCode']
            Country         = Convert-BsonValueToString -Value $locationDocument['Country']
            PhoneNumber     = Convert-BsonValueToString -Value $locationDocument['PhoneNumber']
            MobileNumber    = Convert-BsonValueToString -Value $locationDocument['MobileNumber']
            WorkPhoneNumber = Convert-BsonValueToString -Value $locationDocument['WorkPhoneNumber']
            IsPrimary       = $IsPrimary.IsPresent
            CreatedDate     = $now
            ModifiedDate    = $now
            IsDeleted       = $false
            DeletedDate     = ''
        }
    }
    catch {
        throw "Failed to create contact location: $_"
    }
    finally {
        if ($null -ne $db) { $db.Dispose() }
    }
}

# Example usage:
# PS> New-MikrotikContactLocation -ContactId 'abc123' -LocationName 'HQ' -IsPrimary
