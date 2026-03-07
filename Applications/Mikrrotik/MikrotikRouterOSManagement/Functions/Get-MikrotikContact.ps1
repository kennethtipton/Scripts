function Get-MikrotikContact {
    <#
    .SYNOPSIS
        Gets contact records from LiteDB.
    .DESCRIPTION
        Reads contact records from contacts and resolves location/phone data
        through contact_location_index and contact_locations.
    .PARAMETER DatabasePath
        Full path to the LiteDB file. Defaults to Data\MikrotikDevices.db.
    .PARAMETER DisplayName
        Optional display name filter.
    .PARAMETER IncludeDeleted
        Includes soft-deleted records when specified.
    .EXAMPLE
        PS> Get-MikrotikContact
    .EXAMPLE
        PS> Get-MikrotikContact -DisplayName 'Acme Support'
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
        [string]$DisplayName,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeDeleted
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

        $contactRecords = @(
            @($contacts.FindAll()) | Where-Object {
                -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate'])
            }
        )

        if (-not [string]::IsNullOrWhiteSpace($DisplayName)) {
            $contactRecords = @(
                $contactRecords | Where-Object {
                    (Convert-BsonValueToString -Value $_['DisplayName']) -eq $DisplayName
                }
            )
        }

        if (-not $IncludeDeleted.IsPresent) {
            $contactRecords = @(
                $contactRecords | Where-Object {
                    -not (Convert-BsonValueToBoolean -Value $_['IsDeleted'])
                }
            )
        }

        $allLocations = @(
            @($locations.FindAll()) | Where-Object {
                -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                ($IncludeDeleted.IsPresent -or -not (Convert-BsonValueToBoolean -Value $_['IsDeleted']))
            }
        )

        $allLinks = @(
            @($links.FindAll()) | Where-Object {
                -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                ($IncludeDeleted.IsPresent -or -not (Convert-BsonValueToBoolean -Value $_['IsDeleted']))
            }
        )

        foreach ($contactRecord in $contactRecords) {
            $contactId = Convert-BsonValueToString -Value $contactRecord['_id']

            $contactLinks = @(
                $allLinks | Where-Object {
                    (Convert-BsonValueToString -Value $_['ContactId']) -eq $contactId
                }
            )

            $primaryLink = $contactLinks | Where-Object {
                (Convert-BsonValueToBoolean -Value $_['IsPrimary'])
            } | Select-Object -First 1

            if ($null -eq $primaryLink) {
                $primaryLink = $contactLinks | Select-Object -First 1
            }

            $primaryLocation = $null
            if ($null -ne $primaryLink) {
                $locationId = Convert-BsonValueToString -Value $primaryLink['LocationId']
                $primaryLocation = $allLocations | Where-Object {
                    (Convert-BsonValueToString -Value $_['_id']) -eq $locationId
                } | Select-Object -First 1
            }

            if ($null -eq $primaryLocation) {
                $primaryLocation = [LiteDB.BsonDocument]::new()
            }

            [PSCustomObject]@{
                ContactId              = $contactId
                DisplayName            = Convert-BsonValueToString -Value $contactRecord['DisplayName']
                FirstName              = Convert-BsonValueToString -Value $contactRecord['FirstName']
                LastName               = Convert-BsonValueToString -Value $contactRecord['LastName']
                JobTitle               = Convert-BsonValueToString -Value $contactRecord['JobTitle']
                Department             = Convert-BsonValueToString -Value $contactRecord['Department']
                Company                = Convert-BsonValueToString -Value $contactRecord['Company']
                EmailAddress           = Convert-BsonValueToString -Value $contactRecord['EmailAddress']
                AlternateEmailAddress  = Convert-BsonValueToString -Value $contactRecord['AlternateEmailAddress']
                PhoneNumber            = Convert-BsonValueToString -Value $primaryLocation['PhoneNumber']
                MobileNumber           = Convert-BsonValueToString -Value $primaryLocation['MobileNumber']
                WorkPhoneNumber        = Convert-BsonValueToString -Value $primaryLocation['WorkPhoneNumber']
                AddressLine1           = Convert-BsonValueToString -Value $primaryLocation['AddressLine1']
                AddressLine2           = Convert-BsonValueToString -Value $primaryLocation['AddressLine2']
                City                   = Convert-BsonValueToString -Value $primaryLocation['City']
                State                  = Convert-BsonValueToString -Value $primaryLocation['State']
                PostalCode             = Convert-BsonValueToString -Value $primaryLocation['PostalCode']
                Country                = Convert-BsonValueToString -Value $primaryLocation['Country']
                PrimaryLocationName    = Convert-BsonValueToString -Value $primaryLocation['LocationName']
                LocationCount          = $contactLinks.Count
                Website                = Convert-BsonValueToString -Value $contactRecord['Website']
                Notes                  = Convert-BsonValueToString -Value $contactRecord['Notes']
                ContactType            = Convert-BsonValueToString -Value $contactRecord['ContactType']
                NetworkConnected       = Convert-BsonValueToBoolean -Value $contactRecord['NetworkConnected']
                ContactAbbreviation    = Convert-BsonValueToString -Value $contactRecord['ContactAbbreviation']
                CreatedDate            = Convert-BsonValueToString -Value $contactRecord['CreatedDate']
                ModifiedDate           = Convert-BsonValueToString -Value $contactRecord['ModifiedDate']
                IsDeleted              = Convert-BsonValueToBoolean -Value $contactRecord['IsDeleted']
                DeletedDate            = Convert-BsonValueToString -Value $contactRecord['DeletedDate']
            }
        }
    }
    catch {
        throw "Failed to get contact data: $_"
    }
    finally {
        if ($null -ne $db) {
            $db.Dispose()
        }
    }
}

# Example usage:
# PS> Get-MikrotikContact
# PS> Get-MikrotikContact -DisplayName 'Acme Support'
# PS> Get-MikrotikContact -IncludeDeleted
