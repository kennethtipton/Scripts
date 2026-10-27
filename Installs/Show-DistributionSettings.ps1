<#
.SYNOPSIS
    Window to edit how devices reach the scripts: the DFS, SFTP and FTP transports, for all devices or one device.
.DESCRIPTION
    Edits Transports in C:\SCRIPTS\Data\Settings\Scripts.json (the defaults for every device) and
    the per-device override files Scripts.<COMPUTERNAME>.json next to it.

      All devices   values are saved in Scripts.json.
      One device    the window shows the device's effective values (defaults plus its override);
                    on save only the values that differ from the defaults are written to
                    Scripts.<DEVICE>.json (other settings in that file are kept). A device whose
                    override ends up empty has its override file removed. Labels in bold are
                    overridden for that device.

    Per transport: Enabled, Priority (1 is tried first) and its connection values. Credential is
    only the name of the SSH key (SFTP) or the machine-encrypted password (FTP) kept on each device;
    no secret is ever written to these files.

    The files are only changed on this machine; they reach the devices with the next copy
    (Base copies Data\Settings\Scripts*.json) or publish.

    Opened from SetupApplications (Distribution...), or on its own:
      powershell.exe -STA -Command ". C:\SCRIPTS\Installs\Show-DistributionSettings.ps1; Show-DistributionSettings"
.PARAMETER SettingsPath
    Settings file. Defaults to C:\SCRIPTS\Data\Settings\Scripts.json.
.PARAMETER Devices
    Devices to offer in the list besides those that already have an override file (FQDN or short name).
.PARAMETER Owner
    Window to center on and block while open.
.PARAMETER LogFileName
    Base name of the text log file in C:\SCRIPTS\Logs. Saves are logged there.
.EXAMPLE
    PS> . C:\SCRIPTS\Installs\Show-DistributionSettings.ps1; Show-DistributionSettings
.EXAMPLE
    PS> Show-DistributionSettings -Devices srv010010037050.generationsgaither.com, srv010010050050.generationsgaither.com
.INPUTS
    [string] SettingsPath, [string[]] Devices, [object] Owner, [string] LogFileName
.OUTPUTS
    [bool] True when anything was saved.
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-15
    Time: 12:00:00
    Time Zone: Central Standard Time
    Function Or Application: Function
    Version: 1.0.0
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: Claude

    Copyright (c) 2026
    Licensed under the MIT License.
    Full text available at: https://opensource.org/licenses/MIT

    Overide Variables
    Overide Filename:
    Overide Log Filename: SetupApplications
    Overide Text Log File Path:
    Overide Log Type:
.LINK
    https://www.tnandc.com
#>

#region Settings file helpers (no window needed; also used by tests)
# pscustomobject from ConvertFrom-Json -> ordered tables, so values can be changed and keys keep their order
function ConvertTo-OrderedSetting {
    param($Value)
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $O = [ordered]@{}
        foreach ($P in $Value.PSObject.Properties) { $O[$P.Name] = ConvertTo-OrderedSetting $P.Value }
        return $O
    }
    if ($Value -is [System.Array]) { return , @($Value | ForEach-Object { ConvertTo-OrderedSetting $_ }) }
    $Value
}

function Read-SettingFile {
    param([string]$Path)
    if (-not (Test-Path -Path $Path -PathType Leaf)) { return [ordered]@{} }
    $Text = Get-Content -Path $Path -Raw
    if (-not $Text.Trim()) { return [ordered]@{} }
    ConvertTo-OrderedSetting ($Text | ConvertFrom-Json)
}

# Same JSON layout in Windows PowerShell 5.1 and PowerShell 7 (2-space indent, no \u escapes)
function ConvertTo-SettingJson {
    param($Value, [int]$Depth = 0)
    $Pad = '  ' * ($Depth + 1); $End = '  ' * $Depth
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $Value.ToString().ToLower() }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return [string]$Value }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) { return '{}' }
        $Items = foreach ($K in $Value.Keys) { '{0}{1}: {2}' -f $Pad, (ConvertTo-SettingJson ([string]$K)), (ConvertTo-SettingJson $Value[$K] ($Depth + 1)) }
        return "{`r`n" + ($Items -join ",`r`n") + "`r`n$End}"
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $Arr = @($Value)
        if ($Arr.Count -eq 0) { return '[]' }
        $Items = foreach ($V in $Arr) { $Pad + (ConvertTo-SettingJson $V ($Depth + 1)) }
        return "[`r`n" + ($Items -join ",`r`n") + "`r`n$End]"
    }
    $S = [string]$Value
    $S = $S.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    '"' + $S + '"'
}

