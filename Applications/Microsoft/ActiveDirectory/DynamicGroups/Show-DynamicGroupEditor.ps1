<#
.SYNOPSIS
    Editor for the server's dynamic group rules (Data\Rules\DynamicGroupRules.json).
.DESCRIPTION
    Windows Forms tool to add, change, disable and delete dynamic group rules:
      - Group name, description, OU for the group, search base for users, scope and category
      - Criteria (Attribute / Operator / Value), matched All or Any
      - Include disabled users, allow empty group, users to exclude, optional raw LDAP filter
    Buttons:
      Preview    Shows who the rule matches and what the next run would add or remove
                 (needs the ActiveDirectory module; read-only).
      Save       Validates every rule and writes the rules file (previous version kept in
                 Data\Rules\Backups).
      Run Now    Starts the scheduled task (or runs the sync directly if the task is not on
                 this computer).
      View Log   Opens C:\SCRIPTS\Logs\DynamicGroups.log.

    The rules are server-local: a copy or sync of the application never overwrites them. A server
    without rules starts from Data\DynamicGroupRules.Template.json (no groups); the first Save
    creates its rules file. Defaults (search base, OU for new rules, DC) come from
    Data\DynamicGroups.json.

    Run in Windows PowerShell 5.1: powershell.exe -STA -File .\Show-DynamicGroupEditor.ps1
.PARAMETER ConfigPath
    Rules file. Defaults to RulesFile in Data\DynamicGroups.json (Data\Rules\DynamicGroupRules.json).
.EXAMPLE
    PS> .\Show-DynamicGroupEditor.ps1
.INPUTS
    None
.OUTPUTS
    None
