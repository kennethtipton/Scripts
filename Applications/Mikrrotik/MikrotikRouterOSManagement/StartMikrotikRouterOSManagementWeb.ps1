<#
.SYNOPSIS
    Starts a generic Pode.Web interface for MikroTik RouterOS management.
.DESCRIPTION
    Launches a lightweight Pode.Web HTTP server with a generic landing page,
    status cards, and quick-start guidance. This is a starter UI scaffold that
    can be expanded with RouterOS management pages and actions.
.PARAMETER Port
    TCP port for the Pode.Web server. Default is 8090.
.PARAMETER Address
    Bind address for the server endpoint. Default is '*'.
.PARAMETER Title
    Browser title shown in the Pode.Web template.
.EXAMPLE
    PS> .\StartMikrotikRouterOSManagementWeb.ps1
.EXAMPLE
    PS> .\StartMikrotikRouterOSManagementWeb.ps1 -Port 9095 -Verbose
.EXAMPLE
    PS> .\StartMikrotikRouterOSManagementWeb.ps1 -Address '127.0.0.1' -Port 8090
.INPUTS
    None.
.OUTPUTS
    None.
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-03-06
    Time: 09:00:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 1.0.0
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: GitHub Copilot

    Copyright (c) 2026
    Licensed under the MIT License.
    Full text available at: https://opensource.org/licenses/MIT

    Dependencies:
        Pode module     (Install-Module Pode -Scope CurrentUser)
        Pode.Web module (Install-Module Pode.Web -Scope CurrentUser)
.LINK
    https://www.tnandc.com
    https://badgerati.github.io/Pode.Web/
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 65535)]
    [int]$Port = 8090,

    [Parameter(Mandatory = $false)]
    [string]$Address = '*',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$Title = 'Mikrotik RouterOS Management'
)

$script:CurrentScriptName = $MyInvocation.MyCommand.Name
$script:CanUseAdvancedLog = $false
$script:DeviceDatabasePath = Join-Path -Path $PSScriptRoot -ChildPath 'Data\MikrotikDevices.db'

$writeLogFunc = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\Functions\Write-AdvancedLog.ps1'
if (Test-Path -Path $writeLogFunc) {
    try {
        . $writeLogFunc
    }
    catch {
        Write-Warning "Failed to load Write-AdvancedLog from '$writeLogFunc'. Continuing with verbose logging only. Error: $_"
    }
}

if (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue) {
    $script:CanUseAdvancedLog = $true
}

# Load local device CRUD functions used by the Mikrotik Devices page.
$deviceFunctionFiles = @(
    'Get-MikrotikDevice.ps1'
    'New-MikrotikDevice.ps1'
    'Set-MikrotikDevice.ps1'
    'Remove-MikrotikDevice.ps1'
    'Restore-MikrotikDevice.ps1'
    'Get-MikrotikContact.ps1'
    'New-MikrotikContact.ps1'
    'Set-MikrotikContact.ps1'
    'Remove-MikrotikContact.ps1'
    'Restore-MikrotikContact.ps1'
    'Get-MikrotikContactLocation.ps1'
    'New-MikrotikContactLocation.ps1'
    'Set-MikrotikContactLocation.ps1'
    'Remove-MikrotikContactLocation.ps1'
    'Restore-MikrotikContactLocation.ps1'
    'Initialize-MikrotikContactCollection.ps1'
)

foreach ($deviceFunctionFile in $deviceFunctionFiles) {
    $deviceFunctionPath = Join-Path -Path $PSScriptRoot -ChildPath "Functions\$deviceFunctionFile"
    if (-not (Test-Path -Path $deviceFunctionPath -PathType Leaf)) {
        Write-Warning "Device function file not found: $deviceFunctionPath"
        continue
    }

    try {
        . $deviceFunctionPath
    }
    catch {
        Write-Warning "Failed to load device function '$deviceFunctionPath': $_"
    }
}

function Write-SafeAdvancedLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARNING', 'ERROR')]
        [string]$LogType = 'INFO'
    )

    if ($script:CanUseAdvancedLog) {
        try {
            Write-AdvancedLog -Message $Message -ScriptName $script:CurrentScriptName -LogType $LogType
            return
        }
        catch {
            Write-Verbose "Write-AdvancedLog failed: $_"
        }
    }

    Write-Verbose "[$LogType] $Message"
}

function Test-IsAdministrator {
    [CmdletBinding()]
    param()

    try {
        $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-MikrotikDeviceTableData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath,

        [Parameter(Mandatory = $false)]
        [string]$RouterIdentityHostname,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Active', 'All', 'Deleted')]
        [string]$FilterMode = 'Active'
    )

    if ([string]::IsNullOrWhiteSpace($DatabasePath)) {
        return @(
            [PSCustomObject]@{
                RouterIdentityHostname = 'No records found'
                RouterModel            = ''
                RouterFirmware         = ''
                State                  = ''
                City                   = ''
                StreetAddress          = ''
                LocationType           = ''
                Building               = ''
                Room                   = ''
                Rack                   = ''
                Unit                   = ''
                IsDeleted              = ''
                ModifiedDate           = ''
            }
        )
    }

    $getParams = @{
        DatabasePath = $DatabasePath
    }

    if (-not [string]::IsNullOrWhiteSpace($RouterIdentityHostname)) {
        $getParams['RouterIdentityHostname'] = $RouterIdentityHostname
    }

    if ($FilterMode -eq 'All' -or $FilterMode -eq 'Deleted') {
        $getParams['IncludeDeleted'] = $true
    }

    try {
        $records = @(Get-MikrotikDevice @getParams -ErrorAction Stop)
    }
    catch {
        $records = @()
    }

    if ($FilterMode -eq 'Deleted') {
        $records = @($records | Where-Object { $_.IsDeleted })
    }
    elseif ($FilterMode -eq 'Active') {
        $records = @($records | Where-Object { -not $_.IsDeleted })
    }

    if ($records.Count -eq 0) {
        return @(
            [PSCustomObject]@{
                RouterIdentityHostname = 'No records found'
                RouterModel            = ''
                RouterFirmware         = ''
                State                  = ''
                City                   = ''
                StreetAddress          = ''
                LocationType           = ''
                Building               = ''
                Room                   = ''
                Rack                   = ''
                Unit                   = ''
                IsDeleted              = ''
                ModifiedDate           = ''
            }
        )
    }

    return $records | ForEach-Object {
        [PSCustomObject]@{
            RouterIdentityHostname = $_.RouterIdentityHostname
            RouterModel            = $_.RouterModel
            RouterFirmware         = $_.RouterFirmware
            State                  = $_.State
            City                   = $_.City
            StreetAddress          = $_.StreetAddress
            LocationType           = $_.LocationType
            Building               = $_.Building
            Room                   = $_.Room
            Rack                   = $_.Rack
            Unit                   = $_.Unit
            IsDeleted              = $_.IsDeleted
            ModifiedDate           = $_.ModifiedDate
        }
    }
}

function Get-MikrotikContactTableData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath,

        [Parameter(Mandatory = $false)]
        [string]$DisplayName,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Active', 'All', 'Deleted')]
        [string]$FilterMode = 'Active'
    )

    if ([string]::IsNullOrWhiteSpace($DatabasePath)) {
        return @(
            [PSCustomObject]@{
                DisplayName         = 'No records found'
                Company             = ''
                ContactType         = ''
                NetworkConnected    = ''
                ContactAbbreviation = ''
                EmailAddress        = ''
                IsDeleted           = ''
                ModifiedDate        = ''
            }
        )
    }

    $getParams = @{
        DatabasePath = $DatabasePath
    }

    if (-not [string]::IsNullOrWhiteSpace($DisplayName)) {
        $getParams['DisplayName'] = $DisplayName
    }

    if ($FilterMode -eq 'All' -or $FilterMode -eq 'Deleted') {
        $getParams['IncludeDeleted'] = $true
    }

    try {
        $records = @(Get-MikrotikContact @getParams -ErrorAction Stop)
    }
    catch {
        $records = @()
    }

    if ($FilterMode -eq 'Deleted') {
        $records = @($records | Where-Object { $_.IsDeleted })
    }
    elseif ($FilterMode -eq 'Active') {
        $records = @($records | Where-Object { -not $_.IsDeleted })
    }

    if ($records.Count -eq 0) {
        return @(
            [PSCustomObject]@{
                DisplayName         = 'No records found'
                Company             = ''
                ContactType         = ''
                NetworkConnected    = ''
                ContactAbbreviation = ''
                EmailAddress        = ''
                IsDeleted           = ''
                ModifiedDate        = ''
            }
        )
    }

    return $records | ForEach-Object {
        [PSCustomObject]@{
            DisplayName         = $_.DisplayName
            Company             = $_.Company
            ContactType         = $_.ContactType
            NetworkConnected    = $_.NetworkConnected
            ContactAbbreviation = $_.ContactAbbreviation
            EmailAddress        = $_.EmailAddress
            IsDeleted           = $_.IsDeleted
            ModifiedDate        = $_.ModifiedDate
        }
    }
}

function Get-MikrotikActiveContactDisplayNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath
    )

    try {
        $records = @(
            Get-MikrotikContact -DatabasePath $DatabasePath -ErrorAction Stop | Where-Object {
                -not $_.IsDeleted -and -not [string]::IsNullOrWhiteSpace($_.DisplayName)
            }
        )

        return @(
            $records |
            Select-Object -ExpandProperty DisplayName -Unique |
            Sort-Object
        )
    }
    catch {
        return @()
    }
}

