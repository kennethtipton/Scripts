function New-MikrotikContact {
    <#
    .SYNOPSIS
        Creates a new contact record in LiteDB.
    .DESCRIPTION
        Inserts a contact into contacts and optionally creates an initial
        linked location in contact_locations through contact_location_index.
    .PARAMETER DisplayName
        Display name for the contact.
    .PARAMETER ContactType
        Contact type. Allowed values are Vendor or Company.
    .PARAMETER NetworkConnected
        Indicates whether the contact is network connected. Default is false.
    .PARAMETER ContactAbbreviation
        Short contact abbreviation.
    .PARAMETER DatabasePath
        Full path to the LiteDB file. Defaults to Data\MikrotikDevices.db.
    .EXAMPLE
        PS> New-MikrotikContact -DisplayName 'Acme Support' -ContactType Vendor
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
        [string]$LocationName = 'Primary',

        [Parameter(Mandatory = $false)]
        [string]$Website,

        [Parameter(Mandatory = $false)]
        [string]$Notes,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Person', 'Company', 'Vendor')]
        [string]$ContactType = 'Vendor',

        [Parameter(Mandatory = $false)]
        [bool]$NetworkConnected = $false,

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
        $contacts = $db.GetCollection('contacts')
        $locations = $db.GetCollection('contact_locations')
        $links = $db.GetCollection('contact_location_index')

        $companyText = ([string]$Company).Trim()
        $firstNameText = ([string]$FirstName).Trim()
        $lastNameText = ([string]$LastName).Trim()
        $fullNameText = @($firstNameText, $lastNameText) -ne ''
        $fullNameText = ($fullNameText -join ' ').Trim()

        $effectiveDisplayName = ([string]$DisplayName).Trim()
        if ([string]::IsNullOrWhiteSpace($effectiveDisplayName)) {
            if (-not [string]::IsNullOrWhiteSpace($companyText)) {
                if (-not [string]::IsNullOrWhiteSpace($fullNameText)) {
                    $effectiveDisplayName = "$companyText ($fullNameText)"
                }
                else {
                    $effectiveDisplayName = $companyText
                }
            }
            elseif (-not [string]::IsNullOrWhiteSpace($fullNameText)) {
                $effectiveDisplayName = $fullNameText
            }
        }

        if ([string]::IsNullOrWhiteSpace($effectiveDisplayName)) {
            throw 'DisplayName is required, or provide Company and/or FirstName/LastName so DisplayName can be generated automatically.'
        }

        $existingDisplayName = @(
            @($contacts.FindAll()) | Where-Object {
                -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                (Convert-BsonValueToString -Value $_['DisplayName']) -eq $effectiveDisplayName -and
                -not (Convert-BsonValueToBoolean -Value $_['IsDeleted'])
            }
        ) | Select-Object -First 1

        if ($null -ne $existingDisplayName) {
            throw "A contact already exists with DisplayName '$effectiveDisplayName'."
        }

        if (-not [string]::IsNullOrWhiteSpace($ContactAbbreviation)) {
            $existingAbbreviation = @(
                @($contacts.FindAll()) | Where-Object {
                    -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                    (Convert-BsonValueToString -Value $_['ContactAbbreviation']) -eq $ContactAbbreviation -and
                    -not (Convert-BsonValueToBoolean -Value $_['IsDeleted'])
                }
            ) | Select-Object -First 1

            if ($null -ne $existingAbbreviation) {
                throw "A contact already exists with ContactAbbreviation '$ContactAbbreviation'."
            }
        }

        $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $contactId = [Guid]::NewGuid().ToString()

        $contactDoc = [LiteDB.BsonDocument]::new()
        $contactDoc['_id'] = [LiteDB.BsonValue]::new($contactId)
        $contactDoc['DisplayName'] = [LiteDB.BsonValue]::new($effectiveDisplayName)
        $contactDoc['FirstName'] = [LiteDB.BsonValue]::new($FirstName)
        $contactDoc['LastName'] = [LiteDB.BsonValue]::new($LastName)
        $contactDoc['JobTitle'] = [LiteDB.BsonValue]::new($JobTitle)
        $contactDoc['Department'] = [LiteDB.BsonValue]::new($Department)
        $contactDoc['Company'] = [LiteDB.BsonValue]::new($Company)
        $contactDoc['EmailAddress'] = [LiteDB.BsonValue]::new($EmailAddress)
        $contactDoc['AlternateEmailAddress'] = [LiteDB.BsonValue]::new($AlternateEmailAddress)
        $contactDoc['Website'] = [LiteDB.BsonValue]::new($Website)
        $contactDoc['Notes'] = [LiteDB.BsonValue]::new($Notes)
        $contactDoc['ContactType'] = [LiteDB.BsonValue]::new($ContactType)
        $contactDoc['NetworkConnected'] = [LiteDB.BsonValue]::new($NetworkConnected)
        $contactDoc['ContactAbbreviation'] = [LiteDB.BsonValue]::new($ContactAbbreviation)
        $contactDoc['CreatedDate'] = [LiteDB.BsonValue]::new($timestamp)
        $contactDoc['ModifiedDate'] = [LiteDB.BsonValue]::new($timestamp)
        $contactDoc['IsDeleted'] = [LiteDB.BsonValue]::new($false)
        $contactDoc['DeletedDate'] = [LiteDB.BsonValue]::new('')
        $contactDoc['IsSchemaTemplate'] = [LiteDB.BsonValue]::new($false)

        [void]$contacts.Insert($contactDoc)

        $hasLocationData =
            -not [string]::IsNullOrWhiteSpace($AddressLine1) -or
            -not [string]::IsNullOrWhiteSpace($AddressLine2) -or
            -not [string]::IsNullOrWhiteSpace($City) -or
            -not [string]::IsNullOrWhiteSpace($State) -or
            -not [string]::IsNullOrWhiteSpace($PostalCode) -or
            -not [string]::IsNullOrWhiteSpace($Country) -or
            -not [string]::IsNullOrWhiteSpace($PhoneNumber) -or
            -not [string]::IsNullOrWhiteSpace($MobileNumber) -or
            -not [string]::IsNullOrWhiteSpace($WorkPhoneNumber)

        if ($hasLocationData) {
            $locationId = [Guid]::NewGuid().ToString()

            $locationDoc = [LiteDB.BsonDocument]::new()
            $locationDoc['_id'] = [LiteDB.BsonValue]::new($locationId)
            $locationDoc['LocationName'] = [LiteDB.BsonValue]::new($LocationName)
            $locationDoc['AddressLine1'] = [LiteDB.BsonValue]::new($AddressLine1)
            $locationDoc['AddressLine2'] = [LiteDB.BsonValue]::new($AddressLine2)
            $locationDoc['City'] = [LiteDB.BsonValue]::new($City)
            $locationDoc['State'] = [LiteDB.BsonValue]::new($State)
            $locationDoc['PostalCode'] = [LiteDB.BsonValue]::new($PostalCode)
            $locationDoc['Country'] = [LiteDB.BsonValue]::new($Country)
            $locationDoc['PhoneNumber'] = [LiteDB.BsonValue]::new($PhoneNumber)
            $locationDoc['MobileNumber'] = [LiteDB.BsonValue]::new($MobileNumber)
            $locationDoc['WorkPhoneNumber'] = [LiteDB.BsonValue]::new($WorkPhoneNumber)
            $locationDoc['IsPrimary'] = [LiteDB.BsonValue]::new($true)
            $locationDoc['IsSchemaTemplate'] = [LiteDB.BsonValue]::new($false)
            $locationDoc['CreatedDate'] = [LiteDB.BsonValue]::new($timestamp)
            $locationDoc['ModifiedDate'] = [LiteDB.BsonValue]::new($timestamp)
            $locationDoc['IsDeleted'] = [LiteDB.BsonValue]::new($false)
            $locationDoc['DeletedDate'] = [LiteDB.BsonValue]::new('')
            [void]$locations.Insert($locationDoc)

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
            [void]$links.Insert($linkDoc)
        }

        return [PSCustomObject]@{
            ContactId              = $contactId
            DisplayName            = $effectiveDisplayName
            FirstName              = $FirstName
            LastName               = $LastName
            JobTitle               = $JobTitle
            Department             = $Department
            Company                = $Company
            EmailAddress           = $EmailAddress
            AlternateEmailAddress  = $AlternateEmailAddress
            Website                = $Website
            Notes                  = $Notes
            ContactType            = $ContactType
            NetworkConnected       = $NetworkConnected
            ContactAbbreviation    = $ContactAbbreviation
            CreatedDate            = $timestamp
            ModifiedDate           = $timestamp
            IsDeleted              = $false
            DeletedDate            = ''
        }
    }
    catch {
        throw "Failed to create contact record: $_"
    }
    finally {
        if ($null -ne $db) {
            $db.Dispose()
        }
    }
}

# Example usage:
# PS> New-MikrotikContact -DisplayName 'Acme Support' -ContactType Vendor
