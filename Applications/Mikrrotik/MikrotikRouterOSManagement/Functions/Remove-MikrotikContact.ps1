function Remove-MikrotikContact {
    <#
    .SYNOPSIS
        Soft-deletes a contact record in LiteDB.
    .DESCRIPTION
        Marks the contact as deleted and soft-deletes relation rows in
        contact_location_index. Linked locations are also soft-deleted when
        no other active contact links remain.
    .PARAMETER DisplayName
        Display name to soft-delete.
    .PARAMETER DatabasePath
        Full path to the LiteDB file. Defaults to Data\MikrotikDevices.db.
    .EXAMPLE
        PS> Remove-MikrotikContact -DisplayName 'Acme Support'
    .INPUTS
        None.
    .OUTPUTS
        Boolean.
    .NOTES
        Author: Kenneth Tipton
        Company: TNC
        Date: 2026-03-07
        Version: 2.0.0
        Function Or Application: Function
    .LINK
        https://www.tnandc.com
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DisplayName,

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
        if (-not (Test-Path -Path $liteDbDllPath -PathType Leaf)) { throw "LiteDB.dll not found at '$liteDbDllPath'." }
        if (-not ('LiteDB.LiteDatabase' -as [type])) { Add-Type -Path $liteDbDllPath -ErrorAction Stop }

        $db = [LiteDB.LiteDatabase]::new($DatabasePath)
        $contacts = $db.GetCollection('contacts')
        $locations = $db.GetCollection('contact_locations')
        $links = $db.GetCollection('contact_location_index')

        $contact = @(
            @($contacts.FindAll()) | Where-Object {
                -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                (Convert-BsonValueToString -Value $_['DisplayName']) -eq $DisplayName -and
                -not (Convert-BsonValueToBoolean -Value $_['IsDeleted'])
            }
        ) | Select-Object -First 1

        if ($null -eq $contact) {
            return $false
        }

        if ($PSCmdlet.ShouldProcess("MikrotikContact:$DisplayName", 'Soft-delete contact')) {
            $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $contactId = Convert-BsonValueToString -Value $contact['_id']

            $contact['IsDeleted'] = [LiteDB.BsonValue]::new($true)
            $contact['DeletedDate'] = [LiteDB.BsonValue]::new($timestamp)
            $contact['ModifiedDate'] = [LiteDB.BsonValue]::new($timestamp)
            [void]$contacts.Update($contact)

            $contactLinks = @(
                @($links.FindAll()) | Where-Object {
                    -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                    (Convert-BsonValueToString -Value $_['ContactId']) -eq $contactId -and
                    -not (Convert-BsonValueToBoolean -Value $_['IsDeleted'])
                }
            )

            foreach ($link in $contactLinks) {
                $link['IsDeleted'] = [LiteDB.BsonValue]::new($true)
                $link['DeletedDate'] = [LiteDB.BsonValue]::new($timestamp)
                $link['ModifiedDate'] = [LiteDB.BsonValue]::new($timestamp)
                [void]$links.Update($link)

                $locationId = Convert-BsonValueToString -Value $link['LocationId']
                if ([string]::IsNullOrWhiteSpace($locationId)) { continue }

                $otherActiveLinks = @(
                    @($links.FindAll()) | Where-Object {
                        -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                        (Convert-BsonValueToString -Value $_['LocationId']) -eq $locationId -and
                        -not (Convert-BsonValueToBoolean -Value $_['IsDeleted'])
                    }
                )

                if ($otherActiveLinks.Count -eq 0) {
                    $location = @(
                        @($locations.FindAll()) | Where-Object {
                            -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                            (Convert-BsonValueToString -Value $_['_id']) -eq $locationId -and
                            -not (Convert-BsonValueToBoolean -Value $_['IsDeleted'])
                        }
                    ) | Select-Object -First 1

                    if ($null -ne $location) {
                        $location['IsDeleted'] = [LiteDB.BsonValue]::new($true)
                        $location['DeletedDate'] = [LiteDB.BsonValue]::new($timestamp)
                        $location['ModifiedDate'] = [LiteDB.BsonValue]::new($timestamp)
                        [void]$locations.Update($location)
                    }
                }
            }

            return $true
        }

        return $false
    }
    catch {
        throw "Failed to remove contact record: $_"
    }
    finally {
        if ($null -ne $db) { $db.Dispose() }
    }
}

# Example usage:
# PS> Remove-MikrotikContact -DisplayName 'Acme Support' -Confirm:$false