function Get-MikrotikActiveContactIdByDisplayName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    try {
        $record = @(
            Get-MikrotikContact -DatabasePath $DatabasePath -DisplayName $DisplayName -ErrorAction Stop | Where-Object {
                -not $_.IsDeleted
            }
        ) | Select-Object -First 1

        if ($null -eq $record) {
            return ''
        }

        return [string]$record.ContactId
    }
    catch {
        return ''
    }
}

function Get-MikrotikActiveLocationIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath
    )

    try {
        $records = @(
            Get-MikrotikContactLocation -DatabasePath $DatabasePath -ErrorAction Stop | Where-Object {
                -not $_.IsDeleted -and -not [string]::IsNullOrWhiteSpace($_.LocationId)
            }
        )

        return @(
            $records |
            Select-Object -ExpandProperty LocationId -Unique |
            Sort-Object
        )
    }
    catch {
        return @()
    }
}

function Get-PodeToggleBooleanValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Data,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $hasValue = $false
    $raw = $null

    $candidateNames = @($Name, "$Name[]")

    if ($Data -is [System.Collections.IDictionary]) {
        foreach ($candidateName in $candidateNames) {
            if ($Data.Contains($candidateName)) {
                $raw = $Data[$candidateName]
                $hasValue = $true
                break
            }
        }

        if (-not $hasValue) {
            $matchingKey = @($Data.Keys | Where-Object { ([string]$_) -imatch "^$([Regex]::Escape($Name))(\[\])?.*" }) | Select-Object -First 1
            if ($null -ne $matchingKey) {
                $raw = $Data[$matchingKey]
                $hasValue = $true
            }
        }
    }
    elseif ($null -ne $Data) {
        $prop = @($Data.PSObject.Properties | Where-Object { $_.Name -ieq $Name -or $_.Name -ieq "$Name[]" }) | Select-Object -First 1
        if ($null -eq $prop) {
            $prop = @($Data.PSObject.Properties | Where-Object { $_.Name -imatch "^$([Regex]::Escape($Name))(\[\])?.*" }) | Select-Object -First 1
        }

        if ($null -ne $prop) {
            $raw = $prop.Value
            $hasValue = $true
        }
    }

    if (-not $hasValue) {
        return $false
    }

    if ($raw -is [bool]) {
        return [bool]$raw
    }

    if ($raw -is [System.Array]) {
        $raw = @($raw | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) | Select-Object -First 1
    }

    if ($null -eq $raw) {
        return $false
    }

    $text = [string]$raw
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
    }

    if ($text -match '^(true|on|1|yes|checked)$') {
        return $true
    }

    if ($text -match '^(false|off|0|no)$') {
        return $false
    }

    $parsed = $false
    if ([bool]::TryParse($text, [ref]$parsed)) {
        return $parsed
    }

    # If key/value is present but non-standard, treat as checked.
    return $true
}

function Get-MikrotikContactLocationTableData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath,

        [Parameter(Mandatory = $false)]
        [string]$DisplayName,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Active', 'All', 'Deleted')]
        [string]$FilterMode = 'Active'
    )

    if ([string]::IsNullOrWhiteSpace($DatabasePath)) {
        return @(
            [PSCustomObject]@{
                LocationId   = 'No records found'
                ContactId    = ''
                LocationName = ''
                AddressLine1 = ''
                City         = ''
                State        = ''
                PostalCode   = ''
                Country      = ''
                IsPrimary    = ''
                IsDeleted    = ''
                ModifiedDate = ''
            }
        )
    }

    $getParams = @{
        DatabasePath = $DatabasePath
    }

    if (-not [string]::IsNullOrWhiteSpace($DisplayName)) {
        $getParams['DisplayName'] = $DisplayName
    }

    if ($FilterMode -eq 'All' -or $FilterMode -eq 'Deleted') {
        $getParams['IncludeDeleted'] = $true
    }

    try {
        $records = @(Get-MikrotikContactLocation @getParams -ErrorAction Stop)
    }
    catch {
        $records = @()
    }

    if ($FilterMode -eq 'Deleted') {
        $records = @($records | Where-Object { $_.IsDeleted })
    }
    elseif ($FilterMode -eq 'Active') {
        $records = @($records | Where-Object { -not $_.IsDeleted })
    }

    if ($records.Count -eq 0) {
        return @(
            [PSCustomObject]@{
                LocationId   = 'No records found'
                ContactId    = ''
                LocationName = ''
                AddressLine1 = ''
                City         = ''
                State        = ''
                PostalCode   = ''
                Country      = ''
                IsPrimary    = ''
                IsDeleted    = ''
                ModifiedDate = ''
            }
        )
    }

    return $records | ForEach-Object {
        [PSCustomObject]@{
            LocationId   = $_.LocationId
            ContactId    = $_.ContactId
            LocationName = $_.LocationName
            AddressLine1 = $_.AddressLine1
            City         = $_.City
            State        = $_.State
            PostalCode   = $_.PostalCode
            Country      = $_.Country
            IsPrimary    = $_.IsPrimary
            IsDeleted    = $_.IsDeleted
            ModifiedDate = $_.ModifiedDate
        }
    }
}

Write-Verbose "Address: $Address"
Write-Verbose "Port: $Port"
Write-Verbose "Title: $Title"

try {
    Import-Module -Name Pode -ErrorAction Stop
    Import-Module -Name Pode.Web -ErrorAction Stop
    Write-SafeAdvancedLog -Message 'Pode and Pode.Web modules imported successfully.' -LogType 'INFO'
}
catch {
    Write-Error "Failed to import required modules. Install with:`n  Install-Module Pode -Scope CurrentUser`n  Install-Module Pode.Web -Scope CurrentUser`nError: $_"
    Write-SafeAdvancedLog -Message "Failed to import Pode/Pode.Web modules: $_" -LogType 'ERROR'
    exit 1
}

try {
    [void](Initialize-MikrotikContactCollection -DatabasePath $script:DeviceDatabasePath -ErrorAction Stop)
    Write-SafeAdvancedLog -Message "LiteDB contacts collection initialized at '$($script:DeviceDatabasePath)'." -LogType 'INFO'
}
catch {
    Write-SafeAdvancedLog -Message "Failed to initialize contacts collection: $_" -LogType 'ERROR'
    throw
}

$ServerAddress = $Address
$ServerPort = $Port
$PageTitle = $Title
$DataFolderPath = Join-Path -Path $PSScriptRoot -ChildPath 'Data'

if ($IsWindows) {
    $requiresAdminAddress = @('*', '0.0.0.0', '+', '::')
    if (($requiresAdminAddress -contains $ServerAddress) -and -not (Test-IsAdministrator)) {
        Write-Warning "Address '$ServerAddress' requires administrator privileges. Falling back to localhost (127.0.0.1)."
        Write-SafeAdvancedLog -Message "Non-admin session detected. Replacing address '$ServerAddress' with 127.0.0.1." -LogType 'WARNING'
        $ServerAddress = '127.0.0.1'
    }
}

Write-SafeAdvancedLog -Message "Starting Pode.Web UI on http://${ServerAddress}:$ServerPort" -LogType 'INFO'

