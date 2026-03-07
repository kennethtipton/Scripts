function Initialize-MikrotikContactCollection {
    <#
    .SYNOPSIS
        Creates and initializes contact collections in LiteDB.
    .DESCRIPTION
        Ensures the contacts, contact_locations, and contact_location_index
        collections exist and applies indexes and schema templates. Also
        performs backward-compatible migration from legacy schemas.
    .PARAMETER DatabasePath
        Full path to the LiteDB file. Defaults to Data\MikrotikDevices.db.
    .EXAMPLE
        PS> Initialize-MikrotikContactCollection
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
        [string]$DatabasePath = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Data\MikrotikDevices.db')
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

        $dbDirectory = Split-Path -Parent $DatabasePath
        if (-not (Test-Path -Path $dbDirectory -PathType Container)) {
            New-Item -Path $dbDirectory -ItemType Directory -Force | Out-Null
        }

        $db = [LiteDB.LiteDatabase]::new($DatabasePath)
        $contactsCollection = $db.GetCollection('contacts')
        $locationsCollection = $db.GetCollection('contact_locations')
        $indexCollection = $db.GetCollection('contact_location_index')

        [void]$contactsCollection.EnsureIndex('DisplayName')
        [void]$contactsCollection.EnsureIndex('Company')
        [void]$contactsCollection.EnsureIndex('ContactType')
        try { [void]$contactsCollection.DropIndex('ContactAbbreviation') } catch {}
        [void]$contactsCollection.EnsureIndex('ContactAbbreviation')

        [void]$locationsCollection.EnsureIndex('LocationName')
        [void]$locationsCollection.EnsureIndex('City')
        [void]$locationsCollection.EnsureIndex('State')
        [void]$locationsCollection.EnsureIndex('PostalCode')
        [void]$locationsCollection.EnsureIndex('Country')
        [void]$locationsCollection.EnsureIndex('PhoneNumber')
        [void]$locationsCollection.EnsureIndex('IsPrimary')

        [void]$indexCollection.EnsureIndex('ContactId')
        [void]$indexCollection.EnsureIndex('LocationId')
        [void]$indexCollection.EnsureIndex('IsPrimary')

        $contactSchemaId = '__contacts_schema_template__'
        if ($null -eq $contactsCollection.FindById([LiteDB.BsonValue]::new($contactSchemaId))) {
            $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $doc = [LiteDB.BsonDocument]::new()
            $doc['_id'] = [LiteDB.BsonValue]::new($contactSchemaId)
            $doc['DisplayName'] = [LiteDB.BsonValue]::new('')
            $doc['FirstName'] = [LiteDB.BsonValue]::new('')
            $doc['LastName'] = [LiteDB.BsonValue]::new('')
            $doc['JobTitle'] = [LiteDB.BsonValue]::new('')
            $doc['Department'] = [LiteDB.BsonValue]::new('')
            $doc['Company'] = [LiteDB.BsonValue]::new('')
            $doc['EmailAddress'] = [LiteDB.BsonValue]::new('')
            $doc['AlternateEmailAddress'] = [LiteDB.BsonValue]::new('')
            $doc['Website'] = [LiteDB.BsonValue]::new('')
            $doc['Notes'] = [LiteDB.BsonValue]::new('')
            $doc['ContactType'] = [LiteDB.BsonValue]::new('Vendor')
            $doc['NetworkConnected'] = [LiteDB.BsonValue]::new($false)
            $doc['ContactAbbreviation'] = [LiteDB.BsonValue]::new('')
            $doc['IsSchemaTemplate'] = [LiteDB.BsonValue]::new($true)
            $doc['CreatedDate'] = [LiteDB.BsonValue]::new($timestamp)
            $doc['ModifiedDate'] = [LiteDB.BsonValue]::new($timestamp)
            $doc['IsDeleted'] = [LiteDB.BsonValue]::new($false)
            $doc['DeletedDate'] = [LiteDB.BsonValue]::new('')
            [void]$contactsCollection.Insert($doc)
        }

        $locationSchemaId = '__contact_locations_schema_template__'
        if ($null -eq $locationsCollection.FindById([LiteDB.BsonValue]::new($locationSchemaId))) {
            $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $doc = [LiteDB.BsonDocument]::new()
            $doc['_id'] = [LiteDB.BsonValue]::new($locationSchemaId)
            $doc['LocationName'] = [LiteDB.BsonValue]::new('Primary')
            $doc['AddressLine1'] = [LiteDB.BsonValue]::new('')
            $doc['AddressLine2'] = [LiteDB.BsonValue]::new('')
            $doc['City'] = [LiteDB.BsonValue]::new('')
            $doc['State'] = [LiteDB.BsonValue]::new('')
            $doc['PostalCode'] = [LiteDB.BsonValue]::new('')
            $doc['Country'] = [LiteDB.BsonValue]::new('')
            $doc['PhoneNumber'] = [LiteDB.BsonValue]::new('')
            $doc['MobileNumber'] = [LiteDB.BsonValue]::new('')
            $doc['WorkPhoneNumber'] = [LiteDB.BsonValue]::new('')
            $doc['IsPrimary'] = [LiteDB.BsonValue]::new($true)
            $doc['IsSchemaTemplate'] = [LiteDB.BsonValue]::new($true)
            $doc['CreatedDate'] = [LiteDB.BsonValue]::new($timestamp)
            $doc['ModifiedDate'] = [LiteDB.BsonValue]::new($timestamp)
            $doc['IsDeleted'] = [LiteDB.BsonValue]::new($false)
            $doc['DeletedDate'] = [LiteDB.BsonValue]::new('')
            [void]$locationsCollection.Insert($doc)
        }

        $indexSchemaId = '__contact_location_index_schema_template__'
        if ($null -eq $indexCollection.FindById([LiteDB.BsonValue]::new($indexSchemaId))) {
            $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $doc = [LiteDB.BsonDocument]::new()
            $doc['_id'] = [LiteDB.BsonValue]::new($indexSchemaId)
            $doc['ContactId'] = [LiteDB.BsonValue]::new('')
            $doc['LocationId'] = [LiteDB.BsonValue]::new('')
            $doc['IsPrimary'] = [LiteDB.BsonValue]::new($false)
            $doc['IsSchemaTemplate'] = [LiteDB.BsonValue]::new($true)
            $doc['CreatedDate'] = [LiteDB.BsonValue]::new($timestamp)
            $doc['ModifiedDate'] = [LiteDB.BsonValue]::new($timestamp)
            $doc['IsDeleted'] = [LiteDB.BsonValue]::new($false)
            $doc['DeletedDate'] = [LiteDB.BsonValue]::new('')
            [void]$indexCollection.Insert($doc)
        }

        # Migration: move legacy contact phone/address fields to locations and
        # convert direct ContactId location links to index links.
        $contactRecords = @($contactsCollection.FindAll()) | Where-Object {
            -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate'])
        }

        foreach ($contactRecord in $contactRecords) {
            $contactId = Convert-BsonValueToString -Value $contactRecord['_id']
            if ([string]::IsNullOrWhiteSpace($contactId)) { continue }

            $legacyAddressLine1 = Convert-BsonValueToString -Value $contactRecord['AddressLine1']
            $legacyAddressLine2 = Convert-BsonValueToString -Value $contactRecord['AddressLine2']
            $legacyCity = Convert-BsonValueToString -Value $contactRecord['City']
            $legacyState = Convert-BsonValueToString -Value $contactRecord['State']
            $legacyPostalCode = Convert-BsonValueToString -Value $contactRecord['PostalCode']
            $legacyCountry = Convert-BsonValueToString -Value $contactRecord['Country']
            $legacyPhone = Convert-BsonValueToString -Value $contactRecord['PhoneNumber']
            $legacyMobile = Convert-BsonValueToString -Value $contactRecord['MobileNumber']
            $legacyWorkPhone = Convert-BsonValueToString -Value $contactRecord['WorkPhoneNumber']

            $hasLegacyContactLocationData =
                -not [string]::IsNullOrWhiteSpace($legacyAddressLine1) -or
                -not [string]::IsNullOrWhiteSpace($legacyAddressLine2) -or
                -not [string]::IsNullOrWhiteSpace($legacyCity) -or
                -not [string]::IsNullOrWhiteSpace($legacyState) -or
                -not [string]::IsNullOrWhiteSpace($legacyPostalCode) -or
                -not [string]::IsNullOrWhiteSpace($legacyCountry) -or
                -not [string]::IsNullOrWhiteSpace($legacyPhone) -or
                -not [string]::IsNullOrWhiteSpace($legacyMobile) -or
                -not [string]::IsNullOrWhiteSpace($legacyWorkPhone)

            $existingLinks = @($indexCollection.FindAll()) | Where-Object {
                -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                (Convert-BsonValueToString -Value $_['ContactId']) -eq $contactId
            }

            if ($existingLinks.Count -eq 0 -and $hasLegacyContactLocationData) {
                $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                $locationId = [Guid]::NewGuid().ToString()

                $locationDoc = [LiteDB.BsonDocument]::new()
                $locationDoc['_id'] = [LiteDB.BsonValue]::new($locationId)
                $locationDoc['LocationName'] = [LiteDB.BsonValue]::new('Primary')
                $locationDoc['AddressLine1'] = [LiteDB.BsonValue]::new($legacyAddressLine1)
                $locationDoc['AddressLine2'] = [LiteDB.BsonValue]::new($legacyAddressLine2)
                $locationDoc['City'] = [LiteDB.BsonValue]::new($legacyCity)
                $locationDoc['State'] = [LiteDB.BsonValue]::new($legacyState)
                $locationDoc['PostalCode'] = [LiteDB.BsonValue]::new($legacyPostalCode)
                $locationDoc['Country'] = [LiteDB.BsonValue]::new($legacyCountry)
                $locationDoc['PhoneNumber'] = [LiteDB.BsonValue]::new($legacyPhone)
                $locationDoc['MobileNumber'] = [LiteDB.BsonValue]::new($legacyMobile)
                $locationDoc['WorkPhoneNumber'] = [LiteDB.BsonValue]::new($legacyWorkPhone)
                $locationDoc['IsPrimary'] = [LiteDB.BsonValue]::new($true)
                $locationDoc['IsSchemaTemplate'] = [LiteDB.BsonValue]::new($false)
                $locationDoc['CreatedDate'] = [LiteDB.BsonValue]::new($timestamp)
                $locationDoc['ModifiedDate'] = [LiteDB.BsonValue]::new($timestamp)
                $locationDoc['IsDeleted'] = [LiteDB.BsonValue]::new($false)
                $locationDoc['DeletedDate'] = [LiteDB.BsonValue]::new('')
                [void]$locationsCollection.Insert($locationDoc)

                $linkDoc = [LiteDB.BsonDocument]::new()
                $linkDoc['_id'] = [LiteDB.BsonValue]::new([Guid]::NewGuid().ToString())
                $linkDoc['ContactId'] = [LiteDB.BsonValue]::new($contactId)
                $linkDoc['LocationId'] = [LiteDB.BsonValue]::new($locationId)
                $linkDoc['IsPrimary'] = [LiteDB.BsonValue]::new($true)
                $linkDoc['IsSchemaTemplate'] = [LiteDB.BsonValue]::new($false)
                $linkDoc['CreatedDate'] = [LiteDB.BsonValue]::new($timestamp)
                $linkDoc['ModifiedDate'] = [LiteDB.BsonValue]::new($timestamp)
                $linkDoc['IsDeleted'] = [LiteDB.BsonValue]::new($false)
                $linkDoc['DeletedDate'] = [LiteDB.BsonValue]::new('')
                [void]$indexCollection.Insert($linkDoc)
            }

            $legacyDirectRows = @($locationsCollection.FindAll()) | Where-Object {
                -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                (Convert-BsonValueToString -Value $_['ContactId']) -eq $contactId
            }

            foreach ($legacyRow in $legacyDirectRows) {
                $locationId = Convert-BsonValueToString -Value $legacyRow['_id']
                if ([string]::IsNullOrWhiteSpace($locationId)) { continue }

                $existingLink = @($indexCollection.FindAll()) | Where-Object {
                    -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                    (Convert-BsonValueToString -Value $_['ContactId']) -eq $contactId -and
                    (Convert-BsonValueToString -Value $_['LocationId']) -eq $locationId
                } | Select-Object -First 1

                if ($null -ne $existingLink) { continue }

                $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                $linkDoc = [LiteDB.BsonDocument]::new()
                $linkDoc['_id'] = [LiteDB.BsonValue]::new([Guid]::NewGuid().ToString())
                $linkDoc['ContactId'] = [LiteDB.BsonValue]::new($contactId)
                $linkDoc['LocationId'] = [LiteDB.BsonValue]::new($locationId)
                $linkDoc['IsPrimary'] = [LiteDB.BsonValue]::new((Convert-BsonValueToBoolean -Value $legacyRow['IsPrimary']))
                $linkDoc['IsSchemaTemplate'] = [LiteDB.BsonValue]::new($false)
                $linkDoc['CreatedDate'] = [LiteDB.BsonValue]::new($timestamp)
                $linkDoc['ModifiedDate'] = [LiteDB.BsonValue]::new($timestamp)
                $linkDoc['IsDeleted'] = [LiteDB.BsonValue]::new((Convert-BsonValueToBoolean -Value $legacyRow['IsDeleted']))
                $linkDoc['DeletedDate'] = [LiteDB.BsonValue]::new((Convert-BsonValueToString -Value $legacyRow['DeletedDate']))
                [void]$indexCollection.Insert($linkDoc)
            }

            # Normalize contact record by clearing legacy phone/address fields.
            $contactRecord['AddressLine1'] = [LiteDB.BsonValue]::new('')
            $contactRecord['AddressLine2'] = [LiteDB.BsonValue]::new('')
            $contactRecord['City'] = [LiteDB.BsonValue]::new('')
            $contactRecord['State'] = [LiteDB.BsonValue]::new('')
            $contactRecord['PostalCode'] = [LiteDB.BsonValue]::new('')
            $contactRecord['Country'] = [LiteDB.BsonValue]::new('')
            $contactRecord['PhoneNumber'] = [LiteDB.BsonValue]::new('')
            $contactRecord['MobileNumber'] = [LiteDB.BsonValue]::new('')
            $contactRecord['WorkPhoneNumber'] = [LiteDB.BsonValue]::new('')
            [void]$contactsCollection.Update($contactRecord)
        }

        return [PSCustomObject]@{
            CollectionNames         = @('contacts', 'contact_locations', 'contact_location_index')
            DatabasePath            = $DatabasePath
            Initialized             = $true
            ContactsSchemaTemplate  = $contactSchemaId
            LocationsSchemaTemplate = $locationSchemaId
            IndexSchemaTemplate     = $indexSchemaId
            ContactTypeOptions      = @('Person', 'Company', 'Vendor')
            NetworkConnectedDefault = $false
        }
    }
    catch {
        throw "Failed to initialize contacts collections: $_"
    }
    finally {
        if ($null -ne $db) {
            $db.Dispose()
        }
    }
}

# Example usage:
# PS> Initialize-MikrotikContactCollection
