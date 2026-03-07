function Restore-MikrotikContact {
    <#
    .SYNOPSIS
        Restores a soft-deleted contact record in LiteDB.
    .DESCRIPTION
        Marks the contact as active and restores relation rows in
        contact_location_index and linked locations.
    .PARAMETER DisplayName
        Display name to restore.
    .PARAMETER DatabasePath
        Full path to the LiteDB file. Defaults to Data\MikrotikDevices.db.
    .EXAMPLE
        PS> Restore-MikrotikContact -DisplayName 'Acme Support'
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
                (Convert-BsonValueToBoolean -Value $_['IsDeleted'])
            }
        ) | Select-Object -First 1

        if ($null -eq $contact) {
            return $false
        }

        if ($PSCmdlet.ShouldProcess("MikrotikContact:$DisplayName", 'Restore contact')) {
            $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $contactId = Convert-BsonValueToString -Value $contact['_id']

            $contact['IsDeleted'] = [LiteDB.BsonValue]::new($false)
            $contact['DeletedDate'] = [LiteDB.BsonValue]::new('')
            $contact['ModifiedDate'] = [LiteDB.BsonValue]::new($timestamp)
            [void]$contacts.Update($contact)

            $contactLinks = @(
                @($links.FindAll()) | Where-Object {
                    -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                    (Convert-BsonValueToString -Value $_['ContactId']) -eq $contactId
                }
            )

            foreach ($link in $contactLinks) {
                $link['IsDeleted'] = [LiteDB.BsonValue]::new($false)
                $link['DeletedDate'] = [LiteDB.BsonValue]::new('')
                $link['ModifiedDate'] = [LiteDB.BsonValue]::new($timestamp)
                [void]$links.Update($link)

                $locationId = Convert-BsonValueToString -Value $link['LocationId']
                if ([string]::IsNullOrWhiteSpace($locationId)) { continue }

                $location = @(
                    @($locations.FindAll()) | Where-Object {
                        -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                        (Convert-BsonValueToString -Value $_['_id']) -eq $locationId
                    }
                ) | Select-Object -First 1

                if ($null -ne $location) {
                    $location['IsDeleted'] = [LiteDB.BsonValue]::new($false)
                    $location['DeletedDate'] = [LiteDB.BsonValue]::new('')
                    $location['ModifiedDate'] = [LiteDB.BsonValue]::new($timestamp)
                    [void]$locations.Update($location)
                }
            }

            return $true
        }

        return $false
    }
    catch {
        throw "Failed to restore contact record: $_"
    }
    finally {
        if ($null -ne $db) { $db.Dispose() }
    }
}

# Example usage:
# PS> Restore-MikrotikContact -DisplayName 'Acme Support' -Confirm:$false