try {
    Start-PodeServer {
        Add-PodeEndpoint -Address $ServerAddress -Port $ServerPort -Protocol Http

        Use-PodeWebTemplates -Title $PageTitle -Theme Light

        Add-PodeWebPage -Name 'Dashboard' -Title 'Dashboard' -Icon 'layout' -ArgumentList $DataFolderPath -ScriptBlock {
            param($HomeDataFolderPath)

            New-PodeWebHero -Title 'Mikrotik RouterOS Management' -Message 'Generic Pode.Web starter page is running.'

            New-PodeWebCard -Name 'QuickStart' -DisplayName 'Quick Start' -Content @(
                New-PodeWebText -Value 'Use this page as a base for device inventory, interface dashboards, and change actions.'
                New-PodeWebText -Value 'Next step: add pages for Connection, Interfaces, IP, and Wireless workflows.'
            )

            $statusRows = @(
                [PSCustomObject]@{ Item = 'Service'; Value = 'Pode.Web'; State = 'Online' }
                [PSCustomObject]@{ Item = 'Profile'; Value = 'Generic Scaffold'; State = 'Ready' }
                [PSCustomObject]@{ Item = 'Config Path'; Value = $HomeDataFolderPath; State = 'Available' }
            )

            New-PodeWebTable -Name 'StatusTable' -Compact -ScriptBlock {
                return $statusRows
            } -Columns @(
                Initialize-PodeWebTableColumn -Key 'Item'
                Initialize-PodeWebTableColumn -Key 'Value'
                Initialize-PodeWebTableColumn -Key 'State'
            )
        }

        Add-PodeWebPage -Name 'Mikrotik Devices' -Title 'Mikrotik Devices' -Icon 'server' -ArgumentList $script:DeviceDatabasePath -ScriptBlock {
            param($DeviceDatabasePath)

            $deviceTabs = @(
                New-PodeWebTab -Name 'view' -Layouts @(
                    New-PodeWebTable -Name 'MikrotikDevicesTable' -Sort -SimpleFilter -Compact -ArgumentList $DeviceDatabasePath -ScriptBlock {
                        param($DbPath)
                        try {
                            return Get-MikrotikDeviceTableData -DatabasePath $DbPath
                        }
                        catch {
                            return @(
                                [PSCustomObject]@{
                                    RouterIdentityHostname = 'No records found'
                                    RouterModel            = ''
                                    RouterFirmware         = ''
                                    State                  = ''
                                    City                   = ''
                                    StreetAddress          = ''
                                    LocationType           = ''
                                    Building               = ''
                                    Room                   = ''
                                    Rack                   = ''
                                    Unit                   = ''
                                    IsDeleted              = ''
                                    ModifiedDate           = ''
                                }
                            )
                        }
                    } -Columns @(
                        Initialize-PodeWebTableColumn -Key 'RouterIdentityHostname' -Width 3
                        Initialize-PodeWebTableColumn -Key 'RouterModel' -Width 2
                        Initialize-PodeWebTableColumn -Key 'RouterFirmware' -Width 2
                        Initialize-PodeWebTableColumn -Key 'State' -Width 1
                        Initialize-PodeWebTableColumn -Key 'City' -Width 2
                        Initialize-PodeWebTableColumn -Key 'StreetAddress' -Width 3
                        Initialize-PodeWebTableColumn -Key 'LocationType' -Width 2
                        Initialize-PodeWebTableColumn -Key 'Building' -Width 1
                        Initialize-PodeWebTableColumn -Key 'Room' -Width 1
                        Initialize-PodeWebTableColumn -Key 'Rack' -Width 1
                        Initialize-PodeWebTableColumn -Key 'Unit' -Width 1
                        Initialize-PodeWebTableColumn -Key 'IsDeleted' -Width 1
                        Initialize-PodeWebTableColumn -Key 'ModifiedDate' -Width 2
                    )

                    New-PodeWebCard -Name 'MikrotikTableFilters' -DisplayName 'Table Filters' -Content @(
                        New-PodeWebButton -Name 'FilterActiveDevicesButton' -DisplayName 'Show Active' -Icon 'filter' -Colour Green -ArgumentList $DeviceDatabasePath -ScriptBlock {
                            param($DbPath)
                            try {
                                $rows = Get-MikrotikDeviceTableData -DatabasePath $DbPath -FilterMode 'Active'
                                return @(
                                    ($rows | Update-PodeWebTable -Name 'MikrotikDevicesTable')
                                    (Show-PodeWebToast -Title 'Filter' -Message 'Showing active devices only.')
                                )
                            }
                            catch {
                                return Show-PodeWebToast -Title 'Filter Failed' -Message "Failed to apply active filter: $_"
                            }
                        }

                        New-PodeWebButton -Name 'FilterAllDevicesButton' -DisplayName 'Show Active + Deleted' -Icon 'layers' -Colour Blue -ArgumentList $DeviceDatabasePath -ScriptBlock {
                            param($DbPath)
                            try {
                                $rows = Get-MikrotikDeviceTableData -DatabasePath $DbPath -FilterMode 'All'
                                return @(
                                    ($rows | Update-PodeWebTable -Name 'MikrotikDevicesTable')
                                    (Show-PodeWebToast -Title 'Filter' -Message 'Showing active and deleted devices.')
                                )
                            }
                            catch {
                                return Show-PodeWebToast -Title 'Filter Failed' -Message "Failed to apply all-records filter: $_"
                            }
                        }

                        New-PodeWebButton -Name 'FilterDeletedDevicesButton' -DisplayName 'Show Deleted Only' -Icon 'trash-2' -Colour Red -ArgumentList $DeviceDatabasePath -ScriptBlock {
                            param($DbPath)
                            try {
                                $rows = Get-MikrotikDeviceTableData -DatabasePath $DbPath -FilterMode 'Deleted'
                                return @(
                                    ($rows | Update-PodeWebTable -Name 'MikrotikDevicesTable')
                                    (Show-PodeWebToast -Title 'Filter' -Message 'Showing deleted devices only.')
                                )
                            }
                            catch {
                                return Show-PodeWebToast -Title 'Filter Failed' -Message "Failed to apply deleted filter: $_"
                            }
                        }
                    )

                    New-PodeWebForm -Name 'GetMikrotikDeviceForm' -AsCard -SubmitText 'Get Devices' -ShowReset -Content @(
                        New-PodeWebTextbox -Name 'RouterIdentityHostname' -DisplayName 'Router Identity/Hostname (optional)'
                    ) -ArgumentList $DeviceDatabasePath -ScriptBlock {
                        param($DbPath)

                        try {
                            $hostname = [string]$WebEvent.Data['RouterIdentityHostname']
                            $rows = Get-MikrotikDeviceTableData -DatabasePath $DbPath -RouterIdentityHostname $hostname

                            return @(
                                ($rows | Update-PodeWebTable -Name 'MikrotikDevicesTable')
                                (Show-PodeWebToast -Title 'Get' -Message 'Device table refreshed.')
                            )
                        }
                        catch {
                            return Show-PodeWebToast -Title 'Get Failed' -Message "Failed to query devices: $_"
                        }
                    }

                    New-PodeWebButton -Name 'RefreshMikrotikDevicesButton' -DisplayName 'Refresh Table' -Icon 'refresh-cw' -Colour Blue -ArgumentList $DeviceDatabasePath -ScriptBlock {
                        param($DbPath)
                        try {
                            $rows = Get-MikrotikDeviceTableData -DatabasePath $DbPath
                            return @(
                                ($rows | Update-PodeWebTable -Name 'MikrotikDevicesTable')
                                (Show-PodeWebToast -Title 'Refresh' -Message 'Table refreshed.')
                            )
                        }
                        catch {
                            return Show-PodeWebToast -Title 'Refresh Failed' -Message "Failed to refresh table: $_"
                        }
                    }

                    New-PodeWebForm -Name 'SetMikrotikDeviceForm' -AsCard -SubmitText 'Set Device' -ShowReset -Content @(
                        New-PodeWebTextbox -Name 'CurrentRouterIdentityHostname' -DisplayName 'Current Router Identity/Hostname' -Required
                        New-PodeWebTextbox -Name 'RouterIdentityHostname' -DisplayName 'Router Identity/Hostname'
                        New-PodeWebTextbox -Name 'RouterModel' -DisplayName 'Router Model'
                        New-PodeWebTextbox -Name 'RouterFirmware' -DisplayName 'Router Firmware'
                        New-PodeWebTextbox -Name 'State' -DisplayName 'State'
                        New-PodeWebTextbox -Name 'City' -DisplayName 'City'
                        New-PodeWebTextbox -Name 'StreetAddress' -DisplayName 'Street Address'
                        New-PodeWebTextbox -Name 'LocationType' -DisplayName 'Location Type'
                        New-PodeWebTextbox -Name 'Building' -DisplayName 'Building'
                        New-PodeWebTextbox -Name 'Room' -DisplayName 'Room'
                        New-PodeWebTextbox -Name 'Rack' -DisplayName 'Rack'
                        New-PodeWebTextbox -Name 'Unit' -DisplayName 'Unit'
                    ) -ArgumentList $DeviceDatabasePath -ScriptBlock {
                        param($DbPath)

                        try {
                            $setParams = @{
                                DatabasePath = $DbPath
                                CurrentRouterIdentityHostname = [string]$WebEvent.Data['CurrentRouterIdentityHostname']
                            }

                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['RouterIdentityHostname'])) {
                                $setParams['RouterIdentityHostname'] = [string]$WebEvent.Data['RouterIdentityHostname']
                            }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['RouterModel'])) {
                                $setParams['RouterModel'] = [string]$WebEvent.Data['RouterModel']
                            }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['RouterFirmware'])) {
                                $setParams['RouterFirmware'] = [string]$WebEvent.Data['RouterFirmware']
                            }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['State'])) {
                                $setParams['State'] = [string]$WebEvent.Data['State']
                            }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['City'])) {
                                $setParams['City'] = [string]$WebEvent.Data['City']
                            }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['StreetAddress'])) {
                                $setParams['StreetAddress'] = [string]$WebEvent.Data['StreetAddress']
                            }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['LocationType'])) {
                                $setParams['LocationType'] = [string]$WebEvent.Data['LocationType']
                            }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['Building'])) {
                                $setParams['Building'] = [string]$WebEvent.Data['Building']
                            }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['Room'])) {
                                $setParams['Room'] = [string]$WebEvent.Data['Room']
                            }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['Rack'])) {
                                $setParams['Rack'] = [string]$WebEvent.Data['Rack']
                            }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['Unit'])) {
                                $setParams['Unit'] = [string]$WebEvent.Data['Unit']
                            }

                            [void](Set-MikrotikDevice @setParams)
                            $rows = Get-MikrotikDeviceTableData -DatabasePath $DbPath

                            return @(
                                ($rows | Update-PodeWebTable -Name 'MikrotikDevicesTable')
                                (Show-PodeWebToast -Title 'Set' -Message 'Device updated successfully.')
                                (Reset-PodeWebForm -Name 'SetMikrotikDeviceForm')
                            )
                        }
                        catch {
                            return Show-PodeWebToast -Title 'Set Failed' -Message "Failed to update device: $_"
                        }
                    }

                    New-PodeWebForm -Name 'RemoveMikrotikDeviceForm' -AsCard -SubmitText 'Remove Device' -ShowReset -Content @(
                        New-PodeWebTextbox -Name 'RouterIdentityHostname' -DisplayName 'Router Identity/Hostname' -Required
                    ) -ArgumentList $DeviceDatabasePath -ScriptBlock {
                        param($DbPath)

                        try {
                            $removed = Remove-MikrotikDevice -DatabasePath $DbPath -RouterIdentityHostname ([string]$WebEvent.Data['RouterIdentityHostname']) -Confirm:$false
                            $rows = Get-MikrotikDeviceTableData -DatabasePath $DbPath

                            if ($removed) {
                                return @(
                                    ($rows | Update-PodeWebTable -Name 'MikrotikDevicesTable')
                                    (Show-PodeWebToast -Title 'Remove' -Message 'Device marked as deleted successfully.')
                                    (Reset-PodeWebForm -Name 'RemoveMikrotikDeviceForm')
                                )
                            }

                            return @(
                                ($rows | Update-PodeWebTable -Name 'MikrotikDevicesTable')
                                (Show-PodeWebToast -Title 'Remove' -Message 'No matching active Router Identity/Hostname found to remove.')
                            )
                        }
                        catch {
                            return Show-PodeWebToast -Title 'Remove Failed' -Message "Failed to remove device: $_"
                        }
                    }

                    New-PodeWebForm -Name 'RestoreMikrotikDeviceForm' -AsCard -SubmitText 'Restore Device' -ShowReset -Content @(
                        New-PodeWebTextbox -Name 'RouterIdentityHostname' -DisplayName 'Router Identity/Hostname' -Required
                    ) -ArgumentList $DeviceDatabasePath -ScriptBlock {
                        param($DbPath)

                        try {
                            $restored = Restore-MikrotikDevice -DatabasePath $DbPath -RouterIdentityHostname ([string]$WebEvent.Data['RouterIdentityHostname']) -Confirm:$false
                            $rows = Get-MikrotikDeviceTableData -DatabasePath $DbPath

                            if ($restored) {
                                return @(
                                    ($rows | Update-PodeWebTable -Name 'MikrotikDevicesTable')
                                    (Show-PodeWebToast -Title 'Restore' -Message 'Device restored successfully.')
                                    (Reset-PodeWebForm -Name 'RestoreMikrotikDeviceForm')
                                )
                            }

                            return @(
                                ($rows | Update-PodeWebTable -Name 'MikrotikDevicesTable')
                                (Show-PodeWebToast -Title 'Restore' -Message 'No matching deleted Router Identity/Hostname found to restore.')
                            )
                        }
                        catch {
                            return Show-PodeWebToast -Title 'Restore Failed' -Message "Failed to restore device: $_"
                        }
                    }
                )

                New-PodeWebTab -Name 'Add' -Layouts @(
                    New-PodeWebForm -Name 'NewMikrotikDeviceForm' -AsCard -SubmitText 'New Device' -ShowReset -Content @(
                        New-PodeWebTextbox -Name 'RouterIdentityHostname' -DisplayName 'Router Identity/Hostname' -Required
                        New-PodeWebTextbox -Name 'RouterModel' -DisplayName 'Router Model' -Required
                        New-PodeWebTextbox -Name 'RouterFirmware' -DisplayName 'Router Firmware' -Required
                        New-PodeWebTextbox -Name 'State' -DisplayName 'State'
                        New-PodeWebTextbox -Name 'City' -DisplayName 'City'
                        New-PodeWebTextbox -Name 'StreetAddress' -DisplayName 'Street Address'
                        New-PodeWebTextbox -Name 'LocationType' -DisplayName 'Location Type'
                        New-PodeWebTextbox -Name 'Building' -DisplayName 'Building'
                        New-PodeWebTextbox -Name 'Room' -DisplayName 'Room'
                        New-PodeWebTextbox -Name 'Rack' -DisplayName 'Rack'
                        New-PodeWebTextbox -Name 'Unit' -DisplayName 'Unit'
                    ) -ArgumentList $DeviceDatabasePath -ScriptBlock {
                        param($DbPath)

                        try {
                            [void](New-MikrotikDevice -DatabasePath $DbPath -RouterIdentityHostname ([string]$WebEvent.Data['RouterIdentityHostname']) -RouterModel ([string]$WebEvent.Data['RouterModel']) -RouterFirmware ([string]$WebEvent.Data['RouterFirmware']) -State ([string]$WebEvent.Data['State']) -City ([string]$WebEvent.Data['City']) -StreetAddress ([string]$WebEvent.Data['StreetAddress']) -LocationType ([string]$WebEvent.Data['LocationType']) -Building ([string]$WebEvent.Data['Building']) -Room ([string]$WebEvent.Data['Room']) -Rack ([string]$WebEvent.Data['Rack']) -Unit ([string]$WebEvent.Data['Unit']))
                            $rows = Get-MikrotikDeviceTableData -DatabasePath $DbPath

                            return @(
                                ($rows | Update-PodeWebTable -Name 'MikrotikDevicesTable')
                                (Show-PodeWebToast -Title 'New' -Message 'Device added successfully.')
                                (Reset-PodeWebForm -Name 'NewMikrotikDeviceForm')
                            )
                        }
                        catch {
                            return Show-PodeWebToast -Title 'New Failed' -Message "Failed to add device: $_"
                        }
                    }
                )

            )

            New-PodeWebCard -Name 'MikrotikDeviceCrud' -DisplayName 'Device Inventory (LiteDB)' -Content @(
                New-PodeWebText -Value "Database: $DeviceDatabasePath"
                New-PodeWebTabs -Tabs $deviceTabs
            )
        }

        Add-PodeWebPage -Name 'Contacts' -Title 'Contacts' -Icon 'book-open' -ArgumentList $script:DeviceDatabasePath -ScriptBlock {
            param($ContactsDatabasePath)

            $contactTabs = @(
                New-PodeWebTab -Name 'view' -Layouts @(
                    New-PodeWebTable -Name 'MikrotikContactsTable' -Sort -SimpleFilter -Compact -ArgumentList $ContactsDatabasePath -ScriptBlock {
                        param($DbPath)
                        try {
                            return Get-MikrotikContactTableData -DatabasePath $DbPath
                        }
                        catch {
                            return @(
                                [PSCustomObject]@{
                                    DisplayName         = 'No records found'
                                    Company             = ''
                                    ContactType         = ''
                                    NetworkConnected    = ''
                                    ContactAbbreviation = ''
                                    EmailAddress        = ''
                                    IsDeleted           = ''
                                    ModifiedDate        = ''
                                }
                            )
                        }
                    } -Columns @(
                        Initialize-PodeWebTableColumn -Key 'DisplayName' -Width 3
                        Initialize-PodeWebTableColumn -Key 'Company' -Width 2
                        Initialize-PodeWebTableColumn -Key 'ContactType' -Width 1
                        Initialize-PodeWebTableColumn -Key 'NetworkConnected' -Width 1
                        Initialize-PodeWebTableColumn -Key 'ContactAbbreviation' -Width 1
                        Initialize-PodeWebTableColumn -Key 'EmailAddress' -Width 2
                        Initialize-PodeWebTableColumn -Key 'IsDeleted' -Width 1
                        Initialize-PodeWebTableColumn -Key 'ModifiedDate' -Width 2
                    )

                    New-PodeWebCard -Name 'MikrotikContactTableFilters' -DisplayName 'Table Filters' -Content @(
                        New-PodeWebButton -Name 'FilterActiveContactsButton' -DisplayName 'Show Active' -Icon 'filter' -Colour Green -ArgumentList $ContactsDatabasePath -ScriptBlock {
                            param($DbPath)
                            try {
                                $rows = Get-MikrotikContactTableData -DatabasePath $DbPath -FilterMode 'Active'
                                return @(
                                    ($rows | Update-PodeWebTable -Name 'MikrotikContactsTable')
                                    (Show-PodeWebToast -Title 'Filter' -Message 'Showing active contacts only.')
                                )
                            }
                            catch {
                                return Show-PodeWebToast -Title 'Filter Failed' -Message "Failed to apply active filter: $_"
                            }
                        }

                        New-PodeWebButton -Name 'FilterAllContactsButton' -DisplayName 'Show Active + Deleted' -Icon 'layers' -Colour Blue -ArgumentList $ContactsDatabasePath -ScriptBlock {
                            param($DbPath)
                            try {
                                $rows = Get-MikrotikContactTableData -DatabasePath $DbPath -FilterMode 'All'
                                return @(
                                    ($rows | Update-PodeWebTable -Name 'MikrotikContactsTable')
                                    (Show-PodeWebToast -Title 'Filter' -Message 'Showing active and deleted contacts.')
                                )
                            }
                            catch {
                                return Show-PodeWebToast -Title 'Filter Failed' -Message "Failed to apply all-records filter: $_"
                            }
                        }

                        New-PodeWebButton -Name 'FilterDeletedContactsButton' -DisplayName 'Show Deleted Only' -Icon 'trash-2' -Colour Red -ArgumentList $ContactsDatabasePath -ScriptBlock {
                            param($DbPath)
                            try {
                                $rows = Get-MikrotikContactTableData -DatabasePath $DbPath -FilterMode 'Deleted'
                                return @(
                                    ($rows | Update-PodeWebTable -Name 'MikrotikContactsTable')
                                    (Show-PodeWebToast -Title 'Filter' -Message 'Showing deleted contacts only.')
                                )
                            }
                            catch {
                                return Show-PodeWebToast -Title 'Filter Failed' -Message "Failed to apply deleted filter: $_"
                            }
                        }
                    )

                    New-PodeWebForm -Name 'GetMikrotikContactForm' -AsCard -SubmitText 'Get Contacts' -ShowReset -Content @(
                        New-PodeWebTextbox -Name 'DisplayName' -DisplayName 'Display Name (optional)'
                    ) -ArgumentList $ContactsDatabasePath -ScriptBlock {
                        param($DbPath)

                        try {
                            $displayName = [string]$WebEvent.Data['DisplayName']
                            $rows = Get-MikrotikContactTableData -DatabasePath $DbPath -DisplayName $displayName

                            return @(
                                ($rows | Update-PodeWebTable -Name 'MikrotikContactsTable')
                                (Show-PodeWebToast -Title 'Get' -Message 'Contact table refreshed.')
                            )
                        }
                        catch {
                            return Show-PodeWebToast -Title 'Get Failed' -Message "Failed to query contacts: $_"
                        }
                    }

                    New-PodeWebButton -Name 'RefreshMikrotikContactsButton' -DisplayName 'Refresh Table' -Icon 'refresh-cw' -Colour Blue -ArgumentList $ContactsDatabasePath -ScriptBlock {
                        param($DbPath)
                        try {
                            $rows = Get-MikrotikContactTableData -DatabasePath $DbPath
                            return @(
                                ($rows | Update-PodeWebTable -Name 'MikrotikContactsTable')
                                (Show-PodeWebToast -Title 'Refresh' -Message 'Table refreshed.')
                            )
                        }
                        catch {
                            return Show-PodeWebToast -Title 'Refresh Failed' -Message "Failed to refresh table: $_"
                        }
                    }

                    New-PodeWebForm -Name 'SetMikrotikContactForm' -AsCard -SubmitText 'Set Contact' -ShowReset -Content @(
                        New-PodeWebTextbox -Name 'CurrentDisplayName' -DisplayName 'Current Display Name' -Required
                        New-PodeWebTextbox -Name 'Company' -DisplayName 'Company Name'
                        New-PodeWebTextbox -Name 'DisplayName' -DisplayName 'Display Name'
                        New-PodeWebTextbox -Name 'FirstName' -DisplayName 'First Name'
                        New-PodeWebTextbox -Name 'LastName' -DisplayName 'Last Name'
                        New-PodeWebTextbox -Name 'JobTitle' -DisplayName 'Job Title'
                        New-PodeWebTextbox -Name 'Department' -DisplayName 'Department'
                        New-PodeWebTextbox -Name 'EmailAddress' -DisplayName 'Email Address'
                        New-PodeWebTextbox -Name 'AlternateEmailAddress' -DisplayName 'Alternate Email Address'
                        New-PodeWebTextbox -Name 'Website' -DisplayName 'Website'
                        New-PodeWebTextbox -Name 'Notes' -DisplayName 'Notes'
                        New-PodeWebSelect -Name 'ContactType' -DisplayName 'Contact Type' -Options @('Person', 'Company', 'Vendor')
                        New-PodeWebCheckbox -Name 'NetworkConnectedNew' -DisplayName 'Network Connected (On=True, Off=False)' -AsSwitch
                        New-PodeWebTextbox -Name 'ContactAbbreviation' -DisplayName 'Contact Abbreviation'
                    ) -ArgumentList $ContactsDatabasePath -ScriptBlock {
                        param($DbPath)

                        try {
                            $setParams = @{
                                DatabasePath = $DbPath
                                CurrentDisplayName = [string]$WebEvent.Data['CurrentDisplayName']
                            }

                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['DisplayName'])) { $setParams['DisplayName'] = [string]$WebEvent.Data['DisplayName'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['FirstName'])) { $setParams['FirstName'] = [string]$WebEvent.Data['FirstName'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['LastName'])) { $setParams['LastName'] = [string]$WebEvent.Data['LastName'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['JobTitle'])) { $setParams['JobTitle'] = [string]$WebEvent.Data['JobTitle'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['Department'])) { $setParams['Department'] = [string]$WebEvent.Data['Department'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['Company'])) { $setParams['Company'] = [string]$WebEvent.Data['Company'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['EmailAddress'])) { $setParams['EmailAddress'] = [string]$WebEvent.Data['EmailAddress'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['AlternateEmailAddress'])) { $setParams['AlternateEmailAddress'] = [string]$WebEvent.Data['AlternateEmailAddress'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['Website'])) { $setParams['Website'] = [string]$WebEvent.Data['Website'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['Notes'])) { $setParams['Notes'] = [string]$WebEvent.Data['Notes'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['ContactType'])) { $setParams['ContactType'] = [string]$WebEvent.Data['ContactType'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['ContactAbbreviation'])) { $setParams['ContactAbbreviation'] = [string]$WebEvent.Data['ContactAbbreviation'] }

                            $networkConnectedRaw = $null
                            $networkConnectedCandidates = @('NetworkConnectedNew', 'NetworkConnectedNew[]', 'NetworkConnected', 'NetworkConnected[]')

                            if ($WebEvent.Data -is [System.Collections.IDictionary]) {
                                foreach ($candidate in $networkConnectedCandidates) {
                                    if ($WebEvent.Data.Contains($candidate)) {
                                        $networkConnectedRaw = $WebEvent.Data[$candidate]
                                        break
                                    }
                                }
                            }
                            elseif ($null -ne $WebEvent.Data) {
                                foreach ($candidate in $networkConnectedCandidates) {
                                    $prop = $WebEvent.Data.PSObject.Properties[$candidate]
                                    if ($null -ne $prop) {
                                        $networkConnectedRaw = $prop.Value
                                        break
                                    }
                                }
                            }

                            if ($networkConnectedRaw -is [System.Array]) {
                                $networkConnectedRaw = @($networkConnectedRaw | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) | Select-Object -First 1
                            }

                            $setParams['NetworkConnected'] = $false
                            if ($networkConnectedRaw -is [bool]) {
                                $setParams['NetworkConnected'] = [bool]$networkConnectedRaw
                            }
                            elseif ($null -ne $networkConnectedRaw) {
                                $networkConnectedText = ([string]$networkConnectedRaw).Trim()
                                if ($networkConnectedText -match '^(true|on|1|yes|checked)$') {
                                    $setParams['NetworkConnected'] = $true
                                }
                            }

                            [void](Set-MikrotikContact @setParams)
                            $rows = Get-MikrotikContactTableData -DatabasePath $DbPath

                            return @(
                                ($rows | Update-PodeWebTable -Name 'MikrotikContactsTable')
                                (Show-PodeWebToast -Title 'Set' -Message 'Contact updated successfully.')
                                (Reset-PodeWebForm -Name 'SetMikrotikContactForm')
                            )
                        }
                        catch {
                            return Show-PodeWebToast -Title 'Set Failed' -Message "Failed to update contact: $_"
                        }
                    }

                    New-PodeWebForm -Name 'RemoveMikrotikContactForm' -AsCard -SubmitText 'Remove Contact' -ShowReset -Content @(
                        New-PodeWebTextbox -Name 'DisplayName' -DisplayName 'Display Name' -Required
                    ) -ArgumentList $ContactsDatabasePath -ScriptBlock {
                        param($DbPath)

                        try {
                            $removed = Remove-MikrotikContact -DatabasePath $DbPath -DisplayName ([string]$WebEvent.Data['DisplayName']) -Confirm:$false
                            $rows = Get-MikrotikContactTableData -DatabasePath $DbPath

                            if ($removed) {
                                return @(
                                    ($rows | Update-PodeWebTable -Name 'MikrotikContactsTable')
                                    (Show-PodeWebToast -Title 'Remove' -Message 'Contact marked as deleted successfully.')
                                    (Reset-PodeWebForm -Name 'RemoveMikrotikContactForm')
                                )
                            }

                            return @(
                                ($rows | Update-PodeWebTable -Name 'MikrotikContactsTable')
                                (Show-PodeWebToast -Title 'Remove' -Message 'No matching active Display Name found to remove.')
                            )
                        }
                        catch {
                            return Show-PodeWebToast -Title 'Remove Failed' -Message "Failed to remove contact: $_"
                        }
                    }

                    New-PodeWebForm -Name 'RestoreMikrotikContactForm' -AsCard -SubmitText 'Restore Contact' -ShowReset -Content @(
                        New-PodeWebTextbox -Name 'DisplayName' -DisplayName 'Display Name' -Required
                    ) -ArgumentList $ContactsDatabasePath -ScriptBlock {
                        param($DbPath)

                        try {
                            $restored = Restore-MikrotikContact -DatabasePath $DbPath -DisplayName ([string]$WebEvent.Data['DisplayName']) -Confirm:$false
                            $rows = Get-MikrotikContactTableData -DatabasePath $DbPath

                            if ($restored) {
                                return @(
                                    ($rows | Update-PodeWebTable -Name 'MikrotikContactsTable')
                                    (Show-PodeWebToast -Title 'Restore' -Message 'Contact restored successfully.')
                                    (Reset-PodeWebForm -Name 'RestoreMikrotikContactForm')
                                )
                            }

                            return @(
                                ($rows | Update-PodeWebTable -Name 'MikrotikContactsTable')
                                (Show-PodeWebToast -Title 'Restore' -Message 'No matching deleted Display Name found to restore.')
                            )
                        }
                        catch {
                            return Show-PodeWebToast -Title 'Restore Failed' -Message "Failed to restore contact: $_"
                        }
                    }
                )

                New-PodeWebTab -Name 'Add' -Layouts @(
                    New-PodeWebForm -Name 'NewMikrotikContactForm' -AsCard -SubmitText 'New Contact' -ShowReset -Content @(
                        New-PodeWebTextbox -Name 'Company' -DisplayName 'Company Name'
                        New-PodeWebTextbox -Name 'DisplayName' -DisplayName 'Display Name (optional - auto generated if blank)'
                        New-PodeWebTextbox -Name 'FirstName' -DisplayName 'First Name'
                        New-PodeWebTextbox -Name 'LastName' -DisplayName 'Last Name'
                        New-PodeWebTextbox -Name 'JobTitle' -DisplayName 'Job Title'
                        New-PodeWebTextbox -Name 'Department' -DisplayName 'Department'
                        New-PodeWebTextbox -Name 'EmailAddress' -DisplayName 'Email Address'
                        New-PodeWebTextbox -Name 'AlternateEmailAddress' -DisplayName 'Alternate Email Address'
                        New-PodeWebTextbox -Name 'Website' -DisplayName 'Website'
                        New-PodeWebTextbox -Name 'Notes' -DisplayName 'Notes'
                        New-PodeWebSelect -Name 'ContactType' -DisplayName 'Contact Type' -Options @('Person', 'Company', 'Vendor')
                        New-PodeWebCheckbox -Name 'NetworkConnected' -DisplayName 'Network Connected (On=True, Off=False)' -AsSwitch
                        New-PodeWebTextbox -Name 'ContactAbbreviation' -DisplayName 'Contact Abbreviation'
                    ) -ArgumentList $ContactsDatabasePath -ScriptBlock {
                        param($DbPath)

                        try {
                            if (-not (Get-Command -Name 'New-MikrotikContact' -ErrorAction SilentlyContinue)) {
                                $appRootPath = Split-Path -Parent (Split-Path -Parent $DbPath)
                                $newContactFunctionPath = Join-Path -Path $appRootPath -ChildPath 'Functions\New-MikrotikContact.ps1'

                                if (-not (Test-Path -Path $newContactFunctionPath -PathType Leaf)) {
                                    throw "Could not load New-MikrotikContact. Function file not found: $newContactFunctionPath"
                                }

                                . $newContactFunctionPath
                            }

                            $companyText = ([string]$WebEvent.Data['Company']).Trim()
                            $firstNameText = ([string]$WebEvent.Data['FirstName']).Trim()
                            $lastNameText = ([string]$WebEvent.Data['LastName']).Trim()
                            $fullNameText = @($firstNameText, $lastNameText) -ne ''
                            $fullNameText = ($fullNameText -join ' ').Trim()

                            $displayNameText = ([string]$WebEvent.Data['DisplayName']).Trim()
                            if ([string]::IsNullOrWhiteSpace($displayNameText)) {
                                if (-not [string]::IsNullOrWhiteSpace($companyText)) {
                                    if (-not [string]::IsNullOrWhiteSpace($fullNameText)) {
                                        $displayNameText = "$companyText ($fullNameText)"
                                    }
                                    else {
                                        $displayNameText = $companyText
                                    }
                                }
                                elseif (-not [string]::IsNullOrWhiteSpace($fullNameText)) {
                                    $displayNameText = $fullNameText
                                }
                            }

                            if ([string]::IsNullOrWhiteSpace($displayNameText)) {
                                throw 'Display Name is required, or provide Company and/or First Name/Last Name for auto-generation.'
                            }

                            $newParams = @{
                                DatabasePath = $DbPath
                                DisplayName = $displayNameText
                            }

                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['FirstName'])) { $newParams['FirstName'] = [string]$WebEvent.Data['FirstName'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['LastName'])) { $newParams['LastName'] = [string]$WebEvent.Data['LastName'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['JobTitle'])) { $newParams['JobTitle'] = [string]$WebEvent.Data['JobTitle'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['Department'])) { $newParams['Department'] = [string]$WebEvent.Data['Department'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['Company'])) { $newParams['Company'] = [string]$WebEvent.Data['Company'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['EmailAddress'])) { $newParams['EmailAddress'] = [string]$WebEvent.Data['EmailAddress'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['AlternateEmailAddress'])) { $newParams['AlternateEmailAddress'] = [string]$WebEvent.Data['AlternateEmailAddress'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['Website'])) { $newParams['Website'] = [string]$WebEvent.Data['Website'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['Notes'])) { $newParams['Notes'] = [string]$WebEvent.Data['Notes'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['ContactType'])) { $newParams['ContactType'] = [string]$WebEvent.Data['ContactType'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['ContactAbbreviation'])) { $newParams['ContactAbbreviation'] = [string]$WebEvent.Data['ContactAbbreviation'] }

                            $networkConnectedRaw = $null
                            $networkConnectedCandidates = @('NetworkConnected', 'NetworkConnected[]', 'NetworkConnectedNew', 'NetworkConnectedNew[]')

                            if ($WebEvent.Data -is [System.Collections.IDictionary]) {
                                foreach ($candidate in $networkConnectedCandidates) {
                                    if ($WebEvent.Data.Contains($candidate)) {
                                        $networkConnectedRaw = $WebEvent.Data[$candidate]
                                        break
                                    }
                                }
                            }
                            elseif ($null -ne $WebEvent.Data) {
                                foreach ($candidate in $networkConnectedCandidates) {
                                    $prop = $WebEvent.Data.PSObject.Properties[$candidate]
                                    if ($null -ne $prop) {
                                        $networkConnectedRaw = $prop.Value
                                        break
                                    }
                                }
                            }

                            if ($networkConnectedRaw -is [System.Array]) {
                                $networkConnectedRaw = @($networkConnectedRaw | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) | Select-Object -First 1
                            }

                            $newParams['NetworkConnected'] = $false
                            if ($networkConnectedRaw -is [bool]) {
                                $newParams['NetworkConnected'] = [bool]$networkConnectedRaw
                            }
                            elseif ($null -ne $networkConnectedRaw) {
                                $networkConnectedText = ([string]$networkConnectedRaw).Trim()
                                if ($networkConnectedText -match '^(true|on|1|yes|checked)$') {
                                    $newParams['NetworkConnected'] = $true
                                }
                            }

                            [void](New-MikrotikContact @newParams)
                            $rows = Get-MikrotikContactTableData -DatabasePath $DbPath

                            return @(
                                ($rows | Update-PodeWebTable -Name 'MikrotikContactsTable')
                                (Show-PodeWebToast -Title 'New' -Message 'Contact added successfully.')
                                (Reset-PodeWebForm -Name 'NewMikrotikContactForm')
                            )
                        }
                        catch {
                            return Show-PodeWebToast -Title 'New Failed' -Message "Failed to add contact: $_"
                        }
                    }
                )
            )

            New-PodeWebCard -Name 'MikrotikContactCrud' -DisplayName 'Contacts (LiteDB)' -Content @(
                New-PodeWebText -Value "Database: $ContactsDatabasePath"
                New-PodeWebTabs -Tabs $contactTabs
            )
        }

        Add-PodeWebPage -Name 'Contact Locations' -Title 'Contact Locations' -Icon 'map-pin' -ArgumentList $script:DeviceDatabasePath -ScriptBlock {
            param($ContactsDatabasePath)

            $locationTabs = @(
                New-PodeWebTab -Name 'view' -Layouts @(
                    New-PodeWebTable -Name 'MikrotikContactLocationsTable' -Sort -SimpleFilter -Compact -ArgumentList $ContactsDatabasePath -ScriptBlock {
                        param($DbPath)
                        try {
                            return Get-MikrotikContactLocationTableData -DatabasePath $DbPath
                        }
                        catch {
                            return @(
                                [PSCustomObject]@{
                                    LocationId   = 'No records found'
                                    ContactId    = ''
                                    LocationName = ''
                                    AddressLine1 = ''
                                    City         = ''
                                    State        = ''
                                    PostalCode   = ''
                                    Country      = ''
                                    IsPrimary    = ''
                                    IsDeleted    = ''
                                    ModifiedDate = ''
                                }
                            )
                        }
                    } -Columns @(
                        Initialize-PodeWebTableColumn -Key 'LocationId' -Width 3
                        Initialize-PodeWebTableColumn -Key 'ContactId' -Width 3
                        Initialize-PodeWebTableColumn -Key 'LocationName' -Width 2
                        Initialize-PodeWebTableColumn -Key 'AddressLine1' -Width 3
                        Initialize-PodeWebTableColumn -Key 'City' -Width 2
                        Initialize-PodeWebTableColumn -Key 'State' -Width 1
                        Initialize-PodeWebTableColumn -Key 'PostalCode' -Width 1
                        Initialize-PodeWebTableColumn -Key 'Country' -Width 1
                        Initialize-PodeWebTableColumn -Key 'IsPrimary' -Width 1
                        Initialize-PodeWebTableColumn -Key 'IsDeleted' -Width 1
                        Initialize-PodeWebTableColumn -Key 'ModifiedDate' -Width 2
                    )

                    New-PodeWebCard -Name 'MikrotikLocationTableFilters' -DisplayName 'Table Filters' -Content @(
                        New-PodeWebButton -Name 'FilterActiveLocationsButton' -DisplayName 'Show Active' -Icon 'filter' -Colour Green -ArgumentList $ContactsDatabasePath -ScriptBlock {
                            param($DbPath)
                            try {
                                $rows = Get-MikrotikContactLocationTableData -DatabasePath $DbPath -FilterMode 'Active'
                                return @(
                                    ($rows | Update-PodeWebTable -Name 'MikrotikContactLocationsTable')
                                    (Show-PodeWebToast -Title 'Filter' -Message 'Showing active locations only.')
                                )
                            }
                            catch {
                                return Show-PodeWebToast -Title 'Filter Failed' -Message "Failed to apply active filter: $_"
                            }
                        }

                        New-PodeWebButton -Name 'FilterAllLocationsButton' -DisplayName 'Show Active + Deleted' -Icon 'layers' -Colour Blue -ArgumentList $ContactsDatabasePath -ScriptBlock {
                            param($DbPath)
                            try {
                                $rows = Get-MikrotikContactLocationTableData -DatabasePath $DbPath -FilterMode 'All'
                                return @(
                                    ($rows | Update-PodeWebTable -Name 'MikrotikContactLocationsTable')
                                    (Show-PodeWebToast -Title 'Filter' -Message 'Showing active and deleted locations.')
                                )
                            }
                            catch {
                                return Show-PodeWebToast -Title 'Filter Failed' -Message "Failed to apply all-records filter: $_"
                            }
                        }

                        New-PodeWebButton -Name 'FilterDeletedLocationsButton' -DisplayName 'Show Deleted Only' -Icon 'trash-2' -Colour Red -ArgumentList $ContactsDatabasePath -ScriptBlock {
                            param($DbPath)
                            try {
                                $rows = Get-MikrotikContactLocationTableData -DatabasePath $DbPath -FilterMode 'Deleted'
                                return @(
                                    ($rows | Update-PodeWebTable -Name 'MikrotikContactLocationsTable')
                                    (Show-PodeWebToast -Title 'Filter' -Message 'Showing deleted locations only.')
                                )
                            }
                            catch {
                                return Show-PodeWebToast -Title 'Filter Failed' -Message "Failed to apply deleted filter: $_"
                            }
                        }
                    )

                    New-PodeWebForm -Name 'GetMikrotikContactLocationForm' -AsCard -SubmitText 'Get Locations' -ShowReset -Content @(
                        New-PodeWebTextbox -Name 'DisplayName' -DisplayName 'Contact Display Name (optional)'
                    ) -ArgumentList $ContactsDatabasePath -ScriptBlock {
                        param($DbPath)

                        try {
                            $displayName = [string]$WebEvent.Data['DisplayName']
                            $rows = Get-MikrotikContactLocationTableData -DatabasePath $DbPath -DisplayName $displayName

                            return @(
                                ($rows | Update-PodeWebTable -Name 'MikrotikContactLocationsTable')
                                (Show-PodeWebToast -Title 'Get' -Message 'Location table refreshed.')
                            )
                        }
                        catch {
                            return Show-PodeWebToast -Title 'Get Failed' -Message "Failed to query locations: $_"
                        }
                    }

                    New-PodeWebButton -Name 'RefreshMikrotikContactLocationsButton' -DisplayName 'Refresh Table' -Icon 'refresh-cw' -Colour Blue -ArgumentList $ContactsDatabasePath -ScriptBlock {
                        param($DbPath)
                        try {
                            $rows = Get-MikrotikContactLocationTableData -DatabasePath $DbPath
                            return @(
                                ($rows | Update-PodeWebTable -Name 'MikrotikContactLocationsTable')
                                (Show-PodeWebToast -Title 'Refresh' -Message 'Table refreshed.')
                            )
                        }
                        catch {
                            return Show-PodeWebToast -Title 'Refresh Failed' -Message "Failed to refresh table: $_"
                        }
                    }

                    New-PodeWebForm -Name 'SetMikrotikContactLocationForm' -AsCard -SubmitText 'Set Location' -ShowReset -Content @(
                        New-PodeWebTextbox -Name 'LocationId' -DisplayName 'Location Id' -Required
                        New-PodeWebSelect -Name 'ContactDisplayName' -DisplayName 'Contact (optional relink)' -ScriptBlock {
                            return Get-MikrotikActiveContactDisplayNames -DatabasePath $ContactsDatabasePath
                        }
                        New-PodeWebTextbox -Name 'LocationName' -DisplayName 'Location Name'
                        New-PodeWebTextbox -Name 'AddressLine1' -DisplayName 'Address Line 1'
                        New-PodeWebTextbox -Name 'AddressLine2' -DisplayName 'Address Line 2'
                        New-PodeWebTextbox -Name 'City' -DisplayName 'City'
                        New-PodeWebTextbox -Name 'State' -DisplayName 'State'
                        New-PodeWebTextbox -Name 'PostalCode' -DisplayName 'Postal Code'
                        New-PodeWebTextbox -Name 'Country' -DisplayName 'Country'
                        New-PodeWebTextbox -Name 'PhoneNumber' -DisplayName 'Phone Number'
                        New-PodeWebTextbox -Name 'MobileNumber' -DisplayName 'Mobile Number'
                        New-PodeWebTextbox -Name 'WorkPhoneNumber' -DisplayName 'Work Phone Number'
                        New-PodeWebCheckbox -Name 'IsPrimary' -DisplayName 'Is Primary (On=True, Off=False)' -AsSwitch
                    ) -ArgumentList $ContactsDatabasePath -ScriptBlock {
                        param($DbPath)

                        try {
                            $setParams = @{
                                DatabasePath = $DbPath
                                LocationId = [string]$WebEvent.Data['LocationId']
                            }

                            $selectedContactDisplayName = [string]$WebEvent.Data['ContactDisplayName']
                            if (-not [string]::IsNullOrWhiteSpace($selectedContactDisplayName)) {
                                $selectedContact = @(
                                    Get-MikrotikContact -DatabasePath $DbPath -DisplayName $selectedContactDisplayName -ErrorAction Stop | Where-Object {
                                        -not $_.IsDeleted
                                    }
                                ) | Select-Object -First 1

                                if ($null -eq $selectedContact -or [string]::IsNullOrWhiteSpace([string]$selectedContact.ContactId)) {
                                    throw "Selected contact '$selectedContactDisplayName' could not be resolved."
                                }

                                $setParams['ContactId'] = [string]$selectedContact.ContactId
                            }

                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['LocationName'])) { $setParams['LocationName'] = [string]$WebEvent.Data['LocationName'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['AddressLine1'])) { $setParams['AddressLine1'] = [string]$WebEvent.Data['AddressLine1'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['AddressLine2'])) { $setParams['AddressLine2'] = [string]$WebEvent.Data['AddressLine2'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['City'])) { $setParams['City'] = [string]$WebEvent.Data['City'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['State'])) { $setParams['State'] = [string]$WebEvent.Data['State'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['PostalCode'])) { $setParams['PostalCode'] = [string]$WebEvent.Data['PostalCode'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['Country'])) { $setParams['Country'] = [string]$WebEvent.Data['Country'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['PhoneNumber'])) { $setParams['PhoneNumber'] = [string]$WebEvent.Data['PhoneNumber'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['MobileNumber'])) { $setParams['MobileNumber'] = [string]$WebEvent.Data['MobileNumber'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['WorkPhoneNumber'])) { $setParams['WorkPhoneNumber'] = [string]$WebEvent.Data['WorkPhoneNumber'] }

                            if ($WebEvent.Data.ContainsKey('IsPrimary')) {
                                $isPrimaryRaw = $WebEvent.Data['IsPrimary']
                                $isPrimaryParsed = $false

                                if ($isPrimaryRaw -is [bool]) {
                                    $isPrimaryParsed = [bool]$isPrimaryRaw
                                }
                                elseif ($null -ne $isPrimaryRaw) {
                                    $isPrimaryText = [string]$isPrimaryRaw
                                    if (-not [string]::IsNullOrWhiteSpace($isPrimaryText)) {
                                        if ($isPrimaryText -match '^(true|on|1)$') {
                                            $isPrimaryParsed = $true
                                        }
                                        elseif ($isPrimaryText -match '^(false|off|0)$') {
                                            $isPrimaryParsed = $false
                                        }
                                        elseif (-not [bool]::TryParse($isPrimaryText, [ref]$isPrimaryParsed)) {
                                            throw "IsPrimary must be a valid boolean toggle value."
                                        }
                                    }
                                }

                                $setParams['IsPrimary'] = $isPrimaryParsed
                            }

                            [void](Set-MikrotikContactLocation @setParams)
                            $rows = Get-MikrotikContactLocationTableData -DatabasePath $DbPath

                            return @(
                                ($rows | Update-PodeWebTable -Name 'MikrotikContactLocationsTable')
                                (Show-PodeWebToast -Title 'Set' -Message 'Location updated successfully.')
                                (Reset-PodeWebForm -Name 'SetMikrotikContactLocationForm')
                            )
                        }
                        catch {
                            return Show-PodeWebToast -Title 'Set Failed' -Message "Failed to update location: $_"
                        }
                    }

                    New-PodeWebForm -Name 'RemoveMikrotikContactLocationForm' -AsCard -SubmitText 'Remove Location' -ShowReset -Content @(
                        New-PodeWebTextbox -Name 'LocationId' -DisplayName 'Location Id' -Required
                    ) -ArgumentList $ContactsDatabasePath -ScriptBlock {
                        param($DbPath)

                        try {
                            $removed = Remove-MikrotikContactLocation -DatabasePath $DbPath -LocationId ([string]$WebEvent.Data['LocationId']) -Confirm:$false
                            $rows = Get-MikrotikContactLocationTableData -DatabasePath $DbPath

                            if ($removed) {
                                return @(
                                    ($rows | Update-PodeWebTable -Name 'MikrotikContactLocationsTable')
                                    (Show-PodeWebToast -Title 'Remove' -Message 'Location marked as deleted successfully.')
                                    (Reset-PodeWebForm -Name 'RemoveMikrotikContactLocationForm')
                                )
                            }

                            return @(
                                ($rows | Update-PodeWebTable -Name 'MikrotikContactLocationsTable')
                                (Show-PodeWebToast -Title 'Remove' -Message 'No matching active location found to remove.')
                            )
                        }
                        catch {
                            return Show-PodeWebToast -Title 'Remove Failed' -Message "Failed to remove location: $_"
                        }
                    }

                    New-PodeWebForm -Name 'RestoreMikrotikContactLocationForm' -AsCard -SubmitText 'Restore Location' -ShowReset -Content @(
                        New-PodeWebTextbox -Name 'LocationId' -DisplayName 'Location Id' -Required
                    ) -ArgumentList $ContactsDatabasePath -ScriptBlock {
                        param($DbPath)

                        try {
                            $restored = Restore-MikrotikContactLocation -DatabasePath $DbPath -LocationId ([string]$WebEvent.Data['LocationId']) -Confirm:$false
                            $rows = Get-MikrotikContactLocationTableData -DatabasePath $DbPath

                            if ($restored) {
                                return @(
                                    ($rows | Update-PodeWebTable -Name 'MikrotikContactLocationsTable')
                                    (Show-PodeWebToast -Title 'Restore' -Message 'Location restored successfully.')
                                    (Reset-PodeWebForm -Name 'RestoreMikrotikContactLocationForm')
                                )
                            }

                            return @(
                                ($rows | Update-PodeWebTable -Name 'MikrotikContactLocationsTable')
                                (Show-PodeWebToast -Title 'Restore' -Message 'No matching deleted location found to restore.')
                            )
                        }
                        catch {
                            return Show-PodeWebToast -Title 'Restore Failed' -Message "Failed to restore location: $_"
                        }
                    }
                )

                New-PodeWebTab -Name 'Add' -Layouts @(
                    New-PodeWebForm -Name 'NewMikrotikContactLocationForm' -AsCard -SubmitText 'New Location' -ShowReset -Content @(
                        New-PodeWebSelect -Name 'ContactDisplayName' -DisplayName 'Contact' -Required -ScriptBlock {
                            return Get-MikrotikActiveContactDisplayNames -DatabasePath $ContactsDatabasePath
                        }
                        New-PodeWebTextbox -Name 'LocationName' -DisplayName 'Location Name'
                        New-PodeWebTextbox -Name 'AddressLine1' -DisplayName 'Address Line 1'
                        New-PodeWebTextbox -Name 'AddressLine2' -DisplayName 'Address Line 2'
                        New-PodeWebTextbox -Name 'City' -DisplayName 'City'
                        New-PodeWebTextbox -Name 'State' -DisplayName 'State'
                        New-PodeWebTextbox -Name 'PostalCode' -DisplayName 'Postal Code'
                        New-PodeWebTextbox -Name 'Country' -DisplayName 'Country'
                        New-PodeWebTextbox -Name 'PhoneNumber' -DisplayName 'Phone Number'
                        New-PodeWebTextbox -Name 'MobileNumber' -DisplayName 'Mobile Number'
                        New-PodeWebTextbox -Name 'WorkPhoneNumber' -DisplayName 'Work Phone Number'
                        New-PodeWebCheckbox -Name 'IsPrimary' -DisplayName 'Is Primary (On=True, Off=False)' -AsSwitch
                    ) -ArgumentList $ContactsDatabasePath -ScriptBlock {
                        param($DbPath)

                        try {
                            $newParams = @{
                                DatabasePath = $DbPath
                            }

                            $displayName = [string]$WebEvent.Data['ContactDisplayName']
                            if ([string]::IsNullOrWhiteSpace($displayName)) {
                                throw 'Contact selection is required.'
                            }

                            $newParams['DisplayName'] = $displayName

                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['LocationName'])) { $newParams['LocationName'] = [string]$WebEvent.Data['LocationName'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['AddressLine1'])) { $newParams['AddressLine1'] = [string]$WebEvent.Data['AddressLine1'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['AddressLine2'])) { $newParams['AddressLine2'] = [string]$WebEvent.Data['AddressLine2'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['City'])) { $newParams['City'] = [string]$WebEvent.Data['City'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['State'])) { $newParams['State'] = [string]$WebEvent.Data['State'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['PostalCode'])) { $newParams['PostalCode'] = [string]$WebEvent.Data['PostalCode'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['Country'])) { $newParams['Country'] = [string]$WebEvent.Data['Country'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['PhoneNumber'])) { $newParams['PhoneNumber'] = [string]$WebEvent.Data['PhoneNumber'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['MobileNumber'])) { $newParams['MobileNumber'] = [string]$WebEvent.Data['MobileNumber'] }
                            if (-not [string]::IsNullOrWhiteSpace([string]$WebEvent.Data['WorkPhoneNumber'])) { $newParams['WorkPhoneNumber'] = [string]$WebEvent.Data['WorkPhoneNumber'] }

                            if ($WebEvent.Data.ContainsKey('IsPrimary')) {
                                $isPrimaryRaw = $WebEvent.Data['IsPrimary']
                                $isPrimaryParsed = $false

                                if ($isPrimaryRaw -is [bool]) {
                                    $isPrimaryParsed = [bool]$isPrimaryRaw
                                }
                                elseif ($null -ne $isPrimaryRaw) {
                                    $isPrimaryText = [string]$isPrimaryRaw
                                    if (-not [string]::IsNullOrWhiteSpace($isPrimaryText)) {
                                        if ($isPrimaryText -match '^(true|on|1)$') {
                                            $isPrimaryParsed = $true
                                        }
                                        elseif ($isPrimaryText -match '^(false|off|0)$') {
                                            $isPrimaryParsed = $false
                                        }
                                        elseif (-not [bool]::TryParse($isPrimaryText, [ref]$isPrimaryParsed)) {
                                            throw "IsPrimary must be a valid boolean toggle value."
                                        }
                                    }
                                }

                                $newParams['IsPrimary'] = $isPrimaryParsed
                            }

                            [void](New-MikrotikContactLocation @newParams)
                            $rows = Get-MikrotikContactLocationTableData -DatabasePath $DbPath

                            return @(
                                ($rows | Update-PodeWebTable -Name 'MikrotikContactLocationsTable')
                                (Show-PodeWebToast -Title 'New' -Message 'Location added successfully.')
                                (Reset-PodeWebForm -Name 'NewMikrotikContactLocationForm')
                            )
                        }
                        catch {
                            return Show-PodeWebToast -Title 'New Failed' -Message "Failed to add location: $_"
                        }
                    }
                )

                New-PodeWebTab -Name 'Link' -Layouts @(
                    New-PodeWebForm -Name 'LinkMikrotikContactToLocationsForm' -AsCard -SubmitText 'Link Contact To Locations' -ShowReset -Content @(
                        New-PodeWebSelect -Name 'ContactDisplayName' -DisplayName 'Contact' -Required -ScriptBlock {
                            return Get-MikrotikActiveContactDisplayNames -DatabasePath $ContactsDatabasePath
                        }
                        New-PodeWebSelect -Name 'LocationIds' -DisplayName 'Locations' -Required -Multiple -Size 10 -ScriptBlock {
                            return Get-MikrotikActiveLocationIds -DatabasePath $ContactsDatabasePath
                        }
                    ) -ArgumentList $ContactsDatabasePath -ScriptBlock {
                        param($DbPath)

                        try {
                            $selectedContactDisplayName = [string]$WebEvent.Data['ContactDisplayName']
                            if ([string]::IsNullOrWhiteSpace($selectedContactDisplayName)) {
                                throw 'Contact selection is required.'
                            }

                            $contactId = Get-MikrotikActiveContactIdByDisplayName -DatabasePath $DbPath -DisplayName $selectedContactDisplayName
                            if ([string]::IsNullOrWhiteSpace($contactId)) {
                                throw "Could not resolve ContactId for '$selectedContactDisplayName'."
                            }

                            $selectedLocationIds = @($WebEvent.Data['LocationIds']) | Where-Object {
                                -not [string]::IsNullOrWhiteSpace([string]$_)
                            }

                            if ($selectedLocationIds.Count -eq 0) {
                                throw 'At least one location must be selected.'
                            }

                            $linkedCount = 0
                            foreach ($locationId in $selectedLocationIds) {
                                [void](Set-MikrotikContactLocation -DatabasePath $DbPath -LocationId ([string]$locationId) -ContactId $contactId)
                                $linkedCount++
                            }

                            $rows = Get-MikrotikContactLocationTableData -DatabasePath $DbPath
                            return @(
                                ($rows | Update-PodeWebTable -Name 'MikrotikContactLocationsTable')
                                (Show-PodeWebToast -Title 'Link Complete' -Message "Linked $linkedCount location(s) to '$selectedContactDisplayName'.")
                                (Reset-PodeWebForm -Name 'LinkMikrotikContactToLocationsForm')
                            )
                        }
                        catch {
                            return Show-PodeWebToast -Title 'Link Failed' -Message "Failed to create links: $_"
                        }
                    }
                )
            )

            New-PodeWebCard -Name 'MikrotikContactLocationCrud' -DisplayName 'Contact Locations (LiteDB)' -Content @(
                New-PodeWebText -Value "Database: $ContactsDatabasePath"
                New-PodeWebTabs -Tabs $locationTabs
            )
        }
    }
}
catch {
    Write-Error "Pode.Web server error: $_"
    Write-SafeAdvancedLog -Message "Pode.Web server error: $_" -LogType 'ERROR'
}

# Example footer
# PS> .\StartMikrotikRouterOSManagementWeb.ps1
# PS> .\StartMikrotikRouterOSManagementWeb.ps1 -Port 9095 -Verbose
# PS> .\StartMikrotikRouterOSManagementWeb.ps1 -Address '127.0.0.1' -Port 8090
