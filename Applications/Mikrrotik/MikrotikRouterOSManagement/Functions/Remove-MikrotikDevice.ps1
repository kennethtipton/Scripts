function Remove-MikrotikDevice {
    <#
    .SYNOPSIS
        Soft-deletes a MikroTik device record in LiteDB.
    .DESCRIPTION
        Marks a device inventory entry as deleted by RouterIdentityHostname
        in the mikrotik_devices collection. Records are not physically removed.
    .PARAMETER RouterIdentityHostname
        Router identity/hostname to soft-delete.
    .PARAMETER DatabasePath
        Full path to the LiteDB file. Defaults to Data\MikrotikDevices.db.
    .EXAMPLE
        PS> Remove-MikrotikDevice -RouterIdentityHostname 'R1'
    .INPUTS
        None.
    .OUTPUTS
        Boolean.
    .NOTES
        Author: Kenneth Tipton
        Company: TNC
        Date: 2026-03-06
        Version: 1.0.0
        Function Or Application: Function
    .LINK
        https://www.tnandc.com
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RouterIdentityHostname,

        [Parameter(Mandatory = $false)]
        [string]$DatabasePath = (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Data\MikrotikDevices.db')
    )

    $db = $null

    function Convert-BsonValueToString {
        param([LiteDB.BsonValue]$Value)

        if ($null -eq $Value -or $Value.IsNull) {
            return ''
        }

        if ($Value.IsString) {
            return $Value.AsString
        }

        return $Value.ToString()
    }

    function Convert-BsonValueToBoolean {
        param([LiteDB.BsonValue]$Value)

        if ($null -eq $Value -or $Value.IsNull) {
            return $false
        }

        if ($Value.IsBoolean) {
            return $Value.AsBoolean
        }

        $parsed = $false
        if ([bool]::TryParse($Value.ToString(), [ref]$parsed)) {
            return $parsed
        }

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
        $collection = $db.GetCollection('mikrotik_devices')

        $document = @($collection.FindAll()) | Where-Object {
            (Convert-BsonValueToString -Value $_['RouterIdentityHostname']) -eq $RouterIdentityHostname -and
            -not (Convert-BsonValueToBoolean -Value $_['IsDeleted'])
        } | Select-Object -First 1
        if ($null -eq $document) {
            return $false
        }

        if ($PSCmdlet.ShouldProcess("MikrotikDevice:$RouterIdentityHostname", 'Soft-delete record')) {
            $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $document['IsDeleted'] = [LiteDB.BsonValue]::new($true)
            $document['DeletedDate'] = [LiteDB.BsonValue]::new($timestamp)
            $document['ModifiedDate'] = [LiteDB.BsonValue]::new($timestamp)
            [void]$collection.Update($document)
            return $true
        }

        return $false
    }
    catch {
        throw "Failed to remove MikroTik device record: $_"
    }
    finally {
        if ($null -ne $db) {
            $db.Dispose()
        }
    }
}

# Example usage:
# PS> Remove-MikrotikDevice -RouterIdentityHostname 'R1' -Confirm:$false
