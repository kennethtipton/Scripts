function Get-MikrotikContactLocation {
    <#
    .SYNOPSIS
        Gets contact location records from LiteDB.
    .DESCRIPTION
        Reads contact_locations and resolves contact relations through
        contact_location_index.
    .PARAMETER DatabasePath
        Full path to the LiteDB file. Defaults to Data\MikrotikDevices.db.
    .PARAMETER ContactId
        Optional contact id filter.
    .PARAMETER DisplayName
        Optional contact display name filter that resolves to ContactId.
    .PARAMETER IncludeDeleted
        Includes soft-deleted records when specified.
    .EXAMPLE
        PS> Get-MikrotikContactLocation -DisplayName 'Acme Support'
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

        $db = [LiteDB.LiteDatabase]::new($DatabasePath)
        $contacts = $db.GetCollection('contacts')
        $locations = $db.GetCollection('contact_locations')
        $links = $db.GetCollection('contact_location_index')

        $resolvedContactId = $ContactId
        if (-not [string]::IsNullOrWhiteSpace($DisplayName)) {
            $contact = @(
                @($contacts.FindAll()) | Where-Object {
                    -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                    -not (Convert-BsonValueToBoolean -Value $_['IsDeleted']) -and
                    (Convert-BsonValueToString -Value $_['DisplayName']) -eq $DisplayName
                }
            ) | Select-Object -First 1

            if ($null -eq $contact) {
                return @()
            }

            $resolvedContactId = Convert-BsonValueToString -Value $contact['_id']
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

        if (-not [string]::IsNullOrWhiteSpace($resolvedContactId)) {
            $linkedLocationIds = @(
                $allLinks | Where-Object {
                    (Convert-BsonValueToString -Value $_['ContactId']) -eq $resolvedContactId
                } | ForEach-Object {
                    Convert-BsonValueToString -Value $_['LocationId']
                }
            )

            $allLocations = @(
                $allLocations | Where-Object {
                    $linkedLocationIds -contains (Convert-BsonValueToString -Value $_['_id'])
                }
            )
        }

        foreach ($location in $allLocations) {
            $locationId = Convert-BsonValueToString -Value $location['_id']
            $locationLinks = @(
                $allLinks | Where-Object {
                    (Convert-BsonValueToString -Value $_['LocationId']) -eq $locationId
                }
            )

            $primaryLink = $locationLinks | Where-Object {
                (Convert-BsonValueToBoolean -Value $_['IsPrimary'])
            } | Select-Object -First 1

            if ($null -eq $primaryLink) {
                $primaryLink = $locationLinks | Select-Object -First 1
            }

            [PSCustomObject]@{
                LocationId      = $locationId
                ContactId       = if ($null -ne $primaryLink) { Convert-BsonValueToString -Value $primaryLink['ContactId'] } else { '' }
                LinkedContacts  = $locationLinks.Count
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
                IsPrimary       = if ($null -ne $primaryLink) { Convert-BsonValueToBoolean -Value $primaryLink['IsPrimary'] } else { Convert-BsonValueToBoolean -Value $location['IsPrimary'] }
                CreatedDate     = Convert-BsonValueToString -Value $location['CreatedDate']
                ModifiedDate    = Convert-BsonValueToString -Value $location['ModifiedDate']
                IsDeleted       = Convert-BsonValueToBoolean -Value $location['IsDeleted']
                DeletedDate     = Convert-BsonValueToString -Value $location['DeletedDate']
            }
        }
    }
    catch {
        throw "Failed to get contact location data: $_"
    }
    finally {
        if ($null -ne $db) { $db.Dispose() }
    }
}

# Example usage:
# PS> Get-MikrotikContactLocation -DisplayName 'Acme Support'
