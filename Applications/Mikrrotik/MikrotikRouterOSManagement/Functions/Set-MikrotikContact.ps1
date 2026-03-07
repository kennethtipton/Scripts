function Set-MikrotikContact {
    <#
    .SYNOPSIS
        Updates an existing contact record in LiteDB.
    .DESCRIPTION
        Updates contact identity fields in contacts and updates phone/address
        fields in the linked primary location through contact_location_index.
    .PARAMETER CurrentDisplayName
        Existing display name used to locate the contact.
    .PARAMETER DatabasePath
        Full path to the LiteDB file. Defaults to Data\MikrotikDevices.db.
    .EXAMPLE
        PS> Set-MikrotikContact -CurrentDisplayName 'Acme Support' -NetworkConnected $true
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
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CurrentDisplayName,

        [Parameter(Mandatory = $false)]
        [string]$DisplayName,

        [Parameter(Mandatory = $false)]
        [string]$FirstName,

        [Parameter(Mandatory = $false)]
        [string]$LastName,

        [Parameter(Mandatory = $false)]
        [string]$JobTitle,

        [Parameter(Mandatory = $false)]
        [string]$Department,

        [Parameter(Mandatory = $false)]
        [string]$Company,

        [Parameter(Mandatory = $false)]
        [string]$EmailAddress,

        [Parameter(Mandatory = $false)]
        [string]$AlternateEmailAddress,

        [Parameter(Mandatory = $false)]
        [string]$PhoneNumber,

        [Parameter(Mandatory = $false)]
        [string]$MobileNumber,

        [Parameter(Mandatory = $false)]
        [string]$WorkPhoneNumber,

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
        [string]$LocationName,

        [Parameter(Mandatory = $false)]
        [string]$Website,

        [Parameter(Mandatory = $false)]
        [string]$Notes,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Person', 'Company', 'Vendor')]
        [string]$ContactType,

        [Parameter(Mandatory = $false)]
        [bool]$NetworkConnected,

        [Parameter(Mandatory = $false)]
        [string]$ContactAbbreviation,

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
        if (-not $PSBoundParameters.ContainsKey('DisplayName') -and
            -not $PSBoundParameters.ContainsKey('FirstName') -and
            -not $PSBoundParameters.ContainsKey('LastName') -and
            -not $PSBoundParameters.ContainsKey('JobTitle') -and
            -not $PSBoundParameters.ContainsKey('Department') -and
            -not $PSBoundParameters.ContainsKey('Company') -and
            -not $PSBoundParameters.ContainsKey('EmailAddress') -and
            -not $PSBoundParameters.ContainsKey('AlternateEmailAddress') -and
            -not $PSBoundParameters.ContainsKey('Website') -and
            -not $PSBoundParameters.ContainsKey('Notes') -and
            -not $PSBoundParameters.ContainsKey('ContactType') -and
            -not $PSBoundParameters.ContainsKey('NetworkConnected') -and
            -not $PSBoundParameters.ContainsKey('ContactAbbreviation') -and
            -not $PSBoundParameters.ContainsKey('LocationName') -and
            -not $PSBoundParameters.ContainsKey('AddressLine1') -and
            -not $PSBoundParameters.ContainsKey('AddressLine2') -and
            -not $PSBoundParameters.ContainsKey('City') -and
            -not $PSBoundParameters.ContainsKey('State') -and
            -not $PSBoundParameters.ContainsKey('PostalCode') -and
            -not $PSBoundParameters.ContainsKey('Country') -and
            -not $PSBoundParameters.ContainsKey('PhoneNumber') -and
            -not $PSBoundParameters.ContainsKey('MobileNumber') -and
            -not $PSBoundParameters.ContainsKey('WorkPhoneNumber')) {
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
        $contacts = $db.GetCollection('contacts')
        $locations = $db.GetCollection('contact_locations')
        $links = $db.GetCollection('contact_location_index')

        $contactDoc = @(
            @($contacts.FindAll()) | Where-Object {
                -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                (Convert-BsonValueToString -Value $_['DisplayName']) -eq $CurrentDisplayName -and
                -not (Convert-BsonValueToBoolean -Value $_['IsDeleted'])
            }
        ) | Select-Object -First 1

        if ($null -eq $contactDoc) {
            throw "No active contact found for DisplayName '$CurrentDisplayName'."
        }

        if ($PSBoundParameters.ContainsKey('DisplayName')) {
            $existingWithNewName = @(
                @($contacts.FindAll()) | Where-Object {
                    -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                    (Convert-BsonValueToString -Value $_['DisplayName']) -eq $DisplayName -and
                    -not (Convert-BsonValueToBoolean -Value $_['IsDeleted']) -and
                    (Convert-BsonValueToString -Value $_['_id']) -ne (Convert-BsonValueToString -Value $contactDoc['_id'])
                }
            ) | Select-Object -First 1

            if ($null -ne $existingWithNewName) {
                throw "A contact already exists with DisplayName '$DisplayName'."
            }
        }

        if ($PSBoundParameters.ContainsKey('ContactAbbreviation') -and -not [string]::IsNullOrWhiteSpace($ContactAbbreviation)) {
            $existingWithAbbreviation = @(
                @($contacts.FindAll()) | Where-Object {
                    -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                    (Convert-BsonValueToString -Value $_['ContactAbbreviation']) -eq $ContactAbbreviation -and
                    -not (Convert-BsonValueToBoolean -Value $_['IsDeleted']) -and
                    (Convert-BsonValueToString -Value $_['_id']) -ne (Convert-BsonValueToString -Value $contactDoc['_id'])
                }
            ) | Select-Object -First 1

            if ($null -ne $existingWithAbbreviation) {
                throw "A contact already exists with ContactAbbreviation '$ContactAbbreviation'."
            }
        }

        if ($PSBoundParameters.ContainsKey('DisplayName')) { $contactDoc['DisplayName'] = [LiteDB.BsonValue]::new($DisplayName) }
        if ($PSBoundParameters.ContainsKey('FirstName')) { $contactDoc['FirstName'] = [LiteDB.BsonValue]::new($FirstName) }
        if ($PSBoundParameters.ContainsKey('LastName')) { $contactDoc['LastName'] = [LiteDB.BsonValue]::new($LastName) }
        if ($PSBoundParameters.ContainsKey('JobTitle')) { $contactDoc['JobTitle'] = [LiteDB.BsonValue]::new($JobTitle) }
        if ($PSBoundParameters.ContainsKey('Department')) { $contactDoc['Department'] = [LiteDB.BsonValue]::new($Department) }
        if ($PSBoundParameters.ContainsKey('Company')) { $contactDoc['Company'] = [LiteDB.BsonValue]::new($Company) }
        if ($PSBoundParameters.ContainsKey('EmailAddress')) { $contactDoc['EmailAddress'] = [LiteDB.BsonValue]::new($EmailAddress) }
        if ($PSBoundParameters.ContainsKey('AlternateEmailAddress')) { $contactDoc['AlternateEmailAddress'] = [LiteDB.BsonValue]::new($AlternateEmailAddress) }
        if ($PSBoundParameters.ContainsKey('Website')) { $contactDoc['Website'] = [LiteDB.BsonValue]::new($Website) }
        if ($PSBoundParameters.ContainsKey('Notes')) { $contactDoc['Notes'] = [LiteDB.BsonValue]::new($Notes) }
        if ($PSBoundParameters.ContainsKey('ContactType')) { $contactDoc['ContactType'] = [LiteDB.BsonValue]::new($ContactType) }
        if ($PSBoundParameters.ContainsKey('NetworkConnected')) { $contactDoc['NetworkConnected'] = [LiteDB.BsonValue]::new($NetworkConnected) }
        if ($PSBoundParameters.ContainsKey('ContactAbbreviation')) { $contactDoc['ContactAbbreviation'] = [LiteDB.BsonValue]::new($ContactAbbreviation) }

        $contactDoc['ModifiedDate'] = [LiteDB.BsonValue]::new((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
        $contactDoc['DeletedDate'] = [LiteDB.BsonValue]::new('')
        $contactDoc['IsDeleted'] = [LiteDB.BsonValue]::new($false)

        [void]$contacts.Update($contactDoc)

        $hasLocationUpdate =
            $PSBoundParameters.ContainsKey('LocationName') -or
            $PSBoundParameters.ContainsKey('AddressLine1') -or
            $PSBoundParameters.ContainsKey('AddressLine2') -or
            $PSBoundParameters.ContainsKey('City') -or
            $PSBoundParameters.ContainsKey('State') -or
            $PSBoundParameters.ContainsKey('PostalCode') -or
            $PSBoundParameters.ContainsKey('Country') -or
            $PSBoundParameters.ContainsKey('PhoneNumber') -or
            $PSBoundParameters.ContainsKey('MobileNumber') -or
            $PSBoundParameters.ContainsKey('WorkPhoneNumber')

        $primaryLocation = $null

        if ($hasLocationUpdate) {
            $contactId = Convert-BsonValueToString -Value $contactDoc['_id']
            $activeLinks = @(
                @($links.FindAll()) | Where-Object {
                    -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                    (Convert-BsonValueToString -Value $_['ContactId']) -eq $contactId -and
                    -not (Convert-BsonValueToBoolean -Value $_['IsDeleted'])
                }
            )

            $primaryLink = $activeLinks | Where-Object {
                (Convert-BsonValueToBoolean -Value $_['IsPrimary'])
            } | Select-Object -First 1

            if ($null -eq $primaryLink) {
                $primaryLink = $activeLinks | Select-Object -First 1
            }

            if ($null -ne $primaryLink) {
                $locationId = Convert-BsonValueToString -Value $primaryLink['LocationId']
                $primaryLocation = @(
                    @($locations.FindAll()) | Where-Object {
                        -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                        (Convert-BsonValueToString -Value $_['_id']) -eq $locationId
                    }
                ) | Select-Object -First 1
            }

            if ($null -eq $primaryLocation) {
                $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                $locationId = [Guid]::NewGuid().ToString()

                $primaryLocation = [LiteDB.BsonDocument]::new()
                $primaryLocation['_id'] = [LiteDB.BsonValue]::new($locationId)
                $primaryLocation['LocationName'] = [LiteDB.BsonValue]::new('Primary')
                $primaryLocation['AddressLine1'] = [LiteDB.BsonValue]::new('')
                $primaryLocation['AddressLine2'] = [LiteDB.BsonValue]::new('')
                $primaryLocation['City'] = [LiteDB.BsonValue]::new('')
                $primaryLocation['State'] = [LiteDB.BsonValue]::new('')
                $primaryLocation['PostalCode'] = [LiteDB.BsonValue]::new('')
                $primaryLocation['Country'] = [LiteDB.BsonValue]::new('')
                $primaryLocation['PhoneNumber'] = [LiteDB.BsonValue]::new('')
                $primaryLocation['MobileNumber'] = [LiteDB.BsonValue]::new('')
                $primaryLocation['WorkPhoneNumber'] = [LiteDB.BsonValue]::new('')
                $primaryLocation['IsPrimary'] = [LiteDB.BsonValue]::new($true)
                $primaryLocation['IsSchemaTemplate'] = [LiteDB.BsonValue]::new($false)
                $primaryLocation['CreatedDate'] = [LiteDB.BsonValue]::new($timestamp)
                $primaryLocation['ModifiedDate'] = [LiteDB.BsonValue]::new($timestamp)
                $primaryLocation['IsDeleted'] = [LiteDB.BsonValue]::new($false)
                $primaryLocation['DeletedDate'] = [LiteDB.BsonValue]::new('')

                [void]$locations.Insert($primaryLocation)

                $newLink = [LiteDB.BsonDocument]::new()
                $newLink['_id'] = [LiteDB.BsonValue]::new([Guid]::NewGuid().ToString())
                $newLink['ContactId'] = [LiteDB.BsonValue]::new($contactId)
                $newLink['LocationId'] = [LiteDB.BsonValue]::new($locationId)
                $newLink['IsPrimary'] = [LiteDB.BsonValue]::new($true)
                $newLink['IsSchemaTemplate'] = [LiteDB.BsonValue]::new($false)
                $newLink['CreatedDate'] = [LiteDB.BsonValue]::new($timestamp)
                $newLink['ModifiedDate'] = [LiteDB.BsonValue]::new($timestamp)
                $newLink['IsDeleted'] = [LiteDB.BsonValue]::new($false)
                $newLink['DeletedDate'] = [LiteDB.BsonValue]::new('')
                [void]$links.Insert($newLink)
            }

            if ($PSBoundParameters.ContainsKey('LocationName')) { $primaryLocation['LocationName'] = [LiteDB.BsonValue]::new($LocationName) }
            if ($PSBoundParameters.ContainsKey('AddressLine1')) { $primaryLocation['AddressLine1'] = [LiteDB.BsonValue]::new($AddressLine1) }
            if ($PSBoundParameters.ContainsKey('AddressLine2')) { $primaryLocation['AddressLine2'] = [LiteDB.BsonValue]::new($AddressLine2) }
            if ($PSBoundParameters.ContainsKey('City')) { $primaryLocation['City'] = [LiteDB.BsonValue]::new($City) }
            if ($PSBoundParameters.ContainsKey('State')) { $primaryLocation['State'] = [LiteDB.BsonValue]::new($State) }
            if ($PSBoundParameters.ContainsKey('PostalCode')) { $primaryLocation['PostalCode'] = [LiteDB.BsonValue]::new($PostalCode) }
            if ($PSBoundParameters.ContainsKey('Country')) { $primaryLocation['Country'] = [LiteDB.BsonValue]::new($Country) }
            if ($PSBoundParameters.ContainsKey('PhoneNumber')) { $primaryLocation['PhoneNumber'] = [LiteDB.BsonValue]::new($PhoneNumber) }
            if ($PSBoundParameters.ContainsKey('MobileNumber')) { $primaryLocation['MobileNumber'] = [LiteDB.BsonValue]::new($MobileNumber) }
            if ($PSBoundParameters.ContainsKey('WorkPhoneNumber')) { $primaryLocation['WorkPhoneNumber'] = [LiteDB.BsonValue]::new($WorkPhoneNumber) }

            $primaryLocation['IsPrimary'] = [LiteDB.BsonValue]::new($true)
            $primaryLocation['IsDeleted'] = [LiteDB.BsonValue]::new($false)
            $primaryLocation['DeletedDate'] = [LiteDB.BsonValue]::new('')
            $primaryLocation['ModifiedDate'] = [LiteDB.BsonValue]::new((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
            [void]$locations.Update($primaryLocation)
        }

        $refreshed = @(Get-MikrotikContact -DatabasePath $DatabasePath -DisplayName (Convert-BsonValueToString -Value $contactDoc['DisplayName']) -IncludeDeleted)
        if ($refreshed.Count -gt 0) {
            return $refreshed[0]
        }

        return [PSCustomObject]@{
            ContactId           = Convert-BsonValueToString -Value $contactDoc['_id']
            DisplayName         = Convert-BsonValueToString -Value $contactDoc['DisplayName']
            ContactType         = Convert-BsonValueToString -Value $contactDoc['ContactType']
            ContactAbbreviation = Convert-BsonValueToString -Value $contactDoc['ContactAbbreviation']
            IsDeleted           = Convert-BsonValueToBoolean -Value $contactDoc['IsDeleted']
        }
    }
    catch {
        throw "Failed to update contact record: $_"
    }
    finally {
        if ($null -ne $db) {
            $db.Dispose()
        }
    }
}

# Example usage:
# PS> Set-MikrotikContact -CurrentDisplayName 'Acme Support' -NetworkConnected $true