.NOTES
    Author: Kenneth Tipton
    Company: TNC
    Date: 2026-10-19
    Time: 09:45:00
    Time Zone: Central Standard Time
    Function Or Application: Application
    Version: 1.1.1
    Website: (https://www.tnandc.com)
    Is AI Used: True
    AI Used: Claude

    Copyright (c) 2026
    Licensed under the MIT License.
    Full text available at: https://opensource.org/licenses/MIT

    Overide Variables
    Overide Filename:
    Overide Log Filename: DynamicGroups
    Overide Text Log File Path: C:\SCRIPTS\Logs\DynamicGroups.log
    Overide Log Type:
.LINK
    https://www.tnandc.com
#>
[CmdletBinding()]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

# Windows Forms needs a single-threaded apartment
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $LaunchArgs = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($ConfigPath) { $LaunchArgs += @('-ConfigPath', "`"$ConfigPath`"") }
    Start-Process -FilePath powershell.exe -ArgumentList $LaunchArgs
    return
}

#region Standard locations
$SCA = $PSScriptRoot
$SA  = $SCA
while ($SA -and (Split-Path -Path $SA -Leaf) -ne 'Applications') { $SA = Split-Path -Path $SA -Parent }
if (-not $SA) { throw "$SCA is not inside an 'Applications' folder." }
$SL    = Split-Path -Path $SA -Parent
$SF    = Join-Path -Path $SL -ChildPath 'Functions'
$SG    = Join-Path -Path $SL -ChildPath 'Logs'
$SCAPF = Join-Path -Path $SCA -ChildPath 'Functions'

$SyncScript = Join-Path -Path $SCA -ChildPath 'Update-DynamicGroups.ps1'
$TaskPath   = '\ActiveDirectory\DynamicGroups\'
$TaskName   = 'UpdateDynamicGroups'
#endregion

foreach ($F in 'Get-DynamicGroupSetting.ps1', 'ConvertTo-DynamicGroupLdapFilter.ps1', 'Get-DynamicGroupConfig.ps1', 'Save-DynamicGroupConfig.ps1', 'Get-DynamicGroupTargetMember.ps1') {
    . (Join-Path -Path $SCAPF -ChildPath $F)
}
$App = Get-DynamicGroupSetting -ApplicationPath $SCA
# Read from -ConfigPath, else the rules file (or the 1.0.0 location, or the empty template);
# always save to the rules file
$ReadPath = if ($ConfigPath) { $ConfigPath } else { $App.ReadPath }
if (-not $ConfigPath) { $ConfigPath = $App.RulesPath }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Script:HaveAD = $false
try { Import-Module ActiveDirectory -ErrorAction Stop; $Script:HaveAD = $true } catch { }

$Script:Config  = Get-DynamicGroupConfig -Path $ReadPath -AppSetting $App
$Script:Server  = ''   # DC used by Preview: the same choice as the sync (Server setting, else a writable DC)
$Script:Rules   = New-Object System.Collections.ArrayList
foreach ($R in $Script:Config.Groups) { [void]$Script:Rules.Add($R) }
$Script:Current = -1
$Script:Dirty   = $false
$Script:Loading = $false

$Operators  = @('Equals', 'NotEquals', 'StartsWith', 'EndsWith', 'Contains', 'Present', 'NotPresent')
$Attributes = @('title', 'department', 'company', 'division', 'description', 'physicalDeliveryOfficeName',
    'l', 'st', 'employeeType', 'employeeID', 'manager', 'memberOf') + (1..15 | ForEach-Object { "extensionAttribute$_" })
$DefaultGroupOU = $Script:Config.Settings.DefaultGroupPath

#region Controls
$Font = New-Object System.Drawing.Font('Segoe UI', 9)

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 130)
    $L = New-Object System.Windows.Forms.Label
    $L.Text = $Text; $L.Location = New-Object System.Drawing.Point($X, ($Y + 3)); $L.Size = New-Object System.Drawing.Size($W, 20)
    $L
}
function New-TextBox {
    param([int]$X, [int]$Y, [int]$W)
    $T = New-Object System.Windows.Forms.TextBox
    $T.Location = New-Object System.Drawing.Point($X, $Y); $T.Size = New-Object System.Drawing.Size($W, 23)
    $T.Add_TextChanged({ if (-not $Script:Loading) { $Script:Dirty = $true } })
    $T
}
function New-Combo {
    param([int]$X, [int]$Y, [int]$W, [string[]]$Items)
    $C = New-Object System.Windows.Forms.ComboBox
    $C.DropDownStyle = 'DropDownList'
    $C.Location = New-Object System.Drawing.Point($X, $Y); $C.Size = New-Object System.Drawing.Size($W, 23)
    [void]$C.Items.AddRange($Items)
    $C.Add_SelectedIndexChanged({ if (-not $Script:Loading) { $Script:Dirty = $true } })
    $C
}
function New-CheckBox {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 180)
    $C = New-Object System.Windows.Forms.CheckBox
    $C.Text = $Text; $C.Location = New-Object System.Drawing.Point($X, $Y); $C.Size = New-Object System.Drawing.Size($W, 22)
    $C.Add_CheckedChanged({ if (-not $Script:Loading) { $Script:Dirty = $true } })
    $C
}
function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 100)
    $B = New-Object System.Windows.Forms.Button
    $B.Text = $Text; $B.Location = New-Object System.Drawing.Point($X, $Y); $B.Size = New-Object System.Drawing.Size($W, 28)
    $B
}

$Form = New-Object System.Windows.Forms.Form
$Form.Text = 'Dynamic Groups - ' + $ConfigPath
$Form.Size = New-Object System.Drawing.Size(1060, 740)
$Form.StartPosition = 'CenterScreen'
$Form.FormBorderStyle = 'FixedDialog'
$Form.MaximizeBox = $false
$Form.Font = $Font

# Left: list of rules
$LstGroups = New-Object System.Windows.Forms.ListBox
$LstGroups.Location = New-Object System.Drawing.Point(12, 12)
$LstGroups.Size = New-Object System.Drawing.Size(260, 600)
$LstGroups.IntegralHeight = $false
$BtnNew    = New-Button -Text 'New'    -X 12  -Y 620 -W 82
$BtnCopy   = New-Button -Text 'Copy'   -X 101 -Y 620 -W 82
$BtnDelete = New-Button -Text 'Delete' -X 190 -Y 620 -W 82

# Right: rule fields
$X1 = 290; $X2 = 430; $W2 = 600
$TxtName  = New-TextBox -X $X2 -Y 12  -W 300
$TxtDesc  = New-TextBox -X $X2 -Y 44  -W $W2
$TxtPath  = New-TextBox -X $X2 -Y 76  -W $W2
$TxtBase  = New-TextBox -X $X2 -Y 108 -W $W2
$CmbScope = New-Combo   -X $X2 -Y 140 -W 130 -Items @('Global', 'Universal', 'DomainLocal')
$CmbCat   = New-Combo   -X 680 -Y 140 -W 130 -Items @('Security', 'Distribution')
$CmbMatch = New-Combo   -X $X2 -Y 172 -W 130 -Items @('All', 'Any')
$ChkEnabled  = New-CheckBox -Text 'Rule enabled'           -X $X2 -Y 204 -W 140
$ChkDisabled = New-CheckBox -Text 'Include disabled users' -X 580 -Y 204 -W 180
$ChkEmpty    = New-CheckBox -Text 'Allow empty group'      -X 780 -Y 204 -W 160

$LblCriteria = New-Label -Text 'Criteria (users must match):' -X $X1 -Y 236 -W 300
$Grid = New-Object System.Windows.Forms.DataGridView
$Grid.Location = New-Object System.Drawing.Point($X1, 260)
$Grid.Size = New-Object System.Drawing.Size(740, 210)
$Grid.AllowUserToAddRows = $true
$Grid.AllowUserToDeleteRows = $true
$Grid.RowHeadersWidth = 30
$Grid.AutoSizeColumnsMode = 'Fill'
$ColAttr = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$ColAttr.HeaderText = 'Attribute'; $ColAttr.Name = 'Attribute'; $ColAttr.FillWeight = 30
$ColOp = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
$ColOp.HeaderText = 'Operator'; $ColOp.Name = 'Operator'; $ColOp.FillWeight = 20
[void]$ColOp.Items.AddRange($Operators)
$ColVal = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$ColVal.HeaderText = 'Value'; $ColVal.Name = 'Value'; $ColVal.FillWeight = 50
[void]$Grid.Columns.AddRange($ColAttr, $ColOp, $ColVal)
$Grid.Add_DataError({ $_.ThrowException = $false })
$Grid.Add_CellValueChanged({ if (-not $Script:Loading) { $Script:Dirty = $true } })
$Grid.Add_UserDeletedRow({ $Script:Dirty = $true })
$Grid.Add_DefaultValuesNeeded({ $_.Row.Cells['Operator'].Value = 'Equals' })
# Attribute suggestions while typing
$Grid.Add_EditingControlShowing({
    $Tb = $_.Control -as [System.Windows.Forms.TextBox]
    if (-not $Tb) { return }
    if ($Grid.CurrentCell.ColumnIndex -eq 0) {
        $Src = New-Object System.Windows.Forms.AutoCompleteStringCollection
        $Src.AddRange([string[]]$Attributes)
        $Tb.AutoCompleteCustomSource = $Src
        $Tb.AutoCompleteSource = 'CustomSource'
        $Tb.AutoCompleteMode = 'SuggestAppend'
    }
    else {
        $Tb.AutoCompleteMode = 'None'
    }
})

$TxtExclude = New-TextBox -X $X2 -Y 482 -W $W2
$TxtLdap    = New-TextBox -X $X2 -Y 514 -W $W2

$LblFilter = New-Object System.Windows.Forms.Label
$LblFilter.Location = New-Object System.Drawing.Point($X1, 548)
$LblFilter.Size = New-Object System.Drawing.Size(740, 60)
$LblFilter.ForeColor = [System.Drawing.Color]::DimGray

$BtnPreview = New-Button -Text 'Preview'  -X $X1 -Y 620
$BtnSave    = New-Button -Text 'Save'     -X 400 -Y 620
$BtnRun     = New-Button -Text 'Run Now'  -X 510 -Y 620
$BtnLog     = New-Button -Text 'View Log' -X 620 -Y 620
$BtnClose   = New-Button -Text 'Close'    -X 930 -Y 620

$Status = New-Object System.Windows.Forms.StatusStrip
$StatusText = New-Object System.Windows.Forms.ToolStripStatusLabel
[void]$Status.Items.Add($StatusText)

$Form.Controls.AddRange(@(
    $LstGroups, $BtnNew, $BtnCopy, $BtnDelete,
    (New-Label 'Group name:' $X1 12), $TxtName,
    (New-Label 'Description:' $X1 44), $TxtDesc,
    (New-Label 'Group OU:' $X1 76), $TxtPath,
    (New-Label 'Search users in:' $X1 108), $TxtBase,
    (New-Label 'Scope:' $X1 140), $CmbScope, (New-Label 'Category:' 600 140 80), $CmbCat,
    (New-Label 'Match:' $X1 172), $CmbMatch,
    $ChkEnabled, $ChkDisabled, $ChkEmpty,
    $LblCriteria, $Grid,
    (New-Label 'Exclude users:' $X1 482), $TxtExclude,
    (New-Label 'LDAP filter (adv.):' $X1 514), $TxtLdap,
    $LblFilter,
    $BtnPreview, $BtnSave, $BtnRun, $BtnLog, $BtnClose,
    $Status
))

$Tip = New-Object System.Windows.Forms.ToolTip
$Tip.SetToolTip($TxtName, 'sAMAccountName and name of the group, e.g. DEPT-ExecutiveDirectors. No spaces.')
$Tip.SetToolTip($TxtPath, 'Distinguished name of the OU the group is created in.')
$Tip.SetToolTip($TxtBase, 'Users are searched in this OU and everything below it.')
$Tip.SetToolTip($TxtExclude, 'sAMAccountNames never added to this group, separated by commas.')
$Tip.SetToolTip($TxtLdap, 'Optional. Replaces the criteria grid, e.g. (title=Executive Director). Users only; disabled users excluded unless ticked.')
$Tip.SetToolTip($ChkEmpty, 'Without this, a rule that matches nobody never empties an existing group (protects against typos).')
#endregion

#region Form <-> rule
function Set-Status { param([string]$Text) $StatusText.Text = $Text }

function Update-GroupList {
    $Script:Loading = $true
    $LstGroups.Items.Clear()
    foreach ($R in $Script:Rules) {
        $Label = if ($R.Enabled) { $R.Name } else { "$($R.Name)  (disabled)" }
        [void]$LstGroups.Items.Add($Label)
    }
    $Script:Loading = $false
}

function Show-Rule {
    param([int]$Index)
    $Script:Loading = $true
    $Enable = $Index -ge 0
    foreach ($C in @($TxtName, $TxtDesc, $TxtPath, $TxtBase, $CmbScope, $CmbCat, $CmbMatch, $ChkEnabled, $ChkDisabled, $ChkEmpty, $Grid, $TxtExclude, $TxtLdap, $BtnPreview, $BtnCopy, $BtnDelete)) {
        $C.Enabled = $Enable
    }
    $Grid.Rows.Clear()
    if ($Enable) {
        $R = $Script:Rules[$Index]
        $TxtName.Text  = $R.Name
        $TxtDesc.Text  = $R.Description
        $TxtPath.Text  = $R.Path
        $TxtBase.Text  = $R.SearchBase
        $CmbScope.SelectedItem = $R.GroupScope
        $CmbCat.SelectedItem   = $R.GroupCategory
        $CmbMatch.SelectedItem = $R.MatchType
        $ChkEnabled.Checked  = [bool]$R.Enabled
        $ChkDisabled.Checked = [bool]$R.IncludeDisabledUsers
        $ChkEmpty.Checked    = [bool]$R.AllowEmpty
        foreach ($C in @($R.Criteria)) {
            $Op = if ($Operators -contains $C.Operator) { $C.Operator } else { 'Equals' }
            [void]$Grid.Rows.Add($C.Attribute, $Op, $C.Value)
        }
        $TxtExclude.Text = (@($R.ExcludeUsers) -join ', ')
        $TxtLdap.Text    = $R.LdapFilter
    }
    else {
        foreach ($T in @($TxtName, $TxtDesc, $TxtPath, $TxtBase, $TxtExclude, $TxtLdap)) { $T.Text = '' }
    }
    $Script:Loading = $false
    Update-FilterLabel
}

# Copies the form into the selected rule (no validation; Save validates)
function Save-FormToRule {
    if ($Script:Current -lt 0 -or $Script:Current -ge $Script:Rules.Count) { return }
    $Grid.EndEdit() | Out-Null
    $Criteria = @(foreach ($Row in $Grid.Rows) {
        if ($Row.IsNewRow) { continue }
        $Attr = "$($Row.Cells['Attribute'].Value)".Trim()
        $Op   = "$($Row.Cells['Operator'].Value)".Trim()
        $Val  = "$($Row.Cells['Value'].Value)"
        if (-not $Attr -and -not $Val) { continue }
        [pscustomobject]@{ Attribute = $Attr; Operator = $(if ($Op) { $Op } else { 'Equals' }); Value = $Val }
    })
    $Script:Rules[$Script:Current] = [pscustomobject]@{
        Name                 = $TxtName.Text.Trim()
        Description          = $TxtDesc.Text.Trim()
        Path                 = $TxtPath.Text.Trim()
        GroupScope           = "$($CmbScope.SelectedItem)"
        GroupCategory        = "$($CmbCat.SelectedItem)"
        Enabled              = $ChkEnabled.Checked
        SearchBase           = $(if ($TxtBase.Text.Trim()) { $TxtBase.Text.Trim() } else { $Script:Config.Settings.DefaultSearchBase })
        IncludeDisabledUsers = $ChkDisabled.Checked
        MatchType            = "$($CmbMatch.SelectedItem)"
        Criteria             = $Criteria
        ExcludeUsers         = @($TxtExclude.Text -split '[,;\s]+' | Where-Object { $_ })
        LdapFilter           = $TxtLdap.Text.Trim()
        AllowEmpty           = $ChkEmpty.Checked
    }
}

# Selects a rule in the list and shows it, without copying the form into it first
function Select-Rule {
    param([int]$Index)
    $Script:Loading = $true
    $LstGroups.SelectedIndex = $Index
    $Script:Loading = $false
    $Script:Current = $Index
    Show-Rule -Index $Index
}

function Update-FilterLabel {
    if ($Script:Loading -or $Script:Current -lt 0) { $LblFilter.Text = ''; return }
    Save-FormToRule
    try { $LblFilter.Text = 'LDAP filter: ' + (ConvertTo-DynamicGroupLdapFilter -Rule $Script:Rules[$Script:Current]) }
    catch { $LblFilter.Text = 'LDAP filter: ' + $_.Exception.Message }
}

function Test-Rules {
    $Problems = New-Object System.Collections.Generic.List[string]
    $Seen = @{}
    foreach ($R in $Script:Rules) {
        $N = if ($R.Name) { $R.Name } else { '(no name)' }
        if (-not $R.Name) { $Problems.Add("${N}: name is required.") }
        elseif ($R.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { $Problems.Add("${N}: use letters, digits, '.', '_' or '-' only (no spaces), up to 64 characters.") }
        elseif ($Seen.ContainsKey($R.Name.ToLower())) { $Problems.Add("${N}: name is used by more than one rule.") }
        else { $Seen[$R.Name.ToLower()] = $true }
        if ($R.Path -notmatch '(^|,)DC=') { $Problems.Add("${N}: Group OU must be a distinguished name (OU=...,DC=...).") }
        if ($R.SearchBase -notmatch '(^|,)DC=') { $Problems.Add("${N}: 'Search users in' must be a distinguished name.") }
        try { ConvertTo-DynamicGroupLdapFilter -Rule $R | Out-Null } catch { $Problems.Add("${N}: $($_.Exception.Message)") }
        if ($Script:HaveAD) {
            foreach ($Dn in (@($R.Path, $R.SearchBase) | Select-Object -Unique)) {
                if ($Dn -match '(^|,)DC=') {
                    try { Get-ADObject -Identity $Dn -ErrorAction Stop | Out-Null }
                    catch { $Problems.Add("${N}: '$Dn' was not found in Active Directory.") }
                }
            }
        }
    }
    $Problems
}
#endregion

#region Events
$LstGroups.Add_SelectedIndexChanged({
    if ($Script:Loading) { return }
    Save-FormToRule
    $Script:Current = $LstGroups.SelectedIndex
    Show-Rule -Index $Script:Current
})

foreach ($C in @($TxtLdap, $TxtExclude)) { $C.Add_Leave({ Update-FilterLabel }) }
$Grid.Add_CellEndEdit({ Update-FilterLabel })
$CmbMatch.Add_SelectionChangeCommitted({ Update-FilterLabel })
$ChkDisabled.Add_Click({ Update-FilterLabel })

# Keep the list label in step with the name / enabled box
$TxtName.Add_Leave({
    if ($Script:Current -lt 0) { return }
    Save-FormToRule
    $Sel = $Script:Current
    Update-GroupList
    $Script:Loading = $true; $LstGroups.SelectedIndex = $Sel; $Script:Loading = $false
    $Script:Dirty = $true
})
$ChkEnabled.Add_Click({
    if ($Script:Current -lt 0) { return }
    Save-FormToRule
    $Sel = $Script:Current
    Update-GroupList
    $Script:Loading = $true; $LstGroups.SelectedIndex = $Sel; $Script:Loading = $false
})

$BtnNew.Add_Click({
    Save-FormToRule
    $Path = if ($Script:Current -ge 0) { $Script:Rules[$Script:Current].Path } else { $DefaultGroupOU }
    $New = [pscustomobject]@{
        Name = 'DEPT-NewGroup'; Description = 'Dynamic group: '; Path = $Path
        GroupScope = 'Global'; GroupCategory = 'Security'; Enabled = $true
        SearchBase = $Script:Config.Settings.DefaultSearchBase; IncludeDisabledUsers = $false; MatchType = 'All'
        Criteria = @([pscustomobject]@{ Attribute = 'title'; Operator = 'Equals'; Value = '' })
        ExcludeUsers = @(); LdapFilter = ''; AllowEmpty = $false
    }
    $Index = $Script:Rules.Add($New)
    $Script:Dirty = $true
    Update-GroupList
    Select-Rule -Index $Index
    [void]$TxtName.Focus(); $TxtName.SelectAll()
})

$BtnCopy.Add_Click({
    if ($Script:Current -lt 0) { return }
    Save-FormToRule
    $Src = $Script:Rules[$Script:Current]
    $Copy = $Src | Select-Object *
    $Copy.Name = "$($Src.Name)-Copy"
    $Copy.Criteria = @($Src.Criteria | ForEach-Object { $_ | Select-Object * })
    $Copy.ExcludeUsers = @($Src.ExcludeUsers)
    $Index = $Script:Rules.Add($Copy)
    $Script:Dirty = $true
    Update-GroupList
    Select-Rule -Index $Index
})

$BtnDelete.Add_Click({
    if ($Script:Current -lt 0) { return }
    $Name = $Script:Rules[$Script:Current].Name
    $Answer = [System.Windows.Forms.MessageBox]::Show(
        "Delete the rule '$Name'?`n`nThis removes the rule only. The group and its members stay in Active Directory; the sync simply stops managing it. To keep the rule but pause it, untick 'Rule enabled' instead.",
        'Delete rule', 'YesNo', 'Warning')
    if ($Answer -ne 'Yes') { return }
    $Script:Rules.RemoveAt($Script:Current)
    $Script:Dirty = $true
    $Index = [Math]::Min($Script:Current, $Script:Rules.Count - 1)
    $Script:Current = -1
    Update-GroupList
    Select-Rule -Index $Index
    Set-Status "Deleted '$Name' (not saved yet)."
})

$BtnPreview.Add_Click({
    if ($Script:Current -lt 0) { return }
    Save-FormToRule
    if (-not $Script:HaveAD) {
        [void][System.Windows.Forms.MessageBox]::Show('The ActiveDirectory module (RSAT) is not available on this computer.', 'Preview', 'OK', 'Warning')
        return
    }
    $Rule = $Script:Rules[$Script:Current]
    $Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        if (-not $Rule.SearchBase) { $Rule.SearchBase = $Script:Config.Settings.DefaultSearchBase }
        if (-not $Script:Server) {
            $Script:Server = if ($Script:Config.Settings.Server) { $Script:Config.Settings.Server } else { "$((Get-ADDomainController -Discover -Writable -ErrorAction Stop).HostName)" }
        }
        $Targets = @(Get-DynamicGroupTargetMember -Rule $Rule -Server $Script:Server)
        $TargetDns = @{}
        foreach ($U in $Targets) { $TargetDns[$U.DistinguishedName.ToLower()] = $true }

        $SafeName = $Rule.Name -replace '\\', '\5c' -replace '\*', '\2a' -replace '\(', '\28' -replace '\)', '\29'
        $Group = Get-ADGroup -Server $Script:Server -LDAPFilter "(sAMAccountName=$SafeName)" -Properties member -ErrorAction SilentlyContinue
        $Members = @{}
        if ($Group) { foreach ($Dn in @($Group.member)) { $Members[$Dn.ToLower()] = $Dn } }

        $Rows = New-Object System.Collections.Generic.List[object]
        foreach ($U in ($Targets | Sort-Object Name)) {
            $Rows.Add([pscustomobject]@{
                Change = if ($Members.ContainsKey($U.DistinguishedName.ToLower())) { 'Member' } else { 'Add' }
                Name = $U.Name; SamAccountName = $U.SamAccountName; Title = $U.Title; Department = $U.Department; Enabled = $U.Enabled
            })
        }
        foreach ($Key in $Members.Keys) {
            if ($TargetDns.ContainsKey($Key)) { continue }
            $O = Get-ADObject -Server $Script:Server -Identity $Members[$Key] -Properties objectClass, sAMAccountName, title, department
            $IsUser = (@($O.objectClass) -contains 'user') -and (@($O.objectClass) -notcontains 'computer')
            $Rows.Add([pscustomobject]@{
                Change = if (-not $IsUser) { 'Keep (not a user)' } elseif ($Targets.Count -eq 0 -and -not $Rule.AllowEmpty) { 'Keep (empty-rule guard)' } else { 'Remove' }
                Name = $O.Name; SamAccountName = $O.sAMAccountName; Title = $O.title; Department = $O.department; Enabled = $null
            })
        }

        $Adds    = @($Rows | Where-Object Change -eq 'Add').Count
        $Removes = @($Rows | Where-Object Change -eq 'Remove').Count
        $Head = if ($Group) { "Group exists ($($Members.Count) direct members)." } else { 'Group does not exist yet; it will be created.' }

        $Dlg = New-Object System.Windows.Forms.Form
        $Dlg.Text = "Preview - $($Rule.Name)"
        $Dlg.Size = New-Object System.Drawing.Size(900, 560)
        $Dlg.StartPosition = 'CenterParent'
        $Dlg.Font = $Font
        $Info = New-Object System.Windows.Forms.Label
        $Info.Dock = 'Top'; $Info.Height = 60
        $Info.Text = "$Head  Matches: $($Targets.Count).  Next run: add $Adds, remove $Removes.`nFilter: $(ConvertTo-DynamicGroupLdapFilter -Rule $Rule)`nSearch base: $($Rule.SearchBase)   DC: $($Script:Server)"
        $View = New-Object System.Windows.Forms.DataGridView
        $View.Dock = 'Fill'; $View.ReadOnly = $true; $View.AllowUserToAddRows = $false
        $View.AutoSizeColumnsMode = 'Fill'; $View.RowHeadersVisible = $false
        $Table = New-Object System.Data.DataTable
        foreach ($Col in 'Change', 'Name', 'SamAccountName', 'Title', 'Department', 'Enabled') { [void]$Table.Columns.Add($Col) }
        foreach ($Row in $Rows) { [void]$Table.Rows.Add($Row.Change, $Row.Name, $Row.SamAccountName, $Row.Title, $Row.Department, "$($Row.Enabled)") }
        $View.DataSource = $Table
        $Dlg.Controls.Add($View)
        $Dlg.Controls.Add($Info)
        Set-Status "Preview: $($Targets.Count) match, add $Adds, remove $Removes."
        [void]$Dlg.ShowDialog($Form)
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Preview failed', 'OK', 'Error')
    }
    finally { $Form.Cursor = [System.Windows.Forms.Cursors]::Default }
})

function Invoke-Save {
    Save-FormToRule
    $Problems = @(Test-Rules)
    if ($Problems.Count) {
        [void][System.Windows.Forms.MessageBox]::Show("Not saved. Fix these first:`n`n" + ($Problems -join "`n"), 'Save', 'OK', 'Warning')
        return $false
    }
    $Script:Config.Groups = @($Script:Rules)
    try {
        Save-DynamicGroupConfig -Config $Script:Config -Path $ConfigPath -KeepBackups $App.KeepRuleBackups
        $Script:Dirty = $false
        Set-Status ("Saved {0} rule(s) at {1:HH:mm:ss}." -f $Script:Rules.Count, (Get-Date))
        return $true
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Save failed', 'OK', 'Error')
        return $false
    }
}

$BtnSave.Add_Click({ [void](Invoke-Save) })

$BtnRun.Add_Click({
    Save-FormToRule
    if ($Script:Dirty) {
        $Answer = [System.Windows.Forms.MessageBox]::Show('There are unsaved changes. Save before running?', 'Run Now', 'YesNoCancel', 'Question')
        if ($Answer -eq 'Cancel') { return }
        if ($Answer -eq 'Yes' -and -not (Invoke-Save)) { return }
    }
    try {
        $Task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($Task) {
            Start-ScheduledTask -ErrorAction Stop -TaskPath $TaskPath -TaskName $TaskName
            Set-Status "Started scheduled task $TaskPath$TaskName. Results in the log."
        }
        else {
            $Answer = [System.Windows.Forms.MessageBox]::Show(
                "The scheduled task $TaskPath$TaskName is not on this computer.`n`nRun the sync now in a new window as $env:USERDOMAIN\$env:USERNAME?",
                'Run Now', 'YesNo', 'Question')
            if ($Answer -ne 'Yes') { return }
            Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$SyncScript`"")
            Set-Status 'Sync started in a new window.'
        }
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Run Now failed', 'OK', 'Error')
    }
})

$BtnLog.Add_Click({
    $Log = Join-Path -Path $SG -ChildPath "$($Script:Config.Settings.LogFileName).log"
    if (Test-Path -Path $Log) { Start-Process -FilePath notepad.exe -ArgumentList "`"$Log`"" }
    else { Set-Status "No log yet at $Log." }
})

$BtnClose.Add_Click({ $Form.Close() })

$Form.Add_FormClosing({
    Save-FormToRule
    if (-not $Script:Dirty) { return }
    $Answer = [System.Windows.Forms.MessageBox]::Show('Save changes before closing?', 'Dynamic Groups', 'YesNoCancel', 'Question')
    if ($Answer -eq 'Cancel') { $_.Cancel = $true; return }
    if ($Answer -eq 'Yes' -and -not (Invoke-Save)) { $_.Cancel = $true }
})
#endregion

Update-GroupList
Select-Rule -Index $(if ($Script:Rules.Count) { 0 } else { -1 })
$Script:Dirty = $false
$From = switch ($App.RulesSource) {
    'Legacy'   { ' from the 1.0.0 location; Save moves them to Data\Rules' }
    'Template' { '. No rules on this server yet: click New to add one' }
    default    { '' }
}
Set-Status ("$($Script:Rules.Count) rule(s) loaded$From." + $(if (-not $Script:HaveAD) { ' ActiveDirectory module not found: Preview is unavailable.' } else { '' }))
[void]$Form.ShowDialog()
$Form.Dispose()

# Example usage:
# PS> C:\SCRIPTS\Applications\Microsoft\ActiveDirectory\DynamicGroups\Show-DynamicGroupEditor.ps1
# PS> powershell.exe -STA -File C:\SCRIPTS\Applications\Microsoft\ActiveDirectory\DynamicGroups\Show-DynamicGroupEditor.ps1


# SIG # Begin signature block
# MIIohAYJKoZIhvcNAQcCoIIodTCCKHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBES+qEui+8maVu
# izj1/Z6lprIESniA87AlwefdH4mzpqCCInYwggWNMIIEdaADAgECAhAOmxiO+dAt
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
# KwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEICAz0x3i
# pq977zkaFyMpjVft5KuXNtsCem5qaSiiwC9BMA0GCSqGSIb3DQEBAQUABIIBAHw/
# V69aoFKX3ToF9znAkt3w6Z+hOAClT4Sse72lp4aszZBPaasEmV885q3yi+ELj26W
# btXFtj38KWJRDlVQBrtz/eiu62YyvhWchMYc4/Mup9tp9kmTmwsnQsvNZxeVdG7C
# gzjHcQt6/A/aVJOj1+89+z1wKXenQRqODRN+7VqJJkQVOAZv3QXbECARmrYoUipz
# H6j/d5iIQ0jUXm16RWcCOGVaK0K+JxQkTgxItjkNLdb/pFQCUZ20/WxbncWkXNOF
# zb9AL9mxfaeDdJ1KsynO+iNl2w+7iDYVEUil1PgXT/5XaTSiw7T86e534Ca9werp
# F6kWLPpc5GrP7qYdRLChggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDIwMTcx
# MDU4WjAvBgkqhkiG9w0BCQQxIgQgNDOlfvvXjOHAgO+86HC7qmbq0BwzrL88A2d8
# XnOjP+AwDQYJKoZIhvcNAQEBBQAEggIAqHbo3L60auTSabFeESFGZIr+p0eq5up3
# mIV9zm+qeQDtkGx7+efKDbzUeksySDNCYdjsuvvhoFz3V4CFEFsQpbZgGu3K6Zk0
# zyvBNAcYMp8Y5x4EYUo49SRaUzrr0oGE0P2NliiuuJCrcrFa4qLU2JQPfkgWwFtp
# 9+VCyRso+NJtEKwpAv9IDCyFKX9L/JB7v+enaTCYpzpZazOKOl+a2dBgSoyDTuUb
# m3xc2eBt2qHaDOTeEFMVqfos5BohJPh//qcBXXFD+GE1YnoLIptuG2m0ViR/dGYx
# dNYwEoonCi7rDe6T/co54jk/nUWpeCoddY7IsLTMb0d4aYwDEDQMavDV0w8Pb+SC
# GdtWVqpEisCfr7VKXxJoTxXH8W/VbWANZBJTHrBlROCPO1zQ9WjSbIHK/ZGa+ezT
# rNzX6sXw+7llBUUglG+SaEN6qCbD5n2ZCeaBW5aRh43lkKt2hNcCsCoz5o4j6TIL
# CNe1vf/507EJaPfxm3gejRjthdw3fWpw5vmYcLsWys/9+Ef4scZNaiKKpyyySHhK
# 8HR7PAV+UYzuzAGpVjVVurRqnFf4htisSsxGo2xVnr8ABdz7/JagCUBoZBQgtvlj
# kej3Z3DVwRbl3YCK5otT6mTwupeg91hXH6bnj0zMTdqzm/bP04XzvmmK1XBxGpZo
# QykQLiQ8wjk=
# SIG # End signature block
