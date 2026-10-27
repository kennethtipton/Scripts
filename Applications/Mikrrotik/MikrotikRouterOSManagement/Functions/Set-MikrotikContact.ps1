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


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAPi1EIIe/CawyJ
# iSXJM2z9LPA1tfUGzEdysYkwftZ+9KCCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
# 5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBa
# Fw0zMTExMDkyMzU5NTlaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lD
# ZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBAL/mkHNo3rvkXUo8MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3E
# MB/zG6Q4FutWxpdtHauyefLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKy
# unWZanMylNEQRBAu34LzB4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsF
# xl7sWxq868nPzaw0QF+xembud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU1
# 5zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJB
# MtfbBHMqbpEBfCFM1LyuGwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObUR
# WBf3JFxGj2T3wWmIdph2PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6
# nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxB
# YKqxYxhElRp2Yn72gLD76GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5S
# UUd0viastkF13nqsX40/ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+x
# q4aLT8LWRV+dIPyhHsXAj6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIB
# NjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwP
# TzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMC
# AYYweQYIKwYBBQUHAQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdp
# Y2VydC5jb20wQwYIKwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNv
# bS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0
# aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENB
# LmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0Nc
# Vec4X6CjdBs9thbX979XB72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnov
# Lbc47/T/gLn4offyct4kvFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65Zy
# oUi0mcudT6cGAxN3J0TU53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFW
# juyk1T3osdz9HNj0d1pcVIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPF
# mCLBsln1VWvPJ6tsds5vIy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9z
# twGpn1eqXijiuZQwgga0MIIEnKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqG
# SIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRy
# dXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYg
# MjAyNSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphB
# cr48RsAcrHXbo0ZodLRRF51NrY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6p
# vF4uGjwjqNjfEvUi6wuim5bap+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHe
# HYNnQxqXmRinvuNgxVBdJkf77S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEd
# gkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjU
# jsZvkgFkriK9tUKJm/s80FiocSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bR
# VFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeS
# LsJygoLPp66bkDX1ZlAeSpQl92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIV
# NSaz7BX8VtYGqLt9MmeOreGPRdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL
# 6s36czwzsucuoKs7Yk/ehb//Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2Zd
# SoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFU
# eEY0qVjPKOWug/G6X5uAiynM7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/
# BAgwBgEB/wIBADAdBgNVHQ4EFgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0j
# BBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0
# cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0
# cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8E
# PDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVz
# dGVkUm9vdEc0LmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEw
# DQYJKoZIhvcNAQELBQADggIBABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/
# T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQ
# E7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9r
# EVKChHyfpzee5kH0F8HABBgr0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y
# 1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gx
# dEkMx1NKU4uHQcKfZxAvBAKqMVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3t
# y9qIijanrUR3anzEwlvzZiiyfTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcy
# tL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEB
# YTptMSbhdhGQDpOXgpIUsWTjd6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud
# /v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiS
# uEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZP
# ubdcMIIG6DCCBNCgAwIBAgITQAAAAqtBkGO1asEvkAAAAAACqzANBgkqhkiG9w0B
# AQsFADBwMRMwEQYKCZImiZPyLGQBGRYDY29tMSIwIAYKCZImiZPyLGQBGRYSZ2Vu
# ZXJhdGlvbnNnYWl0aGVyMTUwMwYDVQQDEyxnZW5lcmF0aW9uc2dhaXRoZXItU1JW
# MDEwMDEwMDM4MDM1LUlzc3VpbmdDQTAeFw0yNjA4MjAxNzMzNTRaFw0yNzAxMzEx
# NzI3MjVaMDgxFDASBgNVBAoTC0dlbmVyYXRpb25zMSAwHgYDVQQDExdQb3dlcnNo
# ZWxsIENvZGUgU2lnbmluZzCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEB
# AMgHhkqXmzDlBuov3PJaCmpZddU3S+1mt4Yaahz121grfW1H+nHXf2cUuzH12wzG
# ErW+kF0lqkBll/26aHzETnBepOxaP+KCoKZ7db4mYctch5wdDTANplQu35hPEO6I
# yNhrEk5UQqAjM9ONKCdWkzBo+/vaTbQDpYwc7h2s1s8dZdjU4tqy72+ThXEx8Vp3
# OePAXZ1moCIPXuhjSEoCMasqIuWDwavRRLXONBrhhue84FPyFa7qpTOz7Hg98DfW
# pMA+ZIXl/KJVlRdN5H8b0IZiWczfHUyz76fw67tzngUR7CI2xeTkdSpJ1dl2O+Xi
# T33pvcVEnjq/Pql0rddXBbUCAwEAAaOCArEwggKtMD0GCSsGAQQBgjcVBwQwMC4G
# JisGAQQBgjcVCIK0njms71qCqYE6gt6kboK4gAOBOIO8mwSBh4VAAgFkAgEDMBMG
# A1UdJQQMMAoGCCsGAQUFBwMDMA4GA1UdDwEB/wQEAwIHgDAbBgkrBgEEAYI3FQoE
# DjAMMAoGCCsGAQUFBwMDMB0GA1UdDgQWBBRT5Uu5LaLJBCLOFGRaVsipJu+gMjAf
# BgNVHSMEGDAWgBROXx35Y5WKLzaZqCYJ3GvzXL4RnDCB/QYDVR0fBIH1MIHyMIHv
# oIHsoIHphoHmbGRhcDovLy9DTj1nZW5lcmF0aW9uc2dhaXRoZXItU1JWMDEwMDEw
# MDM4MDM1LUlzc3VpbmdDQSxDTj1zcnYwMTAwMTAwMzgwMzUsQ049Q0RQLENOPVB1
# YmxpYyUyMEtleSUyMFNlcnZpY2VzLENOPVNlcnZpY2VzLENOPUNvbmZpZ3VyYXRp
# b24sREM9Z2VuZXJhdGlvbnNnYWl0aGVyLERDPWNvbT9jZXJ0aWZpY2F0ZVJldm9j
# YXRpb25MaXN0P2Jhc2U/b2JqZWN0Q2xhc3M9Y1JMRGlzdHJpYnV0aW9uUG9pbnQw
# gekGCCsGAQUFBwEBBIHcMIHZMIHWBggrBgEFBQcwAoaByWxkYXA6Ly8vQ049Z2Vu
# ZXJhdGlvbnNnYWl0aGVyLVNSVjAxMDAxMDAzODAzNS1Jc3N1aW5nQ0EsQ049QUlB
# LENOPVB1YmxpYyUyMEtleSUyMFNlcnZpY2VzLENOPVNlcnZpY2VzLENOPUNvbmZp
# Z3VyYXRpb24sREM9Z2VuZXJhdGlvbnNnYWl0aGVyLERDPWNvbT9jQUNlcnRpZmlj
# YXRlP2Jhc2U/b2JqZWN0Q2xhc3M9Y2VydGlmaWNhdGlvbkF1dGhvcml0eTANBgkq
# hkiG9w0BAQsFAAOCAgEAAHvAjyztTm9FmITG34NV4dx+megfwLzllxDHlShSacUx
# XzEPlVd4XScO3O1a+0sngL1XuE8xVDBe6suITmBjbN/BYo8vRjbIUlwUYE54FhRD
# rUOHYYEIecLI1ax1qpnS19Fy8YIOu7y14R2NwbY38uNZ7UDb5TBGiwJdHR+jlQVX
# Qyu0gONFsaP/mqeFKqkOKAQ0UWo38Q6U/4zJ5I9nuiHULQWqEiUEF0kTEudFWwhP
# hiwGjiIRGzmpJtiMuffHRk2kDk3wXcFyR4cjtkQjXqq3crMRnxoC3FohGFL4EmXe
# 3knNDtgR3ODvE0zrzHiPCBeF/goZ5p+/6v35xfCLPDRzXCz1FC3U6/VVomuLf5ln
# m6tO0+X9iFFi2LsnvYi6omNesi+qBRQcXq0uPbK8eA/grIk4+zVVooM2Dc9diS0C
# hwoFqMV0t0H3lpdmCXCLIqYaqO4FwxTy1Mm/Q6PZHPD/Uxq8QUPeOtvD5x7RsNRw
# zT+yaU73mqtqPc/lrcG6SRWd3jE79GbkGM3n+0FfD097Ks0lk/U820Is++u/8gPV
# kEe2UePSM2XYc4CYUlPYStlcyMh1t44TX/5l6qypJBehjdzYnvMe2ZRDL3SmPj4K
# AJiHANKMgoKK9GSW3qCeXMT+qevxRBKnhkBJcBYn/mHIMhHbwSwSTxU0mW+ggLMw
# ggbtMIIE1aADAgECAhAIT9wzT35FTtvDD4/5khg1MA0GCSqGSIb3DQEBCwUAMGkx
# CzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4
# RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYg
# MjAyNSBDQTEwHhcNMjYwODA1MDAwMDAwWhcNMzcxMTA0MjM1OTU5WjBjMQswCQYD
# VQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lD
# ZXJ0IFNIQTI1NiBSU0E0MDk2IFRpbWVzdGFtcCBSZXNwb25kZXIgMjAyNiAxMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtnum8sn+zUr41JtMZbP9OMYw
# +HwJDpG5xkIu/lqcfNYmMX81YmsUiHLbh9ykpeWBGKTLhYBrAN9Tdg/QEzG32XcO
# bmgIblnr0CoQ3WSAeDZ6nH6X6VkFyYkJw3QBJREwvm4UhLzSxmwPA7cFKRTEOMsm
# EEj6qJk/dqLEAL+oQYuOwE2UuiX1Vnul8YReIyWd4kgLn9gq6LNXM0UplkR6jL/Q
# Hxmb6fMoGBJYbnaUI7XD6cKDpekK2SVMld4iDbzeHDtOaaxldH5IxuNusQ69nd8/
# ZXEiB5Hbxj3RlK13cX1W4DlFXKdv/CEhM8Cj1vvlmvhNroyPdRGbbpBlgyf8Wdu5
# N6ByhFwURn0U6ozlPoxN22v+fviUhP+6DR547OZnpBMWDfei1f5sVGwiiW/KQTWO
# K97g+4RJpPzPNV4VYMAwO2jM2Aty2QYPVmOQTJm0msuXnJrSbl2gf9JylpkJlWXq
# k1Q4LJsxz+TELoQCZIljbgvTJgoPU2R12ydv8i1UqL/adelA0y7U9Pmmtbze9Xx3
# rtajC5SzQd1jgfwAwsa90v9YcSPdmeoyoBBA/27cCL237l5DTYYPDLQ4ON3OLTGW
# nvRb6jDrf/T75gMRfUzSLCBQfBusm9+mSWRlC/Df6S/e9Q8i13CuhzOT2Jx+V/nl
# bXM4QoBwlUAhelwwJT0CAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQCMAAwHQYDVR0O
# BBYEFBTJY4owLtRK+26U8+bjQH717M3iMB8GA1UdIwQYMBaAFO9vU0rp5AZ8esri
# kFb2L9RJ7MtOMA4GA1UdDwEB/wQEAwIHgDAWBgNVHSUBAf8EDDAKBggrBgEFBQcD
# CDCBlQYIKwYBBQUHAQEEgYgwgYUwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRp
# Z2ljZXJ0LmNvbTBdBggrBgEFBQcwAoZRaHR0cDovL2NhY2VydHMuZGlnaWNlcnQu
# Y29tL0RpZ2lDZXJ0VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIw
# MjVDQTEuY3J0MF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYy
# MDI1Q0ExLmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJ
# KoZIhvcNAQELBQADggIBAI3FOmEenVIK35msCYB+fShAsWvSYvLBItoNdAgQ2jIq
# rGsVsluXMJU/+mRebBc52s6lbKAvOVPXaizmKkMLLflEEKDZQx4CkS2t8aHPjkXh
# a3hYZ010htFa3dhNgmalH5vuWvh3tTCf4frTS7gPtGc4Z/xaPhQ2AB1mR8eEe/Wb
# H0RWHvVIl6VwQ3+g5FKNfN2N/DWJkf13w2H+2GfqEfbd35Ww8CvoYBjLNIDTadcP
# WdgsjsiOaK/7EsKJgLjUNIVgvcaFOLLQ/GlrA+0ZHJoFUbOr5SJN8zykPspXIXlp
# DJY/gqFUZRROeab9GVgmhbdOJcD/63RhxPahFUGbckRONqMe6DYAv6/mOG0pWd3c
# PStsdcS7buj5DyniwRY8yooMH6ptx5vpP/pZzBPBeZD2U4IsthyxB5Jaa8qrOkB5
# z160TXiM5ADMspZ0TfD9MJoq0tFpFPssKRFhWeEDYPvcUuN7U7lvcdHl4ezQ3NT/
# 7Ffs1sR1yh/LRbdZ3B3Vc6q2WmD8mDC0p9kzl2o73iVtS946IkEj7FkRsZGww1te
# YxERROC745xrtjvcw9ZyyUjHZWGRIpJeMNsPquCDf0fkyHtB+J4AiNZqCQk23rxh
# +KbpyMTNVKItJ5l92Svl20U9NbqMBOVYl1h54NEYLJq1/xHWFKPNK903zJZA9P2D
# MIIITDCCBgCgAwIBAgITGQAAAAu8LyA0hwqD9AAAAAAACzBBBgkqhkiG9w0BAQow
# NKAPMA0GCWCGSAFlAwQCAwUAoRwwGgYJKoZIhvcNAQEIMA0GCWCGSAFlAwQCAwUA
# ogMCAUAwbTETMBEGCgmSJomT8ixkARkWA2NvbTEiMCAGCgmSJomT8ixkARkWEmdl
# bmVyYXRpb25zZ2FpdGhlcjEyMDAGA1UEAxMpZ2VuZXJhdGlvbnNnYWl0aGVyLVNS
# VjAxMDAxMDAzNzAzNS1Sb290Q0EwHhcNMjUwMTMxMTcxNzI1WhcNMjcwMTMxMTcy
# NzI1WjBwMRMwEQYKCZImiZPyLGQBGRYDY29tMSIwIAYKCZImiZPyLGQBGRYSZ2Vu
# ZXJhdGlvbnNnYWl0aGVyMTUwMwYDVQQDEyxnZW5lcmF0aW9uc2dhaXRoZXItU1JW
# MDEwMDEwMDM4MDM1LUlzc3VpbmdDQTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAME7bcPuw+OBlpLFMrUpTOHjElzdC+VrSCfa9scUjHCqDU2B9rTBDzN5
# 5xpCu+NC4psqMzLIbOOOmv1KkfKvdDNkmgK7sJ6v4CxXrLsVELZkugW7mQG2NpTY
# yurNWkIxxn6U8wZHIwRbzH3a5XPHgeejY8+XEn4lDeQ/gy4HZPrT6gO2ML9MoED0
# jkXuSpBlotXDlv8D/EJTvTWoT3i/8sSa6J5uO+r0ckCSCkxvMy4zwifEFLmUNope
# nB8aPzs4NkRnPhNg7OcRyjssDcijiVWV8Tee9N0iAc637aJrTD8CtSyUDMAA0Zhh
# tjaGlcj7xXM1GhBvmlwn0EchVyGsALPC41AMHQRi3FNl6k633iXssKkcQL51EuAx
# XWS73CrcD1w1leFNVZnxmtW3yGzto6ND9ZSuYwyrBrqJLVfXVQJC+0ruUNrz/B/5
# jHey1Se4iLQnGrgrLVhJAAZHGAXuVTYB4f5s1cjjvj7+h6i/ZnJOYlCEW8ipwVW4
# 1AFjnxEAenzxAFv7NeoWuusJoPq9sGvC9xJfxClWt9zZfu4qJ95k1e+t1t4CSnvM
# 5O0uY4KqQDX1I0IOTozy9jT04QSLpm3VdLmznOFebja1213JR/D3GeApyqNJzEr5
# wWiIeZWkk27a+Yc3e9xGTke2nT06j+ytb66v8CIdxuy9JdfBn8aNAgMBAAGjggJ4
# MIICdDAQBgkrBgEEAYI3FQEEAwIBADAdBgNVHQ4EFgQUTl8d+WOVii82magmCdxr
# 81y+EZwwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwDgYDVR0PAQH/BAQDAgGG
# MA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAUQBf/oJasKe2FCSOPWKt9FaN9
# U1EwgfoGA1UdHwSB8jCB7zCB7KCB6aCB5oaB42xkYXA6Ly8vQ049Z2VuZXJhdGlv
# bnNnYWl0aGVyLVNSVjAxMDAxMDAzNzAzNS1Sb290Q0EsQ049c3J2MDEwMDEwMDM3
# MDM1LENOPUNEUCxDTj1QdWJsaWMlMjBLZXklMjBTZXJ2aWNlcyxDTj1TZXJ2aWNl
# cyxDTj1Db25maWd1cmF0aW9uLERDPWdlbmVyYXRpb25zZ2FpdGhlcixEQz1jb20/
# Y2VydGlmaWNhdGVSZXZvY2F0aW9uTGlzdD9iYXNlP29iamVjdENsYXNzPWNSTERp
# c3RyaWJ1dGlvblBvaW50MIHmBggrBgEFBQcBAQSB2TCB1jCB0wYIKwYBBQUHMAKG
# gcZsZGFwOi8vL0NOPWdlbmVyYXRpb25zZ2FpdGhlci1TUlYwMTAwMTAwMzcwMzUt
# Um9vdENBLENOPUFJQSxDTj1QdWJsaWMlMjBLZXklMjBTZXJ2aWNlcyxDTj1TZXJ2
# aWNlcyxDTj1Db25maWd1cmF0aW9uLERDPWdlbmVyYXRpb25zZ2FpdGhlcixEQz1j
# b20/Y0FDZXJ0aWZpY2F0ZT9iYXNlP29iamVjdENsYXNzPWNlcnRpZmljYXRpb25B
# dXRob3JpdHkwQQYJKoZIhvcNAQEKMDSgDzANBglghkgBZQMEAgMFAKEcMBoGCSqG
# SIb3DQEBCDANBglghkgBZQMEAgMFAKIDAgFAA4ICAQCXYn6MOeflWh5jgspvzRQQ
# CWPuI3Ob3d3xt3bCSp1EW7uSAk1vkSc7OmcAUTayZXI7HH9KjIBTey1yuss4ynun
# /ZD87JBLTX9IWZcnD7SsDddk/7Qi4zRMj+Z8orAeLifAHXDGVFogWPr7giAvJU8n
# XPFjmz+5h6Vhujn9Ny5iaCKGXDbsb0FBimSqTyFMZ3hY5Z0AK87dWQIHWnx227Rm
# n5OIJCNC1lqpzHOgRs+VObKNSJMnSjyxOY77AaW73mXf0JGSJ4e61jJGvkghuZmX
# 3D+VvyOeXiNUfVpPRw5EVSUdPqYm6Y7pKTa0Dc7Wat4lCe8UGNwowIA3RfpzxeL3
# o6CvCn2tslFCtyO40fKX6Rgh+Fl5cAddwLYQTIULk4pxLqJBtAUPVhd+yTc+S6gl
# shFy+j1H9m1K9HfoQBTgukTKn3QWkn49FbbiNTAQ/Sr9XN4HF7/zJEu8WrA6GeLq
# QVYtIm2lwELocI3UPzSpp7Vw8TpRsFhJSOvfWEBjbNBvAWB7g79/AuotJ0DHIxnu
# yK6i6mf3ZUi9hj9g+lyXB/TQoRH8p3f01lpl7x60COLxJTSd4C3W0msRsTaqeO7x
# ZNZuc3i35mRD3XPmchB3Xgmx/qxAbnv8vDvOe86nz4wDRcHJtKoOtRdXDuBxqavy
# 8e8SwzOBXivKZRSg9xYQMTGCBWQwggVgAgEBMIGHMHAxEzARBgoJkiaJk/IsZAEZ
# FgNjb20xIjAgBgoJkiaJk/IsZAEZFhJnZW5lcmF0aW9uc2dhaXRoZXIxNTAzBgNV
# BAMTLGdlbmVyYXRpb25zZ2FpdGhlci1TUlYwMTAwMTAwMzgwMzUtSXNzdWluZ0NB
# AhNAAAACq0GQY7VqwS+QAAAAAAKrMA0GCWCGSAFlAwQCAQUAoIGEMBgGCisGAQQB
# gjcCAQwxCjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYK
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIKck64Uf
# 5BC/SZjQigJortglwYs6rld+aRfqeV7GIa7RMA0GCSqGSIb3DQEBAQUABIIBAIKQ
# IWRHPSnA7rn/giZjHg8V2FiNtCIVIbrNrfbaokyaANJZiqF/HG4v7SHxb5s2Td6R
# 6vZdXg4g26J8hcXe+QDGCbSCwcGvse8qvcgTtZA5voqGM905VeVqkX1+EpD5f49t
# NSEKpp02nalUtsxuf6Xw+GccIESzkDpaVz077Ih/K+hh4dD5rVJ9rIhnahYZXaIz
# hj3UBsU+HZqzPDrV9/XvnyCqyr8SXhZAEL+PQ51tV+zeSBWevNZKvQpuvcma9xWO
# HIPSQ08YsZvGfW8DfeEI4JHTpgw8knyOs+PcjDjBbt7AnFFbi0wV0A6G/kE1MMYM
# F9VDjDJjXa09LVPXMHKhggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDEyMjAx
# NzMzWjAvBgkqhkiG9w0BCQQxIgQgu1yyDDf3i/+V9JXwzJpYMrget4t4PIZRXRf8
# W7nIgHgwDQYJKoZIhvcNAQEBBQAEggIAID07Xb9i26nMXBtA9y9zyNFfbNmGAByz
# G7XtQglyQfi3dGDZIG0cQB0Zq3PU1WYIFDJNYh2IiFZlmXxpev2YCYJSCMSflXA9
# tDmDaocHeoz+Kz7rUpMyDuJE4PX6//lD04Bg9LuVNeBpAMrED5PQFcjgz7hmnJKe
# p815oCRpV36cB26whT0lXRBPNigENiXXCUuHuDDtoTvSUnnimfghd/EVSeSTmOAb
# nfB7ahag39m1OSb1ArGuakkMfYuRXnlvWPEovj+Wjt2lPrlLCNluFdfMU3WwqV3J
# OSyG0xsceEIyXTvt58f4fQKS9aUyPpH7RwauEzCoX1i2IaTTjpu8KbuBt/iPX4tz
# gbbVBUHkwqdDDC4kKpspOVMi2vJ2kOq1QAY5aSOMwsuUji1k65GEGiPsAAKhpJbv
# 2AC4E5N9lfZhfluw/80TShE/iOMU/AuaVFQUWv+A+kiRvKi5RYTwGSaWsLgiB3JD
# CC0oOkv1VFPypMuH3KlrcJsCJx5jbwPNXP5nPA0byL7wOQXNE99LDo3415F+CV3M
# IlS/a3QLlLo4pCgpVAaN9LBgPnT4F1yrHgdjdtof0CZ4VAIPCDBa8YvZ4ho2ehnZ
# JxfYp3A7S0Rab4Q1hUIIwJNazMJZM+lYPA7N5B69ECd1iQ8wBMuNZ+W7Yd4nZ6t7
# Dknoa2FxzN8=
# SIG # End signature block