function Save-SettingFile {
    param([string]$Path, $Data)
    $Tmp = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N').Substring(0, 8)
    [System.IO.File]::WriteAllText($Tmp, (ConvertTo-SettingJson $Data) + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Path $Tmp -Destination $Path -Force
}

# Defaults with an override applied, objects merged at every depth (as Get-ApplicationSettings does)
function Merge-SettingTable {
    param($Base, $Over)
    $R = [ordered]@{}
    foreach ($K in $Base.Keys) { $R[$K] = $Base[$K] }
    foreach ($K in $Over.Keys) {
        if ($Over[$K] -is [System.Collections.IDictionary] -and $R[$K] -is [System.Collections.IDictionary]) { $R[$K] = Merge-SettingTable $R[$K] $Over[$K] }
        else { $R[$K] = $Over[$K] }
    }
    $R
}

# The fields shown for each transport type, in display order
function Get-TransportFieldList {
    param([string]$Type)
    switch ($Type) {
        'Dfs'   { @('Root') }
        'Sftp'  { @('Host', 'Port', 'Root', 'User', 'Credential') }
        'Ftp'   { @('Host', 'Port', 'Encryption', 'Root', 'User', 'Credential') }
        default { @('Host', 'Port', 'Root', 'User', 'Credential') }
    }
}

# Values for one device: only what differs from the defaults ($null = nothing to override)
function Get-TransportOverride {
    param($DefaultTransports, $DeviceTransports)
    $Out = [ordered]@{}
    foreach ($Key in $DeviceTransports.Keys) {
        $Def = if ($DefaultTransports.Contains($Key)) { $DefaultTransports[$Key] } else { [ordered]@{} }
        $Diff = [ordered]@{}
        foreach ($F in $DeviceTransports[$Key].Keys) {
            $A = $DeviceTransports[$Key][$F]; $B = if ($Def.Contains($F)) { $Def[$F] } else { $null }
            if ("$A" -cne "$B") { $Diff[$F] = $A }
        }
        if ($Diff.Count) { $Out[$Key] = $Diff }
    }
    if ($Out.Count) { $Out } else { $null }
}

# Problems that should stop a save (empty list = fine)
function Test-TransportValue {
    param($Transports)
    $Bad = @()
    foreach ($Key in $Transports.Keys) {
        $T = $Transports[$Key]
        if (-not $T['Enabled']) { continue }
        switch ($T['Type']) {
            'Dfs' { if ("$($T['Root'])" -notmatch '^\\\\[^\\]+\\[^\\]+') { $Bad += "${Key}: Root must be a UNC path (\\server\share\...)." } }
            default {
                if (-not "$($T['Host'])") { $Bad += "${Key}: Host is empty." }
                if ("$($T['Root'])" -and "$($T['Root'])" -notmatch '^/') { $Bad += "${Key}: Root must start with / (a folder on the $($T['Type']) server)." }
                if (-not "$($T['Credential'])") { $Bad += "${Key}: Credential (the name of the key or password on the device) is empty." }
            }
        }
    }
    $Bad
}
#endregion

function Show-DistributionSettings {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$SettingsPath = (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Data\Settings\Scripts.json'),

        [Parameter(Mandatory = $false)]
        [string[]]$Devices = @(),

        # A System.Windows.Forms.IWin32Window; typed loosely so this file loads before WinForms is
        [Parameter(Mandatory = $false)]
        [object]$Owner,

        [Parameter(Mandatory = $false)]
        [string]$LogFileName = 'SetupApplications'
    )

    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    if (-not (Test-Path -Path $SettingsPath -PathType Leaf)) { throw "Settings file not found: $SettingsPath" }
    $Folder = Split-Path -Path $SettingsPath -Parent
    $Leaf = [System.IO.Path]::GetFileNameWithoutExtension($SettingsPath)
    $WriteLogPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Functions\Write-AdvancedLog.ps1'
    if (Test-Path -Path $WriteLogPath) { . $WriteLogPath }
    function Write-DistLog {
        param([string]$Message)
        if (Get-Command -Name Write-AdvancedLog -ErrorAction SilentlyContinue) {
            try { Write-AdvancedLog -Message $Message -ScriptName 'Show-DistributionSettings.ps1' -LogFileName $LogFileName -LogType INFO } catch { }
        }
    }

    $State = @{ Saved = $false; Dirty = $false; Loading = $false; Scope = ''; Fields = @{}; Labels = @{} }

    #region Window
    $D = New-Object System.Windows.Forms.Form
    $D.Text = "Distribution settings  ($SettingsPath)"
    $D.Size = New-Object System.Drawing.Size(720, 560)
    $D.MinimumSize = New-Object System.Drawing.Size(620, 480)
    $D.StartPosition = if ($Owner) { 'CenterParent' } else { 'CenterScreen' }
    $D.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $Top = New-Object System.Windows.Forms.FlowLayoutPanel
    $Top.Dock = 'Top'; $Top.AutoSize = $true; $Top.Padding = New-Object System.Windows.Forms.Padding(6)
    $ScopeLabel = New-Object System.Windows.Forms.Label; $ScopeLabel.Text = 'Settings for:'; $ScopeLabel.AutoSize = $true
    $ScopeLabel.Margin = New-Object System.Windows.Forms.Padding(3, 7, 3, 3)
    $ScopeBox = New-Object System.Windows.Forms.ComboBox; $ScopeBox.DropDownStyle = 'DropDownList'; $ScopeBox.Width = 300
    $NewDevice = New-Object System.Windows.Forms.TextBox; $NewDevice.Width = 160
    $AddDevice = New-Object System.Windows.Forms.Button; $AddDevice.Text = 'Add device'; $AddDevice.AutoSize = $true
    $Top.Controls.AddRange(@($ScopeLabel, $ScopeBox, $NewDevice, $AddDevice))

    $Info = New-Object System.Windows.Forms.Label
    $Info.Dock = 'Top'; $Info.Height = 38; $Info.Padding = New-Object System.Windows.Forms.Padding(9, 2, 9, 2)

    $Tabs = New-Object System.Windows.Forms.TabControl; $Tabs.Dock = 'Fill'

    $Bottom = New-Object System.Windows.Forms.FlowLayoutPanel
    $Bottom.Dock = 'Bottom'; $Bottom.AutoSize = $true; $Bottom.Padding = New-Object System.Windows.Forms.Padding(6)
    $AddTransport = New-Object System.Windows.Forms.Button; $AddTransport.Text = 'Add transport...'; $AddTransport.AutoSize = $true
    $ResetDevice = New-Object System.Windows.Forms.Button; $ResetDevice.Text = 'Reset device to defaults'; $ResetDevice.AutoSize = $true
    $SaveButton = New-Object System.Windows.Forms.Button; $SaveButton.Text = 'Save'; $SaveButton.AutoSize = $true
    $CloseButton = New-Object System.Windows.Forms.Button; $CloseButton.Text = 'Close'; $CloseButton.AutoSize = $true
    $StatusLabel = New-Object System.Windows.Forms.Label; $StatusLabel.AutoSize = $true
    $StatusLabel.Margin = New-Object System.Windows.Forms.Padding(12, 8, 3, 3)
    $Bottom.Controls.AddRange(@($AddTransport, $ResetDevice, $SaveButton, $CloseButton, $StatusLabel))

    $D.Controls.Add($Tabs); $D.Controls.Add($Info); $D.Controls.Add($Top); $D.Controls.Add($Bottom)
    #endregion

    #region Data
    function Get-Defaults { Read-SettingFile -Path $SettingsPath }
    function Get-OverridePath { param([string]$Device) Join-Path -Path $Folder -ChildPath ('{0}.{1}.json' -f $Leaf, $Device.ToUpper()) }

    # Devices: existing override files plus those passed in (short names, upper case)
    $DeviceList = New-Object System.Collections.Generic.List[string]
    foreach ($F in Get-ChildItem -Path $Folder -Filter "$Leaf.*.json" -File -ErrorAction SilentlyContinue) {
        $N = $F.BaseName.Substring($Leaf.Length + 1).ToUpper()
        if ($N -and -not $DeviceList.Contains($N)) { $DeviceList.Add($N) }
    }
    foreach ($Dev in $Devices) {
        $N = ("$Dev" -split '\.')[0].ToUpper()
        if ($N -and -not $DeviceList.Contains($N)) { $DeviceList.Add($N) }
    }
    $AllLabel = "All devices (defaults: $Leaf.json)"
    function Update-ScopeList {
        param([string]$Select)
        $State.Loading = $true
        $ScopeBox.Items.Clear()
        [void]$ScopeBox.Items.Add($AllLabel)
        foreach ($N in ($DeviceList | Sort-Object)) {
            $Has = Test-Path -Path (Get-OverridePath $N)
            [void]$ScopeBox.Items.Add($(if ($Has) { "$N  (has overrides)" } else { $N }))
        }
        $Idx = 0
        if ($Select) { for ($I = 1; $I -lt $ScopeBox.Items.Count; $I++) { if (("$($ScopeBox.Items[$I])" -split '  ')[0] -eq $Select) { $Idx = $I } } }
        $ScopeBox.SelectedIndex = $Idx
        $State.Loading = $false
    }
    function Get-SelectedDevice {
        if ($ScopeBox.SelectedIndex -le 0) { return '' }
        ("$($ScopeBox.SelectedItem)" -split '  ')[0]
    }
    #endregion

    #region Tabs
    function Set-Dirty { if (-not $State.Loading) { $State.Dirty = $true; $StatusLabel.Text = 'Unsaved changes.' } }

    function Show-Scope {
        $State.Loading = $true
        $Device = Get-SelectedDevice
        $State.Scope = $Device
        $Defaults = Get-Defaults
        $DefT = if ($Defaults.Contains('Transports')) { $Defaults['Transports'] } else { [ordered]@{} }
        $Over = if ($Device) { Read-SettingFile -Path (Get-OverridePath $Device) } else { [ordered]@{} }
        $OverT = if ($Over.Contains('Transports')) { $Over['Transports'] } else { [ordered]@{} }
        $Eff = if ($Device) { Merge-SettingTable $DefT $OverT } else { $DefT }

        $Info.Text = if ($Device) {
            "Device $Device : effective values (defaults plus its override). Bold = overridden for this device. Save writes only the differences to $Leaf.$Device.json."
        } else {
            "Defaults for every device, saved in $Leaf.json. A device that needs other values gets its own override (pick it above)."
        }
        $AddTransport.Enabled = -not $Device
        $ResetDevice.Enabled = [bool]$Device -and (Test-Path -Path (Get-OverridePath $Device))

        $Keep = if ($Tabs.SelectedTab) { $Tabs.SelectedTab.Text } else { '' }
        $Tabs.TabPages.Clear()
        $State.Fields = [ordered]@{}; $State.Labels = @{}
        foreach ($Key in $Eff.Keys) {
            $T = $Eff[$Key]
            $Type = if ($T.Contains('Type') -and $T['Type']) { "$($T['Type'])" } else { $Key }
            $Page = New-Object System.Windows.Forms.TabPage; $Page.Text = $Key
            $Grid = New-Object System.Windows.Forms.TableLayoutPanel
            $Grid.Dock = 'Fill'; $Grid.ColumnCount = 2; $Grid.AutoScroll = $true; $Grid.Padding = New-Object System.Windows.Forms.Padding(8)
            [void]$Grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 120)))
            [void]$Grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
            $State.Fields[$Key] = [ordered]@{ Type = $Type }
            $State.Labels[$Key] = @{}
            $OverKeys = if ($OverT.Contains($Key)) { @($OverT[$Key].Keys) } else { @() }

            $Row = 0
            foreach ($F in @('Enabled', 'Priority') + @(Get-TransportFieldList $Type)) {
                $L = New-Object System.Windows.Forms.Label; $L.Text = $F; $L.AutoSize = $true
                $L.Margin = New-Object System.Windows.Forms.Padding(3, 7, 3, 3)
                if ($OverKeys -contains $F) { $L.Font = New-Object System.Drawing.Font($D.Font, [System.Drawing.FontStyle]::Bold) }
                $V = if ($T.Contains($F)) { $T[$F] } else { $null }
                switch ($F) {
                    'Enabled' {
                        $C = New-Object System.Windows.Forms.CheckBox; $C.Checked = [bool]$V; $C.AutoSize = $true
                        $C.Text = "Use $Type for this $(if ($Device) { 'device' } else { 'scope' })"
                        $C.Add_CheckedChanged({ Set-Dirty })
                    }
                    { $_ -in 'Priority', 'Port' } {
                        $C = New-Object System.Windows.Forms.NumericUpDown; $C.Width = 90
                        if ($F -eq 'Priority') { $C.Minimum = 1; $C.Maximum = 99 } else { $C.Minimum = 1; $C.Maximum = 65535 }
                        $Dflt = if ($F -eq 'Port') { if ($Type -eq 'Sftp') { 22 } else { 21 } } else { 99 }
                        $C.Value = if ($null -ne $V -and "$V" -match '^\d+$') { [decimal][Math]::Min([Math]::Max([int]$V, [int]$C.Minimum), [int]$C.Maximum) } else { $Dflt }
                        $C.Add_ValueChanged({ Set-Dirty })
                    }
                    'Encryption' {
                        $C = New-Object System.Windows.Forms.ComboBox; $C.DropDownStyle = 'DropDownList'; $C.Width = 220
                        [void]$C.Items.AddRange(@('Explicit', 'Implicit', 'None'))
                        $C.SelectedItem = if ("$V" -in 'Explicit', 'Implicit', 'None') { "$V" } else { 'Explicit' }
                        $C.Add_SelectedIndexChanged({ Set-Dirty })
                    }
                    default {
                        $C = New-Object System.Windows.Forms.TextBox; $C.Dock = 'Fill'; $C.Text = "$V"
                        $C.Add_TextChanged({ Set-Dirty })
                    }
                }
                $Grid.Controls.Add($L, 0, $Row); $Grid.Controls.Add($C, 1, $Row)
                $State.Fields[$Key][$F] = $C
                $State.Labels[$Key][$F] = $L
                $Row++
            }
            $Help = New-Object System.Windows.Forms.Label; $Help.AutoSize = $true; $Help.MaximumSize = New-Object System.Drawing.Size(520, 0)
            $Help.Margin = New-Object System.Windows.Forms.Padding(3, 10, 3, 3)
            $Help.Text = switch ($Type) {
                'Dfs'   { 'Root: UNC path of the scripts share. The device reaches it as its computer account (DOMAIN\DEVICE$).' }
                'Sftp'  { 'Root: folder on the SFTP server (starts with /). Credential: name of the SSH key kept on each device (SYSTEM and Administrators only). Not used for syncing yet (DFS only for now).' }
                'Ftp'   { 'Encryption: Explicit or Implicit = FTPS (TLS); None = plain FTP, password and files in clear text. Credential: name of the machine-encrypted password kept on each device. Not used for syncing yet (DFS only for now).' }
                default { '' }
            }
            $Grid.Controls.Add($Help, 1, $Row)
            $Page.Controls.Add($Grid)
            [void]$Tabs.TabPages.Add($Page)
            if ($Key -eq $Keep) { $Tabs.SelectedTab = $Page }
        }
        $State.Dirty = $false
        $StatusLabel.Text = ''
        $State.Loading = $false
    }

    # Values in the window, per transport (ordered, typed)
    function Get-WindowValues {
        $Out = [ordered]@{}
        foreach ($Key in $State.Fields.Keys) {
            $F = $State.Fields[$Key]
            $T = [ordered]@{ Type = $F['Type'] }
            foreach ($Name in $F.Keys) {
                if ($Name -eq 'Type') { continue }
                $C = $F[$Name]
                $T[$Name] = switch ($C.GetType().Name) {
                    'CheckBox'      { [bool]$C.Checked }
                    'NumericUpDown' { [int]$C.Value }
                    'ComboBox'      { "$($C.SelectedItem)" }
                    default         { $C.Text.Trim() }
                }
            }
            $Out[$Key] = $T
        }
        $Out
    }
    #endregion

    #region Save
    function Save-Scope {
        $Vals = Get-WindowValues
        $Device = $State.Scope
        $Defaults = Get-Defaults
        if (-not $Defaults.Contains('Transports')) { $Defaults['Transports'] = [ordered]@{} }

        $Problems = @(Test-TransportValue $Vals)
        if ($Problems.Count) {
            [void][System.Windows.Forms.MessageBox]::Show("Not saved:`r`n`r`n$($Problems -join "`r`n")", 'Distribution settings', 'OK', 'Warning')
            return $false
        }
        $Plain = @($Vals.Keys | Where-Object { $Vals[$_]['Enabled'] -and $Vals[$_]['Type'] -eq 'Ftp' -and $Vals[$_]['Encryption'] -eq 'None' })
        if ($Plain.Count) {
            $A = [System.Windows.Forms.MessageBox]::Show("$($Plain -join ', ') uses plain FTP: the password and the files travel in clear text. Scripts are still checked for a valid signature before they are used, but inventory and logs are not protected.`r`n`r`nSave anyway?", 'Distribution settings', 'YesNo', 'Warning')
            if ($A -ne 'Yes') { return $false }
        }
        if (-not @($Vals.Keys | Where-Object { $Vals[$_]['Enabled'] }).Count) {
            $Who = if ($Device) { $Device } else { 'every device without its own override' }
            $A = [System.Windows.Forms.MessageBox]::Show("No transport is enabled: $Who will not sync and will report locally only.`r`n`r`nSave anyway?", 'Distribution settings', 'YesNo', 'Warning')
            if ($A -ne 'Yes') { return $false }
        }

        if (-not $Device) {
            # Defaults: change only the shown fields, keep anything else in each transport
            foreach ($Key in $Vals.Keys) {
                if (-not $Defaults['Transports'].Contains($Key)) { $Defaults['Transports'][$Key] = [ordered]@{} }
                foreach ($F in $Vals[$Key].Keys) { $Defaults['Transports'][$Key][$F] = $Vals[$Key][$F] }
            }
            Save-SettingFile -Path $SettingsPath -Data $Defaults
            Write-DistLog "Distribution defaults saved in ${SettingsPath}: $(($Vals.Keys | ForEach-Object { '{0}={1}' -f $_, $(if ($Vals[$_]['Enabled']) { "on/$($Vals[$_]['Priority'])" } else { 'off' }) }) -join ', ')."
        }
        else {
            $Path = Get-OverridePath $Device
            $Over = Read-SettingFile -Path $Path
            $Diff = Get-TransportOverride -DefaultTransports $Defaults['Transports'] -DeviceTransports $Vals
            if ($Diff) { $Over['Transports'] = $Diff } elseif ($Over.Contains('Transports')) { $Over.Remove('Transports') }
            if ($Over.Count) {
                Save-SettingFile -Path $Path -Data $Over
                Write-DistLog "Distribution override for $Device saved in ${Path}: $(if ($Diff) { ($Diff.Keys | ForEach-Object { '{0}({1})' -f $_, ($Diff[$_].Keys -join ',') }) -join ', ' } else { 'no transport differences' })."
            }
            elseif (Test-Path -Path $Path) {
                Remove-Item -Path $Path -Force
                Write-DistLog "Distribution override for $Device removed ($Path): same as the defaults."
            }
        }
        $State.Saved = $true
        $State.Dirty = $false
        $StatusLabel.Text = 'Saved. Devices get it with the next copy or publish.'
        $true
    }

    function Confirm-Leave {
        if (-not $State.Dirty) { return $true }
        $A = [System.Windows.Forms.MessageBox]::Show('Save the changes first?', 'Distribution settings', 'YesNoCancel', 'Question')
        if ($A -eq 'Cancel') { return $false }
        if ($A -eq 'Yes') { return [bool](Save-Scope) }
        $true
    }
    #endregion

    #region Events
    $State.LastIndex = 0
    $ScopeBox.Add_SelectedIndexChanged({
        if ($State.Loading) { return }
        if ($ScopeBox.SelectedIndex -eq $State.LastIndex) { return }
        if (-not (Confirm-Leave)) { $State.Loading = $true; $ScopeBox.SelectedIndex = $State.LastIndex; $State.Loading = $false; return }
        $State.LastIndex = $ScopeBox.SelectedIndex
        Show-Scope
    })
    $AddDevice.Add_Click({
        $N = ("$($NewDevice.Text)".Trim() -split '\.')[0].ToUpper()
        if (-not $N -or $N -notmatch '^[A-Z0-9-]{1,15}$') { [void][System.Windows.Forms.MessageBox]::Show('Enter a computer name (short or FQDN).', 'Distribution settings'); return }
        if (-not (Confirm-Leave)) { return }
        if (-not $DeviceList.Contains($N)) { $DeviceList.Add($N) }
        $NewDevice.Text = ''
        Update-ScopeList -Select $N
        $State.LastIndex = $ScopeBox.SelectedIndex
        Show-Scope
    })
    $AddTransport.Add_Click({
        if (-not (Confirm-Leave)) { return }
        $P = New-Object System.Windows.Forms.Form
        $P.Text = 'Add transport'; $P.FormBorderStyle = 'FixedDialog'; $P.MaximizeBox = $false; $P.MinimizeBox = $false
        $P.StartPosition = 'CenterParent'; $P.ClientSize = New-Object System.Drawing.Size(320, 130); $P.Font = $D.Font
        $NL = New-Object System.Windows.Forms.Label; $NL.Text = 'Name (e.g. Sftp2):'; $NL.SetBounds(12, 14, 110, 20)
        $NB = New-Object System.Windows.Forms.TextBox; $NB.SetBounds(126, 12, 180, 22)
        $TL = New-Object System.Windows.Forms.Label; $TL.Text = 'Type:'; $TL.SetBounds(12, 48, 110, 20)
        $TB = New-Object System.Windows.Forms.ComboBox; $TB.DropDownStyle = 'DropDownList'; $TB.SetBounds(126, 46, 180, 22)
        [void]$TB.Items.AddRange(@('Dfs', 'Sftp', 'Ftp')); $TB.SelectedIndex = 1
        $OK = New-Object System.Windows.Forms.Button; $OK.Text = 'Add'; $OK.SetBounds(150, 90, 75, 28); $OK.DialogResult = 'OK'
        $Cn = New-Object System.Windows.Forms.Button; $Cn.Text = 'Cancel'; $Cn.SetBounds(231, 90, 75, 28); $Cn.DialogResult = 'Cancel'
        $P.AcceptButton = $OK; $P.CancelButton = $Cn
        $P.Controls.AddRange(@($NL, $NB, $TL, $TB, $OK, $Cn))
        if ($P.ShowDialog($D) -ne 'OK') { return }
        $Name = $NB.Text.Trim()
        $Defaults = Get-Defaults
        if (-not $Defaults.Contains('Transports')) { $Defaults['Transports'] = [ordered]@{} }
        if ($Name -notmatch '^[A-Za-z][A-Za-z0-9]{0,30}$' -or $Defaults['Transports'].Contains($Name)) {
            [void][System.Windows.Forms.MessageBox]::Show('Use a new name of letters and digits.', 'Distribution settings'); return
        }
        $Type = "$($TB.SelectedItem)"
        $Prio = 1 + [int](@($Defaults['Transports'].Values | ForEach-Object { [int]$_['Priority'] }) | Measure-Object -Maximum).Maximum
        $New = [ordered]@{ Type = $Type; Enabled = $false; Priority = [Math]::Min($Prio, 99) }
        if ($Type -eq 'Dfs') { $New['Root'] = '' }
        else {
            $New['Host'] = ''; $New['Port'] = $(if ($Type -eq 'Sftp') { 22 } else { 21 })
            if ($Type -eq 'Ftp') { $New['Encryption'] = 'Explicit' }
            $New['Root'] = '/scripts'; $New['User'] = ''; $New['Credential'] = "PSM-$Name"
        }
        $Defaults['Transports'][$Name] = $New
        Save-SettingFile -Path $SettingsPath -Data $Defaults
        Write-DistLog "Transport $Name ($Type, disabled) added to $SettingsPath."
        $State.Saved = $true
        Show-Scope
        foreach ($Pg in $Tabs.TabPages) { if ($Pg.Text -eq $Name) { $Tabs.SelectedTab = $Pg } }
    })
    $ResetDevice.Add_Click({
        $Device = $State.Scope
        if (-not $Device) { return }
        $Path = Get-OverridePath $Device
        $A = [System.Windows.Forms.MessageBox]::Show("Remove the transport overrides of $Device (other settings in $([System.IO.Path]::GetFileName($Path)) are kept)?", 'Distribution settings', 'YesNo', 'Question')
        if ($A -ne 'Yes') { return }
        $Over = Read-SettingFile -Path $Path
        if ($Over.Contains('Transports')) { $Over.Remove('Transports') }
        if ($Over.Count) { Save-SettingFile -Path $Path -Data $Over } elseif (Test-Path -Path $Path) { Remove-Item -Path $Path -Force }
        Write-DistLog "Distribution override for $Device reset to the defaults."
        $State.Saved = $true
        Update-ScopeList -Select $Device
        $State.LastIndex = $ScopeBox.SelectedIndex
        Show-Scope
    })
    $SaveButton.Add_Click({ if (Save-Scope) { $Sel = $State.Scope; Update-ScopeList -Select $Sel; $State.LastIndex = $ScopeBox.SelectedIndex; Show-Scope } })
    $CloseButton.Add_Click({ $D.Close() })
    $D.Add_FormClosing({ param($S, $E) if (-not (Confirm-Leave)) { $E.Cancel = $true } })
    #endregion

    Update-ScopeList
    Show-Scope
    if ($Owner) { [void]$D.ShowDialog($Owner) } else { [void]$D.ShowDialog() }
    $D.Dispose()
    $State.Saved
}

