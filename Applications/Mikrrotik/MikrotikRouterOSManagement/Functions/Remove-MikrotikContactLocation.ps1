function Remove-MikrotikContactLocation {
    <#
    .SYNOPSIS
        Soft-deletes a contact location and related links.
    .DESCRIPTION
        Marks a location as deleted. By default it also soft-deletes all
        relationship rows in contact_location_index for that location.
    .PARAMETER DatabasePath
        Full path to the LiteDB file. Defaults to Data\MikrotikDevices.db.
    .PARAMETER LocationId
        Required location id to remove.
    .PARAMETER KeepLinks
        Keeps relationship rows active when specified.
    .EXAMPLE
        PS> Remove-MikrotikContactLocation -LocationId 'loc1'
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
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $false)]
        [string]$DatabasePath = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Data\MikrotikDevices.db'),

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LocationId,

        [Parameter(Mandatory = $false)]
        [switch]$KeepLinks
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

        if ($PSCmdlet.ShouldProcess("MikrotikContactLocation:$LocationId", 'Soft-delete location')) {
            $now = [DateTime]::UtcNow.ToString('o')
            $location['IsDeleted'] = [LiteDB.BsonValue]::new($true)
            $location['DeletedDate'] = [LiteDB.BsonValue]::new($now)
            $location['ModifiedDate'] = [LiteDB.BsonValue]::new($now)
            [void]$locations.Update($location)

            $affectedLinks = 0
            if (-not $KeepLinks.IsPresent) {
                $locationLinks = @(
                    @($links.FindAll()) | Where-Object {
                        -not (Convert-BsonValueToBoolean -Value $_['IsSchemaTemplate']) -and
                        (Convert-BsonValueToString -Value $_['LocationId']) -eq $LocationId
                    }
                )

                foreach ($row in $locationLinks) {
                    $row['IsDeleted'] = [LiteDB.BsonValue]::new($true)
                    $row['DeletedDate'] = [LiteDB.BsonValue]::new($now)
                    $row['ModifiedDate'] = [LiteDB.BsonValue]::new($now)
                    [void]$links.Update($row)
                    $affectedLinks++
                }
            }

            return [PSCustomObject]@{
                LocationId      = $LocationId
                IsDeleted       = $true
                DeletedDate     = $now
                LinksUpdated    = $affectedLinks
                KeepLinks       = $KeepLinks.IsPresent
            }
        }

        return $false
    }
    catch {
        throw "Failed to remove contact location: $_"
    }
    finally {
        if ($null -ne $db) { $db.Dispose() }
    }
}

# Example usage:
# PS> Remove-MikrotikContactLocation -LocationId 'loc1'