# Example usage:
# PS> . C:\SCRIPTS\Installs\Show-DistributionSettings.ps1
# PS> Show-DistributionSettings
# PS> Show-DistributionSettings -Devices srv010010037050.generationsgaither.com, srv010010050050.generationsgaither.com


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBNoH7zQNRwpR54
# ZOUU1YBat9pP0j1vvImjFQ24cYCHvKCCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIHToxdfS
# nvuPnYrL/JxbKBEz24EoCSeWhvbgDZj7wVdEMA0GCSqGSIb3DQEBAQUABIIBABic
# +xtG0kL67oSjRznutETAq8r5kr7OdC0iq5B2uwlhLCXSrnUxMKg3ZL805yJqnsgT
# X6RzW+P/ndALYQ2q5eemDBzOWXOcIOBtc3q5SJS2dTHCWrIxjcV1BUFutNGYHxxe
# nfKo4KsRJRj+VlKHvdkU4BC4+PQL4nPQHwACAkzbgwQi9ZZHdE1lhbOm516kjhk1
# GZ4XdwNaZdvytc515Zz/9AzlDidKchu5152DuZg9R29yYCbYUg7gt/NtenWJXr3D
# 0/FQ2iJ1cojOaln2itKnk4TcFykVsNy/YEUvbnTw5Uf9ze59135d22VL+KnUA6VY
# dKDHYJq5WtcoWAhf6rqhggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDE1MTQ1
# NjAzWjAvBgkqhkiG9w0BCQQxIgQgoWfoZ0g2LiQObyX3twHiVrNX2QkVeRlcpubF
# BP9jhhcwDQYJKoZIhvcNAQEBBQAEggIAceHZibDyRgdTH+DTGaztdd+LRosOfare
# Lw69hq17IVkq0iy9NCM2iIojg43Mwz/KMSVjdhxazH2Xf2r7z1dEc25Jn7r40yOM
# oV3XdSXxzfCY8emwf24dYg7K3LCnbE0v2cdGdJHxYY0jTJDpO2YijmyYJ2PPDJ4I
# n7CyltjuXTCsaqLw+26QEe1iqQ29b+HfPTZTYMA3rcr+/aEmR+VMPzTnJgcnhzHx
# vYRVRCfrk2prjhHTJTXrKf1/GbT70D9ku1q1rxukywuzRfXshyN84xucqNQrZ3x0
# hcBlsV+bayXCHhpnJFM4JhR0CyT/0RE9bLJMt+ifh5AhINBtnJJoqxvepOnkmxbX
# /q3hJJYuU3bTRgpZrvyElnt/PTje0SMJ1gJDT/ogNyImLcKqgdCbNflK3qC6h5sW
# Ks/3ketYSNfHcmLOeO6OEUP35qYWzyN/UXSjR4y5ruJm+hBNT3XpUUNoTTiorXm6
# vkaEDozR9Si4JSfq1mPm6kAyoxN8OsykqmL3b9rXOPerLx4WiPnnWeb481MvxT4N
# MiRu8HwBkAGdm923mbzijj4M9PrywU3JT4HfVYejiy2iy9nd6fSazeOvOI0D19YE
# 9S/TPhDCqzm5eSezd9AcLbwglb5n9kka+xp8b+cT8M33lKXoH2kGfGzPMLZ/Jav2
# /XTCNpeEXtE=
# SIG # End signature block
